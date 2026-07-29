#!/usr/bin/env bash
# =============================================================================
# install_dependencies.sh — SnakeMergeAnnotation
# =============================================================================

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/allanverasce/snakemergeannotation.git}"
INSTALL_DIR="${INSTALL_DIR:-$HOME}"
VENV_DIR="${VENV_DIR:-$HOME/venv}"
DB_BASE_DIR="${DB_BASE_DIR:-_AUTO_}"
PROJECT_DIR="" # <--- CORREÇÃO AQUI

BAKTA_DB_TYPE="${BAKTA_DB_TYPE:-light}"
IMG_BAKTA="${IMG_BAKTA:-engbio/bakta:v1}"
IMG_DFAST="${IMG_DFAST:-engbio/dfast:v1}"
IMG_EGGNOG="${IMG_EGGNOG:-quay.io/biocontainers/eggnog-mapper:2.1.15--pyhdfd78af_0}"

PGAP_SCRIPT_URL="${PGAP_SCRIPT_URL:-https://raw.githubusercontent.com/ncbi/pgap/prod/scripts/pgap.py}"

SKIP_DOCKER=false
SKIP_VENV=false
SKIP_CLONE=false
SKIP_DB=false
SKIP_BAKTA_DB=false
SKIP_DFAST_DB=false
SKIP_EGGNOG_DB=false
SKIP_PGAP=false
FORCE=false

if [ -t 1 ]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'; C_BOLD='\033[1m'; C_NC='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_NC=''
fi
log_info(){ echo -e "${C_BLUE}[INFO]${C_NC} $*"; }
log_ok(){   echo -e "${C_GREEN}[OK]${C_NC}   $*"; }
log_warn(){ echo -e "${C_YELLOW}[WARN]${C_NC} $*"; }
log_err(){  echo -e "${C_RED}[ERROR]${C_NC}  $*" >&2; }
step(){     echo -e "\n${C_BOLD}==> $*${C_NC}"; }
die(){ log_err "$*"; exit 1; }

usage(){ sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-docker)     SKIP_DOCKER=true; shift ;;
        --skip-venv)       SKIP_VENV=true; shift ;;
        --skip-clone)      SKIP_CLONE=true; shift ;;
        --skip-db)         SKIP_DB=true; shift ;;
        --skip-bakta-db)   SKIP_BAKTA_DB=true; shift ;;
        --skip-dfast-db)   SKIP_DFAST_DB=true; shift ;;
        --skip-eggnog-db)  SKIP_EGGNOG_DB=true; shift ;;
        --skip-pgap)       SKIP_PGAP=true; shift ;;
        --bakta-full)      BAKTA_DB_TYPE="full"; shift ;;
        --db-dir)          DB_BASE_DIR="$2"; shift 2 ;;
        --venv-dir)        VENV_DIR="$2"; shift 2 ;;
        --install-dir)     INSTALL_DIR="$2"; shift 2 ;;
        --repo)            REPO_URL="$2"; shift 2 ;;
        --force)           FORCE=true; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) die "Unknown option: $1 (use --help)" ;;
    esac
done

OS_TYPE="unknown"
OS_FAMILY="unknown"
PKG_MANAGER="unknown"
IS_WSL=false

detect_os() {
    step "Detecting operating system"
    case "$(uname -s)" in
        Linux*)
            OS_TYPE="linux"
            if grep -qi microsoft /proc/version 2>/dev/null; then
                IS_WSL=true
                log_warn "WSL environment detected. Docker Desktop (with WSL2 integration) or native dockerd inside WSL should work normally."
            fi
            if [ -r /etc/os-release ]; then
                . /etc/os-release
                case "${ID:-}" in
                    ubuntu|debian|raspbian|linuxmint|pop) OS_FAMILY="debian"; PKG_MANAGER="apt" ;;
                    fedora)                               OS_FAMILY="fedora"; PKG_MANAGER="dnf" ;;
                    rhel|centos|rocky|almalinux)          OS_FAMILY="rhel";   PKG_MANAGER="dnf" ;;
                    arch|manjaro|endeavouros)              OS_FAMILY="arch";   PKG_MANAGER="pacman" ;;
                    opensuse*|sles)                        OS_FAMILY="suse";   PKG_MANAGER="zypper" ;;
                    *)
                        case "${ID_LIKE:-}" in
                            debian) OS_FAMILY="debian"; PKG_MANAGER="apt" ;;
                            rhel|fedora) OS_FAMILY="rhel"; PKG_MANAGER="dnf" ;;
                            arch) OS_FAMILY="arch"; PKG_MANAGER="pacman" ;;
                            suse) OS_FAMILY="suse"; PKG_MANAGER="zypper" ;;
                            *) OS_FAMILY="unknown"; PKG_MANAGER="unknown" ;;
                        esac
                        ;;
                esac
            fi
            ;;
        Darwin*)
            OS_TYPE="macos"; OS_FAMILY="macos"; PKG_MANAGER="brew"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            OS_TYPE="windows"
            ;;
        *)
            OS_TYPE="unknown"
            ;;
    esac

    case "$OS_TYPE" in
        linux)   log_ok "Linux detected — distribution: ${ID:-unknown} (family: $OS_FAMILY, package manager: $PKG_MANAGER)" ;;
        macos)   log_ok "macOS detected" ;;
        windows) die "Native Windows (outside WSL) is not directly supported." ;;
        *)       die "Unrecognized operating system ($(uname -s))." ;;
    esac
}

resolve_db_base_dir() {
    if [ "$DB_BASE_DIR" = "_AUTO_" ]; then
        if [ "$OS_TYPE" = "macos" ]; then
            DB_BASE_DIR="$HOME/snakeMergeAnnotation/databases"
        else
            DB_BASE_DIR="/opt/snakeMergeAnnotation/databases"
        fi
        log_info "Database directory not provided; using default for $OS_TYPE: $DB_BASE_DIR"
    fi
}

do_install_prereqs() {
    step "Installing system prerequisites"
    if [ "$OS_TYPE" = "linux" ]; then
        case "$PKG_MANAGER" in
            apt)
                sudo apt-get update -y
                sudo apt-get install -y ca-certificates curl git build-essential python3-venv python3-pip
                ;;
            dnf)
                sudo dnf install -y ca-certificates curl git @development-tools || \
                sudo dnf install -y ca-certificates curl git gcc gcc-c++ make
                ;;
            pacman)
                sudo pacman -Sy --noconfirm --needed ca-certificates curl git base-devel
                ;;
            zypper)
                sudo zypper --non-interactive install ca-certificates curl git gcc gcc-c++ make
                ;;
            *)
                log_warn "Package manager not identified; assuming curl/git/python3-venv are already installed."
                ;;
        esac
    fi
}

install_docker_linux() {
    if command -v docker >/dev/null 2>&1; then
        log_ok "Docker already installed: $(docker --version)"
        return
    fi
    log_info "Installing Docker Engine..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sudo sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
    sudo systemctl enable --now docker 2>/dev/null || true
    log_ok "Docker installed."
}

setup_docker_rootless_group() {
    step "Configuring Docker without requiring sudo ('docker' group)"
    if ! getent group docker >/dev/null 2>&1; then
        sudo groupadd docker
    fi
    if ! id -nG "$USER" | grep -qw docker; then
        sudo usermod -aG docker "$USER"
        NEED_RELOGIN=true
    fi
    if docker info >/dev/null 2>&1; then
        DOCKER_CMD="docker"
        log_ok "Docker responds without sudo in this session."
    else
        DOCKER_CMD="sudo docker"
    fi
}

setup_docker_macos() {
    step "Configuring Docker on macOS"
    if command -v docker >/dev/null 2>&1; then
        log_ok "Docker already installed"
    elif command -v brew >/dev/null 2>&1; then
        brew install --cask docker
    fi
    DOCKER_CMD="docker"
}

do_install_docker() {
    if [ "$SKIP_DOCKER" = true ]; then
        DOCKER_CMD="docker"
        return
    fi
    step "Installing/checking Docker"
    case "$OS_TYPE" in
        linux)
            install_docker_linux
            setup_docker_rootless_group
            ;;
        macos)
            setup_docker_macos
            ;;
    esac
}

do_setup_venv() {
    if [ "$SKIP_VENV" = true ]; then return; fi
    step "Creating Python virtual environment at: $VENV_DIR"
    if [ -f "$VENV_DIR/bin/activate" ] && [ "$FORCE" != true ]; then
        log_ok "Virtualenv already exists at $VENV_DIR"
    else
        rm -rf "$VENV_DIR"
        python3 -m venv "$VENV_DIR"
        log_ok "Virtualenv created at $VENV_DIR"
    fi
    source "$VENV_DIR/bin/activate"
    pip install --upgrade pip --quiet
    pip install snakemake --quiet
    log_ok "Snakemake installed: $(snakemake --version)"
    deactivate
}

do_clone_repo() {
    if [ "$SKIP_CLONE" = true ]; then return; fi
    step "Cloning SnakeMergeAnnotation repository"
    mkdir -p "$INSTALL_DIR"
    local dir_name="$(basename "$REPO_URL" .git)"
    PROJECT_DIR="$INSTALL_DIR/$dir_name"
    if [ -d "$PROJECT_DIR/.git" ] && [ "$FORCE" != true ]; then
        log_ok "Repository already cloned at $PROJECT_DIR"
    else
        if [ -d "$PROJECT_DIR" ]; then
            log_warn "Removing existing directory $PROJECT_DIR to clone again..."
            rm -rf "$PROJECT_DIR"
        fi
        (cd "$INSTALL_DIR" && git clone "$REPO_URL")
        log_ok "Repository cloned at $PROJECT_DIR"
    fi
}

prepare_db_dirs() {
    step "Preparing database directory: $DB_BASE_DIR"
    if [ "$OS_TYPE" = "linux" ]; then
        sudo mkdir -p "$DB_BASE_DIR"/{bakta_db,dfast_db,eggnog_db}
        sudo chown -R "$USER":"$(id -gn)" "$DB_BASE_DIR"
    else
        mkdir -p "$DB_BASE_DIR"/{bakta_db,dfast_db,eggnog_db}
    fi
    log_ok "Directories ready and permissions set for '$USER'."
}

dir_has_content() {
    [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]
}

download_bakta_db() {
    if [ "$SKIP_BAKTA_DB" = true ]; then return; fi
    if dir_has_content "$DB_BASE_DIR/bakta_db" && [ "$FORCE" != true ]; then
        log_ok "Bakta database already seems to exist at $DB_BASE_DIR/bakta_db."
        return
    fi
    step "Downloading Bakta database (type: $BAKTA_DB_TYPE)"
    
    $DOCKER_CMD run --rm \
        --entrypoint sh \
        -v "$DB_BASE_DIR/bakta_db:/db" \
        oschwengers/bakta:latest \
        -c 'BAKTA_BIN=$(find / -name bakta_db -type f 2>/dev/null | grep "bin/bakta_db" | head -n 1); if [ -z "$BAKTA_BIN" ]; then echo "[ERROR] bakta_db not found in official image!"; exit 1; fi; export PATH="$(dirname "$BAKTA_BIN"):$PATH"; "$BAKTA_BIN" download --output /db --type '"$BAKTA_DB_TYPE"
        
    log_ok "Bakta database downloaded to $DB_BASE_DIR/bakta_db"
}

download_dfast_db() {
    if [ "$SKIP_DFAST_DB" = true ]; then return; fi
    if dir_has_content "$DB_BASE_DIR/dfast_db" && [ "$FORCE" != true ]; then
        log_ok "DFAST database already seems to exist."
        return
    fi
    step "Downloading DFAST databases (proteins, COG/CDD, TIGRFAMs)"
    
    log_info "  -> Reference protein database..."
    $DOCKER_CMD run --rm --entrypoint python -v "$DB_BASE_DIR/dfast_db:/dfast_core/db" \
        "$IMG_DFAST" /dfast_core/scripts/file_downloader.py --protein dfast
        
    log_info "  -> COG/CDD database..."
    $DOCKER_CMD run --rm --entrypoint python -v "$DB_BASE_DIR/dfast_db:/dfast_core/db" \
        "$IMG_DFAST" /dfast_core/scripts/file_downloader.py --cdd Cog
        
    log_info "  -> TIGRFAMs (HMM) database..."
    $DOCKER_CMD run --rm --entrypoint python -v "$DB_BASE_DIR/dfast_db:/dfast_core/db" \
        "$IMG_DFAST" /dfast_core/scripts/file_downloader.py --hmm TIGR
        
    log_ok "DFAST databases downloaded."
}

download_eggnog_db() {
    if [ "$SKIP_EGGNOG_DB" = true ]; then return; fi
    if dir_has_content "$DB_BASE_DIR/eggnog_db" && [ "$FORCE" != true ]; then
        log_ok "eggNOG database already seems to exist."
        return
    fi
    step "Downloading eggNOG-mapper database (image: $IMG_EGGNOG)"
    
    $DOCKER_CMD run --rm --entrypoint download_eggnog_data.py -v "$DB_BASE_DIR/eggnog_db:/eggnog_db" \
        "$IMG_EGGNOG" --data_dir /eggnog_db -y
        
    log_ok "eggNOG-mapper database downloaded."
}

do_download_databases() {
    if [ "$SKIP_DB" = true ]; then return; fi
    prepare_db_dirs
    download_bakta_db
    download_dfast_db
    download_eggnog_db
}

do_setup_pgap() {
    if [ "$SKIP_PGAP" = true ]; then return; fi
    if [ -z "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR" ]; then return; fi

    step "Setting up PGAP (database stays in ~/.pgap)"
    cd "$PROJECT_DIR"

    if [ ! -f pgap.py ] || [ "$FORCE" = true ]; then
        curl -fsSL -o pgap.py "$PGAP_SCRIPT_URL"
        chmod +x pgap.py
    fi

    log_info "Updating/downloading the PGAP database..."
    python3 pgap.py --update
    log_ok "PGAP updated."
}

print_summary() {
    echo
    echo -e "${C_BOLD}================================================================${C_NC}"
    echo -e "${C_BOLD} Installation complete — SnakeMergeAnnotation${C_NC}"
    echo -e "${C_BOLD}================================================================${C_NC}"
}

NEED_RELOGIN=false
DOCKER_CMD="docker"

main() {
    detect_os
    resolve_db_base_dir
    do_install_prereqs
    do_install_docker
    do_setup_venv
    do_clone_repo
    do_download_databases
    do_setup_pgap
    print_summary
}

main "$@"
