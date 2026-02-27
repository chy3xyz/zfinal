#!/usr/bin/env bash

# ZFinal Installation Script
# Supports: macOS, Linux, Windows (WSL)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ZFINAL_REPO="https://github.com/chy3xyz/zfinal.git"
INSTALL_DIR="${HOME}/.zfinal"
BIN_DIR="${HOME}/.local/bin"
ZIG_MIN_VERSION="0.14.0"

# Helper functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Detect OS
detect_os() {
    case "$(uname -s)" in
        Darwin*)
            OS="macos"
            ;;
        Linux*)
            OS="linux"
            ;;
        CYGWIN*|MINGW*|MSYS*)
            OS="windows"
            ;;
        *)
            print_error "Unsupported operating system: $(uname -s)"
            exit 1
            ;;
    esac
    print_info "Detected OS: $OS"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check Zig installation
check_zig() {
    if ! command_exists zig; then
        print_error "Zig is not installed!"
        print_info "Please install Zig from: https://ziglang.org/download/"
        print_info ""
        print_info "Installation instructions:"
        
        case "$OS" in
            macos)
                print_info "  brew install zig"
                ;;
            linux)
                print_info "  # Download from https://ziglang.org/download/"
                print_info "  # Or use your package manager"
                ;;
            windows)
                print_info "  # Download from https://ziglang.org/download/"
                ;;
        esac
        
        exit 1
    fi
    
    local zig_version=$(zig version)
    print_success "Zig $zig_version is installed"
}

# Check SQLite installation (optional)
check_sqlite() {
    if ! command_exists sqlite3; then
        print_warning "SQLite3 is not installed (optional for database features)"
        print_info "To install SQLite3:"
        
        case "$OS" in
            macos)
                print_info "  brew install sqlite3"
                ;;
            linux)
                print_info "  sudo apt-get install sqlite3 libsqlite3-dev  # Debian/Ubuntu"
                print_info "  sudo yum install sqlite sqlite-devel          # CentOS/RHEL"
                ;;
            windows)
                print_info "  Download from: https://www.sqlite.org/download.html"
                ;;
        esac
    else
        print_success "SQLite3 is installed"
    fi
}

# Clone or update repository
setup_repository() {
    if [ -d "$INSTALL_DIR" ]; then
        print_info "ZFinal directory exists, updating..."
        cd "$INSTALL_DIR"
        git pull origin main
    else
        print_info "Cloning ZFinal repository..."
        git clone "$ZFINAL_REPO" "$INSTALL_DIR"
        cd "$INSTALL_DIR"
    fi
}

# Build ZFinal
build_zfinal() {
    print_info "Building ZFinal..."
    cd "$INSTALL_DIR"
    
    if zig build install; then
        print_success "ZFinal built successfully!"
    else
        print_error "Build failed!"
        exit 1
    fi
}

# Install zf CLI tool
install_cli() {
    print_info "Installing zf CLI tool..."
    
    # Create bin directory if it doesn't exist
    mkdir -p "$BIN_DIR"
    
    # Copy zf binary
    local zf_binary="$INSTALL_DIR/zig-out/bin/zf"
    
    if [ -f "$zf_binary" ]; then
        cp "$zf_binary" "$BIN_DIR/zf"
        chmod +x "$BIN_DIR/zf"
        print_success "zf CLI tool installed to $BIN_DIR/zf"
    else
        print_error "zf binary not found at $zf_binary"
        exit 1
    fi
}

# Setup PATH
setup_path() {
    local shell_rc=""
    
    # Detect shell
    case "$SHELL" in
        */bash)
            shell_rc="$HOME/.bashrc"
            ;;
        */zsh)
            shell_rc="$HOME/.zshrc"
            ;;
        */fish)
            shell_rc="$HOME/.config/fish/config.fish"
            ;;
        *)
            shell_rc="$HOME/.profile"
            ;;
    esac
    
    # Check if PATH already contains BIN_DIR
    if ! echo "$PATH" | grep -q "$BIN_DIR"; then
        print_info "Adding $BIN_DIR to PATH in $shell_rc"
        
        if [ -f "$shell_rc" ]; then
            echo "" >> "$shell_rc"
            echo "# ZFinal CLI" >> "$shell_rc"
            echo "export PATH=\"\$PATH:$BIN_DIR\"" >> "$shell_rc"
            print_success "PATH updated in $shell_rc"
            print_warning "Please run: source $shell_rc"
        else
            print_warning "Shell config file not found: $shell_rc"
            print_info "Please manually add $BIN_DIR to your PATH"
        fi
    else
        print_success "PATH already contains $BIN_DIR"
    fi
}

# Verify installation
verify_installation() {
    print_info "Verifying installation..."
    
    export PATH="$PATH:$BIN_DIR"
    
    if command_exists zf; then
        local zf_version=$(zf version 2>/dev/null || echo "unknown")
        print_success "Installation verified!"
        print_info "ZFinal CLI version: $zf_version"
    else
        print_warning "zf command not found in PATH"
        print_info "You may need to restart your shell or run: source ~/.bashrc"
    fi
}

# Print next steps
print_next_steps() {
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                            ║${NC}"
    echo -e "${GREEN}║  🎉  ZFinal Installation Complete!                        ║${NC}"
    echo -e "${GREEN}║                                                            ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}Next steps:${NC}"
    echo ""
    echo "  1. Reload your shell configuration:"
    echo -e "     ${YELLOW}source ~/.bashrc${NC}  # or ~/.zshrc"
    echo ""
    echo "  2. Verify installation:"
    echo -e "     ${YELLOW}zf version${NC}"
    echo ""
    echo "  3. Create your first project:"
    echo -e "     ${YELLOW}zf new myapp${NC}"
    echo -e "     ${YELLOW}cd myapp${NC}"
    echo -e "     ${YELLOW}zig build run${NC}"
    echo ""
    echo "  4. View help:"
    echo -e "     ${YELLOW}zf help${NC}"
    echo ""
    echo -e "${BLUE}Documentation:${NC}"
    echo "  - GitHub: https://github.com/chy3xyz/zfinal"
    echo "  - Docs: $INSTALL_DIR/doc/"
    echo ""
    echo -e "${GREEN}Happy coding with ZFinal! 🚀${NC}"
    echo ""
}

# Uninstall function
uninstall() {
    print_info "Uninstalling ZFinal..."
    
    # Remove installation directory
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
        print_success "Removed $INSTALL_DIR"
    fi
    
    # Remove CLI binary
    if [ -f "$BIN_DIR/zf" ]; then
        rm "$BIN_DIR/zf"
        print_success "Removed $BIN_DIR/zf"
    fi
    
    print_success "ZFinal uninstalled successfully!"
    print_info "You may want to remove the PATH entry from your shell config"
}

# Main installation flow
main() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                                                            ║${NC}"
    echo -e "${BLUE}║              ZFinal Installation Script                   ║${NC}"
    echo -e "${BLUE}║                                                            ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Check for uninstall flag
    if [ "$1" = "--uninstall" ] || [ "$1" = "-u" ]; then
        uninstall
        exit 0
    fi
    
    # Check for help flag
    if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  -h, --help        Show this help message"
        echo "  -u, --uninstall   Uninstall ZFinal"
        echo ""
        exit 0
    fi
    
    # Run installation steps
    detect_os
    check_zig
    check_sqlite
    setup_repository
    build_zfinal
    install_cli
    setup_path
    verify_installation
    print_next_steps
}

# Run main function
main "$@"
