# SnakeMergeAnnotation

<p align="center">
  <img width="600" alt="logo_snakemergeannotation" src="https://github.com/user-attachments/assets/fed334b3-01c3-4d38-b17a-b3a278eacb2f" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/snakemake-≥9.0-brightgreen" alt="Snakemake">
  <img src="https://img.shields.io/badge/docker-required-blue" alt="Docker">
  <img src="https://img.shields.io/badge/python-3.11-blue" alt="Python">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
</p>

> **Dockerized Snakemake Pipeline for Hypothetical Protein Curation in Prokaryotic Genomes.**

SnakeMergeAnnotation orchestrates four annotation tools (Bakta, Prokka, DFAST, BV-BRC/PATRIC and eggNOG) in a single Snakemake workflow, then merges their results to transfer functional annotations to hypothetical proteins.

---

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Output Structure](#output-structure)
- [Docker Images](#docker-images)
- [Merge Pipeline Parameters](#merge-pipeline-parameters)
- [HPC / Cloud Execution](#hpc--cloud-execution)
- [Citation](#citation)

---

## Overwiew
### Main processing steps of the SnakeMergeAnnotation Pipeline
<p align="center">
  <img src="image/pipelinev2.png" alt="Logo" width="300" height="800" />
</p>



All tools run **inside Docker containers**.

---

## How It Works

1. **Annotation** — Each genome is annotated independently by Bakta, Prokka, DFAST, and BV-BRC (PATRIC). BV-BRC submissions are handled in batch via the cloud API.

2. **Comparison** — An all-vs-all BLASTp comparison is performed between the CDS from all four tools per genome.

3. **Merge** — Functional annotations from Bakta, Prokka, eggNOG and DFAST are transferred to BV-BRC CDS entries labeled as `hypothetical protein`, using strict full-length alignment criteria (identical alignment length and CDS length for both query and subject, no frameshifts).

4. **Defense systems** — Defense-related notes from DFAST are additionally transferred via 1:1 perfect BLASTp matches.

5. **Reports** — Per-genome Excel reports, HP reduction plots, and an article-ready summary table are generated automatically.

---

## Requirements
We recommend creating a Python environment to install the package versions. An example is shown below:

```
python -m venv venv
source /home/allan/venv/bin/activate
pip install snakemake
```

### Host dependencies (only these two)

| Dependency | Version | Install |
|------------|---------|---------|
| **Docker** | ≥ 20.10 | https://docs.docker.com/get-docker/ |
| **Snakemake** | ≥ 9.0 | `pip install snakemake` |

> Everything else (Python, BLAST+, Biopython, annotation tools, databases) runs inside Docker containers.

### BV-BRC account

A free account at [bv-brc.org](https://www.bv-brc.org) is required for the PATRIC annotation step.

---

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/your-username/SnakeMergeAnnotation.git
cd SnakeMergeAnnotation
```

### 2. Install Snakemake

```bash
pip install snakemake
# Optional: for HPC cluster execution
pip install snakemake-executor-plugin-slurm
```

### 3. Pull or build Docker images

**Option A — Pull from Docker Hub (recommended):**
```bash
docker pull engbio/bakta:v1
docker pull engbio/prokka:v1
docker pull engbio/dfast:v1
docker pull engbio/patric:v1
docker pull engbio/merge:v1
```

**Option B — Build locally:**
```bash
# Build only the merge image (the others are available on Docker Hub)
cd dockermerge
docker build -t engbio/merge:v1 .
cd ..
```

### 4. Download databases

**Bakta database (light ~3.9 GB or full ~84 GB):**
```bash
# Light version (recommended for most use cases)
docker run --rm \
    -v "/path/to/databases/bakta_db:/db" \
    engbio/bakta:v1 \
    bakta_db --output /db download --type light
```

**DFAST database (~15 GB total):**
```bash
# Protein reference database
docker run --rm \
    -v "/path/to/databases/dfast_db:/dfast_core/db" \
    engbio/dfast:v1 \
    python /dfast_core/scripts/file_downloader.py --protein dfast_default

# COG/CDD database
docker run --rm \
    -v "/path/to/databases/dfast_db:/dfast_core/db" \
    engbio/dfast:v1 \
    python /dfast_core/scripts/file_downloader.py --cdd Cog

# TIGRFAMs HMM database
docker run --rm \
    -v "/path/to/databases/dfast_db:/dfast_core/db" \
    engbio/dfast:v1 \
    python /dfast_core/scripts/file_downloader.py --hmm TIGRFAMs
```

### Types of SnakeMergeAnnotation execution 

<p align="justify">The first is the basic mode, designed for greater accessibility and ease of use. In this format, the program is run through an intuitive and user-friendly web interface, allowing the user to enter:</p>

 - The path to the input files in FASTA format;
 - The output directory for storing the results;
 - The analysis configuration parameters.

<p align="justify"> Additionally, the interface allows users to monitor the progress of the processing in real time, offering greater transparency, traceability, and control over the execution of the pipeline.</p>

<p align="justify">The second execution format is called advanced mode. In this mode, the user manually performs the necessary configurations and selects the command line most appropriate for their specific problem. This mode is recommended for users who are more familiar with computing environments, allowing for greater flexibility, parameter customization, and integration with other automated workflows or high-performance computing (HPC) environments.</p>



# Basic mode
To start basic mode, run the following command:

```
docker rm -f snakemergeannotation && docker run -d   --name snakemergeannotation   -p 5000:5000   -v /var/run/docker.sock:/var/run/docker.sock   engbio/inteface_snakemergeannotation:v1
```

<p align="justify">To open the main window of the SnakeMergeAnnotation interface, open your preferred internet browser and enter the `URL http://localhost:5000  into the address bar.</p>

The main window will be displayed as shown in the figure below.

<img src="image/fig01.png" alt="Window1" width="800" height="600" />  

**Figure from the SnakeMergeAnnotation main window**

<p align="justify">The following image is from the second tab, called annotators, where the user can configure each annotation tool according to the type of organism being analyzed. It is important to enter the full path of the previously downloaded databases and, in the specific case of the Patric tool, the user must register to obtain the platform username and password.</p>

<img src="image/figure2.png" alt="Window1" width="800" height="1200" />  

In the Merge tab, the user can configure the parameters to consider the products that are candidates for automatic curation. 

<img src="image/fig03.png" alt="Window1" width="800" height="600" />  

In the execution tab, the user can run their analysis and monitor processing in real time through the Logs area. 

<img src="image/Figure4.png" alt="Window1" width="800" height="600" />  

---
# Advanced mode

## Configuration

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

---

## Usage


```bash
# docker run --rm engbio/merge:v1 --help
```

### When running the container, the banner will appear like this, with a small preview of the merge options:
![logsnakemerge](https://github.com/user-attachments/assets/ca149a4d-68cd-41d2-bffa-ce4b362cf7b2)


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
### or if a job failed in the middle and left an incomplete file, use:
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
---

### Key output files

| File | Description |
|------|-------------|
| `*_finalversion.gb` | Final enriched GenBank — main result |
| `annotation_comparison_report.xlsx` | BLASTp comparison between all 4 tools |
| `hp_summary_report.tsv` | HP counts at each merge step |
| `article_ready_table.csv` | Summary table with % reduction per genome |
| `*_hp_reduction.png` | HP reduction curve per genome |

---

## Docker Images

| Image | Base | Tool | Purpose |
|-------|------|------|---------|
| `engbio/bakta:v1` | oschwengers/bakta | Bakta ≥1.9 | Primary annotation |
| `engbio/prokka:v1` | staphb/prokka | Prokka 1.14.6 | Secondary annotation |
| `engbio/dfast:v1` | nigyta/dfast_core | DFAST 1.3.7 | Annotation + defense systems |
| `engbio/patric:v1` | Ubuntu 20.04 + BV-BRC CLI | BV-BRC CLI 1.039 | Cloud-based annotation |
| `engbio/merge:v1` | python:3.11-slim + BLAST+ | Custom Python pipeline | Merge and HP reduction |

---

## Merge Pipeline Parameters

The merge step uses BLASTp to identify CDS that match between tools and transfers functional annotations. All parameters are configurable in `config.yaml` under the `merge` section.

| Parameter | Default | Description |
|-----------|---------|-------------|
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

> **Important:** Annotation transfer only occurs for **full-length alignments** where `alignment_length == CDS_length` for both query and subject. This prevents partial matches and frameshifted CDS from being transferred.




## Citation

If you use SnakeMergeAnnotation in your research, please cite the underlying tools:

- **Bakta:** Schwengers et al. (2021) *Microbial Genomics*. https://doi.org/10.1099/mgen.0.000685
- **Prokka:** Seemann (2014) *Bioinformatics*. https://doi.org/10.1093/bioinformatics/btu153
- **DFAST:** Tanizawa et al. (2018) *Bioinformatics*. https://doi.org/10.1093/bioinformatics/btx713
- **BV-BRC:** Olson et al. (2023) *Nucleic Acids Research*. https://doi.org/10.1093/nar/gkac1003
- **Snakemake:** Mölder et al. (2021) *F1000Research*. https://doi.org/10.12688/f1000research.29032.2

---

## License

AGPL-3.0 license — see [LICENSE](LICENSE) for details.
