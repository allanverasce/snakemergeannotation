# Advanced Guide — Command-Line Mode

This guide is for anyone already familiar with Snakemake, Docker, and editing `.yaml` files who prefers running the pipeline directly from the terminal, with finer control over parameters.

## 1. Clone the repository

```
git clone https://github.com/allanverasce/snakemergeannotation.git
cd snakemergeannotation
```

## 2. Install Snakemake

```
pip install snakemake

# Optional: for HPC cluster execution
pip install snakemake-executor-plugin-slurm
```

## 3. Download the databases

See the full instructions in **[Quick Start Guide — Step 2](quick-start-guide.md#step-2--download-the-databases)**; the commands are the same, including the PGAP database:

```
python pgap.py --update
```

You only need to download databases for the tools you plan to enable — see [Genomic vs. metagenomic usage examples](#genomic-vs-metagenomic-usage-examples) below.

## 4. Configuration

Edit **only** `config.yaml` — this is the single interface between you and the workflow.

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
  max_jobs: 2       # genomes processed in parallel during merge

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
# PGAP
# ===========================================
pgap:
  enabled: true      # set to false for metagenomic data with unknown taxonomy

# ===========================================
# BV-BRC / PATRIC
# ===========================================
patric:
  enabled: true      # set to false for metagenomic data with unknown taxonomy
  docker_image: "engbio/patric:v1"
  username: "your@email.com"    # REQUIRED if enabled — bv-brc.org account
  password: "your_password"     # REQUIRED if enabled
  taxonomy_id: 1883             # NCBI TaxID (1883 = Streptomycetaceae)
  description: "Bacteria"

# ===========================================
# MERGE — BLASTp parameters
# ===========================================
merge:
  docker_image: "engbio/merge:v1"
  min_pident: 95.0   # minimum % identity required to consider a match
  min_qcov:   0.9    # minimum query coverage (0–1)
  jobs:       2       # genomes processed in parallel
```

For metagenomic data, remember to also set `genus`/`gram` to `"unknown"` under `bakta`, `genus` to `"unknown"` under `prokka`, and `organism` to `"unknown"` under `dfast`.

> The merge parameters (`min_pident`, `min_qcov`) can be moved to a separate `config_advanced.yaml` file if you'd like to keep the main `config.yaml` simpler. See [Merge profiles](#merge-profiles) below.

## 5. Run

Place your genome FASTA files in the folder set as `fasta_dir`. The workflow automatically detects all `.fasta`, `.fa`, and `.fna` files.

```
snakemake --configfile config.yaml --cores 8
```

The `--config base_tool=<tool>` flag lets you choose which tool's annotation is used as the local reference for the all-vs-all BLASTp comparison (see [Genomic vs. metagenomic usage examples](#genomic-vs-metagenomic-usage-examples) below).

When you run the merge container directly, you'll see a banner with a short preview of the available merge options:

<p align="center">
<img src="https://github.com/user-attachments/assets/ca149a4d-68cd-41d2-bffa-ce4b362cf7b2" alt="Merge container banner" width="700">
</p>

```
docker run --rm engbio/merge:v1 --help
```

### Dry run (check the DAG without executing)

```
snakemake --configfile config.yaml --cores 8 --dry-run
```

### Visualize the execution graph

```
snakemake --configfile config.yaml --dag | dot -Tpng > dag.png
```

### Resume an interrupted run

Snakemake automatically resumes from where it stopped — just run the same command again. Completed steps are skipped.

```
snakemake --configfile config.yaml --cores 8
```

If a job failed midway and left an incomplete file:

```
snakemake --configfile config.yaml --cores 8 --rerun-incomplete
```

## Genomic vs. metagenomic usage examples

SnakeMergeAnnotation supports both genomic (isolate, known taxonomy) and metagenomic (MAG/bin, unknown taxonomy) workflows. The main difference is which tools are enabled and which one is used as the `base_tool` — the local reference annotation that all others are compared against via BLASTp.

### Genomics (isolate, with known taxonomy)

All tools enabled, using PATRIC as the base tool:

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

If you'd rather use Bakta as the base annotation even in genomic mode — for example, to avoid depending on PATRIC's external login/service for the reference BLAST — use:

```bash
--config base_tool=bakta
```

### Metagenomics (MAG/bin, unknown taxonomy)

PATRIC and PGAP disabled, Bakta as the base tool:

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

Remember to also set the taxonomy-related fields to `"unknown"` in `config.yaml` for Bakta (`genus`, `strain`, `gram`), Prokka (`genus`), and DFAST (`organism`).

### What the extra flags do

| Flag | Purpose |
|---|---|
| `--jobs` | Maximum number of Snakemake jobs (genomes/rules) running in parallel |
| `--resources mem_mb=... heavy_slots=... light_slots=...` | Caps total memory and limits how many resource-heavy vs. lightweight rules run at once |
| `--keep-going` | Keeps running remaining jobs even if one job fails, instead of stopping the whole workflow |
| `--rerun-incomplete` | Re-runs any step that was left incomplete by an interrupted previous run |
| `--latency-wait 60` | Waits up to 60 seconds for output files to appear before considering a step failed (useful on network filesystems) |

## 6. HPC / Cloud execution

### SLURM cluster

```
pip install snakemake-executor-plugin-slurm

snakemake --configfile config.yaml \
          --executor slurm \
          --jobs 100 \
          --default-resources mem_mb=16000 runtime=120 cpus_per_task=8 slurm_partition=cpu
```

### AWS Batch / Google Batch

```
pip install snakemake-executor-plugin-aws-batch

snakemake --configfile config.yaml \
          --executor aws-batch \
          --jobs 500
```

### Adjusting resources per rule

For large genomes or slower machines:

```
snakemake --configfile config.yaml --cores 16 \
          --set-resources annotate_dfast:mem_mb=32000
```

## Output structure

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
│   ├── <genome>_..._Prokka_UPDATED.gb
│   ├── <genome>_..._dfast_UPDATED.gb
│   ├── <genome>_..._dfast_finalversion.gb  ◀ FINAL
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

## Merge profiles

The BLASTp parameters control how strict the annotation transfer is. All are configurable in `config.yaml`, under the `merge` section:

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

> **Important:** annotation transfer only occurs for **full-length alignments**, where `alignment_length == CDS_length` for both query and subject. This prevents transfers for partial matches or frameshifted CDS.

## Docker images used

| Image | Base | Tool | Purpose |
|---|---|---|---|
| `engbio/bakta:v1` | oschwengers/bakta | Bakta ≥1.9 | Primary annotation |
| `engbio/prokka:v1` | staphb/prokka | Prokka 1.14.6 | Secondary annotation |
| `engbio/dfast:v1` | nigyta/dfast_core | DFAST 1.3.7 | Annotation + defense systems |
| `engbio/patric:v1` | Ubuntu 20.04 + BV-BRC CLI | BV-BRC CLI 1.039 | Cloud-based annotation |
| `engbio/merge:v1` | python:3.11-slim + BLAST+ | Custom Python pipeline | Merge and HP reduction |
