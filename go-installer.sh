#!/usr/bin/env bash
# =============================================================================
#  go-installer.sh — Instala, atualiza e gerencia o Go (tarball oficial do go.dev)
#  Feito para Debian 13 (Trixie); funciona em outras distros baseadas em Debian.
#  (c) Criado com o apoio do Claude.AI
#
#  Uso rápido (rode como seu usuário normal; o script pede sudo quando precisa):
#     ./go-installer.sh                 # menu interativo
#     ./go-installer.sh install         # instala a última versão estável
#     ./go-installer.sh update          # atualiza para a última versão estável
#     ./go-installer.sh check           # confere se está tudo correto
#     ./go-installer.sh help            # todas as opções
# =============================================================================
set -Eeuo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="${0##*/}"

# ---- Configuração (pode ser sobrescrita por variáveis de ambiente) ----------
readonly GO_DL_URL="${GO_DL_URL:-https://go.dev/dl}"     # origem dos downloads
readonly INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"  # Go fica em $INSTALL_PREFIX/go
readonly GOROOT_DIR="${INSTALL_PREFIX}/go"
readonly PREVIOUS_DIR="${INSTALL_PREFIX}/go.previous"    # versão anterior (rollback)
readonly MIN_FREE_MB=700
readonly MARK_BEGIN="# >>> go-installer >>>"
readonly MARK_END="# <<< go-installer <<<"

# ---- Opções de linha de comando ---------------------------------------------
ASSUME_YES=0
FORCE=0
WANT_VERSION="latest"

# ---- Usuário alvo (quem recebe a configuração do PATH) ----------------------
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    TARGET_USER="$SUDO_USER"
else
    TARGET_USER="$(id -un)"
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
readonly TARGET_USER TARGET_HOME
readonly STATE_DIR="${TARGET_HOME}/.local/state/go-installer"
readonly BACKUP_ROOT="${STATE_DIR}/backups"
readonly LOG_FILE="${STATE_DIR}/go-installer.log"
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
readonly RUN_STAMP
CURRENT_BACKUP_DIR=""   # criado sob demanda, um por execução

# ---- Variáveis preenchidas em tempo de execução -----------------------------
GO_ARCH=""; GO_VERSION=""; GO_FILE=""; GO_SHA=""
TMP_DIR=""; STAGING_DIR=""

# =============================================================================
#  Saída e log
# =============================================================================
if [[ -t 1 ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'
    C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

_log_file() {
    [[ -d "$STATE_DIR" ]] || return 0
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$LOG_FILE" 2>/dev/null || true
}
info()  { printf '%s➜%s %s\n' "$C_BLUE" "$C_RESET" "$*"; _log_file INFO "$*"; }
ok()    { printf '%s✔%s %s\n' "$C_GREEN" "$C_RESET" "$*"; _log_file OK "$*"; }
warn()  { printf '%s⚠%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; _log_file WARN "$*"; }
err()   { printf '%s✘%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; _log_file ERROR "$*"; }
die()   { err "$*"; exit 1; }
title() { printf '\n%s%s== %s ==%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET"; _log_file STEP "$*"; }

confirm() {  # confirm "pergunta" [padrao: n|s]
    local prompt="$1" default="${2:-n}" answer
    if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
    if [[ ! -t 0 ]]; then
        [[ $default == s ]] && return 0
        warn "Sem terminal interativo; respondendo 'não' para: $prompt (use --yes)"
        return 1
    fi
    local hint="[s/N]"; [[ $default == s ]] && hint="[S/n]"
    read -r -p "${C_BOLD}?${C_RESET} ${prompt} ${hint} " answer || answer=""
    answer="${answer:-$default}"
    [[ ${answer,,} =~ ^(s|sim|y|yes)$ ]]
}

# =============================================================================
#  Limpeza e tratamento de erros
# =============================================================================
cleanup() {  # roda na saída; não altera o código de saída do script
    trap - ERR
    set +e
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then rm -rf "$TMP_DIR"; fi
    if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
        run_root rm -rf "$STAGING_DIR" 2>/dev/null
    fi
    fix_state_ownership
}
on_error() {
    err "Falha inesperada na linha $1 (comando: $2). Veja o log em: $LOG_FILE"
}
trap cleanup EXIT
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# =============================================================================
#  Helpers de privilégio
# =============================================================================
# Executa com privilégios de root somente quando o destino exige.
run_root() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    elif [[ -w "$INSTALL_PREFIX" ]]; then
        "$@"                       # prefixo gravável pelo usuário (ex.: ~/.local)
    else
        sudo "$@"
    fi
}

# Executa um comando como o usuário alvo, com ambiente limpo.
run_as_user() {
    if [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]]; then
        # runuser fica em /usr/sbin, que pode não estar no PATH (ex.: após 'su' sem '-').
        local ru
        for ru in "$(command -v runuser 2>/dev/null)" /usr/sbin/runuser /sbin/runuser; do
            [[ -n $ru && -x $ru ]] && { "$ru" -u "$TARGET_USER" -- "$@"; return; }
        done
        sudo -u "$TARGET_USER" -- "$@"
    else
        "$@"
    fi
}

ensure_state_dir() {
    mkdir -p "$BACKUP_ROOT"
    fix_state_ownership
}

fix_state_ownership() {
    if [[ $EUID -eq 0 && "$TARGET_USER" != "root" && -d "$STATE_DIR" ]]; then
        chown -R "$TARGET_USER": "${TARGET_HOME}/.local/state/go-installer" 2>/dev/null || true
        chown "$TARGET_USER": "${TARGET_HOME}/.local" "${TARGET_HOME}/.local/state" 2>/dev/null || true
    fi
}

# =============================================================================
#  Verificações do sistema
# =============================================================================
check_os() {
    local id="" name="" codename=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        id="$(. /etc/os-release; echo "${ID:-}")"
        name="$(. /etc/os-release; echo "${PRETTY_NAME:-}")"
        codename="$(. /etc/os-release; echo "${VERSION_CODENAME:-}")"
    fi
    if [[ $id == debian ]]; then
        ok "Sistema: ${name}"
        [[ $codename == trixie ]] || warn "Feito para o Debian 13 (trixie); detectado: ${codename:-desconhecido}."
    else
        warn "Sistema não é Debian (${name:-desconhecido}). Seguindo mesmo assim."
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   GO_ARCH="amd64" ;;
        aarch64|arm64)  GO_ARCH="arm64" ;;
        armv6l|armv7l)  GO_ARCH="armv6l" ;;
        i386|i686)      GO_ARCH="386" ;;
        ppc64le)        GO_ARCH="ppc64le" ;;
        riscv64)        GO_ARCH="riscv64" ;;
        s390x)          GO_ARCH="s390x" ;;
        *) die "Arquitetura não suportada: $(uname -m)" ;;
    esac
    ok "Arquitetura: linux/${GO_ARCH}"
}

ensure_deps() {
    local -A pkg_for=( [curl]=curl [tar]=tar [gzip]=gzip [jq]=jq [sha256sum]=coreutils )
    local missing=() cmd
    for cmd in "${!pkg_for[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("${pkg_for[$cmd]}")
    done
    [[ -e /etc/ssl/certs/ca-certificates.crt ]] || missing+=("ca-certificates")
    if [[ $EUID -ne 0 && ! -w "$INSTALL_PREFIX" ]] && ! command -v sudo >/dev/null 2>&1; then
        die "O comando 'sudo' não foi encontrado. Instale-o (como root: apt install sudo) ou rode o script como root."
    fi
    if ((${#missing[@]})); then
        mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)
        warn "Dependências ausentes: ${missing[*]}"
        confirm "Instalar agora via apt?" s || die "Instale manualmente: sudo apt install ${missing[*]}"
        if [[ $EUID -eq 0 ]]; then
            apt-get update -qq && apt-get install -y "${missing[@]}"
        else
            sudo apt-get update -qq && sudo apt-get install -y "${missing[@]}"
        fi
    fi
    command -v gcc >/dev/null 2>&1 || \
        warn "gcc não encontrado: pacotes que usam cgo não vão compilar (opcional: sudo apt install build-essential)."
    ok "Dependências presentes"
}

check_free_space() {
    local dir free_mb
    for dir in "$INSTALL_PREFIX" "${TMPDIR:-/tmp}"; do
        free_mb=$(df -Pm "$dir" | awk 'NR==2 {print $4}')
        if (( free_mb < MIN_FREE_MB )); then
            die "Pouco espaço em $dir: ${free_mb} MB livres (mínimo ${MIN_FREE_MB} MB)."
        fi
    done
    ok "Espaço em disco suficiente"
}

check_conflicts() {
    # Go instalado pelo APT conflita com o do tarball (dois 'go' no sistema).
    local pkgs
    pkgs=$(dpkg-query -W -f='${Status} ${Package}\n' 'golang-go' 'golang-[0-9]*-go' 2>/dev/null \
           | awk '$3=="installed" {print $4}' || true)
    if [[ -n $pkgs ]]; then
        warn "Go instalado pelo APT encontrado: $(echo "$pkgs" | tr '\n' ' ')"
        if confirm "Remover esses pacotes para evitar conflito (recomendado)?" s; then
            # shellcheck disable=SC2086
            run_root apt-get remove -y $pkgs
            ok "Pacotes do APT removidos"
        else
            warn "Mantidos. O 'go' que vier primeiro no PATH será usado."
        fi
    fi
}

# =============================================================================
#  Versões e download
# =============================================================================
installed_version() {
    [[ -x "$GOROOT_DIR/bin/go" ]] || return 1
    "$GOROOT_DIR/bin/go" env GOVERSION 2>/dev/null \
        || "$GOROOT_DIR/bin/go" version | awk '{print $3}'
}

version_gt() {  # version_gt a b  -> verdadeiro se a > b
    [[ "$1" != "$2" && "$(printf '%s\n%s\n' "${1#go}" "${2#go}" | sort -V | tail -n1)" == "${1#go}" ]]
}

resolve_release() {  # preenche GO_VERSION, GO_FILE, GO_SHA
    local json url line
    if [[ $WANT_VERSION == latest ]]; then
        url="${GO_DL_URL}/?mode=json"
    else
        url="${GO_DL_URL}/?mode=json&include=all"
    fi
    info "Consultando versões em ${GO_DL_URL} ..."
    json="$(curl -fsSL --retry 3 --connect-timeout 15 "$url")" \
        || die "Não foi possível acessar ${url}. Verifique sua conexão."
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$json" || die "Resposta inesperada do servidor de downloads."

    if [[ $WANT_VERSION == latest ]]; then
        GO_VERSION="$(jq -r '[.[] | select(.stable == true)][0].version // empty' <<<"$json")"
        [[ -n $GO_VERSION ]] || die "Não encontrei nenhuma versão estável na lista."
    else
        GO_VERSION="go${WANT_VERSION#go}"
    fi

    line="$(jq -r --arg v "$GO_VERSION" --arg a "$GO_ARCH" '
        .[] | select(.version == $v) | .files[]
        | select(.os == "linux" and .arch == $a and .kind == "archive")
        | "\(.filename) \(.sha256)"' <<<"$json" | head -n1)"
    [[ -n $line ]] || die "Versão ${GO_VERSION} não encontrada para linux/${GO_ARCH}."
    read -r GO_FILE GO_SHA <<<"$line"
    [[ $GO_FILE =~ ^go[0-9][0-9a-z.]*\.linux-[0-9a-z]+\.tar\.gz$ ]] || die "Nome de arquivo inesperado: $GO_FILE"
    [[ $GO_SHA =~ ^[0-9a-f]{64}$ ]] || die "Checksum inválido recebido para $GO_FILE"
    ok "Versão alvo: ${C_BOLD}${GO_VERSION}${C_RESET} (${GO_FILE})"
}

download_and_verify() {
    TMP_DIR="$(mktemp -d -t go-installer.XXXXXX)"
    info "Baixando ${GO_FILE} ..."
    curl -fL --retry 3 --connect-timeout 15 --progress-bar \
         -o "${TMP_DIR}/${GO_FILE}" "${GO_DL_URL}/${GO_FILE}" \
        || die "Falha no download de ${GO_DL_URL}/${GO_FILE}"
    info "Conferindo SHA-256 ..."
    (cd "$TMP_DIR" && printf '%s  %s\n' "$GO_SHA" "$GO_FILE" | sha256sum -c --status -) \
        || die "Checksum NÃO confere! O arquivo pode estar corrompido ou adulterado."
    ok "Checksum confere (${GO_SHA:0:16}…)"
    # O tarball oficial contém um único diretório 'go/' na raiz.
    if tar -tzf "${TMP_DIR}/${GO_FILE}" | grep -qv '^go/'; then
        die "Estrutura do tarball inesperada (esperado apenas 'go/')."
    fi
    ok "Estrutura do tarball válida"
}

# Extrai em área temporária e só então troca os diretórios (troca quase atômica).
# A instalação atual é preservada em go.previous para permitir rollback.
install_tree() {
    STAGING_DIR="${INSTALL_PREFIX}/.go-installer-staging.$$"
    run_root mkdir -p "$STAGING_DIR"
    info "Extraindo em área temporária ..."
    run_root tar -C "$STAGING_DIR" -xzf "${TMP_DIR}/${GO_FILE}"
    [[ -d "$STAGING_DIR/go" && ! -L "$STAGING_DIR/go" ]] || die "Tarball não contém o diretório 'go/' esperado."

    local staged_ver
    staged_ver="$("$STAGING_DIR/go/bin/go" env GOVERSION 2>/dev/null || true)"
    [[ $staged_ver == "$GO_VERSION" ]] || die "Binário extraído reporta '${staged_ver}', esperado '${GO_VERSION}'."

    if [[ -d "$GOROOT_DIR" ]]; then
        local old; old="$(installed_version || echo desconhecida)"
        run_root rm -rf "$PREVIOUS_DIR"
        run_root mv "$GOROOT_DIR" "$PREVIOUS_DIR"
        ok "Versão anterior (${old}) guardada em ${PREVIOUS_DIR}"
    fi
    run_root mv "$STAGING_DIR/go" "$GOROOT_DIR"
    run_root rmdir "$STAGING_DIR"
    STAGING_DIR=""
    ok "Go ${GO_VERSION} instalado em ${GOROOT_DIR}"
}

# =============================================================================
#  Arquivos de configuração do shell (com backup)
# =============================================================================
rc_files() {  # lista os arquivos de inicialização a configurar
    local f
    echo "${TARGET_HOME}/.profile"              # shells de login e sessão gráfica (sempre)
    # Se existir ~/.bash_profile ou ~/.bash_login, o bash de login ignora o ~/.profile.
    for f in .bash_profile .bash_login .bashrc .zshrc; do
        [[ -f "${TARGET_HOME}/${f}" ]] && echo "${TARGET_HOME}/${f}"
    done
    return 0
}

path_block() {
    # O Go do tarball vai NA FRENTE do PATH (vence um /usr/bin/go antigo do APT);
    # as ferramentas instaladas com 'go install' (~/go/bin) vão no final.
    cat <<EOF
${MARK_BEGIN}
# Gerado por go-installer.sh. Não edite entre os marcadores; rode o script de novo.
case ":\$PATH:" in
    *":${GOROOT_DIR}/bin:"*) ;;
    *) PATH="${GOROOT_DIR}/bin:\$PATH" ;;
esac
case ":\$PATH:" in
    *":\$HOME/go/bin:"*) ;;
    *) PATH="\$PATH:\$HOME/go/bin" ;;
esac
export PATH
${MARK_END}
EOF
}

# Remove o bloco do instalador e linhas em branco do fim do arquivo.
strip_block() {
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        skip    { next }
        { lines[++n] = $0 }
        END {
            while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
            for (i = 1; i <= n; i++) print lines[i]
        }' "$1"
}

backup_file() {  # copia o arquivo para a pasta de backup desta execução
    local file="$1"
    [[ -f "$file" ]] || return 0
    if [[ -z "$CURRENT_BACKUP_DIR" ]]; then
        CURRENT_BACKUP_DIR="${BACKUP_ROOT}/${RUN_STAMP}"
        mkdir -p "$CURRENT_BACKUP_DIR"
    fi
    local dest="${CURRENT_BACKUP_DIR}/$(basename "$file")"
    cp -p "$file" "$dest"
    printf '%s\t%s\n' "$(basename "$file")" "$file" >>"${CURRENT_BACKUP_DIR}/MANIFEST"
    ok "Backup: ${file} → ${dest}"
}

# Escreve o conteúdo novo preservando dono e permissões do arquivo original.
write_preserving() {  # write_preserving origem_tmp destino
    if [[ -f "$2" ]]; then
        cat "$1" >"$2"
    else
        cp "$1" "$2"
        chmod 644 "$2"
        if [[ $EUID -eq 0 && "$TARGET_USER" != root ]]; then chown "$TARGET_USER": "$2"; fi
    fi
}

configure_shell() {
    title "Configurando o PATH"
    local file tmp
    tmp="$(mktemp)"
    while IFS= read -r file; do
        {
            if [[ -f "$file" ]]; then
                strip_block "$file"
                [[ -s "$file" ]] && [[ -n "$(strip_block "$file")" ]] && echo
            fi
            path_block
        } >"$tmp"
        if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then
            ok "$(basename "$file"): já configurado"
            continue
        fi
        backup_file "$file"
        write_preserving "$tmp" "$file"
        ok "$(basename "$file"): PATH configurado"
    done < <(rc_files)
    rm -f "$tmp"
    warn_manual_entries
}

warn_manual_entries() {  # avisa sobre configurações antigas feitas à mão
    local file hits
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        hits="$(awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
            $0 == b { skip = 1; next } $0 == e { skip = 0; next }
            !skip && /(\/usr\/local\/go|GOROOT|go\/bin)/ && !/^[[:space:]]*#/ { printf "    linha %d: %s\n", NR, $0 }' "$file")"
        if [[ -n $hits ]]; then
            warn "$(basename "$file") tem configuração de Go fora do bloco do instalador (revise e remova se for duplicada):"
            printf '%s\n' "$hits" >&2
        fi
    done < <(rc_files)
}

unconfigure_shell() {
    local file tmp
    tmp="$(mktemp)"
    while IFS= read -r file; do
        [[ -f "$file" ]] && grep -qxF "$MARK_BEGIN" "$file" || continue
        strip_block "$file" >"$tmp"
        backup_file "$file"
        write_preserving "$tmp" "$file"
        ok "$(basename "$file"): bloco do Go removido"
    done < <(rc_files)
    rm -f "$tmp"
}

# =============================================================================
#  Verificação completa
# =============================================================================
verify_install() {  # verify_install [versao_esperada]
    local expected="${1:-}" fails=0 v goroot found tdir out file

    _pass() { printf '  %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$1"; _log_file CHECK "OK: $1"; }
    _fail() { printf '  %s✘%s %s\n' "$C_RED" "$C_RESET" "$1"; _log_file CHECK "FALHA: $1"; fails=$((fails + 1)); }

    title "Conferindo a instalação"

    if [[ -x "$GOROOT_DIR/bin/go" ]]; then _pass "Binário em ${GOROOT_DIR}/bin/go"
    else _fail "Binário ${GOROOT_DIR}/bin/go não encontrado"; return 1; fi

    v="$(installed_version || true)"
    if [[ -z $expected || $v == "$expected" ]]; then _pass "Versão: ${v}"
    else _fail "Versão ${v} (esperado ${expected})"; fi

    goroot="$("$GOROOT_DIR/bin/go" env GOROOT 2>/dev/null || true)"
    if [[ $goroot == "$GOROOT_DIR" ]]; then _pass "GOROOT = ${goroot}"
    else _fail "GOROOT = '${goroot}' (esperado ${GOROOT_DIR})"; fi

    while IFS= read -r file; do
        if [[ -f "$file" ]] && grep -qxF "$MARK_BEGIN" "$file" && grep -qxF "$MARK_END" "$file"; then
            _pass "PATH configurado em $(basename "$file")"
        else
            _fail "Bloco do PATH ausente em ${file}"
        fi
    done < <(rc_files)

    # Novo shell de login do usuário, com ambiente limpo, deve achar o 'go' correto.
    found="$(run_as_user env -i HOME="$TARGET_HOME" USER="$TARGET_USER" PATH=/usr/local/bin:/usr/bin:/bin \
             bash -lc 'command -v go' 2>/dev/null || true)"
    if [[ $found == "$GOROOT_DIR/bin/go" ]]; then _pass "Novo shell de login encontra ${found}"
    else _fail "Novo shell de login encontra '${found:-nada}' (esperado ${GOROOT_DIR}/bin/go)"; fi

    if [[ -f "${TARGET_HOME}/.bashrc" ]]; then
        found="$(run_as_user env -i HOME="$TARGET_HOME" USER="$TARGET_USER" PATH=/usr/local/bin:/usr/bin:/bin TERM=dumb \
                 bash -ic 'command -v go' 2>/dev/null | tail -n1 || true)"
        if [[ $found == "$GOROOT_DIR/bin/go" ]]; then _pass "Terminal interativo (bash) encontra ${found}"
        else _fail "Terminal interativo encontra '${found:-nada}' (esperado ${GOROOT_DIR}/bin/go)"; fi
    fi

    # Compila e roda um programa de teste em um diretório isolado (não toca na sua $HOME).
    tdir="$(mktemp -d -t go-installer-test.XXXXXX)"
    cat >"$tdir/main.go" <<'EOF'
package main

import (
	"fmt"
	"runtime"
)

func main() { fmt.Printf("ok %s %s/%s\n", runtime.Version(), runtime.GOOS, runtime.GOARCH) }
EOF
    out="$(cd "$tdir" && env -i HOME="$tdir" PATH="$GOROOT_DIR/bin:/usr/bin:/bin" \
           GOCACHE="$tdir/cache" GOPATH="$tdir/gopath" GOTOOLCHAIN=local GOFLAGS=-modcacherw CGO_ENABLED=0 \
           "$GOROOT_DIR/bin/go" run main.go 2>&1 || true)"
    rm -rf "$tdir"
    if [[ $out == "ok ${v} linux/"* ]]; then _pass "Programa de teste compilou e rodou (${out#ok })"
    else _fail "Programa de teste falhou: ${out}"; fi

    if [[ -d "$PREVIOUS_DIR" ]]; then
        printf '  %sℹ%s Versão anterior disponível para rollback: %s\n' "$C_CYAN" "$C_RESET" \
            "$("$PREVIOUS_DIR/bin/go" env GOVERSION 2>/dev/null || echo '?')"
    fi

    if (( fails == 0 )); then
        ok "Tudo certo! (${v})"
        return 0
    fi
    err "${fails} verificação(ões) falharam."
    return 1
}

# =============================================================================
#  Comandos
# =============================================================================
preflight() {
    title "Verificando o sistema"
    ensure_state_dir
    _log_file INFO "=== ${SCRIPT_NAME} v${SCRIPT_VERSION} — usuário alvo: ${TARGET_USER} ==="
    check_os
    detect_arch
    ensure_deps
    check_free_space
}

finish_message() {
    printf '\n%sPronto!%s Para usar o Go neste terminal agora, rode:\n' "$C_BOLD" "$C_RESET"
    printf '    %ssource ~/.profile%s   (ou abra um novo terminal)\n' "$C_CYAN" "$C_RESET"
    printf 'Apps abertos pelo menu (ex.: VS Code) só enxergam o novo PATH depois de sair e entrar na sessão.\n'
    if [[ -n $CURRENT_BACKUP_DIR ]]; then
        printf 'Backups dos arquivos alterados: %s\n' "$CURRENT_BACKUP_DIR"
    fi
}

cmd_install() {
    preflight
    local cur
    if cur="$(installed_version)"; then
        warn "Já existe um Go em ${GOROOT_DIR} (${cur})."
        if [[ $FORCE -eq 0 ]]; then
            info "Use '${SCRIPT_NAME} update' para atualizar, ou 'install --force' para reinstalar."
            configure_shell
            verify_install "$cur" || true
            return 0
        fi
    fi
    check_conflicts
    title "Baixando o Go"
    resolve_release
    download_and_verify
    title "Instalando"
    install_tree
    configure_shell
    if ! verify_install "$GO_VERSION"; then
        err "A instalação não passou na verificação."
        [[ -d "$PREVIOUS_DIR" ]] && confirm "Restaurar a versão anterior?" s && do_rollback
        exit 1
    fi
    finish_message
}

cmd_update() {
    preflight
    local cur
    cur="$(installed_version)" || die "Go não está instalado em ${GOROOT_DIR}. Use '${SCRIPT_NAME} install'."
    info "Versão instalada: ${C_BOLD}${cur}${C_RESET}"
    title "Procurando atualização"
    resolve_release
    if [[ $cur == "$GO_VERSION" && $FORCE -eq 0 ]]; then
        ok "Você já está na versão mais recente (${cur})."
        return 0
    fi
    if version_gt "$cur" "$GO_VERSION" && [[ $FORCE -eq 0 ]]; then
        warn "A versão instalada (${cur}) é mais nova que a alvo (${GO_VERSION}). Use --force para fazer downgrade."
        return 0
    fi
    confirm "Atualizar ${cur} → ${GO_VERSION}?" s || { info "Cancelado."; return 0; }
    check_conflicts
    download_and_verify
    title "Atualizando"
    install_tree
    configure_shell
    if ! verify_install "$GO_VERSION"; then
        err "A nova versão não passou na verificação. Voltando para ${cur} ..."
        do_rollback
        exit 1
    fi
    printf '\n'
    info "Dica: ferramentas em ~/go/bin (gopls, dlv…) continuam funcionando, mas é bom"
    info "recompilá-las com a nova versão: ${SCRIPT_NAME} tools"
    finish_message
}

cmd_check() {
    ensure_state_dir
    detect_arch
    local cur
    cur="$(installed_version)" || die "Go não está instalado em ${GOROOT_DIR}."
    verify_install "$cur" || exit 1
    title "Atualizações"
    local latest
    latest="$(resolve_release >/dev/null 2>&1 && printf '%s' "$GO_VERSION")" || latest=""
    if [[ -n $latest ]]; then
        if version_gt "$latest" "$cur"; then
            warn "Nova versão disponível: ${latest}. Rode: ${SCRIPT_NAME} update"
        else
            ok "Nenhuma atualização disponível."
        fi
    else
        warn "Não foi possível consultar a última versão (sem conexão?)."
    fi
}

do_rollback() {
    [[ -d "$PREVIOUS_DIR" ]] || die "Não há versão anterior em ${PREVIOUS_DIR}."
    local prev cur
    prev="$("$PREVIOUS_DIR/bin/go" env GOVERSION 2>/dev/null || echo '?')"
    cur="$(installed_version || echo nenhuma)"
    info "Trocando ${cur} ⇄ ${prev} ..."
    if [[ -d "$GOROOT_DIR" ]]; then
        run_root mv "$GOROOT_DIR" "${GOROOT_DIR}.swap.$$"
        run_root mv "$PREVIOUS_DIR" "$GOROOT_DIR"
        run_root mv "${GOROOT_DIR}.swap.$$" "$PREVIOUS_DIR"
    else
        run_root mv "$PREVIOUS_DIR" "$GOROOT_DIR"
    fi
    ok "Versão ativa agora: ${prev} (a ${cur} ficou em ${PREVIOUS_DIR})"
}

cmd_rollback() {
    ensure_state_dir
    title "Rollback"
    confirm "Voltar para a versão anterior do Go?" s || { info "Cancelado."; return 0; }
    do_rollback
    verify_install "$(installed_version)" || exit 1
}

cmd_uninstall() {
    ensure_state_dir
    title "Desinstalação"
    [[ -d "$GOROOT_DIR" || -d "$PREVIOUS_DIR" ]] || warn "Nenhuma instalação encontrada em ${GOROOT_DIR}."
    confirm "Remover ${GOROOT_DIR} (e ${PREVIOUS_DIR}) e a configuração do PATH?" n || { info "Cancelado."; return 0; }
    run_root rm -rf "$GOROOT_DIR" "$PREVIOUS_DIR"
    ok "Arquivos do Go removidos"
    unconfigure_shell
    info "Seus projetos e módulos em ${TARGET_HOME}/go foram mantidos."
    info "Para apagar também o cache de módulos: rm -rf ~/go ~/.cache/go-build"
    if [[ -n $CURRENT_BACKUP_DIR ]]; then info "Backups dos arquivos alterados: ${CURRENT_BACKUP_DIR}"; fi
}

cmd_backups() {  # backups [list|restore [carimbo]]
    ensure_state_dir
    local action="${1:-list}" stamp="${2:-}" dir name dest
    case "$action" in
        list)
            title "Backups de configuração (${BACKUP_ROOT})"
            if ! compgen -G "${BACKUP_ROOT}/*/MANIFEST" >/dev/null; then
                info "Nenhum backup encontrado."; return 0
            fi
            for dir in "${BACKUP_ROOT}"/*/; do
                [[ -f "${dir}MANIFEST" ]] || continue
                printf '  %s%s%s  %s\n' "$C_BOLD" "$(basename "$dir")" "$C_RESET" \
                    "$(cut -f1 "${dir}MANIFEST" | sort -u | tr '\n' ' ')"
            done
            info "Para restaurar: ${SCRIPT_NAME} backups restore [carimbo]"
            ;;
        restore)
            if [[ -z $stamp ]]; then
                stamp="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | tail -n1)"
            fi
            dir="${BACKUP_ROOT}/${stamp}"
            [[ -n $stamp && -f "${dir}/MANIFEST" ]] || die "Backup '${stamp}' não encontrado. Veja: ${SCRIPT_NAME} backups list"
            title "Restaurando backup ${stamp}"
            sort -u "${dir}/MANIFEST" | while IFS=$'\t' read -r name dest; do
                echo "    ${dest}"
            done
            confirm "Restaurar esses arquivos? (o estado atual também ganha um backup)" n || { info "Cancelado."; return 0; }
            sort -u "${dir}/MANIFEST" | while IFS=$'\t' read -r name dest; do
                [[ -f "$dest" ]] && cp -p "$dest" "${dest}.antes-restauracao-${RUN_STAMP}"
                cat "${dir}/${name}" >"$dest"
                ok "Restaurado: ${dest} (estado anterior em ${dest}.antes-restauracao-${RUN_STAMP})"
            done
            ;;
        *) die "Uso: ${SCRIPT_NAME} backups [list|restore [carimbo]]" ;;
    esac
}

cmd_tools() {
    ensure_state_dir
    installed_version >/dev/null || die "Instale o Go primeiro: ${SCRIPT_NAME} install"
    title "Instalando ferramentas de desenvolvimento em ${TARGET_HOME}/go/bin"
    local -a tools=(
        "golang.org/x/tools/gopls@latest"                              # language server (editores)
        "github.com/go-delve/delve/cmd/dlv@latest"                     # debugger
        "golang.org/x/tools/cmd/goimports@latest"                      # formata + organiza imports
        "honnef.co/go/tools/cmd/staticcheck@latest"                    # análise estática
        "golang.org/x/vuln/cmd/govulncheck@latest"                     # vulnerabilidades
        "github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest" # meta-linter
    )
    local t fails=0
    for t in "${tools[@]}"; do
        info "go install ${t}"
        if run_as_user env HOME="$TARGET_HOME" PATH="$GOROOT_DIR/bin:/usr/local/bin:/usr/bin:/bin" \
                "$GOROOT_DIR/bin/go" install "$t"; then
            ok "${t%@*}"
        else
            err "Falhou: ${t}"; fails=$((fails + 1))
        fi
    done
    (( fails == 0 )) && ok "Ferramentas instaladas." || warn "${fails} ferramenta(s) falharam."
}

usage() {
    cat <<EOF
${C_BOLD}${SCRIPT_NAME} v${SCRIPT_VERSION}${C_RESET} — instala e gerencia o Go a partir do tarball oficial

${C_BOLD}Uso:${C_RESET} ${SCRIPT_NAME} [comando] [opções]

${C_BOLD}Comandos:${C_RESET}
  install            Instala a última versão estável (ou a de --version)
  update             Atualiza para a última versão estável (mantém a anterior p/ rollback)
  check              Confere instalação, PATH, compilação e se há atualização
  rollback           Volta para a versão anterior (go.previous)
  uninstall          Remove o Go e o bloco de PATH (mantém ~/go)
  backups [list]     Lista os backups dos arquivos de configuração
  backups restore [carimbo]
                     Restaura um backup (o mais recente se omitido)
  tools              Instala/atualiza gopls, dlv, goimports, staticcheck,
                     govulncheck e golangci-lint
  help               Mostra esta ajuda
  (sem comando)      Abre o menu interativo

${C_BOLD}Opções:${C_RESET}
  -v, --version X    Versão específica (ex.: 1.25.3) para install/update
  -f, --force        Reinstala mesmo se já estiver na versão / permite downgrade
  -y, --yes          Responde "sim" a todas as perguntas (modo não interativo)
  -h, --help         Mostra esta ajuda

${C_BOLD}Arquivos:${C_RESET}
  Go:        ${GOROOT_DIR}   (anterior: ${PREVIOUS_DIR})
  Backups:   ${BACKUP_ROOT}/<data-hora>/
  Log:       ${LOG_FILE}

Rode como seu usuário normal: o script usa sudo apenas onde é necessário.
EOF
}

menu() {
    local cur; cur="$(installed_version 2>/dev/null || echo 'não instalado')"
    printf '%s%sInstalador do Go%s  —  versão atual: %s%s%s\n\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_BOLD" "$cur" "$C_RESET"
    local options=("Instalar" "Atualizar" "Conferir instalação" "Instalar ferramentas (gopls, dlv…)" \
                   "Rollback para a versão anterior" "Listar backups" "Desinstalar" "Sair")
    local PS3=$'\n'"Escolha uma opção: "
    select opt in "${options[@]}"; do
        case "$REPLY" in
            1) cmd_install; break ;;
            2) cmd_update; break ;;
            3) cmd_check; break ;;
            4) cmd_tools; break ;;
            5) cmd_rollback; break ;;
            6) cmd_backups list; break ;;
            7) cmd_uninstall; break ;;
            8) break ;;
            *) echo "Opção inválida." ;;
        esac
    done
}

# =============================================================================
#  Main
# =============================================================================
main() {
    local cmd="" args=()
    while (($#)); do
        case "$1" in
            -y|--yes)     ASSUME_YES=1 ;;
            -f|--force)   FORCE=1 ;;
            -v|--version) [[ -n "${2:-}" ]] || die "--version precisa de um valor (ex.: 1.25.3)"
                          WANT_VERSION="$2"; shift ;;
            --version=*)  WANT_VERSION="${1#*=}" ;;
            -h|--help|help) usage; exit 0 ;;
            -*)           die "Opção desconhecida: $1 (veja: ${SCRIPT_NAME} help)" ;;
            *)            if [[ -z $cmd ]]; then cmd="$1"; else args+=("$1"); fi ;;
        esac
        shift
    done
    if [[ $WANT_VERSION != latest && ! ${WANT_VERSION#go} =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?((rc|beta)[0-9]+)?$ ]]; then
        die "Versão inválida: ${WANT_VERSION}"
    fi
    [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "Não encontrei a pasta pessoal de ${TARGET_USER}."
    if [[ $EUID -eq 0 && "$TARGET_USER" == root ]]; then
        warn "Rodando como root puro: o PATH será configurado para o root. Prefira rodar como seu usuário."
    fi

    case "$cmd" in
        "")         if [[ -t 0 ]]; then menu; else usage; fi ;;
        install)    cmd_install ;;
        update)     cmd_update ;;
        check)      cmd_check ;;
        rollback)   cmd_rollback ;;
        uninstall)  cmd_uninstall ;;
        backups)    cmd_backups "${args[@]}" ;;
        tools)      cmd_tools ;;
        *)          die "Comando desconhecido: ${cmd} (veja: ${SCRIPT_NAME} help)" ;;
    esac
}

main "$@"
