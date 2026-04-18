#!/usr/bin/env bash
# DuFrogComands - instalador de ferramentas de pentest
# Uso: ./install.sh [--minimal | --full | --list | --help]

set -euo pipefail

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

MODE="full"
IS_WSL=0
DISTRO_PRETTY=""

# Conjuntos lógicos de ferramentas (nomes usados para `have`/summary).
TOOLS_CORE=(nmap ffuf gobuster sqlmap jq curl http)
TOOLS_EXTRA=(hydra hashcat john socat chisel tcpdump wireshark node)

usage() {
    cat <<EOF
DuFrogComands - instalador de ferramentas de pentest

Uso: ./install.sh [opção]

Opções:
  --minimal   Instala apenas o conjunto CORE: ${TOOLS_CORE[*]}
  --full      Instala CORE + EXTRA (padrão): ${TOOLS_EXTRA[*]}
  --list      Mostra os conjuntos e sai
  -h, --help  Mostra esta ajuda
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --minimal) MODE="minimal" ;;
            --full)    MODE="full" ;;
            --list)    MODE="list" ;;
            -h|--help) usage; exit 0 ;;
            *) err "Opção desconhecida: $1"; usage; exit 2 ;;
        esac
        shift
    done
}

detect_os() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        DISTRO_PRETTY="macOS $(sw_vers -productVersion 2>/dev/null || echo '?')"
        echo "macos"; return
    fi
    if grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null; then
        IS_WSL=1
    fi
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO_PRETTY="${PRETTY_NAME:-${NAME:-$ID} ${VERSION_ID:-}}"
        case "${ID_LIKE:-$ID}" in
            *debian*|*ubuntu*) echo "debian"; return ;;
            *arch*)            echo "arch"; return ;;
            *fedora*|*rhel*)   echo "fedora"; return ;;
        esac
        case "$ID" in
            debian|ubuntu|kali|parrot) echo "debian"; return ;;
            arch|manjaro)              echo "arch"; return ;;
            fedora|rhel|centos)        echo "fedora"; return ;;
        esac
    fi
    echo "unknown"
}

have() { command -v "$1" >/dev/null 2>&1; }

sudo_run() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

ensure_local_bin_in_path() {
    mkdir -p "$HOME/.local/bin"
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) : ;;
        *)
            export PATH="$HOME/.local/bin:$PATH"
            local rc="$HOME/.bashrc"
            [[ "${SHELL:-}" == */zsh ]] && rc="$HOME/.zshrc"
            if ! grep -q '.local/bin' "$rc" 2>/dev/null; then
                echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
                ok "Adicionado ~/.local/bin ao PATH em $rc"
            fi
            ;;
    esac
    hash -r
}

# ---------- macOS ----------

install_macos() {
    if ! have brew; then
        log "Instalando Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    log "Atualizando Homebrew..."
    brew update

    local core=(nmap ffuf gobuster sqlmap jq curl httpie)
    local extra=(hydra hashcat john socat chisel tcpdump nvm)
    local -a formulas=("${core[@]}")
    [[ "$MODE" == "full" ]] && formulas+=("${extra[@]}")

    for f in "${formulas[@]}"; do
        if brew list --formula "$f" >/dev/null 2>&1; then
            ok "$f já instalado"
        else
            log "Instalando $f..."
            brew install "$f" || warn "Falha ao instalar $f"
        fi
    done

    if [[ "$MODE" == "full" ]]; then
        if brew list --cask wireshark >/dev/null 2>&1; then
            ok "wireshark já instalado"
        else
            log "Instalando wireshark (cask)..."
            brew install --cask wireshark || warn "Falha ao instalar wireshark"
        fi
        setup_nvm_macos
    fi
}

setup_nvm_macos() {
    local nvm_prefix
    nvm_prefix="$(brew --prefix nvm 2>/dev/null || echo /opt/homebrew/opt/nvm)"
    mkdir -p "$HOME/.nvm"
    local rc="$HOME/.zshrc"
    [[ -n "${BASH_VERSION:-}" ]] && rc="$HOME/.bashrc"
    if ! grep -q 'NVM_DIR' "$rc" 2>/dev/null; then
        {
            echo ''
            echo '# nvm (DuFrogComands)'
            echo 'export NVM_DIR="$HOME/.nvm"'
            echo "[ -s \"$nvm_prefix/nvm.sh\" ] && . \"$nvm_prefix/nvm.sh\""
            echo "[ -s \"$nvm_prefix/etc/bash_completion.d/nvm\" ] && . \"$nvm_prefix/etc/bash_completion.d/nvm\""
        } >> "$rc"
        ok "nvm configurado em $rc"
    else
        ok "nvm já configurado em $rc"
    fi
}

# ---------- Debian/Ubuntu/WSL ----------

install_debian() {
    log "Atualizando apt..."
    sudo_run apt-get update -y

    local core=(nmap ffuf sqlmap jq curl httpie golang-go git ca-certificates)
    local extra=(hydra hashcat john socat tcpdump wireshark build-essential)
    local -a pkgs=("${core[@]}")
    if [[ "$MODE" == "full" ]]; then
        pkgs+=("${extra[@]}")
        log "Pré-aceitando prompt do wireshark-common (non-root capture)..."
        echo "wireshark-common wireshark-common/install-setuid boolean true" \
            | sudo_run debconf-set-selections
    fi

    log "Instalando pacotes via apt..."
    DEBIAN_FRONTEND=noninteractive sudo_run apt-get install -y "${pkgs[@]}" \
        || warn "Alguns pacotes falharam"

    install_gobuster_go
    if [[ "$MODE" == "full" ]]; then
        install_chisel_go
        setup_wireshark_group
        setup_nvm_linux
    fi
}

# ---------- Arch ----------

install_arch() {
    log "Atualizando pacman..."
    sudo_run pacman -Sy --noconfirm

    local core=(nmap ffuf gobuster sqlmap jq curl httpie go git)
    local extra=(hydra hashcat john socat tcpdump wireshark-qt base-devel)
    local -a pkgs=("${core[@]}")
    [[ "$MODE" == "full" ]] && pkgs+=("${extra[@]}")

    log "Instalando pacotes via pacman..."
    sudo_run pacman -S --needed --noconfirm "${pkgs[@]}" || warn "Alguns pacotes falharam"

    if [[ "$MODE" == "full" ]]; then
        install_chisel_go
        setup_wireshark_group
        setup_nvm_linux
    fi
}

# ---------- Fedora ----------

install_fedora() {
    log "Instalando via dnf..."
    local core=(nmap sqlmap jq curl httpie golang git)
    local extra=(hydra hashcat john socat tcpdump wireshark)
    local -a pkgs=("${core[@]}")
    [[ "$MODE" == "full" ]] && pkgs+=("${extra[@]}")

    sudo_run dnf install -y "${pkgs[@]}" || warn "Alguns pacotes falharam"

    install_gobuster_go
    install_ffuf_go
    if [[ "$MODE" == "full" ]]; then
        install_chisel_go
        setup_wireshark_group
        setup_nvm_linux
    fi
}

# ---------- Go-based installs ----------

install_gobuster_go() {
    if have gobuster; then ok "gobuster já instalado"; return; fi
    if ! have go; then warn "go não disponível, pulando gobuster"; return; fi
    log "Instalando gobuster via go install..."
    if GOBIN="$HOME/.local/bin" go install github.com/OJ/gobuster/v3@latest; then
        hash -r
        ok "gobuster em ~/.local/bin"
    else
        warn "Falha ao instalar gobuster"
    fi
}

install_ffuf_go() {
    if have ffuf; then ok "ffuf já instalado"; return; fi
    if ! have go; then warn "go não disponível, pulando ffuf"; return; fi
    log "Instalando ffuf via go install..."
    if GOBIN="$HOME/.local/bin" go install github.com/ffuf/ffuf/v2@latest; then
        hash -r
        ok "ffuf em ~/.local/bin"
    else
        warn "Falha ao instalar ffuf"
    fi
}

install_chisel_go() {
    if have chisel; then ok "chisel já instalado"; return; fi
    if ! have go; then warn "go não disponível, pulando chisel"; return; fi
    log "Instalando chisel via go install..."
    if GOBIN="$HOME/.local/bin" go install github.com/jpillora/chisel@latest; then
        hash -r
        ok "chisel em ~/.local/bin"
    else
        warn "Falha ao instalar chisel"
    fi
}

# ---------- Linux extras ----------

setup_wireshark_group() {
    if ! have wireshark && ! have dumpcap; then
        warn "wireshark não detectado, pulando setup de grupo"
        return
    fi
    if ! getent group wireshark >/dev/null 2>&1; then
        log "Criando grupo wireshark..."
        sudo_run groupadd -r wireshark || warn "Falha ao criar grupo wireshark"
    fi
    if id -nG "$USER" | tr ' ' '\n' | grep -qx wireshark; then
        ok "usuário $USER já está no grupo wireshark"
    else
        log "Adicionando $USER ao grupo wireshark..."
        sudo_run usermod -aG wireshark "$USER" \
            && ok "adicionado ao grupo wireshark (re-login necessário)" \
            || warn "Falha ao adicionar usuário ao grupo wireshark"
    fi
}

setup_nvm_linux() {
    if [[ -d "$HOME/.nvm" ]]; then
        ok "nvm já presente em ~/.nvm"
    else
        log "Instalando nvm..."
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash \
            || warn "Falha ao instalar nvm"
    fi
    export NVM_DIR="$HOME/.nvm"
    # shellcheck disable=SC1091
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    if have nvm; then
        log "Instalando node LTS via nvm..."
        nvm install --lts >/dev/null && ok "node LTS instalado"
    fi
}

# ---------- Summary ----------

summary() {
    echo
    log "Verificando instalações (modo: $MODE):"
    local -a tools=("${TOOLS_CORE[@]}")
    [[ "$MODE" == "full" ]] && tools+=("${TOOLS_EXTRA[@]}")
    for t in "${tools[@]}"; do
        if have "$t"; then
            ok "$t -> $(command -v "$t")"
        else
            warn "$t NÃO encontrado"
        fi
    done
    echo
    log "Abra um novo terminal (ou faça 'source' do rc) para carregar nvm/PATH."
    [[ "$MODE" == "full" ]] && log "Após sair/reentrar, o grupo wireshark será aplicado."
}

main() {
    parse_args "$@"

    if [[ "$MODE" == "list" ]]; then
        echo "CORE:  ${TOOLS_CORE[*]}"
        echo "EXTRA: ${TOOLS_EXTRA[*]}"
        exit 0
    fi

    local os
    os="$(detect_os)"

    if [[ "$IS_WSL" -eq 1 ]]; then
        log "WSL detectado (base: ${DISTRO_PRETTY:-Debian/Ubuntu})"
    else
        log "SO detectado: ${DISTRO_PRETTY:-$os}"
    fi
    log "Modo: $MODE"

    ensure_local_bin_in_path

    case "$os" in
        macos)   install_macos ;;
        debian)  install_debian ;;
        arch)    install_arch ;;
        fedora)  install_fedora ;;
        *)
            err "SO não suportado automaticamente. Abra uma issue ou contribua em install.sh."
            exit 1
            ;;
    esac

    summary
}

main "$@"
