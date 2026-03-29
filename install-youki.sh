#!/usr/bin/env bash
# =============================================================================
#  install-youki.sh — Instalador do Youki OCI Container Runtime
#  Repositório: https://github.com/youki-dev/youki
#
#  Pré-requisitos:
#    - Ubuntu / Debian
#    - Acesso SSH ao GitHub configurado (git@github.com)
#
#  Uso:
#    chmod +x install-youki.sh
#    ./install-youki.sh             # build de desenvolvimento (youki-dev)
#    ./install-youki.sh --release   # build otimizado (youki-release)
#    ./install-youki.sh --docker    # configura Youki como runtime no Docker
# =============================================================================

set -euo pipefail

# ─── Cores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Variáveis ───────────────────────────────────────────────────────────────
INSTALL_DIR="/usr/local/bin"
REPO_HTTPS="https://github.com/youki-dev/youki.git"
BUILD_TARGET="youki-dev"   # alterado para "youki-release" com --release
CONFIGURE_DOCKER=false

# Resolvido após checar SUDO_USER (definido em check_root)
ORIGINAL_USER=""
ORIGINAL_HOME=""
CLONE_DIR=""

# ─── Funções utilitárias ─────────────────────────────────────────────────────
log()     { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${RESET}"; \
            echo -e "${BOLD}  $*${RESET}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════${RESET}\n"; }

# ─── Parse de argumentos ─────────────────────────────────────────────────────
for arg in "$@"; do
  case $arg in
    --release) BUILD_TARGET="youki-release" ;;
    --docker)  CONFIGURE_DOCKER=true        ;;
    --help)
      echo "Uso: $0 [--release] [--docker]"
      echo ""
      echo "  (padrão)   Build de desenvolvimento via 'just youki-dev'"
      echo "  --release  Build otimizado via 'just youki-release'"
      echo "  --docker   Configura Youki como runtime alternativo no Docker"
      exit 0
      ;;
    *) warn "Argumento desconhecido: $arg" ;;
  esac
done

# ─── Verificações iniciais ────────────────────────────────────────────────────
check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "Este script deve ser executado como root (use sudo)."
  fi

  ORIGINAL_USER="${SUDO_USER:-$USER}"
  ORIGINAL_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
  CLONE_DIR="$ORIGINAL_HOME/youki"

  log "Usuário original : ${BOLD}$ORIGINAL_USER${RESET}"
  log "Home             : ${BOLD}$ORIGINAL_HOME${RESET}"
  log "Clone dir        : ${BOLD}$CLONE_DIR${RESET}"
}

check_os() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    error "Youki só suporta Linux. Sistema detectado: $(uname -s)"
  fi

  if ! command -v apt-get &>/dev/null; then
    error "Este script requer um sistema baseado em Debian/Ubuntu (apt-get não encontrado)."
  fi

  if ! command -v systemctl &>/dev/null; then
    warn "systemd não detectado. Youki pode ter funcionalidade limitada."
  fi
}

detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
  fi
  log "Distribuição: ${BOLD}${PRETTY_NAME:-Linux}${RESET}"
  log "Arquitetura : ${BOLD}$(uname -m)${RESET}"
}

# ─── Instalação de dependências ───────────────────────────────────────────────
install_deps() {
  header "Instalando dependências"

  log "Atualizando lista de pacotes..."
  apt-get update -q

  log "Instalando dependências de build..."
  apt-get install -y \
    git             \
    pkg-config      \
    libsystemd-dev  \
    build-essential \
    libelf-dev      \
    libseccomp-dev  \
    libclang-dev    \
    libssl-dev      \
    just

  log "Instalando rustup..."
  apt install -y rustup

  success "Todas as dependências instaladas."
}

setup_rust() {
  header "Configurando Rust toolchain"

  if ! su - "$ORIGINAL_USER" -c "rustup toolchain list 2>/dev/null | grep -q stable"; then
    log "Inicializando rustup (stable toolchain)..."
    su - "$ORIGINAL_USER" -c "rustup default stable"
  else
    log "Rust toolchain já configurado: $(su - "$ORIGINAL_USER" -c 'rustc --version')"
  fi

  export PATH="$ORIGINAL_HOME/.cargo/bin:$PATH"

  success "Rust pronto: $(su - "$ORIGINAL_USER" -c 'rustc --version')"
}

# ─── Clone do repositório ─────────────────────────────────────────────────────
clone_repo() {
  header "Clonando repositório"

  if [[ -d "$CLONE_DIR" ]]; then
    warn "Diretório $CLONE_DIR já existe."
    read -rp "  Deseja removê-lo e clonar novamente? [s/N] " confirm
    if [[ "$confirm" =~ ^[sS]$ ]]; then
      rm -rf "$CLONE_DIR"
    else
      log "Usando repositório existente em $CLONE_DIR"
      return
    fi
  fi

  log "Clonando: $REPO_HTTPS → $CLONE_DIR"
  su - "$ORIGINAL_USER" -c "git clone $REPO_HTTPS $CLONE_DIR"

  success "Repositório clonado em: ${BOLD}$CLONE_DIR${RESET}"
}

# ─── Build com just ───────────────────────────────────────────────────────────
build_youki() {
  header "Compilando Youki (just $BUILD_TARGET)"

  log "Executando: just $BUILD_TARGET"
  log "Isso pode levar alguns minutos na primeira compilação..."

  su - "$ORIGINAL_USER" -c "
    export PATH=\"$ORIGINAL_HOME/.cargo/bin:\$PATH\"
    cd $CLONE_DIR
    just $BUILD_TARGET
  "

  # O binário fica na raiz do repositório após o build via just
  BUILT_BINARY="$CLONE_DIR/youki"

  if [[ ! -x "$BUILT_BINARY" ]]; then
    error "Binário não encontrado em $BUILT_BINARY após o build."
  fi

  success "Build concluído: ${BOLD}$BUILT_BINARY${RESET}"

  log "Instalando em $INSTALL_DIR/youki..."
  install -m 755 "$BUILT_BINARY" "$INSTALL_DIR/youki"

  success "Youki instalado em: ${BOLD}$INSTALL_DIR/youki${RESET}"
}

# ─── Configuração do Docker ───────────────────────────────────────────────────
configure_docker() {
  header "Configurando Youki como runtime no Docker"

  if ! command -v docker &>/dev/null; then
    warn "Docker não encontrado. Pulando configuração."
    return
  fi

  DOCKER_CONFIG="/etc/docker/daemon.json"
  YOUKI_BIN="$INSTALL_DIR/youki"

  if [[ -f "$DOCKER_CONFIG" ]]; then
    cp "$DOCKER_CONFIG" "${DOCKER_CONFIG}.bak"
    log "Backup criado: ${DOCKER_CONFIG}.bak"

    python3 - <<EOF
import json

with open("$DOCKER_CONFIG", "r") as f:
    config = json.load(f)

config.setdefault("runtimes", {})["youki"] = {"path": "$YOUKI_BIN"}

with open("$DOCKER_CONFIG", "w") as f:
    json.dump(config, f, indent=2)

print("daemon.json atualizado.")
EOF
  else
    mkdir -p "$(dirname "$DOCKER_CONFIG")"
    cat > "$DOCKER_CONFIG" <<EOF
{
  "runtimes": {
    "youki": {
      "path": "$YOUKI_BIN"
    }
  }
}
EOF
  fi

  log "Recarregando Docker daemon..."
  systemctl reload docker || systemctl restart docker

  success "Youki configurado como runtime alternativo no Docker."
  log "Para usar: ${BOLD}docker run --runtime youki hello-world${RESET}"
}

# ─── Verificação pós-instalação ───────────────────────────────────────────────
verify_install() {
  header "Verificação da instalação"

  YOUKI_CMD="$INSTALL_DIR/youki"

  if [[ ! -x "$YOUKI_CMD" ]]; then
    error "Youki não encontrado em $YOUKI_CMD após instalação."
  fi

  VERSION_OUTPUT=$("$YOUKI_CMD" --version 2>&1 || true)
  success "Instalação verificada: ${BOLD}$VERSION_OUTPUT${RESET}"

  echo ""
  log "Informações do sistema:"
  "$YOUKI_CMD" info 2>&1 | head -20 || true

  echo ""
  log "Help do binário:"
  "$YOUKI_CMD" -h 2>&1 || true
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  header "Youki Installer — OCI Container Runtime em Rust"

  log "Modo de build : ${BOLD}$BUILD_TARGET${RESET}"

  check_root

  log "Destino clone : ${BOLD}$CLONE_DIR${RESET}"
  log "Destino bin   : ${BOLD}$INSTALL_DIR/youki${RESET}"
  check_os
  detect_distro

  install_deps
  setup_rust
  clone_repo
  build_youki

  if $CONFIGURE_DOCKER; then
    configure_docker
  fi

  verify_install

  echo ""
  echo -e "${GREEN}${BOLD}✔ Instalação concluída!${RESET}"
  echo ""
  echo -e "  Binário      : ${BOLD}$INSTALL_DIR/youki${RESET}"
  echo -e "  Build target : ${BOLD}$BUILD_TARGET${RESET}"
  echo -e "  Repositório  : ${BOLD}$CLONE_DIR${RESET}"
  echo ""
  echo -e "  Próximos passos:"
  echo -e "   • Testar youki  : ${CYAN}youki --version${RESET}"
  echo -e "   • Info   youki  : ${CYAN}youki info${RESET}"
  echo -e "   • youki  bench  : ${CYAN}time podman run --runtime youki --rm alpine echo hi${RESET}"
  echo -e "   • runc   bench  : ${CYAN}time podman run --runtime runc  --rm alpine echo hi${RESET}"
  echo -e "   • crun   bench  : ${CYAN}time podman run --runtime crun  --rm alpine echo hi${RESET}"
  echo -e "   • Docs          : ${CYAN}https://youki-dev.github.io/youki/${RESET}"
  echo -e ""
  echo -e "  ${YELLOW}Nota: faça logout/login para aplicar o grupo docker ao usuário $ORIGINAL_USER${RESET}"
  echo ""
}

main "$@"
