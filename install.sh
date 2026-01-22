#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Ralph Installer
# ============================================

REPO="jjlinares/ralph"
BINARY_NAME="ralph"
SCRIPT_NAME="ralph.sh"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

info() { echo "${BLUE}[INFO]${RESET} $*"; }
success() { echo "${GREEN}[OK]${RESET} $*"; }
warn() { echo "${YELLOW}[WARN]${RESET} $*"; }
error() { echo "${RED}[ERROR]${RESET} $*" >&2; }

# Detect install directory
detect_install_dir() {
  if [[ -w "/usr/local/bin" ]]; then
    echo "/usr/local/bin"
  elif [[ -d "$HOME/.local/bin" ]]; then
    echo "$HOME/.local/bin"
  else
    mkdir -p "$HOME/.local/bin"
    echo "$HOME/.local/bin"
  fi
}

# Check if a command exists
has_command() {
  command -v "$1" &>/dev/null
}

# Check dependencies
check_dependencies() {
  local missing=()

  if ! has_command jq; then
    missing+=("jq")
  fi

  if ! has_command claude && ! has_command opencode; then
    warn "Neither 'claude' nor 'opencode' CLI found"
    warn "Install one of:"
    warn "  - Claude Code: https://github.com/anthropics/claude-code"
    warn "  - OpenCode: https://opencode.ai"
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required dependencies: ${missing[*]}"
    echo ""
    echo "Install with:"
    echo "  macOS:  brew install ${missing[*]}"
    echo "  Ubuntu: sudo apt install ${missing[*]}"
    exit 1
  fi
}

# Download and install
install_ralph() {
  local install_dir="$1"
  local install_path="$install_dir/$BINARY_NAME"
  local tmp_file
  tmp_file=$(mktemp)

  info "Downloading ralph..."

  if has_command curl; then
    curl -fsSL "https://raw.githubusercontent.com/${REPO}/master/${SCRIPT_NAME}" -o "$tmp_file"
  elif has_command wget; then
    wget -qO "$tmp_file" "https://raw.githubusercontent.com/${REPO}/master/${SCRIPT_NAME}"
  else
    error "Neither curl nor wget found"
    exit 1
  fi

  # Verify download
  if [[ ! -s "$tmp_file" ]]; then
    error "Download failed or file is empty"
    rm -f "$tmp_file"
    exit 1
  fi

  # Install
  mv "$tmp_file" "$install_path"
  chmod +x "$install_path"

  success "Installed to $install_path"
}

# Check if install dir is in PATH
check_path() {
  local install_dir="$1"

  if [[ ":$PATH:" != *":$install_dir:"* ]]; then
    warn "$install_dir is not in your PATH"
    echo ""
    echo "Add it to your shell config:"
    echo ""
    if [[ -f "$HOME/.zshrc" ]]; then
      echo "  echo 'export PATH=\"$install_dir:\$PATH\"' >> ~/.zshrc"
      echo "  source ~/.zshrc"
    elif [[ -f "$HOME/.bashrc" ]]; then
      echo "  echo 'export PATH=\"$install_dir:\$PATH\"' >> ~/.bashrc"
      echo "  source ~/.bashrc"
    else
      echo "  export PATH=\"$install_dir:\$PATH\""
    fi
    echo ""
  fi
}

# Main
main() {
  echo ""
  echo "${BOLD}Ralph Installer${RESET}"
  echo "================"
  echo ""

  # Check dependencies
  check_dependencies

  # Detect install location
  local install_dir
  install_dir=$(detect_install_dir)
  info "Install directory: $install_dir"

  # Install
  install_ralph "$install_dir"

  # Check PATH
  check_path "$install_dir"

  # Verify installation
  if has_command ralph; then
    echo ""
    success "Installation complete!"
    echo ""
    echo "Usage:"
    echo "  ralph --help"
    echo "  ralph -a claude --prd PRD.md"
    echo ""
  else
    echo ""
    success "Installation complete!"
    echo ""
    echo "Run: $install_dir/ralph --help"
    echo ""
  fi
}

# Run
main "$@"
