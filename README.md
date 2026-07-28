# SnakeMergeAnnotation

<p align="center">
  <img src="https://img.shields.io/badge/snakemake-≥9.0-brightgreen" alt="Snakemake">
  <img src="https://img.shields.io/badge/docker-required-blue" alt="Docker">
  <img src="https://img.shields.io/badge/python-3.11-blue" alt="Python">
  <img src="https://img.shields.io/badge/license-AGPL--3.0-green" alt="License">
</p>

> **Dockerized Snakemake pipeline for hypothetical protein curation in prokaryotic genomes.**

<p align="justify"> SnakeMergeAnnotation orchestrates annotation tools — Bakta, Prokka, DFAST, PGAP, eggNOG, and BV-BRC/PATRIC — in a single Snakemake workflow, then merges their results to transfer functional annotations to hypothetical proteins. It works for both **genomic** (isolate genomes with known taxonomy) and **metagenomic** (MAGs/bins with unknown taxonomy) data.</p>

---

## Requirements

You only need to install two things on your machine — everything else (Python, BLAST+, Biopython, annotation tools, databases) runs inside Docker containers:

| Dependency | Version | Install |
|---|---|---|
| **Docker** | ≥ 20.10 | <https://docs.docker.com/get-docker/> |
| **Snakemake** | ≥ 9.0 | `pip install snakemake` |

A free account at [bv-brc.org](https://www.bv-brc.org) is also required for the PATRIC annotation step.

We recommend creating an isolated Python environment before installing Snakemake:
```
python -m venv venv
source venv/bin/activate
pip install snakemake
```

Go to the software directory,for example, `cd snakemergeannotation` and run the following command:Run:
   ```
   python app.py
   ```
   then open `http://localhost:5000` in your browser.

The interface will walk you through the configuration, tools, merge, and execution tabs, with real-time progress tracking through the logs. You can also turn individual annotation tools on or off directly in the interface — no command-line flags needed.

##  New to bioinformatics or the command line? Start here
---
Full step-by-step guide with screenshots: **[docs/quick-start-guide.md](docs/quick-start-guide.md)**

---

##  Advanced mode (command line)

If you're already familiar with Snakemake, Docker, and editing `.yaml` files, you can jump straight to manual execution via `config.yaml` and the command line — including genomic vs. metagenomic run examples and HPC/cloud execution.

 Full guide: **[docs/advanced-guide.md](docs/advanced-guide.md)**

---

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Genomic vs. Metagenomic Data](#genomic-vs-metagenomic-data)
- [Requirements](#requirements)
- [Repository Structure](#repository-structure)
- [Output Results](#output-results)
- [Docker Images](#docker-images)
- [Running Into Problems?](#running-into-problems)
- [Technical Terms](#technical-terms)
- [Citation](#citation)
- [License](#license)

For installation steps, configuration, usage, HPC/cloud execution, and merge pipeline parameters, see **[docs/quick-start-guide.md](docs/quick-start-guide.md)** and **[docs/advanced-guide.md](docs/advanced-guide.md)**.

---

## Overview

### Main processing steps of the SnakeMergeAnnotation pipeline

<p align="center">
  <img src="screen/pipelinev3.png" alt="pipeline1" width="300" height="800">
  &nbsp;&nbsp;&nbsp;
  <img src="screen/pipelineH.png" alt="pipelineH" width="300" height="800">
</p>

All tools run **inside Docker containers**.

---

## How It Works

<p align="justify">The execution of the SnakeMergeAnnotation pipeline is customizable. The user can choose not to run some of the annotation modules — simply disable the tools directly in the graphical interface, or, if using the command-line version, specify the parameters to disable the desired tools. However, if the user wishes to run all modules, they must follow every setup step described, such as creating a username and password on the PATRIC platform. The process is divided into stages:</p>

1. **Annotation** — each genome is annotated independently by Bakta, Prokka, DFAST, eggNOG, PGAP, and BV-BRC (PATRIC). BV-BRC submissions are handled in batch via the cloud API.

2. **Comparison** — an "all-versus-all" BLASTp comparison is performed between the CDSs from all tools for each genome, using the result produced by the user-defined tool (`base_tool`) as the local reference.

3. **Merge** — functional annotations from Bakta, Prokka, eggNOG, PGAP, and DFAST are transferred to the BV-BRC CDS entries labeled `hypothetical protein`, using strict full-length alignment criteria (the alignment length must equal the CDS length) and the user-defined minimum identity percentage.

4. **Defense systems** — defense-related notes from DFAST are additionally transferred via 1:1 perfect BLASTp matches.

5. **Additional resources in the final annotation** — the consolidated annotation is enriched with the following information:
   - Gene symbols
   - EC numbers (enzyme classification)
   - GO terms (gene ontologies)
   - KEGG Orthology (KO)
   - KEGG Pathways
   - KEGG Reactions
   - KEGG rclass
   - BRITE hierarchies
   - PFAM domains

6. **Reports** — per-genome Excel reports, HP reduction plots, and an article-ready summary table are generated automatically.

7. **Note:** SnakeMergeAnnotation can be used for genomic or metagenomic data — see [Genomic vs. Metagenomic Data](#genomic-vs-metagenomic-data) below.

---

## Genomic vs. Metagenomic Data

SnakeMergeAnnotation can be used for **genomic** or **metagenomic** data.

For metagenomic data specifically, the PATRIC and PGAP tools are **disabled by default**, since both require the user to specify the taxonomy. If the user already has this information, the tools can be enabled as desired.

- In **Bakta**, the fields `Genus`, `Strain`, and `Gram` must be set to `"unknown"`.
- In **Prokka**, `Genus` must be set to `"unknown"`.
- In **DFAST**, `organism` must also be set to `"unknown"`.

Full command-line examples for both genomic and metagenomic runs: see **[docs/advanced-guide.md — Genomic vs. metagenomic usage examples](docs/advanced-guide.md#genomic-vs-metagenomic-usage-examples)**.

---

## Repository Structure

```
snakemergeannotation/
├── app.py                  # Graphical interface (basic mode)
├── Snakefile                # Pipeline definition (advanced mode)
├── pgap.py                  # PGAP database downloader/updater
├── config.yaml              # Essential configuration
├── config_advanced.yaml     # Technical parameters (optional)
├── docs/                     # Guides and documentation
│   ├── quick-start-guide.md
│   ├── advanced-guide.md
│   ├── troubleshooting.md
│   └── glossary.md
├── examples/                 # Sample configuration and data
├── screen/                    # Screenshots used in the documentation
├── templates/                 # Web interface templates
└── LICENSE
```

---

## Output Results

At the end of the run, the most important files are automatically highlighted in `output_dir/README.txt`. The main ones are:

| File | Description |
|---|---|
| `*_cured.gb` | Final enriched GenBank file — main result |
| `annotation_comparison_report.xlsx` | BLASTp comparison across all tools |
| `hp_summary_report.tsv` | HP counts at each merge step |
| `article_ready_table.csv` | Summary table with % reduction per genome |
| `*_hp_reduction.png` | HP reduction curve per genome |

Full output folder structure: see **[docs/advanced-guide.md — Output Structure](docs/advanced-guide.md#output-structure)**.

---

## Docker Images

| Image | Base | Tool | Purpose |
|---|---|---|---|
| `engbio/bakta:v1` | oschwengers/bakta | Bakta ≥1.9 | Annotation |
| `engbio/prokka:v1` | staphb/prokka | Prokka 1.14.6 | SAnnotation |
| `engbio/dfast:v1` | nigyta/dfast_core | DFAST 1.3.7 | Annotation + defense systems |
| `engbio/patric:v1` | Ubuntu 20.04 + BV-BRC CLI | BV-BRC CLI 1.039 | Annotation |
| `engbio/merge:v1` | python:3.11-slim + BLAST+ | Custom Python pipeline | Merge and HP reduction |
| `quay.io/biocontainers/eggnog-mapper:2.1.13--pyhdfd78af_1` |  |eggnog-mappe | Annotation |
| `ncbi/pgap:2026-06-18.build8602` | | ncbi/pgap | Annotation | 

---

## Running Into Problems?

Check **[docs/troubleshooting.md](docs/troubleshooting.md)** before opening an issue — most common errors (incorrect paths, missing databases, insufficient memory) are already documented there.

---

## Technical Terms

If you come across unfamiliar terms or acronyms (CDS, BLASTp, frameshift, MAG, etc.), check the **[glossary](docs/glossary.md)**.

---

## Citation

If you use SnakeMergeAnnotation in your research, please cite the underlying tools:

- **PGAP:** Tatiana et al. (2016) *Nucleic Acids Research*. <https://doi.org/10.1093/nar/gkw569>
- **Bakta:** Schwengers et al. (2021) *Microbial Genomics*. <https://doi.org/10.1099/mgen.0.000685>
- **Prokka:** Seemann (2014) *Bioinformatics*. <https://doi.org/10.1093/bioinformatics/btu153>
- **DFAST:** Tanizawa et al. (2018) *Bioinformatics*. <https://doi.org/10.1093/bioinformatics/btx713>
- **BV-BRC:** Olson et al. (2023) *Nucleic Acids Research*. <https://doi.org/10.1093/nar/gkac1003>
- **eggNOG:** Cantalapiedra et al. (2021) *Molecular Biology and Evolution*. <https://doi.org/10.1093/molbev/msab293>
- **Snakemake:** Mölder et al. (2021) *F1000Research*. <https://doi.org/10.12688/f1000research.29032.2>

---

## License

AGPL-3.0 license — see [LICENSE](LICENSE) for details.
