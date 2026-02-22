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

IMG_BAKTA  = config["bakta"]["docker_image"]
IMG_PROKKA = config["prokka"]["docker_image"]
IMG_DFAST  = config["dfast"]["docker_image"]
IMG_PATRIC = config["patric"]["docker_image"]
IMG_MERGE  = config["merge"]["docker_image"]

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

DIR_BAKTA  = os.path.join(OUTPUT_DIR, "bakta_out")
DIR_PROKKA = os.path.join(OUTPUT_DIR, "prokka_out")
DIR_DFAST  = os.path.join(OUTPUT_DIR, "dfast_out")
DIR_PATRIC = os.path.join(OUTPUT_DIR, "patric_out")
DIR_MERGE  = os.path.join(OUTPUT_DIR, "merge_input")
DIR_RESULT = os.path.join(OUTPUT_DIR, "merge_results")
DIR_LOGS   = os.path.join(OUTPUT_DIR, "logs")

# ===========
# FINAL RULE
# ===========

rule all:
    input:
        expand(
            os.path.join(DIR_MERGE,
                "{sample}_patric_bakta_UPDATED_Prokka_UPDATED_dfast_finalversion.gb"),
            sample=SAMPLES
        ),
        os.path.join(DIR_MERGE,  "hp_summary_report.tsv"),
        os.path.join(DIR_RESULT, "hp_reduction_plot.png"),
        os.path.join(DIR_RESULT, "article_ready_table.csv"),
        expand(
            os.path.join(DIR_RESULT, "{sample}", "annotation_comparison_report.xlsx"),
            sample=SAMPLES
        )


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
# PROKKA
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
# DFAST
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

        shell(f"""
            docker run --rm \
                -v "{FASTA_DIR}:/input:ro" \
                -v "{params.tmpdir}:/output" \
                -v "{DB_DFAST}:/dfast_core/db:ro" \
                --entrypoint dfast \
                {IMG_DFAST} \
                --genome "/input/{{wildcards.sample}}.fasta" \
                --out "/output/{{wildcards.sample}}_dfast" \
                --cpu {threads} \
            > {{log[0]}} 2>&1
        """)

        shell(f"""
            GBK=$(find {params.tmpdir}/{{wildcards.sample}}_dfast \
                  -maxdepth 2 -name "genome.gbk" | head -n 1)
            cp "$GBK" {{output.gbk}}
            rm -rf {params.tmpdir}/{{wildcards.sample}}_dfast
        """)


# =======
# PATRIC 
# =======

rule annotate_patric:
    input:
        expand(os.path.join(FASTA_DIR, "{sample}.fasta"), sample=SAMPLES)
    output:
        expand(os.path.join(DIR_PATRIC, "{sample}_patric.gb"), sample=SAMPLES)
    params:
        jobs_dir = os.path.join(OUTPUT_DIR, "patric_jobs")
    resources:
        mem_mb = 4000
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
                set -euo pipefail
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
                        p3-ls -l --type "/$USER_EMAIL/$WS_OUT/$gname" 2>/dev/null \\
                            | grep -q "job_result" \\
                            && echo "Done: $gname" \\
                            || {{ echo "Waiting: $gname"; all_done=false; }}
                    done < "$JOBS_FILE"
                    $all_done && break
                    sleep "$INTERVAL"
                done

                while IFS=' ' read -r sid gname; do
                    [ -z "$sid" ] && continue
                    p3-cp ws:"/$USER_EMAIL/$WS_OUT/.${{gname}}/${{gname}}.gb" \\
                          "/output/${{gname}}_patric.gb" \\
                    && echo "Saved: ${{gname}}_patric.gb" \\
                    || echo "ERROR: $gname"
                done < "$JOBS_FILE"

                p3-logout
            """))

        shell(f"""
            docker run --rm \
                -v "{FASTA_DIR}:/input:ro" \
                -v "{DIR_PATRIC}:/output" \
                -v "{params.jobs_dir}:/jobs" \
                {IMG_PATRIC} \
                bash /jobs/patric_inner.sh \
            > {{log[0]}} 2>&1
        """)


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


# =========
# RUN MERGE
# =========

rule run_merge:
    input:
        expand(os.path.join(DIR_MERGE, "{sample}_patric.gb"),  sample=SAMPLES),
        expand(os.path.join(DIR_MERGE, "{sample}_bakta.gbff"), sample=SAMPLES),
        expand(os.path.join(DIR_MERGE, "{sample}_prokka.gbk"), sample=SAMPLES),
        expand(os.path.join(DIR_MERGE, "{sample}_dfast.gbk"),  sample=SAMPLES)
    output:
        report    = os.path.join(DIR_MERGE,  "hp_summary_report.tsv"),
        hp_plot   = os.path.join(DIR_RESULT, "hp_reduction_plot.png"),
        art_table = os.path.join(DIR_RESULT, "article_ready_table.csv"),
        finals    = expand(
            os.path.join(DIR_MERGE,
                "{sample}_patric_bakta_UPDATED_Prokka_UPDATED_dfast_finalversion.gb"),
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
        os.makedirs(DIR_RESULT, exist_ok=True)
        os.makedirs(os.path.dirname(log[0]), exist_ok=True)

        shell(f"""
            docker run --rm \
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