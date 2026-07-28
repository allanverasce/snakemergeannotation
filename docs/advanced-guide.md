# Advanced Guide — Command-Line Mode

This guide is for anyone already familiar with Snakemake, Docker, and editing `.yaml` files who prefers running the pipeline directly from the terminal, with finer control over parameters.

## 1. Clone the repository

```bash
git clone https://github.com/allanverasce/snakemergeannotation.git
cd SnakeMergeAnnotation
```

## 2. Install Snakemake

```bash
pip install snakemake
# Optional: for HPC cluster execution
pip install snakemake-executor-plugin-slurm
```

## 3. Download databases

See the full instructions in **[Quick Start Guide — Step 3](quick-start-guide.md#step-3--download-the-databases)**; the commands are the same, including the PGAP database:

```bash
python pgap.py --update
```

You only need to download databases for the tools you plan to enable — see [Genomic vs. metagenomic usage examples](#genomic-vs-metagenomic-usage-examples) below.

## 4. Configuration

Edit **only** `config.yaml` — this is the single interface between the user and the workflow.

```yaml
# ===========================================
# REQUIRED: set your paths
# ===========================================
paths:
  fasta_dir:  "/path/to/your/genomes"    # folder containing .fasta / .fa / .fna files
  output_dir: "/path/to/output"          # all results will be saved here

# ===========================================
# COMPUTE RESOURCES
# ===========================================
general:
  threads: 8       # threads per job

resources:
  mem_mb:   16000  # memory per job in MB
  max_jobs: 2      # organisms processed in parallel during merge

# ===========================================
# BAKTA
# ===========================================
bakta:
  enabled: true
  docker_image: "engbio/bakta:v1"
  db_path: "/path/to/databases/bakta_db/db-light"   # REQUIRED
  gram: "+"          # "+" gram-positive | "-" gram-negative | "?" unknown
  genus: "Streptomyces"
  translation_table: 11

# ===========================================
# PROKKA
# ===========================================
prokka:
  enabled: true
  docker_image: "engbio/prokka:v1"
  genus: "Streptomyces"
  kingdom: "Bacteria"
  gcode: 11

# ===========================================
# DFAST
# ===========================================
dfast:
  enabled: true
  docker_image: "engbio/dfast:v1"
  db_path: "/path/to/databases/dfast_db"            # REQUIRED

# ===========================================
# BV-BRC / PATRIC
# ===========================================
patric:
  enabled: true
  docker_image: "engbio/patric:v1"
  username: "your@email.com"    # REQUIRED — bv-brc.org account
  password: "your_password"     # REQUIRED
  taxonomy_id: 1883             # NCBI TaxID (1883 = Streptomycetaceae)
  description: "Bacteria"

# ===========================================
# MERGE — BLASTp parameters
# ===========================================
merge:
  docker_image: "engbio/merge:v1"
  min_pident: 95.0   # minimum identity % (default: 95.0)
  min_qcov:   0.9    # minimum query coverage 0–1 (default: 0.9)
  jobs:       2      # organisms processed in parallel (default: 2)
```

For metagenomic data, remember to also set `genus`/`gram` to `"unknown"` under `bakta`, `genus` to `"unknown"` under `prokka`, and `organism` to `"unknown"` under `dfast`, and to disable PATRIC and PGAP (either in the graphical interface or with `--config patric.enabled=false pgap.enabled=false`, shown below).

> The merge parameters (`min_pident`, `min_qcov`) can be moved to a separate `config_advanced.yaml` file if you'd like to keep the main `config.yaml` simpler.

## 5. Usage

```bash
# docker run --rm engbio/merge:v1 --help
```

**When running the container, the banner will appear like this, with a small preview of the merge options:**

<p align="center">
<img src="https://github.com/user-attachments/assets/ca149a4d-68cd-41d2-bffa-ce4b362cf7b2" alt="logsnakemerge">
</p>

Place your genome FASTA files in the `fasta_dir` defined in `config.yaml`. The workflow automatically detects all `.fasta`, `.fa`, and `.fna` files.

```bash
# Standard execution — local workstation
snakemake --configfile config.yaml --cores 8
```

### Dry run (check the DAG without executing)

```bash
snakemake --configfile config.yaml --cores 8 --dry-run
```

### Visualize the execution graph

```bash
snakemake --configfile config.yaml --dag | dot -Tpng > dag.png
```

### Resume interrupted run

Snakemake automatically resumes from where it stopped — just run the same command again. Completed steps are skipped.

```bash
snakemake --configfile config.yaml --cores 8
```

### Or, if a job failed in the middle and left an incomplete file, use:

```bash
snakemake --configfile config.yaml --cores 8 --rerun-incomplete
```

---

## HPC / Cloud Execution

### SLURM cluster

Install the SLURM executor plugin and run:

```bash
pip install snakemake-executor-plugin-slurm

snakemake --configfile config.yaml \
          --executor slurm \
          --jobs 100 \
          --default-resources mem_mb=16000 runtime=120 cpus_per_task=8 slurm_partition=cpu
```

### AWS Batch / Google Batch

```bash
pip install snakemake-executor-plugin-aws-batch

snakemake --configfile config.yaml \
          --executor aws-batch \
          --jobs 500
```

### Adjusting resources per rule

For large genomes or slower machines, increase resources directly in the command:

```bash
snakemake --configfile config.yaml --cores 16 \
          --set-resources annotate_dfast:mem_mb=32000
```

---

## Genomic vs. metagenomic usage examples

### Genomics (isolate, with known taxonomy)

All tools enabled, using PATRIC as the default:

```bash
source $HOME/venv/bin/activate

snakemake --configfile config.yaml \
  --cores 20 \
  --jobs 2 \
  --resources mem_mb=20000 heavy_slots=1 light_slots=4 \
  --keep-going \
  --rerun-incomplete \
  --latency-wait 60 \
  --config base_tool=patric
```

If you prefer to use Bakta as the database even in genomic mode (to avoid relying on PATRIC's external login/service for the reference BLAST):

```bash
--config base_tool=bakta
```

### Metagenomics (MAG/bin, unknown taxonomy)

PATRIC and PGAP disabled, Bakta as the baseline:

```bash
source $HOME/venv/bin/activate

snakemake --configfile config.yaml \
  --cores 20 \
  --jobs 2 \
  --resources mem_mb=20000 heavy_slots=1 light_slots=4 \
  --keep-going \
  --rerun-incomplete \
  --latency-wait 60 \
  --config base_tool=bakta patric.enabled=false pgap.enabled=false
```

Remember to also set the taxonomy-related fields to `"unknown"` in `config.yaml` for Bakta (`genus`, `strain`, `gram`), Prokka (`genus`), and DFAST (`organism`) — see [Genomic data vs. metagenomic data](quick-start-guide.md#genomic-data-vs-metagenomic-data).

### What the extra flags do

| Flag | Purpose |
|---|---|
| `base_tool` | Which tool's annotation is used as the local reference for the all-vs-all BLASTp comparison (`patric` or `bakta`) |
| `--jobs` | Maximum number of Snakemake jobs (genomes/rules) running in parallel |
| `--resources mem_mb=... heavy_slots=... light_slots=...` | Caps total memory and limits how many resource-heavy vs. lightweight rules run at once |
| `--keep-going` | Keeps running remaining jobs even if one job fails, instead of stopping the whole workflow |
| `--rerun-incomplete` | Re-runs any step that was left incomplete by an interrupted previous run |
| `--latency-wait 60` | Waits up to 60 seconds for output files to appear before considering a step failed (useful on network filesystems) |

---

## Output Structure

```
output_dir/
│
├── bakta_out/
│   └── <genome>/
│       └── <genome>_bakta.gbff
│
├── prokka_out/
│   └── <genome>_prokka/
│       └── <genome>_prokka.gbk
│
├── dfast_out/
│   └── <genome>_dfast.gbk
│
├── patric_out/
│   └── <genome>_patric.gb
│
├── merge_input/                             ← intermediate merge files
│   ├── <genome>_patric.gb                   input base annotation
│   ├── <genome>_patric_bakta_UPDATED.gb     after Bakta merge
│   ├── <genome>_patric_bakta_UPDATED_Prokka_UPDATED.gb
│   ├── <genome>_patric_bakta_UPDATED_Prokka_UPDATED_dfast_UPDATED.gb
│   ├── <genome>_patric_bakta_UPDATED_Prokka_UPDATED_dfast_finalversion.gb  ◀ FINAL
│   └── hp_summary_report.tsv                consolidated HP reduction table
│
├── merge_results/
│   ├── <genome>/
│   │   └── annotation_comparison_report.xlsx   (4 sheets: Summary, Exact, Partial, Unique)
│   ├── <genome>_hp_reduction.png               per-genome reduction plot
│   ├── hp_reduction_plot.png                   consolidated plot (all genomes)
│   └── article_ready_table.csv                 table ready for publication
│
└── logs/
    ├── bakta/    <genome>.log
    ├── prokka/   <genome>.log
    ├── dfast/    <genome>.log
    ├── patric/   all_samples.log
    └── merge/    pipeline.log
```

> Note: file names under `merge_input/` reflect whichever tool was used as the `base_tool` (e.g., files will start with `_bakta` instead of `_patric` if `base_tool=bakta`).

### Key output files

| File | Description |
|---|---|
| `*_finalversion.gb` | Final enriched GenBank — main result |
| `annotation_comparison_report.xlsx` | BLASTp comparison between all tools |
| `hp_summary_report.tsv` | HP counts at each merge step |
| `article_ready_table.csv` | Summary table with % reduction per genome |
| `*_hp_reduction.png` | HP reduction curve per genome |

---

## Docker Images

| Image | Base | Tool | Purpose |
|---|---|---|---|
| `engbio/bakta:v1` | oschwengers/bakta | Bakta ≥1.9 | Primary annotation |
| `engbio/prokka:v1` | staphb/prokka | Prokka 1.14.6 | Secondary annotation |
| `engbio/dfast:v1` | nigyta/dfast_core | DFAST 1.3.7 | Annotation + defense systems |
| `engbio/patric:v1` | Ubuntu 20.04 + BV-BRC CLI | BV-BRC CLI 1.039 | Cloud-based annotation |
| `engbio/merge:v1` | python:3.11-slim + BLAST+ | Custom Python pipeline | Merge and HP reduction |

---

## Merge Pipeline Parameters

The merge step uses BLASTp to identify CDS that match between tools and transfers functional annotations. All parameters are configurable in `config.yaml` under the `merge` section.

| Parameter | Default | Description |
|---|---|---|
| `min_pident` | `95.0` | Minimum BLASTp identity (%) to consider a match |
| `min_qcov` | `0.9` | Minimum query coverage (0–1) |
| `jobs` | `2` | Number of genomes processed in parallel |

**Strict mode** (only near-identical proteins):
```yaml
merge:
  min_pident: 100.0
  min_qcov:   1.0
```

**Permissive mode** (broader transfers):
```yaml
merge:
  min_pident: 80.0
  min_qcov:   0.7
```

> **Important:** annotation transfer only occurs for **full-length alignments** where `alignment_length == CDS_length` for both query and subject. This prevents partial matches and frameshifted CDS from being transferred.
