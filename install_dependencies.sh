#!/usr/bin/env bash
# =============================================================================
# install_dependencies.sh — SnakeMergeAnnotation (Local Install)
# =============================================================================

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/allanverasce/snakemergeannotation.git}"
DB_BASE_DIR="${DB_BASE_DIR:-_AUTO_}"

BAKTA_DB_TYPE="${BAKTA_DB_TYPE:-light}"
IMG_BAKTA="${IMG_BAKTA:-engbio/bakta:v1}"
IMG_DFAST="${IMG_DFAST:-engbio/dfast:v1}"

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
        --force)           FORCE=true; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) die "Unknown option: $1 (use --help)" ;;
    esac
done

OS_TYPE="unknown"
OS_FAMILY="unknown"
PKG_MANAGER="unknown"

detect_os() {
    step "Detecting operating system"
    case "$(uname -s)" in
        Linux*)
            OS_TYPE="linux"
            if [ -r /etc/os-release ]; then
                . /etc/os-release
                case "${ID:-}" in
                    ubuntu|debian|linuxmint|pop) OS_FAMILY="debian"; PKG_MANAGER="apt" ;;
                    *) OS_FAMILY="unknown"; PKG_MANAGER="unknown" ;;
                esac
            fi
            ;;
        *) OS_TYPE="unknown" ;;
    esac
    log_ok "OS detected: $OS_TYPE ($OS_FAMILY)"
}

setup_directories() {
    step "Setting up local isolation directories"
    
    # Define o BASE_DIR como a pasta onde este script está localizado
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BASE_DIR="$SCRIPT_DIR"
    
    # Se o script estiver sendo rodado de dentro do repositório já clonado
    if [ -d "$SCRIPT_DIR/.git" ] || [ -f "$SCRIPT_DIR/Snakefile" ]; then
        PROJECT_DIR="$SCRIPT_DIR"
        SKIP_CLONE=true
        log_info "Running inside project directory: $PROJECT_DIR"
    else
        PROJECT_DIR="$BASE_DIR/pipeline"
        log_info "Project will be cloned to: $PROJECT_DIR"
        mkdir -p "$PROJECT_DIR"
    fi

    VENV_DIR="${VENV_DIR:-$PROJECT_DIR/venv}"
    
    if [ "$DB_BASE_DIR" = "_AUTO_" ]; then
        DB_BASE_DIR="$BASE_DIR/databases"
    fi
    mkdir -p "$DB_BASE_DIR"
    
    log_info "Virtual environment: $VENV_DIR"
    log_info "Database directory: $DB_BASE_DIR"
}

do_install_prereqs() {
    step "Installing system prerequisites"
    if [ "$OS_TYPE" = "linux" ] && [ "$PKG_MANAGER" = "apt" ]; then
        sudo apt-get update -y
        sudo apt-get install -y ca-certificates curl wget git build-essential python3-venv python3-pip python3-tk gzip tar
    fi
}

install_docker_linux() {
    if command -v docker >/dev/null 2>&1; then return; fi
    log_info "Installing Docker Engine..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sudo sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
    sudo systemctl enable --now docker 2>/dev/null || true
}

setup_docker_rootless_group() {
    if ! getent group docker >/dev/null 2>&1; then sudo groupadd docker; fi
    if ! id -nG "$USER" | grep -qw docker; then sudo usermod -aG docker "$USER"; fi
    
    if docker info >/dev/null 2>&1; then
        DOCKER_CMD="docker"
    else
        DOCKER_CMD="sudo docker"
    fi
}

do_install_docker() {
    if [ "$SKIP_DOCKER" = true ]; then DOCKER_CMD="docker"; return; fi
    step "Checking Docker setup"
    install_docker_linux
    setup_docker_rootless_group
    log_ok "Docker is ready."
}

do_clone_repo() {
    if [ "$SKIP_CLONE" = true ]; then return; fi
    step "Cloning SnakeMergeAnnotation repository"
    
    if { [ -d "$PROJECT_DIR/.git" ] || [ -f "$PROJECT_DIR/Snakefile" ]; } && [ "$FORCE" != true ]; then
        log_ok "Arquivos do projeto já identificados em $PROJECT_DIR. Pulando clonagem."
    else
        if [ -d "$PROJECT_DIR" ] && [ "$(ls -A "$PROJECT_DIR" 2>/dev/null)" ]; then
            log_warn "A pasta $PROJECT_DIR já existe e contém arquivos. Pulando clonagem por segurança."
            return
        fi
        git clone "$REPO_URL" "$PROJECT_DIR"
        log_ok "Repositório clonado."
    fi
}

do_setup_venv() {
    if [ "$SKIP_VENV" = true ]; then return; fi
    step "Creating isolated Python virtual environment"
    if [ ! -f "$VENV_DIR/bin/activate" ] || [ "$FORCE" = true ]; then
        rm -rf "$VENV_DIR"
        python3 -m venv "$VENV_DIR"
    fi
    source "$VENV_DIR/bin/activate"
    pip install --upgrade pip --quiet
    pip install snakemake flask --quiet
    log_ok "Virtualenv ready inside project. Snakemake and Flask installed."
    deactivate
}

prepare_db_dirs() {
    step "Preparing database directories"
    mkdir -p "$DB_BASE_DIR"/{bakta_db,dfast_db,eggnog_db}
}

dir_has_content() { [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]; }

download_bakta_db() {
    if [ "$SKIP_BAKTA_DB" = true ]; then return; fi
    if dir_has_content "$DB_BASE_DIR/bakta_db" && [ "$FORCE" != true ]; then log_ok "Bakta DB exists."; return; fi
    step "Downloading Bakta database"
    $DOCKER_CMD run --rm --entrypoint sh -v "$DB_BASE_DIR/bakta_db:/db" oschwengers/bakta:latest -c 'BAKTA_BIN=$(find / -name bakta_db -type f 2>/dev/null | grep "bin/bakta_db" | head -n 1); export PATH="$(dirname "$BAKTA_BIN"):$PATH"; "$BAKTA_BIN" download --output /db --type '"$BAKTA_DB_TYPE"
}

download_dfast_db() {
    if [ "$SKIP_DFAST_DB" = true ]; then return; fi
    if dir_has_content "$DB_BASE_DIR/dfast_db" && [ "$FORCE" != true ]; then log_ok "DFAST DB exists."; return; fi
    step "Downloading DFAST databases"
    $DOCKER_CMD run --rm --entrypoint python -v "$DB_BASE_DIR/dfast_db:/dfast_core/db" "$IMG_DFAST" /dfast_core/scripts/file_downloader.py --protein dfast
    $DOCKER_CMD run --rm --entrypoint python -v "$DB_BASE_DIR/dfast_db:/dfast_core/db" "$IMG_DFAST" /dfast_core/scripts/file_downloader.py --cdd Cog
    $DOCKER_CMD run --rm --entrypoint python -v "$DB_BASE_DIR/dfast_db:/dfast_core/db" "$IMG_DFAST" /dfast_core/scripts/file_downloader.py --hmm TIGR
}

download_eggnog_db() {
    if [ "$SKIP_EGGNOG_DB" = true ]; then 
        return
    fi

    local eggnog_dir="$DB_BASE_DIR/eggnog_db"

    if dir_has_content "$eggnog_dir" && [ "$FORCE" != true ]; then
        log_ok "eggNOG database exists."
        return
    fi

    step "Downloading eggNOG database"

    mkdir -p "$eggnog_dir"

    log_info "Downloading eggNOG data using $IMG_EGGNOG"

    $DOCKER_CMD run --rm \
        -v "$eggnog_dir:/opt/snakemergeannotation/databases" \
        "$IMG_EGGNOG" \
        download_eggnog_data.py \
        --data_dir /opt/snakemergeannotation/databases \
        -y

    log_ok "eggNOG database installed in $eggnog_dir"
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
    step "Setting up PGAP"
    cd "$PROJECT_DIR"

    if [ ! -f pgap.py ] || [ "$FORCE" = true ]; then
        curl -fsSL -o pgap.py "$PGAP_SCRIPT_URL"
        chmod +x pgap.py
    fi

    if docker info >/dev/null 2>&1; then
        python3 pgap.py --update
    else
        log_warn "Docker needs sudo. Preserving seu HOME folder path during setup..."
        sudo HOME="$HOME" python3 pgap.py --update
        if [ -d "$HOME/.pgap" ]; then
            sudo chown -R "$USER":"$(id -gn)" "$HOME/.pgap"
        fi
    fi
    log_ok "PGAP setup complete."
}

print_summary() {
    echo -e "\n${C_BOLD}================================================================${C_NC}"
    echo -e "${C_BOLD} Sistema Instalado com Sucesso${C_NC}"
    echo -e " - Diretório da Pipeline: $PROJECT_DIR"
    echo -e " - Ambiente Virtual:      $VENV_DIR"
    echo -e " - Diretório de DBs:      $DB_BASE_DIR"
    echo -e "${C_BOLD}================================================================${C_NC}\n"
}

main() {
    detect_os
    setup_directories
    do_install_prereqs
    do_install_docker
    do_clone_repo
    do_setup_venv
    do_download_databases
    do_setup_pgap
    print_summary
}

main "$@"
