# =============================================================================
# Snakefile — SnakeMergeAnnotation workflow
# =============================================================================
# Usage:
#   snakemake --configfile config.yaml --cores 8
# =============================================================================
import os
import glob
import subprocess

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

MEM_MB   = config["resources"]["mem_mb"]
MAX_JOBS = config["resources"]["max_jobs"]

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
print(f"[SnakeMergeAnnotation] {len(SAMPLES)} genome(s) detected: {', '.join(SAMPLES)}")

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
        # Final enriched GBK per sample
        expand(
            os.path.join(DIR_MERGE, CURED_PATTERN),
            sample=SAMPLES
        ),
        # Reports and plots
        os.path.join(DIR_MERGE,  "hp_summary_report.tsv"),
        os.path.join(DIR_RESULT, "hp_reduction_plot.png"),
        os.path.join(DIR_RESULT, "article_ready_table.csv"),
        expand(
            os.path.join(DIR_RESULT, "{sample}", "annotation_comparison_report.xlsx"),
            sample=SAMPLES
        )


# ======
# BAKTA (1)
# ======

rule annotate_bakta:
    input:
        fasta = os.path.join(FASTA_DIR, "{sample}.fasta")
    output:
        gbff  = os.path.join(DIR_BAKTA, "{sample}", "{sample}_bakta.gbff")
    params:
        outdir = os.path.join(DIR_BAKTA, "{sample}")
    threads: THREADS
    resources:
        mem_mb = MEM_MB
    log:
        os.path.join(DIR_LOGS, "bakta", "{sample}.log")
    run:
        import os
        os.makedirs(params.outdir, exist_ok=True)
        os.makedirs(os.path.dirname(log[0]), exist_ok=True)

        extra = ""
        if BAKTA_GENUS:                       extra += f" --genus {BAKTA_GENUS}"
        if BAKTA_SPECIES:                     extra += f" --species {BAKTA_SPECIES}"
        if BAKTA_GRAM and BAKTA_GRAM != "?": extra += f" --gram {BAKTA_GRAM}"

        shell(f"""
            docker run --rm \
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


# =======
# PROKKA (2)
# =======

rule annotate_prokka:
    input:
        fasta = os.path.join(FASTA_DIR, "{sample}.fasta")
    output:
        gbk   = os.path.join(DIR_PROKKA, "{sample}_prokka", "{sample}_prokka.gbk")
    threads: THREADS
    resources:
        mem_mb = MEM_MB
    log:
        os.path.join(DIR_LOGS, "prokka", "{sample}.log")
    run:
        import os
        os.makedirs(DIR_PROKKA, exist_ok=True)
        os.makedirs(os.path.dirname(log[0]), exist_ok=True)

        extra = ""
        if PROKKA_GENUS: extra += f" --genus {PROKKA_GENUS}"

        shell(f"""
            docker run --rm \
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


# =====
# DFAST (3)
# =====

rule annotate_dfast:
    input:
        fasta = os.path.join(FASTA_DIR, "{sample}.fasta")
    output:
        gbk   = os.path.join(DIR_DFAST, "{sample}_dfast.gbk")
    params:
        tmpdir = os.path.join(OUTPUT_DIR, "dfast_tmp")
    threads: THREADS
    resources:
        mem_mb = MEM_MB
    log:
        os.path.join(DIR_LOGS, "dfast", "{sample}.log")
    run:
        import os
        os.makedirs(params.tmpdir, exist_ok=True)
        os.makedirs(DIR_DFAST, exist_ok=True)
        os.makedirs(os.path.dirname(log[0]), exist_ok=True)

        # Pre-create output dir so DFAST (non-root) can write into it
        outdir = os.path.join(params.tmpdir, wildcards.sample + "_dfast")
        os.makedirs(outdir, exist_ok=True)

        shell(f"""
            set -euo pipefail

            docker run --rm \
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

        # SAFE EXTRACTION
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


# =======
# PATRIC (4)
# =======

rule annotate_patric:
    input:
        expand(os.path.join(FASTA_DIR, "{sample}.fasta"), sample=SAMPLES)
    output:
        expand(os.path.join(DIR_PATRIC, "{sample}_patric.gb"), sample=SAMPLES)
    params:
        jobs_dir = os.path.join(OUTPUT_DIR, "patric_jobs")
    resources:
        mem_mb = MEM_MB
    log:
        os.path.join(DIR_LOGS, "patric", "all_samples.log")
    run:
        import os, textwrap
        os.makedirs(params.jobs_dir, exist_ok=True)
        os.makedirs(DIR_PATRIC, exist_ok=True)
        os.makedirs(os.path.dirname(log[0]), exist_ok=True)

        inner = os.path.join(params.jobs_dir, "patric_inner.sh")
        with open(inner, "w") as f:
            f.write(textwrap.dedent(f"""
                #!/bin/bash
                set -euxo pipefail
                USERNAME="{PATRIC_USER}"
                PASSWORD="{PATRIC_PASS}"
                TAXID="{PATRIC_TAXID}"
                DESC="{PATRIC_DESC}"
                WS_OUT="{PATRIC_WS}"
                JOBS_FILE="/jobs/jobs_list.txt"
                INTERVAL="{PATRIC_INTERVAL}"

                login_output=$(p3-login "$USERNAME" "$PASSWORD")
                USER_EMAIL=$(echo "$login_output" | grep -oP '(?<=Logged in with username ).*')
                echo "Logged in: $USER_EMAIL"
                echo "" > "$JOBS_FILE"

                for fasta in /input/*.fasta /input/*.fa /input/*.fna; do
                    [ -e "$fasta" ] || continue
                    gname=$(basename "$fasta" | sed 's/\\.[^.]*$//')
                    [ -f "/output/${{gname}}_patric.gb" ] && echo "SKIP: $gname" && continue
                    out=$(p3-submit-genome-annotation -f \\
                        --contigs-file "$fasta" \\
                        -t "$TAXID" -d "$DESC" \\
                        "/$USER_EMAIL/$WS_OUT" "$gname")
                    echo "$out"
                    sid=$(echo "$out" | grep -oP '(?<=Submitted annotation with id )\\d+')
                    [ -n "$sid" ] && echo "$sid $gname" >> "$JOBS_FILE"
                done

                while true; do
                    all_done=true
                    while IFS=' ' read -r sid gname; do
                        [ -z "$sid" ] && continue
                        p3-ls -l --type "/$USER_EMAIL/$WS_OUT/$gname" 2>/dev/null \
                            | grep -q "job_result" \
                            && echo "Done: $gname" \
                            || {{ echo "Waiting: $gname"; all_done=false; }}
                    done < "$JOBS_FILE"
                    $all_done && break
                    sleep "$INTERVAL"
                done

                while IFS=' ' read -r sid gname; do
                    [ -z "$sid" ] && continue
                    p3-cp ws:"/$USER_EMAIL/$WS_OUT/.${{gname}}/${{gname}}.gb" \
                          "/output/${{gname}}_patric.gb" \
                    && echo "Saved: ${{gname}}_patric.gb" \
                    || echo "ERROR: $gname"
                done < "$JOBS_FILE"

                p3-logout
            """))

        shell(f"""
            docker run --rm \
                -u $(id -u):$(id -g) \
                -e HOME=/jobs \
                -v "{FASTA_DIR}:/input:ro" \
                -v "{DIR_PATRIC}:/output" \
                -v "{params.jobs_dir}:/jobs" \
                {IMG_PATRIC} \
                bash /jobs/patric_inner.sh \
            > {{log[0]}} 2>&1
        """)


# ===================
# PREPARE MERGE INPUT (5)
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
# EXTRACT CDS (6)
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

        shell(f"""
            docker run --rm \
                -u $(id -u):$(id -g) \
                -v "{DIR_MERGE}:/data:ro" \
                -v "{DIR_EGGNOG}:/output" \
                --entrypoint python \
                {IMG_MERGE} \
                /app/cds_extract.py \
                    /data/{{wildcards.sample}}_patric.gb \
                    /output/{{wildcards.sample}}_proteins.fasta \
            > {{log[0]}} 2>&1
        """)


# ==========
# RUN EGGNOG (7)
# ==========

rule run_eggnog:
    input:
        faa = os.path.join(DIR_EGGNOG, "{sample}_proteins.fasta")
    output:
        annotations = os.path.join(DIR_EGGNOG,
            "{sample}_eggnog.emapper.annotations")
    threads: THREADS
    resources:
        mem_mb = MEM_MB
    log:
        os.path.join(DIR_LOGS, "eggnog", "{sample}_eggnog.log")
    run:
        import os
        import tempfile
        
        os.makedirs(DIR_EGGNOG, exist_ok=True)
        os.makedirs(os.path.dirname(log[0]), exist_ok=True)
        
        # Criar diretório temporário exclusivo
        temp_dir = tempfile.mkdtemp(prefix=f"eggnog_{wildcards.sample}_", dir=DIR_EGGNOG)
        
        try:
            # Ajustar permissões
            os.chmod(temp_dir, 0o755)
            
            shell(f"""
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
                        --temp_dir /tmp \
                > {{log[0]}} 2>&1
            """)
        finally:
            # Limpar diretório temporário
            import shutil
            shutil.rmtree(temp_dir, ignore_errors=True)


#===================
# MOVE EGGNOG RESULT (8)
#===================
rule move_eggnog_result:
    input:
        eggnog = os.path.join(DIR_EGGNOG, "{sample}_eggnog.emapper.annotations")                  
    output:
        eggnog = os.path.join(DIR_MERGE, "{sample}_eggnog.emapper.annotations")  
    shell:
        """
        cp {input.eggnog} {output.eggnog}
        """
        
# =========
# RUN MERGE (9)
# =========

rule run_merge:
    input:
        # Anotações
        expand(os.path.join(DIR_MERGE, "{sample}_patric.gb"),  sample=SAMPLES),
        expand(os.path.join(DIR_MERGE, "{sample}_bakta.gbff"), sample=SAMPLES),
        expand(os.path.join(DIR_MERGE, "{sample}_prokka.gbk"), sample=SAMPLES),
        expand(os.path.join(DIR_MERGE, "{sample}_dfast.gbk"),  sample=SAMPLES),
        # EggNOG results
        expand(os.path.join(DIR_MERGE, "{sample}_eggnog.emapper.annotations"), sample=SAMPLES)
    output:
        report    = os.path.join(DIR_MERGE,  "hp_summary_report.tsv"),
        hp_plot   = os.path.join(DIR_RESULT, "hp_reduction_plot.png"),
        art_table = os.path.join(DIR_RESULT, "article_ready_table.csv"),
        finals    = expand(
            os.path.join(DIR_MERGE, FINAL_VERSION_PATTERN),
            sample=SAMPLES
        ),
        cured     = expand(
            os.path.join(DIR_MERGE, CURED_PATTERN),
            sample=SAMPLES
        ),
        xlsx      = expand(
            os.path.join(DIR_RESULT, "{sample}", "annotation_comparison_report.xlsx"),
            sample=SAMPLES
        )
    threads: THREADS
    resources:
        mem_mb = MEM_MB
    log:
        os.path.join(DIR_LOGS, "merge", "pipeline.log")
    run:
        import os
        import time
        
        os.makedirs(DIR_RESULT, exist_ok=True)
        os.makedirs(os.path.dirname(log[0]), exist_ok=True)

        shell(f"""
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
                --jobs       {MERGE_JOBS} \
            > {{log[0]}} 2>&1
        """)
        
        # Verificar se os arquivos cured foram gerados
        for sample in SAMPLES:
            cured_file = os.path.join(DIR_MERGE, CURED_PATTERN.format(sample=sample))
            if not os.path.exists(cured_file):
                raise FileNotFoundError(f"Arquivo cured não foi gerado: {cured_file}")
        
        # Verificar relatórios consolidados
        if not os.path.exists(os.path.join(DIR_MERGE, "hp_summary_report.tsv")):
            raise FileNotFoundError("Relatório consolidado não foi gerado")
