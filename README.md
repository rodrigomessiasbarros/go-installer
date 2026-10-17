# go-installer

Script em Bash que instala, atualiza e gerencia a linguagem **Go** a partir do **tarball oficial** do [go.dev](https://go.dev/dl/), em vez da versão (geralmente mais antiga) dos repositórios da distribuição.

Feito para o **Debian 13 (Trixie)** e compatível com outras distribuições baseadas em Debian.

```bash
./go-installer.sh install   # instala a última versão estável
./go-installer.sh update    # atualiza quando sair uma versão nova
./go-installer.sh check     # confere se está tudo certo
```

---

## Recursos

- **Sempre a versão estável mais recente**, consultada direto no go.dev, ou uma versão específica com `--version`.
- **Download verificado:** confere o SHA-256 oficial e a estrutura do tarball antes de instalar qualquer coisa.
- **Troca segura:** extrai numa área temporária e só então substitui a instalação. A versão anterior fica guardada para rollback.
- **Rollback automático:** se a nova versão falhar na conferência pós-instalação, o script volta sozinho para a anterior.
- **PATH configurado automaticamente** no `~/.profile`, no `~/.bashrc` e, se existirem, no `~/.bash_profile` e no `~/.zshrc`. Pode rodar quantas vezes quiser sem duplicar nada.
- **Backup dos arquivos de configuração** antes de qualquer alteração, com comando para restaurar.
- **Conferência completa:** versão, `GOROOT`, PATH em shells novos (login e interativo) e um programa de teste compilado e executado.
- **Detecta conflitos** com o Go instalado pelo APT e com configurações antigas feitas à mão.
- **Menu interativo** quando executado sem argumentos.
- **Ferramentas de desenvolvimento** com um comando: gopls, Delve, goimports, staticcheck, govulncheck e golangci-lint.

## Requisitos

- Debian 13 (ou derivado) em `amd64`, `arm64`, `armv6l`, `386`, `ppc64le`, `riscv64` ou `s390x`
- `sudo` (para gravar em `/usr/local`)
- `curl`, `tar`, `gzip`, `jq` e `ca-certificates`. Se faltar algum, o script oferece instalar via `apt`.
- Opcional: `build-essential`, para compilar pacotes que usam cgo

## Instalação

```bash
git clone https://github.com/SEU-USUARIO/go-installer.git
cd go-installer
chmod +x go-installer.sh
./go-installer.sh install
```

Ou baixe só o script:

```bash
curl -fsSLO https://raw.githubusercontent.com/SEU-USUARIO/go-installer/main/go-installer.sh
chmod +x go-installer.sh
./go-installer.sh install
```

> **Rode como seu usuário normal**, não como root. O script usa `sudo` só nos passos que precisam e configura o PATH para o seu usuário. Com `sudo ./go-installer.sh` também funciona: o PATH vai para quem chamou o `sudo`.

Ao terminar, carregue o novo PATH:

```bash
source ~/.profile    # ou abra um novo terminal
go version
```

Programas abertos pelo menu do sistema (como o VS Code) só enxergam o novo PATH depois que você sair e entrar na sessão.

## Uso

```
./go-installer.sh [comando] [opções]
```

| Comando | Descrição |
|---|---|
| *(sem comando)* | Abre o menu interativo |
| `install` | Instala a última versão estável (ou a de `--version`) |
| `update` | Atualiza para a última versão estável, mantendo a anterior para rollback |
| `check` | Confere a instalação e avisa se há versão nova |
| `rollback` | Volta para a versão anterior |
| `uninstall` | Remove o Go e o bloco do PATH (mantém `~/go`) |
| `backups` | Lista os backups dos arquivos de configuração |
| `backups restore [carimbo]` | Restaura um backup (o mais recente, se omitido) |
| `tools` | Instala ou atualiza as ferramentas de desenvolvimento |
| `help` | Mostra a ajuda |

| Opção | Descrição |
|---|---|
| `-v`, `--version X` | Versão específica, por exemplo `1.25.3` |
| `-f`, `--force` | Reinstala mesmo na mesma versão, ou permite downgrade |
| `-y`, `--yes` | Responde "sim" a todas as perguntas (modo não interativo) |
| `-h`, `--help` | Mostra a ajuda |

### Exemplos

```bash
# Instalar uma versão específica
./go-installer.sh install --version 1.25.3

# Atualizar sem perguntas (bom para automação)
./go-installer.sh update -y

# Voltar para a versão anterior
./go-installer.sh rollback

# Instalar gopls, dlv, goimports, staticcheck, govulncheck e golangci-lint
./go-installer.sh tools
```

## O que o script altera

| Item | Local |
|---|---|
| Go instalado | `/usr/local/go` |
| Versão anterior (rollback) | `/usr/local/go.previous` |
| Bloco do PATH | `~/.profile`, `~/.bashrc` e, se existirem, `~/.bash_profile` e `~/.zshrc` |
| Backups das configurações | `~/.local/state/go-installer/backups/<data-hora>/` |
| Log | `~/.local/state/go-installer/go-installer.log` |
| Ferramentas (`tools`) | `~/go/bin` |

O bloco adicionado aos arquivos do shell fica entre marcadores, para o script poder atualizá-lo ou removê-lo sem tocar no resto do arquivo:

```bash
# >>> go-installer >>>
# Gerado por go-installer.sh. Não edite entre os marcadores; rode o script de novo.
case ":$PATH:" in
    *":/usr/local/go/bin:"*) ;;
    *) PATH="/usr/local/go/bin:$PATH" ;;
esac
case ":$PATH:" in
    *":$HOME/go/bin:"*) ;;
    *) PATH="$PATH:$HOME/go/bin" ;;
esac
export PATH
# <<< go-installer <<<
```

O Go do tarball entra **na frente** do PATH, para vencer um `/usr/bin/go` antigo do APT. Já o `~/go/bin` entra no final, para que ferramentas instaladas com `go install` não sobreponham comandos do sistema.

## Backups e restauração

Antes de alterar qualquer arquivo de configuração, o script copia o original para uma pasta com a data e a hora da execução. Só faz backup quando algo realmente muda.

```bash
./go-installer.sh backups                          # lista
./go-installer.sh backups restore                  # restaura o mais recente
./go-installer.sh backups restore 20261017-150613  # restaura um específico
```

Ao restaurar, o estado atual de cada arquivo também é preservado, como `arquivo.antes-restauracao-<data-hora>`.

## Variáveis de ambiente

| Variável | Padrão | Uso |
|---|---|---|
| `INSTALL_PREFIX` | `/usr/local` | Pasta onde o Go é instalado (em `$INSTALL_PREFIX/go`). Se for gravável pelo usuário, como `~/.local`, o script não usa `sudo`. |
| `GO_DL_URL` | `https://go.dev/dl` | Origem dos downloads, útil para espelhos internos |

```bash
# Instalação só para o seu usuário, sem sudo
INSTALL_PREFIX="$HOME/.local" ./go-installer.sh install
```

Use o mesmo `INSTALL_PREFIX` em todos os comandos seguintes (`update`, `check` etc.).

## Desinstalação

```bash
./go-installer.sh uninstall
```

Remove `/usr/local/go`, `/usr/local/go.previous` e o bloco do PATH, com backup dos arquivos alterados. Seus projetos e o cache de módulos em `~/go` são mantidos. Para apagá-los também:

```bash
rm -rf ~/go ~/.cache/go-build
```

## Solução de problemas

**`go: command not found` logo após instalar**
O terminal atual ainda usa o PATH antigo. Rode `source ~/.profile` ou abra um novo terminal.

**O script avisa sobre "configuração de Go fora do bloco do instalador"**
Há uma linha antiga, feita à mão, mexendo no PATH ou no `GOROOT`. O script mostra o arquivo e a linha. Revise e apague se for duplicada. Em geral, não é preciso definir `GOROOT`.

**O editor não encontra o `go`**
Saia e entre de novo na sessão gráfica. No VS Code, rode depois *Go: Install/Update Tools*.

**Algo deu errado**
Veja o log em `~/.local/state/go-installer/go-installer.log`, rode `./go-installer.sh check` e, se precisar, `./go-installer.sh rollback`.

---

(c) Criado com o apoio do Claude.AI
