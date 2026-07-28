#!/usr/bin/env bash
# =============================================================================
# install_dependencies.sh — SnakeMergeAnnotation
# =============================================================================
# Installs ALL dependencies for the pipeline:
#   1. System prerequisites (curl, git, python3-venv)
#   2. Docker (automatically detects the OS)
#   3. Docker without sudo ("docker" group, on Linux)
#   4. Python virtual environment (venv) + Snakemake
#   5. Clone the SnakeMergeAnnotation repository
#   6. Databases: Bakta (light), DFAST (proteins/COG/TIGRFAMs),
#      eggNOG-mapper (most recent stable version) — all under /opt (Linux)
#   7. PGAP: downloads pgap.py and runs "pgap.py --update" (stays in the user's
#      HOME, as PGAP itself manages by default)
#
# Usage:
#   chmod +x install_dependencies.sh
#   ./install_dependencies.sh [options]
#
# Options:
#   --skip-docker       Do not install/configure Docker
#   --skip-venv         Do not create the virtualenv nor install Snakemake
#   --skip-clone        Do not clone the repository
#   --skip-db           Do not download any databases (bakta/dfast/eggnog)
#   --skip-bakta-db     Skip only the Bakta database
#   --skip-dfast-db     Skip only the DFAST database
#   --skip-eggnog-db    Skip only the eggNOG-mapper database
#   --skip-pgap         Do not download/update the PGAP database
#   --bakta-full        Download the COMPLETE Bakta database (default: light)
#   --db-dir DIR        Base directory for databases (default: /opt/snakeMergeAnnotation/databases
#                       on Linux; $HOME/snakeMergeAnnotation/databases on macOS,
#                       to avoid permission issues in /opt and
#                       Docker Desktop "file sharing" issues)
#   --venv-dir DIR      Path to the virtualenv (default: $HOME/venv)
#   --install-dir DIR   Where to clone the repository (default: $HOME)
#   --repo URL          URL of the git repository
#   --force             Redo steps even if they already seem complete
#   -h, --help          Show this help
# =============================================================================

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/allanverasce/snakemergeannotation.git}"
INSTALL_DIR="${INSTALL_DIR:-$HOME}"
VENV_DIR="${VENV_DIR:-$HOME/venv}"
# Sentinel: the actual value is resolved after OS detection (see
# resolve_db_base_dir), because the correct default changes between Linux and macOS.
DB_BASE_DIR="${DB_BASE_DIR:-_AUTO_}"

BAKTA_DB_TYPE="${BAKTA_DB_TYPE:-light}"          # light | full
IMG_BAKTA="${IMG_BAKTA:-engbio/bakta:v1}"
IMG_DFAST="${IMG_DFAST:-engbio/dfast:v1}"
# Adjusted to exactly match "eggnog.docker_image" in your config.yaml.
# Default: official biocontainers build, tag aligned with the latest stable
# release of eggNOG-mapper (2.1.15 — compatible with eggNOG v5 database).
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

# -----------------------------------------------------------------------------
# ARGUMENTS
# -----------------------------------------------------------------------------
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

# =============================================================================
# 1. OPERATING SYSTEM DETECTION
# =============================================================================
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
                # shellcheck disable=SC1091
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
        macos)   log_ok "macOS detected (version $(sw_vers -productVersion 2>/dev/null || echo '?'))" ;;
        windows) die "Native Windows (outside WSL) is not directly supported. Install WSL2 (https://learn.microsoft.com/windows/wsl/install) and run this script inside it." ;;
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

# =============================================================================
# 2. PREREQUISITES
# =============================================================================
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
    elif [ "$OS_TYPE" = "macos" ]; then
        log_info "macOS detected. Assuming brew/git/python3 are managed by the user."
    fi
}

# =============================================================================
# 3. DOCKER INSTALLATION
# =============================================================================
install_docker_linux() {
    if command -v docker >/dev/null 2>&1 && [ "$FORCE" != true ]; then
        log_ok "Docker already installed: $(docker --version)"
        return
    fi

    log_info "Installing Docker Engine..."
    case "$PKG_MANAGER" in
        arch)
            sudo pacman -Sy --noconfirm --needed docker docker-buildx
            ;;
        *)
            curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
            sudo sh /tmp/get-docker.sh
            rm -f /tmp/get-docker.sh
            ;;
    esac

    sudo systemctl enable --now docker 2>/dev/null || \
        log_warn "Could not enable the docker service via systemctl (verify manually that the daemon is active — common in WSL without systemd enabled)."

    log_ok "Docker installed: $(docker --version 2>/dev/null || echo 'verify manually')"
}

setup_docker_rootless_group() {
    step "Configuring Docker without requiring sudo ('docker' group)"

    if [ "$IS_WSL" = true ] && command -v docker.exe >/dev/null 2>&1; then
        log_info "WSL with Docker Desktop detected (docker.exe in PATH); the daemon runs on Windows and is exposed via socket — local 'docker' group is not required."
    fi

    if ! getent group docker >/dev/null 2>&1; then
        sudo groupadd docker
        log_ok "Group 'docker' created."
    fi

    if id -nG "$USER" | grep -qw docker; then
        log_ok "User '$USER' already belongs to the 'docker' group."
    else
        sudo usermod -aG docker "$USER"
        log_warn "User '$USER' added to the 'docker' group. You must LOGOUT/LOGIN (or restart) for this to take effect in this and future terminal sessions."
        NEED_RELOGIN=true
    fi

    if docker info >/dev/null 2>&1; then
        DOCKER_CMD="docker"
        log_ok "Docker responds without sudo in this session."
    else
        log_warn "The 'docker' group is not yet active in this terminal session."
        log_warn "This script will use 'sudo docker' only to FINISH the installation now."
        log_warn "After logging back in, use 'docker' normally, without sudo."
        DOCKER_CMD="sudo docker"
    fi
}

setup_docker_macos() {
    step "Configuring Docker on macOS"
    if command -v docker >/dev/null 2>&1; then
        log_ok "Docker already installed: $(docker --version)"
    elif command -v brew >/dev/null 2>&1; then
        log_info "Installing Docker Desktop via Homebrew (cask)..."
        brew install --cask docker
        log_warn "Open the Docker Desktop application manually at least once to complete the setup (you must accept macOS permissions)."
    else
        die "Homebrew not found. Install Docker Desktop manually at https://www.docker.com/products/docker-desktop/ and run this script again with --skip-docker."
    fi
    DOCKER_CMD="docker"
}

do_install_docker() {
    if [ "$SKIP_DOCKER" = true ]; then
        log_warn "Docker installation skipped (--skip-docker). Assuming 'docker' is available in PATH."
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

    log_info "Testing Docker (${DOCKER_CMD})..."
    if $DOCKER_CMD run --rm hello-world >/dev/null 2>&1; then
        log_ok "Docker working correctly."
    else
        if [ "$OS_TYPE" = "macos" ]; then
            log_warn "Could not run 'hello-world'. If Docker Desktop was just installed, open the application manually once (it needs to initialize its internal VM) and run the script again, or continue after confirming Docker Desktop is active in the menu bar."
        else
            log_warn "Could not run 'hello-world' automatically. Check Docker manually if anything fails further down (on WSL without systemd, you may need to start the daemon with 'sudo service docker start')."
        fi
    fi
}

# =============================================================================
# 4. VIRTUALENV PYTHON + SNAKEMAKE
# =============================================================================
do_setup_venv() {
    if [ "$SKIP_VENV" = true ]; then
        log_warn "Virtualenv creation skipped (--skip-venv)."
        return
    fi
    step "Creating Python virtual environment at: $VENV_DIR"

    command -v python3 >/dev/null 2>&1 || die "python3 not found. Install Python 3 before continuing (macOS: 'brew install python3'; Linux: python3 package from your package manager)."

    if [ -f "$VENV_DIR/bin/activate" ] && [ "$FORCE" != true ]; then
        log_ok "Virtualenv already exists at $VENV_DIR (use --force to recreate)."
    else
        rm -rf "$VENV_DIR"
        python3 -m venv "$VENV_DIR"
        log_ok "Virtualenv created at $VENV_DIR"
    fi

    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"
    pip install --upgrade pip --quiet
    pip install snakemake --quiet
    log_ok "Snakemake installed: $(snakemake --version)"
    deactivate
}

# =============================================================================
# 5. DOWNLOAD FROM GITHUB
# =============================================================================
PROJECT_DIR=""

do_clone_repo() {
    if [ "$SKIP_CLONE" = true ]; then
        log_warn "Repository clone skipped (--skip-clone)."
        return
    fi
    step "Cloning SnakeMergeAnnotation repository"

    command -v git >/dev/null 2>&1 || die "git not found. Install git before continuing."

    mkdir -p "$INSTALL_DIR"
    local dir_name
    dir_name="$(basename "$REPO_URL" .git)"
    PROJECT_DIR="$INSTALL_DIR/$dir_name"

    if [ -d "$PROJECT_DIR/.git" ] && [ "$FORCE" != true ]; then
        log_ok "Repository already cloned at $PROJECT_DIR"
    else
        (cd "$INSTALL_DIR" && git clone "$REPO_URL")
        log_ok "Repository cloned at $PROJECT_DIR"
    fi
}

# =============================================================================
# 6. DOWNLOAD DATABASES
# =============================================================================
prepare_db_dirs() {
    step "Preparing database directory: $DB_BASE_DIR"
    if [ "$OS_TYPE" = "linux" ]; then
        sudo mkdir -p "$DB_BASE_DIR"/{bakta_db,dfast_db,eggnog_db}
        sudo chown -R "$USER":"$(id -gn)" "$DB_BASE_DIR"
    else
        mkdir -p "$DB_BASE_DIR"/{bakta_db,dfast_db,eggnog_db}
    fi
    log_ok "Directories ready and permissions set for '$USER'."

    if [ "$OS_TYPE" = "macos" ]; then
        case "$DB_BASE_DIR" in
            "$HOME"/*) : ;; 
            *)
                log_warn "The directory '$DB_BASE_DIR' is outside your HOME. Confirm it is allowed in Docker Desktop > Settings > Resources > File sharing, otherwise the 'docker run -v ...' commands used to download the databases will mount an empty directory inside the container."
                ;;
        esac
    fi
}

dir_has_content() {
    [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]
}

download_bakta_db() {
    if [ "$SKIP_BAKTA_DB" = true ]; then
        log_warn "Bakta database download skipped (--skip-bakta-db)."
        return
    fi
    if dir_has_content "$DB_BASE_DIR/bakta_db" && [ "$FORCE" != true ]; then
        log_ok "Bakta database already seems to exist at $DB_BASE_DIR/bakta_db (use --force to redo)."
        return
    fi
    step "Downloading Bakta database (type: $BAKTA_DB_TYPE)"
    
    # Caminho absoluto para o bakta_db encontrado dentro da engbio/bakta:v1
    $DOCKER_CMD run --rm \
        --entrypoint /opt/conda/bin/bakta_db \
        -v "$DB_BASE_DIR/bakta_db:/db" \
        "$IMG_BAKTA" \
        download --output /db --type "$BAKTA_DB_TYPE"
        
    log_ok "Bakta database downloaded to $DB_BASE_DIR/bakta_db"
}

download_dfast_db() {
    if [ "$SKIP_DFAST_DB" = true ]; then
        log_warn "DFAST database download skipped (--skip-dfast-db)."
        return
    fi
    if dir_has_content "$DB_BASE_DIR/dfast_db" && [ "$FORCE" != true ]; then
        log_ok "DFAST database already seems to exist at $DB_BASE_DIR/dfast_db (use --force to redo)."
        return
    fi
    step "Downloading DFAST databases (proteins, COG/CDD, TIGRFAMs)"

    log_info "  -> Reference protein database..."
    $DOCKER_CMD run --rm \
        --entrypoint python \
        -v "$DB_BASE_DIR/dfast_db:/dfast_core/db" \
        "$IMG_DFAST" \
        /dfast_core/scripts/file_downloader.py --protein dfast

    log_info "  -> COG/CDD database..."
    $DOCKER_CMD run --rm \
        --entrypoint python \
        -v "$DB_BASE_DIR/dfast_db:/dfast_core/db" \
        "$IMG_DFAST" \
        /dfast_core/scripts/file_downloader.py --cdd Cog

    log_info "  -> TIGRFAMs (HMM) database..."
    $DOCKER_CMD run --rm \
        --entrypoint python \
        -v "$DB_BASE_DIR/dfast_db:/dfast_core/db" \
        "$IMG_DFAST" \
        /dfast_core/scripts/file_downloader.py --hmm TIGR

    log_ok "DFAST databases downloaded to $DB_BASE_DIR/dfast_db"
}

download_eggnog_db() {
    if [ "$SKIP_EGGNOG_DB" = true ]; then
        log_warn "eggNOG-mapper database download skipped (--skip-eggnog-db)."
        return
    fi
    if dir_has_content "$DB_BASE_DIR/eggnog_db" && [ "$FORCE" != true ]; then
        log_ok "eggNOG database already seems to exist at $DB_BASE_DIR/eggnog_db (use --force to redo)."
        return
    fi
    step "Downloading eggNOG-mapper database (image: $IMG_EGGNOG)"
    log_info "This downloads eggnog.db, eggnog_proteins.dmnd (DIAMOND), and eggnog.taxa.db — it may take quite a while (tens of GB)."

    $DOCKER_CMD run --rm \
        --entrypoint download_eggnog_data.py \
        -v "$DB_BASE_DIR/eggnog_db:/eggnog_db" \
        "$IMG_EGGNOG" \
        --data_dir /eggnog_db -y
        
    log_ok "eggNOG-mapper database downloaded to $DB_BASE_DIR/eggnog_db"
}

do_download_databases() {
    if [ "$SKIP_DB" = true ]; then
        log_warn "All database downloads skipped (--skip-db)."
        return
    fi
    prepare_db_dirs
    download_bakta_db
    download_dfast_db
    download_eggnog_db
}

# =============================================================================
# 7. DOWNLOAD PGAP (database stays in the user's HOME, managed by pgap.py itself)
# =============================================================================
do_setup_pgap() {
    if [ "$SKIP_PGAP" = true ]; then
        log_warn "PGAP setup skipped (--skip-pgap)."
        return
    fi
    if [ -z "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR" ]; then
        log_warn "Project directory not available (repository was not cloned in this run); skipping PGAP step. Run with --repo/--install-dir set correctly or without --skip-clone."
        return
    fi

    step "Setting up PGAP (database stays in ~/.pgap, managed by PGAP itself)"

    if [ "$OS_TYPE" = "macos" ]; then
        log_warn "PGAP (NCBI) is officially developed and tested only on Linux. On macOS it may work via Docker, but there is no official NCBI support — if it fails, consider running this step inside a Linux VM/container."
    fi

    cd "$PROJECT_DIR"

    if [ ! -f pgap.py ] || [ "$FORCE" = true ]; then
        log_info "Downloading pgap.py..."
        curl -fsSL -o pgap.py "$PGAP_SCRIPT_URL"
        chmod +x pgap.py
    else
        log_ok "pgap.py already present at $PROJECT_DIR"
    fi

    log_info "Updating/downloading the PGAP database (python pgap.py --update)..."
    log_warn "This step downloads several GB and may take quite a while."
    python3 pgap.py --update
    log_ok "PGAP updated."
}

# =============================================================================
# SUMMARY
# =============================================================================
print_summary() {
    echo
    echo -e "${C_BOLD}================================================================${C_NC}"
    echo -e "${C_BOLD} Installation complete — SnakeMergeAnnotation${C_NC}"
    echo -e "${C_BOLD}================================================================${C_NC}"
    echo "Operating system    : $OS_TYPE ($OS_FAMILY)"
    [ "$SKIP_VENV" = false ]  && echo "Virtualenv           : $VENV_DIR"
    [ "$SKIP_CLONE" = false ] && echo "Project              : ${PROJECT_DIR:-'(not cloned)'}"
    [ "$SKIP_DB" = false ]    && echo "Databases            : $DB_BASE_DIR"
    echo
    echo "Next steps:"
    [ "${NEED_RELOGIN:-false}" = true ] && \
        echo -e "  ${C_YELLOW}*${C_NC} LOGOUT/LOGIN (or 'newgrp docker') to use 'docker' without sudo."
    [ "$SKIP_VENV" = false ] && \
        echo "  * Activate the virtualenv:  source $VENV_DIR/bin/activate"
    echo "  * Adjust your config.yaml pointing to:"
    [ "$SKIP_DB" = false ] && echo "      - bakta.db_path:   $DB_BASE_DIR/bakta_db"
    [ "$SKIP_DB" = false ] && echo "      - dfast.db_path:   $DB_BASE_DIR/dfast_db"
    [ "$SKIP_DB" = false ] && echo "      - eggnog.db_path:  $DB_BASE_DIR/eggnog_db"
    [ "$SKIP_DB" = false ] && echo "      - eggnog.docker_image: $IMG_EGGNOG"
    echo "  * Run the pipeline with: snakemake --configfile config.yaml ..."
    echo -e "${C_BOLD}================================================================${C_NC}"
}

# =============================================================================
# MAIN
# =============================================================================
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
