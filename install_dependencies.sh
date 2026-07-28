#!/usr/bin/env bash
# =============================================================================
# install_dependencies.sh — SnakeMergeAnnotation
# =============================================================================
# Instala TODAS as dependências do pipeline:
#   1. Docker (detecta o SO automaticamente)
#   2. Docker sem sudo (grupo "docker", em Linux)
#   3. Ambiente virtual Python (venv) + Snakemake
#   4. Clone do repositório SnakeMergeAnnotation
#   5. Bancos de dados: Bakta (light), DFAST (proteínas/COG/TIGRFAMs),
#      eggNOG-mapper (versão mais recente estável) — tudo em /opt (Linux)
#   6. PGAP: baixa o pgap.py e roda "pgap.py --update" (fica no HOME do
#      usuário, como o próprio PGAP gerencia por padrão)
#
# Uso:
#   chmod +x install_dependencies.sh
#   ./install_dependencies.sh [opções]
#
# Opções:
#   --skip-docker       Não instala/configura o Docker
#   --skip-venv         Não cria o virtualenv nem instala o Snakemake
#   --skip-clone        Não clona o repositório
#   --skip-db           Não baixa nenhum banco de dados (bakta/dfast/eggnog)
#   --skip-bakta-db     Pula só o banco do Bakta
#   --skip-dfast-db     Pula só o banco do DFAST
#   --skip-eggnog-db    Pula só o banco do eggNOG-mapper
#   --skip-pgap         Não baixa/atualiza o banco do PGAP
#   --bakta-full        Baixa o banco COMPLETO do Bakta (padrão: light)
#   --db-dir DIR        Diretório base dos bancos (padrão: /opt/snakeMergeAnnotation/databases
#                        no Linux; $HOME/snakeMergeAnnotation/databases no macOS,
#                        para evitar problemas de permissão em /opt e de
#                        "file sharing" do Docker Desktop)
#   --venv-dir DIR      Caminho do virtualenv (padrão: $HOME/venv)
#   --install-dir DIR   Onde clonar o repositório (padrão: $HOME)
#   --repo URL          URL do repositório git
#   --force             Refaz etapas mesmo se já parecerem concluídas
#   -h, --help          Mostra esta ajuda
# =============================================================================

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/allanverasce/snakemergeannotation.git}"
INSTALL_DIR="${INSTALL_DIR:-$HOME}"
VENV_DIR="${VENV_DIR:-$HOME/venv}"
# Sentinela: o valor real é resolvido depois da detecção do SO (ver
# resolve_db_base_dir), pois o padrão correto muda entre Linux e macOS.
DB_BASE_DIR="${DB_BASE_DIR:-__AUTO__}"

BAKTA_DB_TYPE="${BAKTA_DB_TYPE:-light}"          # light | full
IMG_BAKTA="${IMG_BAKTA:-engbio/bakta:v1}"
IMG_DFAST="${IMG_DFAST:-engbio/dfast:v1}"
# Ajuste para bater exatamente com "eggnog.docker_image" do seu config.yaml.
# Padrão: build oficial biocontainers, tag alinhada à última release estável
# do eggNOG-mapper (2.1.15 — compatível com o banco eggNOG v5). A v3 (eggNOG
# v7) ainda está em desenvolvimento ativo no momento deste script.
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
log_warn(){ echo -e "${C_YELLOW}[AVISO]${C_NC} $*"; }
log_err(){  echo -e "${C_RED}[ERRO]${C_NC}  $*" >&2; }
step(){     echo -e "\n${C_BOLD}==> $*${C_NC}"; }
die(){ log_err "$*"; exit 1; }

# -----------------------------------------------------------------------------
# ARGUMENTOS
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
        *) die "Opção desconhecida: $1 (use --help)" ;;
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
    step "Detectando sistema operacional"
    case "$(uname -s)" in
        Linux*)
            OS_TYPE="linux"
            if grep -qi microsoft /proc/version 2>/dev/null; then
                IS_WSL=true
                log_warn "Ambiente WSL detectado. O Docker Desktop (com integração WSL2) ou dockerd nativo dentro do WSL devem funcionar normalmente."
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
                            *debian*) OS_FAMILY="debian"; PKG_MANAGER="apt" ;;
                            *rhel*|*fedora*) OS_FAMILY="rhel"; PKG_MANAGER="dnf" ;;
                            *arch*) OS_FAMILY="arch"; PKG_MANAGER="pacman" ;;
                            *suse*) OS_FAMILY="suse"; PKG_MANAGER="zypper" ;;
                            *) OS_FAMILY="desconhecida"; PKG_MANAGER="desconhecido" ;;
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
        linux)   log_ok "Linux detectado — distribuição: ${ID:-desconhecida} (família: $OS_FAMILY, gerenciador: $PKG_MANAGER)" ;;
        macos)   log_ok "macOS detectado (versão $(sw_vers -productVersion 2>/dev/null || echo '?'))" ;;
        windows) die "Windows nativo (fora do WSL) não é suportado diretamente. Instale o WSL2 (https://learn.microsoft.com/windows/wsl/install) e rode este script dentro dele." ;;
        *)       die "Sistema operacional não reconhecido ($(uname -s))." ;;
    esac
}


resolve_db_base_dir() {
    if [ "$DB_BASE_DIR" = "__AUTO__" ]; then
        if [ "$OS_TYPE" = "macos" ]; then
            DB_BASE_DIR="$HOME/snakeMergeAnnotation/databases"
        else
            DB_BASE_DIR="/opt/snakeMergeAnnotation/databases"
        fi
        log_info "Diretório de bancos de dados não informado; usando padrão para $OS_TYPE: $DB_BASE_DIR"
    fi
}

# =============================================================================
# 2. DOCKER INSTALATION
# =============================================================================
install_prereqs_linux() {
    case "$PKG_MANAGER" in
        apt)
            sudo apt-get update -y
            sudo apt-get install -y ca-certificates curl git build-essential
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
            log_warn "Gerenciador de pacotes não identificado; presumindo curl/git já instalados."
            ;;
    esac
}

install_docker_linux() {
    if command -v docker >/dev/null 2>&1 && [ "$FORCE" != true ]; then
        log_ok "Docker já instalado: $(docker --version)"
        return
    fi

    log_info "Instalando Docker Engine..."
    case "$PKG_MANAGER" in
        arch)
            sudo pacman -Sy --noconfirm --needed docker docker-buildx
            ;;
        *)
            # Script oficial de conveniência do Docker detecta apt/dnf/zypper
            # internamente e cobre Debian/Ubuntu/Fedora/RHEL/CentOS/openSUSE.
            curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
            sudo sh /tmp/get-docker.sh
            rm -f /tmp/get-docker.sh
            ;;
    esac

    sudo systemctl enable --now docker 2>/dev/null || \
        log_warn "Não foi possível habilitar o serviço docker via systemctl (verifique manualmente se o daemon está ativo — comum em WSL sem systemd habilitado)."

    log_ok "Docker instalado: $(docker --version 2>/dev/null || echo 'verifique manualmente')"
}

setup_docker_rootless_group() {
    # "Docker sem sudo" = usuário no grupo 'docker' (abordagem padrão e
    # oficialmente documentada pela Docker Inc. para uso sem sudo).
    step "Configurando Docker sem necessidade de sudo (grupo 'docker')"

    if [ "$IS_WSL" = true ] && command -v docker.exe >/dev/null 2>&1; then
        log_info "WSL com Docker Desktop detectado (docker.exe no PATH); o daemon roda no Windows e é exposto via socket — grupo 'docker' local não é necessário."
    fi

    if ! getent group docker >/dev/null 2>&1; then
        sudo groupadd docker
        log_ok "Grupo 'docker' criado."
    fi

    if id -nG "$USER" | grep -qw docker; then
        log_ok "Usuário '$USER' já pertence ao grupo 'docker'."
    else
        sudo usermod -aG docker "$USER"
        log_warn "Usuário '$USER' adicionado ao grupo 'docker'. É necessário FAZER LOGOUT/LOGIN (ou reiniciar) para valer nesta e nas próximas sessões de terminal."
        NEED_RELOGIN=true
    fi

    # Testa se o grupo já está ativo NESTA sessão de shell.
    if docker info >/dev/null 2>&1; then
        DOCKER_CMD="docker"
        log_ok "Docker responde sem sudo nesta sessão."
    else
        log_warn "Grupo 'docker' ainda não está ativo nesta sessão de terminal."
        log_warn "Este script vai usar 'sudo docker' apenas para TERMINAR a instalação agora."
        log_warn "Depois de logar novamente, use 'docker' normalmente, sem sudo."
        DOCKER_CMD="sudo docker"
    fi
}

setup_docker_macos() {
    step "Configurando Docker no macOS"
    if command -v docker >/dev/null 2>&1; then
        log_ok "Docker já instalado: $(docker --version)"
    elif command -v brew >/dev/null 2>&1; then
        log_info "Instalando Docker Desktop via Homebrew (cask)..."
        brew install --cask docker
        log_warn "Abra o aplicativo Docker Desktop manualmente ao menos uma vez para concluir a configuração (é necessário aceitar permissões do macOS)."
    else
        die "Homebrew não encontrado. Instale o Docker Desktop manualmente em https://www.docker.com/products/docker-desktop/ e rode este script novamente com --skip-docker."
    fi
    # No macOS o Docker Desktop já roda sem sudo por padrão (usa uma VM interna).
    DOCKER_CMD="docker"
}

do_install_docker() {
    if [ "$SKIP_DOCKER" = true ]; then
        log_warn "Instalação do Docker pulada (--skip-docker). Assumindo 'docker' disponível no PATH."
        DOCKER_CMD="docker"
        return
    fi
    step "Instalando/verificando Docker"
    case "$OS_TYPE" in
        linux)
            install_prereqs_linux
            install_docker_linux
            setup_docker_rootless_group
            ;;
        macos)
            setup_docker_macos
            ;;
    esac

    log_info "Testando Docker (${DOCKER_CMD})..."
    if $DOCKER_CMD run --rm hello-world >/dev/null 2>&1; then
        log_ok "Docker funcionando corretamente."
    else
        if [ "$OS_TYPE" = "macos" ]; then
            log_warn "Não foi possível rodar 'hello-world'. Se o Docker Desktop acabou de ser instalado, abra o aplicativo manualmente uma vez (ele precisa inicializar sua VM interna) e rode o script de novo, ou continue depois de confirmar que o Docker Desktop está com o ícone ativo na barra de menus."
        else
            log_warn "Não foi possível rodar 'hello-world' automaticamente. Verifique o Docker manualmente se algo falhar mais adiante (em WSL sem systemd pode ser necessário iniciar o daemon com 'sudo service docker start')."
        fi
    fi
}

# =============================================================================
# 3. VIRTUALENV PYTHON + SNAKEMAKE
# =============================================================================
do_setup_venv() {
    if [ "$SKIP_VENV" = true ]; then
        log_warn "Criação do virtualenv pulada (--skip-venv)."
        return
    fi
    step "Criando ambiente virtual Python em: $VENV_DIR"

    command -v python3 >/dev/null 2>&1 || die "python3 não encontrado. Instale o Python 3 antes de continuar (macOS: 'brew install python3'; Linux: pacote python3 do seu gerenciador)."

    if [ -d "$VENV_DIR" ] && [ "$FORCE" != true ]; then
        log_ok "Virtualenv já existe em $VENV_DIR (use --force para recriar)."
    else
        python3 -m venv "$VENV_DIR"
        log_ok "Virtualenv criado em $VENV_DIR"
    fi

    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"
    pip install --upgrade pip --quiet
    pip install snakemake --quiet
    log_ok "Snakemake instalado: $(snakemake --version)"
    deactivate
}

# =============================================================================
# 4. DOWNLOAD FROM GITHUB
# =============================================================================
PROJECT_DIR=""

do_clone_repo() {
    if [ "$SKIP_CLONE" = true ]; then
        log_warn "Clone do repositório pulado (--skip-clone)."
        return
    fi
    step "Clonando repositório SnakeMergeAnnotation"

    command -v git >/dev/null 2>&1 || die "git não encontrado. Instale o git antes de continuar."

    mkdir -p "$INSTALL_DIR"
    local dir_name
    dir_name="$(basename "$REPO_URL" .git)"
    PROJECT_DIR="$INSTALL_DIR/$dir_name"

    if [ -d "$PROJECT_DIR/.git" ] && [ "$FORCE" != true ]; then
        log_ok "Repositório já clonado em $PROJECT_DIR"
    else
        (cd "$INSTALL_DIR" && git clone "$REPO_URL")
        log_ok "Repositório clonado em $PROJECT_DIR"
    fi
}

# =============================================================================
# 5. DOWNLOAD DATABASES
# =============================================================================
prepare_db_dirs() {
    step "Preparando diretório de bancos de dados: $DB_BASE_DIR"
    if [ "$OS_TYPE" = "linux" ]; then
        sudo mkdir -p "$DB_BASE_DIR"/{bakta_db,dfast_db,eggnog_db}
        sudo chown -R "$USER":"$(id -gn)" "$DB_BASE_DIR"
    else
        mkdir -p "$DB_BASE_DIR"/{bakta_db,dfast_db,eggnog_db}
    fi
    log_ok "Diretórios prontos e com permissão para '$USER'."

    if [ "$OS_TYPE" = "macos" ]; then
        case "$DB_BASE_DIR" in
            "$HOME"/*) : ;; # dentro do HOME: compartilhado por padrão no Docker Desktop
            *)
                log_warn "O diretório '$DB_BASE_DIR' está fora do seu HOME. Confirme que ele está liberado em Docker Desktop > Settings > Resources > File sharing, senão os 'docker run -v ...' usados para baixar os bancos vão montar um diretório vazio dentro do container."
                ;;
        esac
    fi
}

dir_has_content() {
    [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]
}

download_bakta_db() {
    if [ "$SKIP_BAKTA_DB" = true ]; then
        log_warn "Download do banco Bakta pulado (--skip-bakta-db)."
        return
    fi
    if dir_has_content "$DB_BASE_DIR/bakta_db" && [ "$FORCE" != true ]; then
        log_ok "Banco Bakta já parece existir em $DB_BASE_DIR/bakta_db (use --force para refazer)."
        return
    fi
    step "Baixando banco de dados do Bakta (tipo: $BAKTA_DB_TYPE)"
    $DOCKER_CMD run --rm \
        -v "$DB_BASE_DIR/bakta_db:/db" \
        "$IMG_BAKTA" \
        bakta_db --output /db download --type "$BAKTA_DB_TYPE"
    log_ok "Banco Bakta baixado em $DB_BASE_DIR/bakta_db"
}

download_dfast_db() {
    if [ "$SKIP_DFAST_DB" = true ]; then
        log_warn "Download do banco DFAST pulado (--skip-dfast-db)."
        return
    fi
    if dir_has_content "$DB_BASE_DIR/dfast_db" && [ "$FORCE" != true ]; then
        log_ok "Banco DFAST já parece existir em $DB_BASE_DIR/dfast_db (use --force para refazer)."
        return
    fi
    step "Baixando bancos de dados do DFAST (proteínas, COG/CDD, TIGRFAMs)"

    log_info "  -> Banco de proteínas de referência..."
    $DOCKER_CMD run --rm \
        -v "$DB_BASE_DIR/dfast_db:/dfast_core/db" \
        "$IMG_DFAST" \
        python /dfast_core/scripts/file_downloader.py --protein dfast

    log_info "  -> Banco COG/CDD..."
    $DOCKER_CMD run --rm \
        -v "$DB_BASE_DIR/dfast_db:/dfast_core/db" \
        "$IMG_DFAST" \
        python /dfast_core/scripts/file_downloader.py --cdd Cog

    log_info "  -> Banco TIGRFAMs (HMM)..."
    $DOCKER_CMD run --rm \
        -v "$DB_BASE_DIR/dfast_db:/dfast_core/db" \
        "$IMG_DFAST" \
        python /dfast_core/scripts/file_downloader.py --hmm TIGR

    log_ok "Bancos DFAST baixados em $DB_BASE_DIR/dfast_db"
}

download_eggnog_db() {
    if [ "$SKIP_EGGNOG_DB" = true ]; then
        log_warn "Download do banco eggNOG-mapper pulado (--skip-eggnog-db)."
        return
    fi
    if dir_has_content "$DB_BASE_DIR/eggnog_db" && [ "$FORCE" != true ]; then
        log_ok "Banco eggNOG já parece existir em $DB_BASE_DIR/eggnog_db (use --force para refazer)."
        return
    fi
    step "Baixando banco de dados do eggNOG-mapper (imagem: $IMG_EGGNOG)"
    log_info "Isso baixa eggnog.db, eggnog_proteins.dmnd (DIAMOND) e eggnog.taxa.db — pode levar bastante tempo (dezenas de GB)."

    # download_eggnog_data.py pede confirmação interativa [y,n] para cada
    # banco; -y assume 'sim' para todas as perguntas (execução não-interativa).
    # Tentamos primeiro assumindo que o script já está no PATH da imagem
    # (mesmo padrão usado no Snakefile para 'emapper.py'); se falhar, tenta
    # de novo forçando o entrypoint — cobre imagens com ENTRYPOINT diferente.
    if ! $DOCKER_CMD run --rm \
            -v "$DB_BASE_DIR/eggnog_db:/eggnog_db" \
            "$IMG_EGGNOG" \
            download_eggnog_data.py --data_dir /eggnog_db -y; then
        log_warn "Chamada direta falhou; tentando novamente forçando o entrypoint..."
        $DOCKER_CMD run --rm \
            --entrypoint download_eggnog_data.py \
            -v "$DB_BASE_DIR/eggnog_db:/eggnog_db" \
            "$IMG_EGGNOG" \
            --data_dir /eggnog_db -y
    fi
    log_ok "Banco eggNOG-mapper baixado em $DB_BASE_DIR/eggnog_db"
}

do_download_databases() {
    if [ "$SKIP_DB" = true ]; then
        log_warn "Download de todos os bancos de dados pulado (--skip-db)."
        return
    fi
    prepare_db_dirs
    download_bakta_db
    download_dfast_db
    download_eggnog_db
}

# =============================================================================
# 6. DOWNLOAD PGAP (banco fica no HOME do usuário, gerenciado pelo próprio pgap.py)
# =============================================================================
do_setup_pgap() {
    if [ "$SKIP_PGAP" = true ]; then
        log_warn "Configuração do PGAP pulada (--skip-pgap)."
        return
    fi
    if [ -z "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR" ]; then
        log_warn "Diretório do projeto não disponível (repositório não foi clonado nesta execução); pulando etapa do PGAP. Rode com --repo/--install-dir corretos ou sem --skip-clone."
        return
    fi

    step "Configurando PGAP (banco de dados fica em ~/.pgap, gerenciado pelo próprio PGAP)"

    if [ "$OS_TYPE" = "macos" ]; then
        log_warn "O PGAP (NCBI) é desenvolvido e testado oficialmente apenas em Linux. Em macOS ele pode funcionar via Docker, mas não há suporte oficial da NCBI — se falhar, considere rodar essa etapa dentro de uma VM/container Linux."
    fi

    cd "$PROJECT_DIR"

    if [ ! -f pgap.py ] || [ "$FORCE" = true ]; then
        log_info "Baixando pgap.py..."
        curl -fsSL -o pgap.py "$PGAP_SCRIPT_URL"
        chmod +x pgap.py
    else
        log_ok "pgap.py já presente em $PROJECT_DIR"
    fi

    log_info "Atualizando/baixando o banco de dados do PGAP (python pgap.py --update)..."
    log_warn "Esta etapa baixa vários GB e pode demorar bastante."
    python3 pgap.py --update
    log_ok "PGAP atualizado."
}

# =============================================================================
# SUMMARY
# =============================================================================
print_summary() {
    echo
    echo -e "${C_BOLD}================================================================${C_NC}"
    echo -e "${C_BOLD} Instalação concluída — SnakeMergeAnnotation${C_NC}"
    echo -e "${C_BOLD}================================================================${C_NC}"
    echo "Sistema operacional : $OS_TYPE ($OS_FAMILY)"
    [ "$SKIP_VENV" = false ]  && echo "Virtualenv           : $VENV_DIR"
    [ "$SKIP_CLONE" = false ] && echo "Projeto               : ${PROJECT_DIR:-'(não clonado)'}"
    [ "$SKIP_DB" = false ]    && echo "Bancos de dados        : $DB_BASE_DIR"
    echo
    echo "Próximos passos:"
    [ "${NEED_RELOGIN:-false}" = true ] && \
        echo -e "  ${C_YELLOW}*${C_NC} Faça LOGOUT/LOGIN (ou 'newgrp docker') para usar 'docker' sem sudo."
    [ "$SKIP_VENV" = false ] && \
        echo "  * Ative o virtualenv:  source $VENV_DIR/bin/activate"
    echo "  * Ajuste seu config.yaml apontando para:"
    [ "$SKIP_DB" = false ] && echo "      - bakta.db_path:   $DB_BASE_DIR/bakta_db"
    [ "$SKIP_DB" = false ] && echo "      - dfast.db_path:   $DB_BASE_DIR/dfast_db"
    [ "$SKIP_DB" = false ] && echo "      - eggnog.db_path:  $DB_BASE_DIR/eggnog_db"
    [ "$SKIP_DB" = false ] && echo "      - eggnog.docker_image: $IMG_EGGNOG (confirme que bate com o que você quer usar)"
    echo "  * Rode o pipeline com: snakemake --configfile config.yaml ..."
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
    do_install_docker
    do_setup_venv
    do_clone_repo
    do_download_databases
    do_setup_pgap
    print_summary
}

main "$@"
