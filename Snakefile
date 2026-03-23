# =============================================================================
# Snakefile — SnakeMergeAnnotation workflow (MONITORADO POR ATIVIDADE)
# =============================================================================
# Usage:
#   snakemake --configfile config.yaml --cores all --jobs {max_jobs} --keep-going
# =============================================================================
import os
import glob
import subprocess
import re
import shlex
import time
import threading

SNAKEFILE_DIR = os.path.dirname(workflow.snakefile)

# -----------------------------------------------------------------------------
# Funções auxiliares
# -----------------------------------------------------------------------------
def sanitize_prefix(name):
    return re.sub(r'[^a-zA-Z0-9_-]', '_', name)

def mem_to_mb(mem_str):
    mem_str = mem_str.lower().strip()
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

def parse_time_str(tstr):
    tstr = tstr.strip().lower()
    match = re.match(r'^(\d+)([smh])?$', tstr)
    if not match:
        raise ValueError(f"Formato inválido: {tstr}. Use números seguidos de s, m ou h")
    num, unit = match.groups()
    num = int(num)
    if unit == 'h':
        return num * 3600
    elif unit == 'm':
        return num * 60
    else:
        return num

def run_with_watchdog(cmd, log_file, max_retries=2, inactivity_timeout=3600, check_interval=60, shell=True, shell_executable='/bin/bash'):
    for attempt in range(max_retries + 1):
        os.makedirs(os.path.dirname(log_file), exist_ok=True)

        with open(log_file, 'a') as log_fh:
            log_fh.write(f"\n--- Tentativa {attempt+1} de {max_retries+1} ---\n")
            log_fh.write(f"Comando: {cmd if shell else ' '.join(cmd)}\n")
            log_fh.write(f"Timeout inatividade: {inactivity_timeout}s\n")
            log_fh.flush()

            # Inicia o processo com o shell especificado
            proc = subprocess.Popen(
                cmd,
                shell=shell,
                stdout=log_fh,
                stderr=subprocess.STDOUT,
                text=True,
                executable=shell_executable if shell else None
            )
            last_mtime = time.time()
            active = True
            killed = False

            def monitor():
                nonlocal last_mtime, active, killed
                while active:
                    time.sleep(check_interval)
                    if not active:
                        break
                    if os.path.exists(log_file):
                        cur_mtime = os.path.getmtime(log_file)
                        if cur_mtime > last_mtime:
                            last_mtime = cur_mtime
                        else:
                            if time.time() - last_mtime > inactivity_timeout:
                                with open(log_file, 'a') as f:
                                    f.write(f"\n[WATCHDOG] Nenhuma modificação no log por {inactivity_timeout}s. Matando processo.\n")
                                proc.terminate()
                                time.sleep(5)
                                if proc.poll() is None:
                                    proc.kill()
                                killed = True
                                break

            monitor_thread = threading.Thread(target=monitor)
            monitor_thread.daemon = True
            monitor_thread.start()

            try:
                proc.wait()
            except:
                pass
            active = False
            monitor_thread.join(timeout=2)

            if proc.returncode == 0:
                return
            else:
                if not killed:
                    with open(log_file, 'a') as f:
                        f.write(f"\nProcesso terminou com código {proc.returncode}\n")
                if attempt == max_retries:
                    raise subprocess.CalledProcessError(proc.returncode, cmd)
                else:
                    with open(log_file, 'a') as f:
                        f.write(f"Aguardando 10s antes da próxima tentativa...\n")
                    time.sleep(10)

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

# =================
# CONFIG READING
# =================
FASTA_DIR  = config["paths"]["fasta_dir"]
OUTPUT_DIR = config["paths"]["output_dir"]
THREADS    = config["general"]["threads"]

IMG_BAKTA   = config["bakta"]["docker_image"]
IMG_PROKKA  = config["prokka"]["docker_image"]
IMG_DFAST   = config["dfast"]["docker_image"]
IMG_PATRIC  = config["patric"]["docker_image"]
IMG_MERGE   = config["merge"]["docker_image"]
IMG_EGGNOG  = config["eggnog"]["docker_image"]

MEM_TOTAL = config["resources"]["mem_mb"]
MAX_JOBS = config["resources"]["max_jobs"]
TOTAL_CORES = int(subprocess.getoutput("nproc"))
MAX_PESADOS_POR_CORES = TOTAL_CORES // THREADS
MAX_PESADOS_POR_MEM = MEM_TOTAL // 30000
PARALELISMO_PESADO = min(MAX_JOBS, MAX_PESADOS_POR_CORES, MAX_PESADOS_POR_MEM)
PARALELISMO_LEVE = MAX_JOBS * 2

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
# WATCHDOG PARAMETERS (defaults)
# ===========
MAX_RETRIES   = config.get("watchdog", {}).get("max_retries", 2)
INACTIVITY_TIMEOUT = parse_time_str(config.get("watchdog", {}).get("inactivity_timeout", "3600s"))
CHECK_INTERVAL     = parse_time_str(config.get("watchdog", {}).get("check_interval", "60s"))

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

# ====================
# PGAP CONFIG
# ====================
PGAP_ENABLED = config.get("pgap", {}).get("enabled", False)
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
FINAL_VERSION_PATTERN = "{sample}_patric_bakta_UPDATED_Prokka_UPDATED_dfast_finalversion.gb"
CURED_PATTERN = "{sample}_cured.gb"

# ===========
# FINAL RULE
# ===========
rule all:
    input:
        expand(os.path.join(DIR_MERGE, CURED_PATTERN), sample=SAMPLES),
        expand(os.path.join(DIR_MERGE, FINAL_VERSION_PATTERN), sample=SAMPLES),
        expand(os.path.join(DIR_RESULT, "{sample}", "annotation_comparison_report.xlsx"), sample=SAMPLES),
        expand(os.path.join(DIR_MERGE, "{sample}_pgap.gbk"), sample=SAMPLES) if PGAP_ENABLED else [],
        expand(os.path.join(DIR_RESULT, "{sample}_cured.gb"), sample=SAMPLES)

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
        mem_mb = MEM_TOTAL // MAX_JOBS
    log:
        os.path.join(DIR_LOGS, "bakta", "{sample}.log")
    run:
        import os
        os.makedirs(params.outdir, exist_ok=True)
        os.makedirs(os.path.dirname(log[0]), exist_ok=True)

        extra = ""
        if BAKTA_GENUS:   extra += f" --genus {BAKTA_GENUS}"
        if BAKTA_SPECIES: extra += f" --species {BAKTA_SPECIES}"
        if BAKTA_GRAM and BAKTA_GRAM != "?": extra += f" --gram {BAKTA_GRAM}"

        cmd = f"""
docker run --rm \
    -u $(id -u):$(id -g) \
    -v "{FASTA_DIR}:/input:ro" \
    -v "{DB_BAKTA}:/db:ro" \
    -v "{params.outdir}:/output" \
    {IMG_BAKTA} \
    --db /db \
    --output /output \
    --prefix "{wildcards.sample}_bakta" \
    --threads {threads} \
    --translation-table {BAKTA_TTABLE} \
    --force \
    {extra} \
    "/input/{wildcards.sample}.fasta"
"""
        run_with_watchdog(cmd, log[0],
                          max_retries=MAX_RETRIES,
                          inactivity_timeout=INACTIVITY_TIMEOUT,
                          check_interval=CHECK_INTERVAL,
                          shell=True)

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
        mem_mb = MEM_TOTAL // MAX_JOBS
    log:
        os.path.join(DIR_LOGS, "prokka", "{sample}.log")
    run:
        import os
        os.makedirs(DIR_PROKKA, exist_ok=True)
        os.makedirs(os.path.dirname(log[0]), exist_ok=True)

        extra = ""
        if PROKKA_GENUS: extra += f" --genus {PROKKA_GENUS}"

        cmd = f"""
docker run --rm \
    -u $(id -u):$(id -g) \
    -v "{FASTA_DIR}:/input:ro" \
    -v "{DIR_PROKKA}:/output" \
    {IMG_PROKKA} \
    prokka \
        --outdir "/output/{wildcards.sample}_prokka" \
        --prefix "{wildcards.sample}_prokka" \
        --kingdom {PROKKA_KINGDOM} \
        --gcode {PROKKA_GCODE} \
        --cpus {threads} \
        --force \
        {extra} \
        "/input/{wildcards.sample}.fasta"
"""
        run_with_watchdog(cmd, log[0],
                          max_retries=MAX_RETRIES,
                          inactivity_timeout=INACTIVITY_TIMEOUT,
                          check_interval=CHECK_INTERVAL,
                          shell=True)

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
        mem_mb = MEM_TOTAL // MAX_JOBS
    log:
        os.path.join(DIR_LOGS, "dfast", "{sample}.log")
    run:
        import os
        os.makedirs(params.tmpdir, exist_ok=True)
        os.makedirs(DIR_DFAST, exist_ok=True)
        os.makedirs(os.path.dirname(log[0]), exist_ok=True)

        outdir = os.path.join(params.tmpdir, wildcards.sample + "_dfast")
        os.makedirs(outdir, exist_ok=True)

        cmd1 = f"""
set -euo pipefail
docker run --rm \
    -u $(id -u):$(id -g) \
    -v "{FASTA_DIR}:/input:ro" \
    -v "{params.tmpdir}:/output" \
    -v "{DB_DFAST}:/dfast_core/db:ro" \
    --entrypoint dfast \
    {IMG_DFAST} \
    --genome "/input/{wildcards.sample}.fasta" \
    --out "/output/{wildcards.sample}_dfast" \
    --cpu {threads} \
    --force
"""
        run_with_watchdog(cmd1, log[0],
                          max_retries=MAX_RETRIES,
                          inactivity_timeout=INACTIVITY_TIMEOUT,
                          check_interval=CHECK_INTERVAL,
                          shell=True)

        cmd2 = f"""
set -euo pipefail
TARGET="{params.tmpdir}/{wildcards.sample}_dfast"
if [ ! -d "$TARGET" ]; then
    echo "ERROR: DFAST output directory not found"
    exit 1
fi
GBK=$(find "$TARGET" -maxdepth 2 -name "genome.gbk" | head -n 1)
if [ -z "$GBK" ]; then
    echo "ERROR: genome.gbk not found"
    exit 1
fi
cp "$GBK" "{output.gbk}"
rm -rf "$TARGET"
"""
        run_with_watchdog(cmd2, log[0],
                          max_retries=1,
                          inactivity_timeout=300,
                          check_interval=30,
                          shell=True)

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
        mem_mb = MEM_TOTAL // MAX_JOBS
    log:
        os.path.join(DIR_LOGS, "patric", "{sample}.log")
    run:
        import os, textwrap
        os.makedirs(params.jobs_dir, exist_ok=True)
        os.makedirs(DIR_PATRIC, exist_ok=True)
        os.makedirs(os.path.dirname(log[0]), exist_ok=True)

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

                # Re‑login antes da cópia
                p3-login "$USERNAME" "$PASSWORD" > /dev/null 2>&1
                p3-cp ws:"/$USER_EMAIL/$WS_OUT/.${{gname}}/${{gname}}.gb" \\
                      "/output/${{gname}}_patric.gb"

                p3-logout
            """))

        os.chmod(inner, 0o755)

        cmd = f"""
docker run --rm \
    -u $(id -u):$(id -g) \
    -e HOME=/jobs \
    -v "{FASTA_DIR}:/input:ro" \
    -v "{DIR_PATRIC}:/output" \
    -v "{params.jobs_dir}:/jobs" \
    {IMG_PATRIC} \
    bash /jobs/patric_{wildcards.sample}.sh
"""
        run_with_watchdog(cmd, log[0],
                          max_retries=MAX_RETRIES,
                          inactivity_timeout=INACTIVITY_TIMEOUT * 2,
                          check_interval=CHECK_INTERVAL,
                          shell=True)

# ===================
# PREPARE MERGE INPUT
# ===================
rule prepare_merge_input:
    input:
        patric = os.path.join(DIR_PATRIC, "{sample}_patric.gb"),
        bakta  = os.path.join(DIR_BAKTA,  "{sample}", "{sample}_bakta.gbff"),
        prokka = os.path.join(DIR_PROKKA, "{sample}_prokka", "{sample}_prokka.gbk"),
        dfast  = os.path.join(DIR_DFAST,  "{sample}_dfast.gbk")
    output:
        patric = os.path.join(DIR_MERGE, "{sample}_patric.gb"),
        bakta  = os.path.join(DIR_MERGE, "{sample}_bakta.gbff"),
        prokka = os.path.join(DIR_MERGE, "{sample}_prokka.gbk"),
        dfast  = os.path.join(DIR_MERGE, "{sample}_dfast.gbk")
    shell:
        """
        mkdir -p {DIR_MERGE}
        cp {input.patric} {output.patric}
        cp {input.bakta}  {output.bakta}
        cp {input.prokka} {output.prokka}
        cp {input.dfast}  {output.dfast}
        """

# ===========
# EXTRACT CDS
# ===========
rule extract_cds:
    input:
        patric = os.path.join(DIR_MERGE, "{sample}_patric.gb")
    output:
        faa = os.path.join(DIR_EGGNOG, "{sample}_proteins.fasta")
    log:
        os.path.join(DIR_LOGS, "eggnog", "{sample}_extract.log")
    run:
        import os
        os.makedirs(DIR_EGGNOG, exist_ok=True)
        os.makedirs(os.path.dirname(log[0]), exist_ok=True)

        cmd = f"""
docker run --rm \
    -u $(id -u):$(id -g) \
    -v "{DIR_MERGE}:/data:ro" \
    -v "{DIR_EGGNOG}:/output" \
    --entrypoint python \
    {IMG_MERGE} \
    /app/cds_extract.py \
        /data/{wildcards.sample}_patric.gb \
        /output/{wildcards.sample}_proteins.fasta
"""
        run_with_watchdog(cmd, log[0],
                          max_retries=1,
                          inactivity_timeout=300,
                          check_interval=30,
                          shell=True)

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
        mem_mb = MEM_TOTAL // MAX_JOBS
    log:
        os.path.join(DIR_LOGS, "eggnog", "{sample}_eggnog.log")
    run:
        import os, tempfile
        os.makedirs(DIR_EGGNOG, exist_ok=True)
        os.makedirs(os.path.dirname(log[0]), exist_ok=True)

        temp_dir = tempfile.mkdtemp(prefix=f"eggnog_{wildcards.sample}_", dir=DIR_EGGNOG)

        try:
            os.chmod(temp_dir, 0o755)
            cmd = f"""
docker run --rm \
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
        --temp_dir /tmp
"""
            run_with_watchdog(cmd, log[0],
                              max_retries=MAX_RETRIES,
                              inactivity_timeout=INACTIVITY_TIMEOUT,
                              check_interval=CHECK_INTERVAL,
                              shell=True)
        finally:
            import shutil
            shutil.rmtree(temp_dir, ignore_errors=True)

# ===================
# MOVE EGGNOG RESULT
# ===================
rule move_eggnog_result:
    input:
        eggnog = os.path.join(DIR_EGGNOG, "{sample}_eggnog.emapper.annotations")
    output:
        eggnog = os.path.join(DIR_MERGE, "{sample}_eggnog.emapper.annotations")
    shell:
        """
        mkdir -p {DIR_MERGE}
        cp {input.eggnog} {output.eggnog}
        """

# ====================
# PGAP (só definido se habilitado)
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
            import os, subprocess
            os.makedirs(os.path.dirname(output.script), exist_ok=True)
            if not os.path.exists(output.script):
                cmd = ["curl", "-o", output.script, params.url]
                with open(log[0], 'w') as logfile:
                    subprocess.run(cmd, stdout=logfile, stderr=subprocess.STDOUT, check=True)
                os.chmod(output.script, 0o755)

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
            mem_mb = mem_to_mb(PGAP_MEM)
        log:
            os.path.join(DIR_LOGS, "pgap", "{sample}.log")
        run:
            import os, subprocess, glob, shutil, sys
            safe_prefix = sanitize_prefix(wildcards.sample)
            print(f"DEBUG: Prefixo original: {wildcards.sample} -> sanitizado: {safe_prefix}")

            os.makedirs(os.path.dirname(params.outdir), exist_ok=True)
            os.makedirs(os.path.dirname(log[0]), exist_ok=True)

            if os.path.exists(params.outdir):
                shutil.rmtree(params.outdir)

            cmd = [
                sys.executable, params.script,
                "-r", "-v",
                "-o", params.outdir,
                "--prefix", safe_prefix,
                "-c", str(params.cpus),
                "-m", params.mem,
                "-g", input.fasta,
                "-s", params.species
            ]
            if params.extra:
                cmd.extend(shlex.split(params.extra))

            run_with_watchdog(cmd, log[0],
                              max_retries=MAX_RETRIES,
                              inactivity_timeout=INACTIVITY_TIMEOUT * 2,
                              check_interval=CHECK_INTERVAL,
                              shell=False)

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
                    raise Exception(f"Nenhum arquivo .gb* encontrado em {params.outdir}")
                src = found[0]

            shutil.copy(src, output.gbk)
            print(f"DEBUG: Arquivo copiado para {output.gbk}")

    rule move_pgap_result:
        input:
            pgap = os.path.join(DIR_PGAP, "{sample}", "{sample}_pgap.gbk")
        output:
            pgap = os.path.join(DIR_MERGE, "{sample}_pgap.gbk")
        shell:
            """
            mkdir -p {DIR_MERGE}
            cp {input.pgap} {output.pgap}
            """

# =========
# RUN MERGE
# =========
rule run_merge:
    input:
        expand(os.path.join(DIR_MERGE, "{sample}_patric.gb"),  sample=SAMPLES),
        expand(os.path.join(DIR_MERGE, "{sample}_bakta.gbff"), sample=SAMPLES),
        expand(os.path.join(DIR_MERGE, "{sample}_prokka.gbk"), sample=SAMPLES),
        expand(os.path.join(DIR_MERGE, "{sample}_dfast.gbk"),  sample=SAMPLES),
        expand(os.path.join(DIR_MERGE, "{sample}_pgap.gbk"),  sample=SAMPLES),
        expand(os.path.join(DIR_MERGE, "{sample}_eggnog.emapper.annotations"), sample=SAMPLES)
    output:
        report    = os.path.join(DIR_MERGE,  "hp_summary_report.tsv"),
        hp_plot   = os.path.join(DIR_RESULT, "hp_reduction_plot.png"),
        art_table = os.path.join(DIR_RESULT, "article_ready_table.csv"),
        finals    = expand(os.path.join(DIR_MERGE, FINAL_VERSION_PATTERN), sample=SAMPLES),
        cured     = expand(os.path.join(DIR_MERGE, CURED_PATTERN), sample=SAMPLES),
        xlsx      = expand(os.path.join(DIR_RESULT, "{sample}", "annotation_comparison_report.xlsx"), sample=SAMPLES)
    threads: max(1, THREADS // MAX_JOBS)
    resources:
        mem_mb =  MEM_TOTAL // MAX_JOBS
    log:
        os.path.join(DIR_LOGS, "merge", "pipeline.log")
    run:
        import os
        os.makedirs(DIR_RESULT, exist_ok=True)
        os.makedirs(os.path.dirname(log[0]), exist_ok=True)

        cmd = f"""
docker run --rm \
    -u $(id -u):$(id -g) \
    -v "{DIR_MERGE}:/data" \
    -v "{DIR_RESULT}:/results" \
    {IMG_MERGE} \
    -i /data \
    -o /results \
    -t {threads} \
    --min-pident {MERGE_MIN_PIDENT} \
    --min-qcov   {MERGE_MIN_QCOV} \
    --jobs       {MERGE_JOBS}
"""
        run_with_watchdog(cmd, log[0],
                          max_retries=MAX_RETRIES,
                          inactivity_timeout=INACTIVITY_TIMEOUT,
                          check_interval=CHECK_INTERVAL,
                          shell=True)

rule copy_cured_results:
    input:
        cured = os.path.join(DIR_MERGE, CURED_PATTERN)
    output:
        result_cured = os.path.join(DIR_RESULT, "{sample}_cured.gb")
    shell:
        """
        cp {input.cured} {output.result_cured}
        """
