# =============================================================================
# Snakefile — SnakeMergeAnnotation workflow (PARALELIZADO VIA CONFIG)
# =============================================================================
# Usage:
#   snakemake --configfile config.yaml \
#             --cores all \
#             --jobs {max_jobs} \
#             --resources heavy_slots=<N> light_slots=<M> \
#             --keep-going \
#             --latency-wait 60 \
#             --rerun-incomplete
#
# Para definir a ordem das ferramentas (opcional):
#   --config merge.tool_order=prokka,dfast,pgap,eggnog
# (OBS: a ferramenta base e demais habilitadas serão adicionadas automaticamente)
# =============================================================================
import os
import glob
import subprocess
import re
import shutil

SNAKEFILE_DIR = os.path.dirname(workflow.snakefile)

# -----------------------------------------------------------------------------
# Funções auxiliares
# -----------------------------------------------------------------------------
def sanitize_prefix(name):
    """Substitui caracteres inválidos (como pontos) por underscore."""
    return re.sub(r'[^a-zA-Z0-9_-]', '_', name)


def mem_to_mb(mem_str):
    """Converte string como '24g' ou '24576m' para MB (int)."""
    mem_str = str(mem_str).lower().strip()
    match = re.match(r'^(\d+)([gm]?)$', mem_str)
    if not match:
        return 8192
    num, unit = match.groups()
    num = int(num)
    if unit == 'g':
        return num * 1024
    elif unit == 'm':
        return num
    else:
        return num


def parse_timeout(timeout_str):   
    match = re.match(r'^(\d+)([mh])$', str(timeout_str))
    if not match:
        raise ValueError(f"Formato inválido para timeout: {timeout_str}")
    value, unit = match.groups()
    value = int(value)
    if unit == 'h':
        return value * 60
    return value


def ensure_writable_dir(path):
    """Cria o diretório (se necessário) e garante permissão de escrita para
    qualquer UID usado dentro do container (-u $(id -u):$(id -g)).
    Isso evita falhas silenciosas de permissão que geram 'Missing output files'."""
    os.makedirs(path, exist_ok=True)
    try:
        os.chmod(path, 0o777)
    except PermissionError:
        # Diretório já existe com dono diferente; segue sem travar o pipeline.
        pass
    return path


def verify_output(path, tool_name, sample, search_dir=None, patterns=None):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return path

    if search_dir and patterns:
        found = []
        for pat in patterns:
            found.extend(glob.glob(os.path.join(search_dir, "**", pat), recursive=True))
        found = [f for f in found if os.path.getsize(f) > 0]
        if found:
            shutil.copy(found[0], path)
            print(f"[{tool_name}] Aviso: nome de saída divergente para '{sample}'. "
                  f"Copiado '{found[0]}' -> '{path}'")
            return path

    raise RuntimeError(
        f"[{tool_name}] Falha ao gerar saída esperada para a amostra '{sample}': "
        f"'{path}' não existe ou está vazio. Verifique o log da regra para o "
        f"erro real do container (provavelmente mascarado por falta de "
        f"'set -euo pipefail')."
    )


# =====================
# WATCHDOG CONFIGURATION
# =====================
MAX_RETRIES = int(config["watchdog"]["max_retries"])
INACTIVITY_TIMEOUT_STR = config["watchdog"]["inactivity_timeout"]
BASE_TIMEOUT_MIN = parse_timeout(INACTIVITY_TIMEOUT_STR)

LONG_RULES = ["run_eggnog", "annotate_pgap", "run_merge"]
EXTRA_TIME_MIN = 840


def get_timeout_min(rule_name):
    mins = BASE_TIMEOUT_MIN
    if rule_name in LONG_RULES:
        mins += EXTRA_TIME_MIN
    return mins


# =======
# BANNER
# =======
onstart:
    subprocess.run([
        "docker", "run", "--rm",
        "--entrypoint", "python",
        config["merge"]["docker_image"],
        "-c",
        """
import pyfiglet
GREEN = "\\033[32m"
RED   = "\\033[31m"
RESET = "\\033[0m"
print(GREEN + pyfiglet.figlet_format("SnakeMergeAnnotation", font="standard", width=200) + RESET)
print(RED   + pyfiglet.figlet_format("Software",             font="standard", width=200) + RESET)
"""
    ])

onerror:
    print("=" * 70)
    print("[SnakeMergeAnnotation] O pipeline falhou.")
    print(f"Verifique os logs em: {config['paths']['output_dir']}/logs/<regra>/<amostra>.log")
    print("Se o erro for 'Missing output files' em filesystem de rede, "
          "rode novamente com --latency-wait 60 (ou maior) e --rerun-incomplete.")
    print("=" * 70)

# =================
# CONFIG READING
# =================
FASTA_DIR  = config["paths"]["fasta_dir"]
OUTPUT_DIR = config["paths"]["output_dir"]
THREADS    = max(1, int(config["general"]["threads"]))  # guarda contra 0/valores inválidos

IMG_BAKTA   = config["bakta"]["docker_image"]
IMG_PROKKA  = config["prokka"]["docker_image"]
IMG_DFAST   = config["dfast"]["docker_image"]
IMG_PATRIC  = config["patric"]["docker_image"]
IMG_MERGE   = config["merge"]["docker_image"]
IMG_EGGNOG  = config["eggnog"]["docker_image"]

MEM_TOTAL = int(config["resources"]["mem_mb"])
MAX_JOBS = max(1, int(config["resources"]["max_jobs"]))
TOTAL_CORES = max(1, int(subprocess.getoutput("nproc") or "1"))

# PARALELISMO_* agora é efetivamente usado via `resources:` nas regras abaixo,
# através dos "resource pools" heavy_slots / light_slots do Snakemake.
MAX_PESADOS_POR_CORES = max(1, TOTAL_CORES // THREADS)
MAX_PESADOS_POR_MEM = max(1, MEM_TOTAL // 30000)
PARALELISMO_PESADO = max(1, min(MAX_JOBS, MAX_PESADOS_POR_CORES, MAX_PESADOS_POR_MEM))
PARALELISMO_LEVE = MAX_JOBS * 2

print(f"[SnakeMergeAnnotation] Paralelismo calculado: "
      f"heavy_slots={PARALELISMO_PESADO} (rode com --resources heavy_slots={PARALELISMO_PESADO} "
      f"light_slots={PARALELISMO_LEVE})")

DB_BAKTA      = config["bakta"]["db_path"]
BAKTA_GENUS   = config["bakta"].get("genus", "")
BAKTA_SPECIES = config["bakta"].get("species", "")
BAKTA_GRAM    = config["bakta"].get("gram", "?")
BAKTA_TTABLE  = config["bakta"].get("translation_table", 11)

PROKKA_GENUS   = config["prokka"].get("genus", "")
PROKKA_KINGDOM = config["prokka"].get("kingdom", "Bacteria")
PROKKA_GCODE   = config["prokka"].get("gcode", 11)

DB_DFAST = config["dfast"]["db_path"]

PATRIC_USER     = config["patric"]["username"]
PATRIC_PASS     = config["patric"]["password"]
PATRIC_TAXID    = config["patric"]["taxonomy_id"]
PATRIC_DESC     = config["patric"]["description"]
PATRIC_WS       = config["patric"]["workspace_output_dir"]
PATRIC_INTERVAL = config["patric"].get("monitor_interval", 60)

MERGE_MIN_PIDENT = config["merge"].get("min_pident", 95.0)
MERGE_MIN_QCOV   = config["merge"].get("min_qcov",   0.9)
MERGE_JOBS       = config["merge"].get("jobs",        2)

DB_EGGNOG        = config["eggnog"]["db_path"]
EGGNOG_SENSMODE  = config["eggnog"].get("sensmode", "diamond")

# ===========
# DIRECTORIES
# ===========
DIR_BAKTA   = os.path.join(OUTPUT_DIR, "bakta_out")
DIR_PROKKA  = os.path.join(OUTPUT_DIR, "prokka_out")
DIR_DFAST   = os.path.join(OUTPUT_DIR, "dfast_out")
DIR_PATRIC  = os.path.join(OUTPUT_DIR, "patric_out")
DIR_MERGE   = os.path.join(OUTPUT_DIR, "merge_input")
DIR_RESULT  = os.path.join(OUTPUT_DIR, "merge_results")
DIR_EGGNOG  = os.path.join(OUTPUT_DIR, "eggnog_out")
DIR_LOGS    = os.path.join(OUTPUT_DIR, "logs")

# Garante toda a árvore de diretórios de log/saída ANTES de qualquer regra
# rodar, evitando falhas de "diretório pai inexistente" em execuções paralelas.
for d in [DIR_BAKTA, DIR_PROKKA, DIR_DFAST, DIR_PATRIC, DIR_MERGE,
          DIR_RESULT, DIR_EGGNOG, DIR_LOGS]:
    ensure_writable_dir(d)
for sub in ["bakta", "prokka", "dfast", "patric", "eggnog", "pgap", "merge"]:
    ensure_writable_dir(os.path.join(DIR_LOGS, sub))

# ====================
# FLAGS PARA FERRAMENTAS
# ====================
PATRIC_ENABLED  = config.get("patric", {}).get("enabled", True)
BAKTA_ENABLED   = config.get("bakta", {}).get("enabled", True)
PROKKA_ENABLED  = config.get("prokka", {}).get("enabled", True)
DFAST_ENABLED   = config.get("dfast", {}).get("enabled", True)
PGAP_ENABLED    = config.get("pgap", {}).get("enabled", False)
EGGNOG_ENABLED  = config.get("eggnog", {}).get("enabled", True)

# ====================
# BASE TOOL
# ====================
BASE_TOOL = config.get("base_tool", "patric")
TOOL_EXT = {
    "patric": ".gb",
    "bakta": ".gbff",
    "prokka": ".gbk",
    "dfast": ".gbk",
    "pgap": ".gbk"
}
BASE_EXT = TOOL_EXT.get(BASE_TOOL, ".gb")

_ENABLED_MAP = {
    "patric": PATRIC_ENABLED,
    "bakta": BAKTA_ENABLED,
    "prokka": PROKKA_ENABLED,
    "dfast": DFAST_ENABLED,
    "pgap": PGAP_ENABLED,
}
if BASE_TOOL not in _ENABLED_MAP:
    raise ValueError(
        f"[SnakeMergeAnnotation] base_tool='{BASE_TOOL}' não é reconhecido. "
        f"Use um destes: {list(_ENABLED_MAP.keys())}"
    )
if not _ENABLED_MAP[BASE_TOOL]:
    enabled_options = [k for k, v in _ENABLED_MAP.items() if v]
    raise ValueError(
        f"[SnakeMergeAnnotation] base_tool='{BASE_TOOL}' está DESABILITADO "
        f"(confira '{BASE_TOOL}.enabled' no config.yaml, ou se você passou "
        f"--config base_tool={BASE_TOOL} na linha de comando sem também "
        f"habilitar a ferramenta). Ferramentas atualmente habilitadas: "
        f"{enabled_options if enabled_options else '[NENHUMA — verifique o config.yaml]'}. "
        f"Habilite '{BASE_TOOL}' (ex: --config {BASE_TOOL}.enabled=true) "
        f"ou escolha base_tool entre as ferramentas já habilitadas acima."
    )

# ====================
# TOOL ORDER (dinâmica com exclusão da base_tool)
# ====================
_TOOL_ORDER_RAW = config.get("merge", {}).get("tool_order", None)
VALID_STEPS = {"patric", "bakta", "prokka", "dfast", "pgap", "eggnog"}

# Monta lista de ferramentas habilitadas EXCLUINDO a base_tool
enabled_secondary = []
if PATRIC_ENABLED and BASE_TOOL != "patric":
    enabled_secondary.append("patric")
if BAKTA_ENABLED and BASE_TOOL != "bakta":
    enabled_secondary.append("bakta")
if PROKKA_ENABLED and BASE_TOOL != "prokka":
    enabled_secondary.append("prokka")
if DFAST_ENABLED and BASE_TOOL != "dfast":
    enabled_secondary.append("dfast")
if PGAP_ENABLED and BASE_TOOL != "pgap":
    enabled_secondary.append("pgap")
if EGGNOG_ENABLED and BASE_TOOL != "eggnog":
    enabled_secondary.append("eggnog")

if _TOOL_ORDER_RAW:   
    order_list = []
    seen = set()
    for item in str(_TOOL_ORDER_RAW).split(","):
        item = item.strip()
        if not item:
            continue
        if item not in VALID_STEPS:
            raise ValueError(f"Ferramenta inválida em merge.tool_order: '{item}'. Use: {sorted(VALID_STEPS)}")
        if item not in seen:
            seen.add(item)
            order_list.append(item)
    # Filtra apenas as ferramentas que estão habilitadas e não são a base
    order_list = [t for t in order_list if t in enabled_secondary]
    # Adiciona, no final, ferramentas habilitadas que não apareceram na ordem
    for t in enabled_secondary:
        if t not in seen:
            order_list.append(t)
            print(f"[Aviso] Ferramenta '{t}' habilitada não estava em merge.tool_order; adicionada ao final.")
else:
    # Ordem padrão (definida no config ou default) – usa apenas as habilitadas
    default_order = ["bakta", "prokka", "dfast", "pgap", "eggnog"]  # padrão do config
    order_list = [t for t in default_order if t in enabled_secondary]
    # Adiciona eventuais habilitadas que não estão no default (ex.: patric, se não for base)
    for t in enabled_secondary:
        if t not in order_list:
            order_list.append(t)

TOOL_ORDER = ",".join(order_list)

# String para usar nos nomes de arquivo (substitui vírgulas por hífen)
ORDER_STR = "-".join(order_list)
print(f"[SnakeMergeAnnotation] Ordem final das ferramentas (excluindo base_tool '{BASE_TOOL}'): {TOOL_ORDER}")
print(f"[SnakeMergeAnnotation] Suffix para relatórios: {ORDER_STR}")

# ====================
# PGAP CONFIG
# ====================
PGAP_SCRIPT = os.path.join(SNAKEFILE_DIR, config.get("pgap", {}).get("script_path", "pgap.py"))
PGAP_MEM = config.get("pgap", {}).get("mem", "24g")
PGAP_CPUS = config.get("pgap", {}).get("cpus", 8)
PGAP_EXTRA = config.get("pgap", {}).get("extra_args", "")
PGAP_SPECIES = config.get("pgap", {}).get("species", "")
DIR_PGAP = os.path.join(OUTPUT_DIR, "pgap_out")

# =====================
# SAMPLE DETECTION
# =====================
def get_samples():
    found = []
    for ext in ["*.fasta", "*.fa", "*.fna"]:
        for f in glob.glob(os.path.join(FASTA_DIR, ext)):
            name = os.path.splitext(os.path.basename(f))[0]
            if name not in found:
                found.append(name)
    if not found:
        raise ValueError(f"[SnakeMergeAnnotation] No FASTA found in: {FASTA_DIR}")
    return sorted(found)


SAMPLES = get_samples()
print(f"[SnakeMergeAnnotation] {len(SAMPLES)} genome(s) detected")

# =====================
# OUTPUT FILE PATTERNS
# =====================
CURED_PATTERN = "{sample}_cured.gb"

RESULT_BATCH_DIR = SAMPLES[0] if len(SAMPLES) == 1 else "batch_" + "-".join(SAMPLES)

# =====================
# PGAP RATE LIMIT CONTROL
# =====================
PGAP_INTERVAL_SEC = 70
PGAP_LOCK_DIR = os.path.join(OUTPUT_DIR, ".pgap_lock")
ensure_writable_dir(PGAP_LOCK_DIR)

# ===========
# FINAL RULE
# ===========
rule all:
    input:
        expand(os.path.join(DIR_PATRIC, "{sample}_patric.gb"), sample=SAMPLES) if PATRIC_ENABLED else [],
        expand(os.path.join(DIR_BAKTA, "{sample}", "{sample}_bakta.gbff"), sample=SAMPLES) if BAKTA_ENABLED else [],
        expand(os.path.join(DIR_PROKKA, "{sample}_prokka", "{sample}_prokka.gbk"), sample=SAMPLES) if PROKKA_ENABLED else [],
        expand(os.path.join(DIR_DFAST, "{sample}_dfast.gbk"), sample=SAMPLES) if DFAST_ENABLED else [],
        expand(os.path.join(DIR_PGAP, "{sample}", "{sample}_pgap.gbk"), sample=SAMPLES) if PGAP_ENABLED else [],
        expand(os.path.join(DIR_MERGE, CURED_PATTERN), sample=SAMPLES),
        expand(os.path.join(DIR_RESULT, "{sample}", "{sample}_cured.gb"), sample=SAMPLES)

# ======
# BAKTA
# ======
rule annotate_bakta:
    input:
        fasta = os.path.join(FASTA_DIR, "{sample}.fasta")
    output:
        gbff  = os.path.join(DIR_BAKTA, "{sample}", "{sample}_bakta.gbff")
    params:
        outdir = os.path.join(DIR_BAKTA, "{sample}")
    threads: max(1, THREADS // MAX_JOBS)
    resources:
        mem_mb = MEM_TOTAL // MAX_JOBS,
        heavy_slots = 1
    retries: MAX_RETRIES
    log:
        os.path.join(DIR_LOGS, "bakta", "{sample}.log")
    run:
        ensure_writable_dir(params.outdir)
        ensure_writable_dir(os.path.dirname(log[0]))
        extra = ""
        if BAKTA_GENUS:   extra += f" --genus {BAKTA_GENUS}"
        if BAKTA_SPECIES: extra += f" --species {BAKTA_SPECIES}"
        if BAKTA_GRAM and BAKTA_GRAM != "?": extra += f" --gram {BAKTA_GRAM}"
        timeout_min = get_timeout_min("annotate_bakta")
        shell(f"""
            set -euo pipefail
            timeout {timeout_min}m docker run --rm \
                -u $(id -u):$(id -g) \
                -v "{FASTA_DIR}:/input:ro" \
                -v "{DB_BAKTA}:/db:ro" \
                -v "{params.outdir}:/output" \
                {IMG_BAKTA} \
                --db /db \
                --output /output \
                --prefix "{{wildcards.sample}}_bakta" \
                --threads {threads} \
                --translation-table {BAKTA_TTABLE} \
                --force \
                {extra} \
                "/input/{{wildcards.sample}}.fasta" \
            > {{log[0]}} 2>&1
        """)
        verify_output(
            output.gbff, "bakta", wildcards.sample,
            search_dir=params.outdir,
            patterns=["*_bakta.gbff", "*.gbff"]
        )

# =======
# PROKKA
# =======
rule annotate_prokka:
    input:
        fasta = os.path.join(FASTA_DIR, "{sample}.fasta")
    output:
        gbk   = os.path.join(DIR_PROKKA, "{sample}_prokka", "{sample}_prokka.gbk")
    threads: max(1, THREADS // MAX_JOBS)
    resources:
        mem_mb = MEM_TOTAL // MAX_JOBS,
        heavy_slots = 1
    retries: MAX_RETRIES
    log:
        os.path.join(DIR_LOGS, "prokka", "{sample}.log")
    run:
        ensure_writable_dir(DIR_PROKKA)
        ensure_writable_dir(os.path.dirname(log[0]))
        extra = ""
        if PROKKA_GENUS: extra += f" --genus {PROKKA_GENUS}"
        timeout_min = get_timeout_min("annotate_prokka")
        shell(f"""
            set -euo pipefail
            timeout {timeout_min}m docker run --rm \
                -u $(id -u):$(id -g) \
                -v "{FASTA_DIR}:/input:ro" \
                -v "{DIR_PROKKA}:/output" \
                {IMG_PROKKA} \
                prokka \
                    --outdir "/output/{{wildcards.sample}}_prokka" \
                    --prefix "{{wildcards.sample}}_prokka" \
                    --kingdom {PROKKA_KINGDOM} \
                    --gcode {PROKKA_GCODE} \
                    --cpus {threads} \
                    --force \
                    {extra} \
                    "/input/{{wildcards.sample}}.fasta" \
            > {{log[0]}} 2>&1
        """)
        verify_output(
            output.gbk, "prokka", wildcards.sample,
            search_dir=os.path.join(DIR_PROKKA, f"{wildcards.sample}_prokka"),
            patterns=["*_prokka.gbk", "*.gbk"]
        )

# =====
# DFAST
# =====
rule annotate_dfast:
    input:
        fasta = os.path.join(FASTA_DIR, "{sample}.fasta")
    output:
        gbk   = os.path.join(DIR_DFAST, "{sample}_dfast.gbk")
    params:
        tmpdir = os.path.join(OUTPUT_DIR, "dfast_tmp")
    threads: max(1, THREADS // MAX_JOBS)
    resources:
        mem_mb = MEM_TOTAL // MAX_JOBS,
        heavy_slots = 1
    retries: MAX_RETRIES
    log:
        os.path.join(DIR_LOGS, "dfast", "{sample}.log")
    run:
        ensure_writable_dir(params.tmpdir)
        ensure_writable_dir(DIR_DFAST)
        ensure_writable_dir(os.path.dirname(log[0]))
        outdir = os.path.join(params.tmpdir, wildcards.sample + "_dfast")
        ensure_writable_dir(outdir)
        timeout_min = get_timeout_min("annotate_dfast")
        shell(f"""
            set -euo pipefail
            timeout {timeout_min}m docker run --rm \
                -u $(id -u):$(id -g) \
                -v "{FASTA_DIR}:/input:ro" \
                -v "{params.tmpdir}:/output" \
                -v "{DB_DFAST}:/dfast_core/db:ro" \
                --entrypoint dfast \
                {IMG_DFAST} \
                --genome "/input/{{wildcards.sample}}.fasta" \
                --out "/output/{{wildcards.sample}}_dfast" \
                --cpu {threads} \
                --force \
            > {{log[0]}} 2>&1
        """)
        shell(f"""
            set -euo pipefail
            TARGET="{params.tmpdir}/{{wildcards.sample}}_dfast"
            if [ ! -d "$TARGET" ]; then
                echo "ERROR: DFAST output directory not found"
                exit 1
            fi
            GBK=$(find "$TARGET" -maxdepth 2 -name "genome.gbk" | head -n 1)
            if [ -z "$GBK" ]; then
                echo "ERROR: genome.gbk not found"
                exit 1
            fi
            cp "$GBK" "{{output.gbk}}"
            rm -rf "$TARGET"
        """)
        verify_output(output.gbk, "dfast", wildcards.sample)

# =======
# PATRIC
# =======
rule annotate_patric:
    input:
        fasta = os.path.join(FASTA_DIR, "{sample}.fasta")
    output:
        gb = os.path.join(DIR_PATRIC, "{sample}_patric.gb")
    params:
        jobs_dir = os.path.join(OUTPUT_DIR, "patric_jobs")
    threads: 1
    resources:
        mem_mb = MEM_TOTAL // MAX_JOBS,
        heavy_slots = 1
    retries: MAX_RETRIES
    log:
        os.path.join(DIR_LOGS, "patric", "{sample}.log")
    run:
        import textwrap
        ensure_writable_dir(params.jobs_dir)
        ensure_writable_dir(DIR_PATRIC)
        ensure_writable_dir(os.path.dirname(log[0]))
        inner = os.path.join(params.jobs_dir, f"patric_{wildcards.sample}.sh")
        with open(inner, "w") as f:
            f.write(textwrap.dedent(f"""
                #!/bin/bash
                set -euxo pipefail
                USERNAME="{PATRIC_USER}"
                PASSWORD="{PATRIC_PASS}"
                TAXID="{PATRIC_TAXID}"
                DESC="{PATRIC_DESC}"
                WS_OUT="{PATRIC_WS}"

                fasta="/input/{wildcards.sample}.fasta"
                gname="{wildcards.sample}"

                login_output=$(p3-login "$USERNAME" "$PASSWORD")
                USER_EMAIL=$(echo "$login_output" | grep -oP '(?<=Logged in with username ).*')

                echo "Logged in: $USER_EMAIL"

                out=$(p3-submit-genome-annotation -f \\
                    --contigs-file "$fasta" \\
                    -t "$TAXID" \\
                    -d "$DESC" \\
                    "/$USER_EMAIL/$WS_OUT" "$gname")

                echo "$out"

                sid=$(echo "$out" | grep -oP '(?<=Submitted annotation with id )\\d+')

                while true; do
                    if p3-ls -l --type "/$USER_EMAIL/$WS_OUT/$gname" 2>/dev/null | grep -q "job_result"; then
                        echo "Done: $gname"
                        break
                    fi
                    echo "Waiting: $gname"
                    sleep {PATRIC_INTERVAL}
                done

                # Re-login antes da cópia
                p3-login "$USERNAME" "$PASSWORD" > /dev/null 2>&1
                p3-cp ws:"/$USER_EMAIL/$WS_OUT/.${{gname}}/${{gname}}.gb" \\
                      "/output/${{gname}}_patric.gb"

                p3-logout
            """))
        os.chmod(inner, 0o755)
        timeout_min = get_timeout_min("annotate_patric")
        shell(f"""
            set -euo pipefail
            timeout {timeout_min}m docker run --rm \
                -u $(id -u):$(id -g) \
                -e HOME=/jobs \
                -v "{FASTA_DIR}:/input:ro" \
                -v "{DIR_PATRIC}:/output" \
                -v "{params.jobs_dir}:/jobs" \
                {IMG_PATRIC} \
                bash /jobs/patric_{wildcards.sample}.sh \
            > {{log[0]}} 2>&1
        """)
        verify_output(output.gb, "patric", wildcards.sample)

# ===================
# PREPARE MERGE INPUT
# ===================
def get_base_file_path(sample, tool):
    if tool == "patric":
        return os.path.join(DIR_PATRIC, f"{sample}_patric.gb")
    elif tool == "bakta":
        return os.path.join(DIR_BAKTA, sample, f"{sample}_bakta.gbff")
    elif tool == "prokka":
        return os.path.join(DIR_PROKKA, f"{sample}_prokka", f"{sample}_prokka.gbk")
    elif tool == "dfast":
        return os.path.join(DIR_DFAST, f"{sample}_dfast.gbk")
    elif tool == "pgap":
        return os.path.join(DIR_PGAP, sample, f"{sample}_pgap.gbk")
    else:
        raise ValueError(f"Unknown tool: {tool}")


def get_merge_inputs(wildcards):
    inputs = []
    sample = wildcards.sample
    # Base sempre incluso
    inputs.append(get_base_file_path(sample, BASE_TOOL))
    # Demais ferramentas habilitadas
    if PATRIC_ENABLED and BASE_TOOL != "patric":
        inputs.append(get_base_file_path(sample, "patric"))
    if BAKTA_ENABLED and BASE_TOOL != "bakta":
        inputs.append(get_base_file_path(sample, "bakta"))
    if PROKKA_ENABLED and BASE_TOOL != "prokka":
        inputs.append(get_base_file_path(sample, "prokka"))
    if DFAST_ENABLED and BASE_TOOL != "dfast":
        inputs.append(get_base_file_path(sample, "dfast"))
    if PGAP_ENABLED and BASE_TOOL != "pgap":
        inputs.append(get_base_file_path(sample, "pgap"))
    return inputs


rule prepare_merge_input:
    input:
        get_merge_inputs
    output:
        signal = os.path.join(DIR_MERGE, ".merge_inputs_ready.{sample}")
    resources:
        light_slots = 1
    retries: MAX_RETRIES
    shell:
        """
        set -euo pipefail
        mkdir -p {DIR_MERGE}
        for f in {input}; do
            if [ -f "$f" ]; then
                cp "$f" {DIR_MERGE}/
                echo "Copied: $f"
            else
                echo "ERROR: File not found: $f" >&2
                exit 1
            fi
        done
        touch {output.signal}
        """

# ===========
# EXTRACT CDS (somente se eggNOG habilitado)
# ===========
def get_base_annotation_file(wildcards):
    """Retorna o caminho do arquivo de anotação ORIGINAL da ferramenta base
    (ex: saída direta de annotate_bakta/annotate_dfast/...), que já é um
    output estaticamente declarado por outra regra. Usar isso em vez do
    caminho copiado dentro de merge_input/ evita MissingInputException,
    já que `output:` não pode ser função no Snakemake >= 8."""
    return get_base_file_path(wildcards.sample, BASE_TOOL)


if EGGNOG_ENABLED:
    rule extract_cds:
        input:
            base_file = get_base_annotation_file,
            # Garante que prepare_merge_input já rodou (mantém a ordem lógica
            # do pipeline), mesmo lendo o arquivo original em vez da cópia.
            merge_ready = os.path.join(DIR_MERGE, ".merge_inputs_ready.{sample}")
        output:
            faa = os.path.join(DIR_EGGNOG, "{sample}_proteins.fasta")
        resources:
            light_slots = 1
        retries: MAX_RETRIES
        log:
            os.path.join(DIR_LOGS, "eggnog", "{sample}_extract.log")
        run:
            ensure_writable_dir(DIR_EGGNOG)
            ensure_writable_dir(os.path.dirname(log[0]))

            base_file = input.base_file
            if not os.path.exists(base_file):
                raise FileNotFoundError(
                    f"Arquivo base não encontrado: {base_file}. "
                    "Certifique-se de que prepare_merge_input foi executado."
                )

            timeout_min = get_timeout_min("extract_cds")
            shell(f"""
                set -euo pipefail
                timeout {timeout_min}m docker run --rm \
                    -u $(id -u):$(id -g) \
                    -v "{DIR_MERGE}:/data:ro" \
                    -v "{DIR_EGGNOG}:/output" \
                    --entrypoint python \
                    {IMG_MERGE} \
                    /app/cds_extract.py \
                        /data/{os.path.basename(base_file)} \
                        /output/{{wildcards.sample}}_proteins.fasta \
                > {{log[0]}} 2>&1
                # Fixer de permissão via container: usa a MESMA imagem/identidade
                # que escreveu o arquivo (em vez de 'chmod' pelo host, que falha
                # se o UID do container for remapeado pelo Docker userns-remap).
                docker run --rm \
                    -u $(id -u):$(id -g) \
                    -v "{DIR_EGGNOG}:/output" \
                    --entrypoint chmod \
                    {IMG_MERGE} \
                    -R a+rwX /output 2>/dev/null || true
            """)
            verify_output(output.faa, "extract_cds", wildcards.sample)

    # ==========
    # RUN EGGNOG
    # ==========
    rule run_eggnog:
        input:
            faa = os.path.join(DIR_EGGNOG, "{sample}_proteins.fasta")
        output:
            annotations = os.path.join(DIR_EGGNOG, "{sample}_eggnog.emapper.annotations")
        threads: max(1, THREADS // MAX_JOBS)
        resources:
            mem_mb = MEM_TOTAL // MAX_JOBS,
            heavy_slots = 1
        retries: MAX_RETRIES
        log:
            os.path.join(DIR_LOGS, "eggnog", "{sample}_eggnog.log")
        run:
            import tempfile
            ensure_writable_dir(DIR_EGGNOG)
            ensure_writable_dir(os.path.dirname(log[0]))
            temp_dir = tempfile.mkdtemp(prefix=f"eggnog_{wildcards.sample}_", dir=DIR_EGGNOG)
            try:
                os.chmod(temp_dir, 0o777)
                timeout_min = get_timeout_min("run_eggnog")
                shell(f"""
                    set -euo pipefail
                    timeout {timeout_min}m docker run --rm \
                        -u $(id -u):$(id -g) \
                        -v "{DIR_EGGNOG}:/data:rw" \
                        -v "{DB_EGGNOG}:/eggnog_db:ro" \
                        -v "{temp_dir}:/tmp:rw" \
                        -e TMPDIR=/tmp \
                        -e TEMP=/tmp \
                        -e TMP=/tmp \
                        --workdir /data \
                        {IMG_EGGNOG} \
                        emapper.py \
                            -i /data/{wildcards.sample}_proteins.fasta \
                            --itype proteins \
                            -m {EGGNOG_SENSMODE} \
                            --data_dir /eggnog_db \
                            --output {wildcards.sample}_eggnog \
                            --output_dir /data \
                            --cpu {threads} \
                            --override \
                            --temp_dir /tmp \
                    > {{log[0]}} 2>&1
                """)
                verify_output(output.annotations, "eggnog", wildcards.sample)
            finally:
                shutil.rmtree(temp_dir, ignore_errors=True)

    # ===================
    # MOVE EGGNOG RESULT
    # ===================
    rule move_eggnog_result:
        input:
            eggnog = os.path.join(DIR_EGGNOG, "{sample}_eggnog.emapper.annotations")
        output:
            eggnog = os.path.join(DIR_MERGE, "{sample}_eggnog.emapper.annotations")
        resources:
            light_slots = 1
        retries: MAX_RETRIES
        shell:
            """
            set -euo pipefail
            mkdir -p {DIR_MERGE}
            cp {input.eggnog} {output.eggnog}
            """

# ====================
# PGAP
# ====================
if PGAP_ENABLED:
    rule download_pgap_script:
        output:
            script = PGAP_SCRIPT
        params:
            url = "https://raw.githubusercontent.com/ncbi/pgap/prod/scripts/pgap.py"
        log:
            os.path.join(DIR_LOGS, "pgap", "download.log")
        run:
            ensure_writable_dir(os.path.dirname(output.script))
            if not os.path.exists(output.script):
                cmd = ["curl", "-fsSL", "-o", output.script, params.url]
                with open(log[0], 'w') as logfile:
                    subprocess.run(cmd, stdout=logfile, stderr=subprocess.STDOUT, check=True)
                os.chmod(output.script, 0o755)
            verify_output(output.script, "pgap_download", "script")

    rule annotate_pgap:
        input:
            fasta = os.path.join(FASTA_DIR, "{sample}.fasta"),
            script = PGAP_SCRIPT
        output:
            gbk = os.path.join(DIR_PGAP, "{sample}", "{sample}_pgap.gbk")
        params:
            outdir = os.path.join(DIR_PGAP, "{sample}"),
            script = PGAP_SCRIPT,
            mem = PGAP_MEM,
            cpus = PGAP_CPUS,
            extra = PGAP_EXTRA,
            species = PGAP_SPECIES if PGAP_SPECIES else "{sample}"
        threads: PGAP_CPUS
        resources:
            mem_mb = mem_to_mb(PGAP_MEM),
            heavy_slots = 1
        retries: MAX_RETRIES
        log:
            os.path.join(DIR_LOGS, "pgap", "{sample}.log")
        run:
            import sys
            if os.path.exists(output.gbk) and os.path.getsize(output.gbk) > 1000:
                print(f"{output.gbk} já existe e é válido. Pulando processamento.")
                return
            safe_prefix = sanitize_prefix(wildcards.sample)
            print(f"Processando {wildcards.sample}...")
            print(f"DEBUG: Prefixo original: {wildcards.sample} -> sanitizado: {safe_prefix}")
            if os.path.exists(params.outdir):
                print(f"Removendo diretório existente: {params.outdir}")
                shutil.rmtree(params.outdir)
            ensure_writable_dir(os.path.dirname(params.outdir))
            ensure_writable_dir(os.path.dirname(log[0]))
            cmd = [
                sys.executable, params.script,
                "-r", "-v",
                "-o", params.outdir,
                "--prefix", safe_prefix,
                "-c", str(params.cpus),
                "-m", params.mem,
                "-g", input.fasta,
                "-s", params.species,
                "--no-self-update"
            ]
            if params.extra:
                import shlex
                cmd.extend(shlex.split(params.extra))
            with open(log[0], 'w') as logfile:
                logfile.write(f"Comando executado: {' '.join(cmd)}\n\n")
                result = subprocess.run(cmd, stdout=logfile, stderr=subprocess.STDOUT)
                if result.returncode != 0:
                    logfile.write(f"\nERRO: comando falhou com código {result.returncode}\n")
                    logfile.write(f"\nConteúdo de {os.path.dirname(params.outdir)}:\n")
                    for root, dirs, files in os.walk(os.path.dirname(params.outdir)):
                        for file in files:
                            logfile.write(f"  {os.path.join(root, file)}\n")
                    raise subprocess.CalledProcessError(result.returncode, cmd)
            expected = os.path.join(params.outdir, f"{safe_prefix}.gbk")
            if os.path.exists(expected):
                src = expected
            else:
                patterns = ["*.gbff", "*.gbk", "*.gbf", "*.gb"]
                found = []
                for pat in patterns:
                    found.extend(glob.glob(os.path.join(params.outdir, "**", pat), recursive=True))
                if not found:
                    found = glob.glob(os.path.join(params.outdir, "*.[gG][bB]*"))
                if not found:
                    found = glob.glob(os.path.join(params.outdir, "*.gff"))
                if not found:
                    raise Exception(f"Nenhum arquivo de anotação (.gb* ou .gff) encontrado em {params.outdir}")
                src = found[0]
            shutil.copy(src, output.gbk)
            print(f"Arquivo copiado para {output.gbk}")
            verify_output(output.gbk, "pgap", wildcards.sample)

    rule move_pgap_result:
        input:
            pgap = os.path.join(DIR_PGAP, "{sample}", "{sample}_pgap.gbk")
        output:
            pgap = os.path.join(DIR_MERGE, "{sample}_pgap.gbk")
        resources:
            light_slots = 1
        retries: MAX_RETRIES
        shell:
            """
            set -euo pipefail
            mkdir -p {DIR_MERGE}
            cp {input.pgap} {output.pgap}
            """

# =========
# RUN MERGE - depende do sinal e do eggnog (se habilitado)
# =========
rule run_merge:
    input:       
        expand(os.path.join(DIR_MERGE, ".merge_inputs_ready.{sample}"), sample=SAMPLES),       
        expand(os.path.join(DIR_MERGE, "{sample}_eggnog.emapper.annotations"), sample=SAMPLES) if EGGNOG_ENABLED else []
    output:
        # Nomes dinâmicos baseados na ordem das ferramentas
        report    = os.path.join(DIR_MERGE,  f"hp_summary_report__{ORDER_STR}.tsv"),
        hp_plot   = os.path.join(DIR_RESULT, RESULT_BATCH_DIR, f"hp_reduction_plot__{ORDER_STR}.png"),
        art_table = os.path.join(DIR_RESULT, RESULT_BATCH_DIR, f"article_ready_table__{ORDER_STR}.csv"),
        cured     = expand(os.path.join(DIR_MERGE, CURED_PATTERN), sample=SAMPLES)
    threads: max(1, THREADS // MAX_JOBS)
    resources:
        mem_mb = MEM_TOTAL // MAX_JOBS,
        heavy_slots = 1
    retries: MAX_RETRIES
    log:
        os.path.join(DIR_LOGS, "merge", "pipeline.log")
    run:
        ensure_writable_dir(DIR_RESULT)
        ensure_writable_dir(os.path.join(DIR_RESULT, RESULT_BATCH_DIR))
        ensure_writable_dir(os.path.dirname(log[0]))
        flags = []
        if not PATRIC_ENABLED: flags.append("--no-patric")
        if not BAKTA_ENABLED:  flags.append("--no-bakta")
        if not PROKKA_ENABLED: flags.append("--no-prokka")
        if not DFAST_ENABLED:  flags.append("--no-dfast")
        if not PGAP_ENABLED:   flags.append("--no-pgap")
        if not EGGNOG_ENABLED: flags.append("--no-eggnog")
        flags.append(f"--base-tool {BASE_TOOL}")
        if TOOL_ORDER:
            flags.append(f"--tool-order {TOOL_ORDER}")
        timeout_min = get_timeout_min("run_merge")
        shell(f"""
            set -euo pipefail
            timeout {timeout_min}m docker run --rm \
                -u $(id -u):$(id -g) \
                -v "{DIR_MERGE}:/data" \
                -v "{DIR_RESULT}:/results" \
                {IMG_MERGE} \
                -i /data \
                -o /results \
                -t {threads} \
                --min-pident {MERGE_MIN_PIDENT} \
                --min-qcov   {MERGE_MIN_QCOV} \
                --jobs       {MERGE_JOBS} \
                {" ".join(flags)} \
            > {{log[0]}} 2>&1
            docker run --rm \
                -u $(id -u):$(id -g) \
                -v "{DIR_MERGE}:/data" \
                -v "{DIR_RESULT}:/results" \
                --entrypoint chmod \
                {IMG_MERGE} \
                -R a+rwX /data /results 2>/dev/null || true
        """)

        # --- CORREÇÃO: Verificação flexível com nomes fixos e renomeação ---
        def _shallowest(paths):
            """Ordena por profundidade (menos subpastas primeiro), preferindo
            arquivos já no lugar certo sobre os que estão em subpastas."""
            return sorted(paths, key=lambda p: p.count(os.sep))

        def resolve_output(out_file, possible_names, search_dir=None):
            """Garante que 'out_file' exista, procurando recursivamente por
            nomes alternativos (sem sufixo, com sufixo __ORDER_STR, ou dentro
            de subpastas como 'order__<sufixo>/' / '<amostra>/' criadas pelo
            container do merge quando um tool_order customizado é usado).
            Se 'search_dir' não for passado, usa o diretório do próprio
            'out_file' — mas quando o destino final foi movido para uma
            subpasta (ex.: a pasta do organismo) e o container ainda escreve
            os arquivos direto na raiz, passe explicitamente o diretório raiz
            para que a busca recursiva o alcance."""
            if search_dir is None:
                search_dir = os.path.dirname(out_file)
            ensure_writable_dir(os.path.dirname(out_file))
            found = None

            for name in possible_names:
                matches = glob.glob(os.path.join(search_dir, "**", name), recursive=True)
                matches = [m for m in matches if os.path.getsize(m) > 0]
                if matches:
                    found = _shallowest(matches)[0]
                    break

            if found:
                if os.path.abspath(found) != os.path.abspath(out_file):
                    shutil.move(found, out_file)
                    print(f"[run_merge] Arquivo encontrado como '{found}' -> movido para '{out_file}'")
                else:
                    print(f"[run_merge] Arquivo de saída já existe: {out_file}")
                return

            # Fallback: busca recursiva por qualquer arquivo com padrão semelhante
            base = os.path.basename(out_file)
            # Remove sufixo dinâmico (parte após "__")
            if "__" in base:
                prefix = base.split("__")[0]
                ext = os.path.splitext(base)[1]
                pattern = prefix + "*" + ext
            else:
                pattern = base
            matches = glob.glob(os.path.join(search_dir, "**", pattern), recursive=True)
            matches = [m for m in matches if os.path.getsize(m) > 0]
            if matches:
                m = _shallowest(matches)[0]
                shutil.move(m, out_file)
                print(f"[run_merge] Arquivo encontrado por padrão '{pattern}': '{m}' -> movido para '{out_file}'")
                return

            # Erro detalhado com listagem recursiva do diretório
            if os.path.exists(search_dir):
                dir_content = "\n".join(
                    sorted(
                        os.path.relpath(os.path.join(root, f), search_dir)
                        for root, _, files in os.walk(search_dir)
                        for f in files
                    )
                ) or "(diretório vazio)"
            else:
                dir_content = "diretório não existe"
            raise RuntimeError(
                f"[run_merge] Nenhum arquivo de saída encontrado para {out_file}. "
                f"Padrões procurados (recursivamente em '{search_dir}'): {possible_names} e '{pattern}'. "
                f"Conteúdo de {search_dir}:\n{dir_content}"
            )

        # Mapeia saída esperada -> (possíveis nomes fixos/alternativos, diretório de busca)
        output_map = {
            output.report: (
                ["hp_summary_report.tsv", f"hp_summary_report__{ORDER_STR}.tsv"],
                None,  # busca no próprio diretório do output (DIR_MERGE)
            ),
            output.hp_plot: (
                ["hp_reduction_plot.png", f"hp_reduction_plot__{ORDER_STR}.png"],
                DIR_RESULT,  # o container escreve na raiz de merge_results, não na pasta do organismo
            ),
            output.art_table: (
                ["article_ready_table.csv", f"article_ready_table__{ORDER_STR}.csv"],
                DIR_RESULT,
            ),
        }
        for out_file, (possible_names, search_dir) in output_map.items():
            resolve_output(out_file, possible_names, search_dir=search_dir)

        # Arquivos '{sample}_cured.gb' — o container também pode gravá-los
        # como '{sample}_cured__{ORDER_STR}.gb' quando um tool_order
        # customizado é usado, então precisam do mesmo tratamento.
        for sample, cured_out in zip(SAMPLES, output.cured):
            resolve_output(cured_out, [
                f"{sample}_cured.gb",
                f"{sample}_cured__{ORDER_STR}.gb"
            ])

        # Limpa o que sobrou solto na raiz de merge_results (ex.: a pasta
        # 'order__<sufixo>/' que o container do merge cria e que já foi
        # esvaziada dos arquivos úteis acima). Quando o lote tem uma única
        # amostra, o restante é movido para dentro da pasta do organismo por
        # segurança (arquivamento) em vez de apagado.
        for entry in os.listdir(DIR_RESULT):
            entry_path = os.path.join(DIR_RESULT, entry)
            if entry == RESULT_BATCH_DIR or entry in SAMPLES or not os.path.isdir(entry_path):
                continue
            if entry.startswith("order__"):
                if len(SAMPLES) == 1:
                    dest = os.path.join(DIR_RESULT, RESULT_BATCH_DIR, entry)
                    if os.path.exists(dest):
                        shutil.rmtree(dest)
                    shutil.move(entry_path, dest)
                    print(f"[run_merge] Pasta bruta '{entry_path}' movida para '{dest}'")
                else:
                    print(f"[run_merge] Aviso: pasta bruta '{entry_path}' não foi movida "
                          f"(lote com múltiplas amostras — sem organismo único para associá-la).")

rule copy_cured_results:
    input:
        cured = os.path.join(DIR_MERGE, CURED_PATTERN)
    output:
        result_cured = os.path.join(DIR_RESULT, "{sample}", "{sample}_cured.gb")
    resources:
        light_slots = 1
    retries: MAX_RETRIES
    shell:
        """
        set -euo pipefail
        mkdir -p "$(dirname {output.result_cured})"
        cp {input.cured} {output.result_cured}
        """
