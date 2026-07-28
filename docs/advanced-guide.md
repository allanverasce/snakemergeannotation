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

See the full instructions in **[Quick Start Guide — Step 2](quick-start-guide.md#step-2--download-the-databases)**; the commands are the same.

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
  min_pident: 95.0   # minimum % identity required to consider a match
  min_qcov:   0.9    # minimum query coverage (0–1)
  jobs:       2       # genomes processed in parallel
```

> The merge parameters (`min_pident`, `min_qcov`) can be moved to a separate `config_advanced.yaml` file if you'd like to keep the main `config.yaml` simpler. See [Merge profiles](#merge-profiles) below.

## 5. Run

Place your genome FASTA files in the folder set as `fasta_dir`. The workflow automatically detects all `.fasta`, `.fa`, and `.fna` files.

```
snakemake --configfile config.yaml --cores 8
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

## View merge container options

```
docker run --rm engbio/merge:v1 --help
```
