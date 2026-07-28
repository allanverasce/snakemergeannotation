# SnakeMergeAnnotation

[![Snakemake](https://img.shields.io/badge/snakemake-≥9.0-brightgreen)](https://snakemake.readthedocs.io/)
[![Docker](https://img.shields.io/badge/docker-required-blue)](https://docs.docker.com/get-docker/)
[![Python](https://img.shields.io/badge/python-3.11-blue)](https://www.python.org/)
[![License](https://img.shields.io/badge/license-AGPL--3.0-green)](LICENSE)

> Dockerized Snakemake pipeline for hypothetical protein curation in prokaryotic genomes.

In short: SnakeMergeAnnotation automatically runs several genome annotation tools (Bakta, Prokka, DFAST, BV-BRC/PATRIC, and eggNOG), compares their results, and uses that comparison to "resolve" proteins labeled as **hypothetical** (i.e., of unknown function) whenever another tool already knows what their function is. In the end, you get a more complete genome annotation, plus reports and plots ready for analysis or publication.

---

## New to bioinformatics or the command line? Start here

You only need three steps:

1. Install [Docker](https://docs.docker.com/get-docker/)
2. Install Snakemake: `pip install snakemake`
3. Run:
   ```
   python app.py
   ```
   then open `http://localhost:5000` in your browser.

The interface will walk you through the configuration, tools, merge, and execution tabs, with real-time progress tracking through the logs.

Full step-by-step guide with screenshots: **[docs/quick-start-guide.md](docs/quick-start-guide.md)**

Want to try it with sample data first? See the **[demo mode](docs/quick-start-guide.md#demo-mode)**.

---

## Advanced mode (command line)

If you're already familiar with Snakemake, Docker, and editing `.yaml` files, you can jump straight to manual execution via `config.yaml` and the command line.

Full guide: **[docs/advanced-guide.md](docs/advanced-guide.md)**

---

## How it works (overview)

1. **Annotation** — each genome is annotated independently by Bakta, Prokka, DFAST, eggNOG, and BV-BRC (PATRIC).
2. **Comparison** — an all-vs-all BLASTp comparison is performed between the predicted proteins (CDS) from all tools.
3. **Merge** — functional annotations from Bakta, Prokka, eggNOG, and DFAST are transferred to BV-BRC entries labeled as "hypothetical protein," using strict alignment criteria (matching alignment length and CDS length, no frameshifts).
4. **Defense systems** — defense-related annotations from DFAST are also transferred via perfect 1:1 matches.
5. **Final enrichment** — the consolidated annotation is enhanced with: gene symbols, EC numbers, GO terms, KEGG Orthology (KO), KEGG pathways, KEGG rclass, BRITE hierarchies, and PFAM domains.
6. **Reports** — per-genome Excel reports, hypothetical-protein reduction plots, and an article-ready summary table are generated automatically.

![Pipeline overview](screen/pipelinev3.png)

---

## Requirements

You only need to install two things on your machine — everything else runs inside Docker containers:

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

---

## Repository structure

```
snakemergeannotation/
├── app.py                  # Graphical interface (basic mode)
├── Snakefile                # Pipeline definition (advanced mode)
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

## Output results

At the end of the run, the most important files are automatically highlighted in `output_dir/README.txt`. The main ones are:

| File | Description |
|---|---|
| `*_finalversion.gb` | Final enriched GenBank file — main result |
| `annotation_comparison_report.xlsx` | BLASTp comparison across all 4 tools |
| `hp_summary_report.tsv` | Hypothetical protein counts at each merge step |
| `article_ready_table.csv` | Summary table ready for publication |
| `*_hp_reduction.png` | Hypothetical protein reduction curve per genome |

Full output folder structure: see **[docs/advanced-guide.md](docs/advanced-guide.md#output-structure)**.

---

## Running into problems?

Check **[docs/troubleshooting.md](docs/troubleshooting.md)** before opening an issue — most common errors (incorrect paths, missing databases, insufficient memory) are already documented there.

---

## Technical terms

If you come across unfamiliar terms or acronyms (CDS, BLASTp, frameshift, etc.), check the **[glossary](docs/glossary.md)**.

---

## Citation

If you use SnakeMergeAnnotation in your research, please also cite the underlying tools:

- **PGAP:** Tatiana et al. (2016) *Nucleic Acids Research*. <https://doi.org/10.1093/nar/gkw569>
- **Bakta:** Schwengers et al. (2021) *Microbial Genomics*. <https://doi.org/10.1099/mgen.0.000685>
- **Prokka:** Seemann (2014) *Bioinformatics*. <https://doi.org/10.1093/bioinformatics/btu153>
- **DFAST:** Tanizawa et al. (2018) *Bioinformatics*. <https://doi.org/10.1093/bioinformatics/btx713>
- **BV-BRC:** Olson et al. (2023) *Nucleic Acids Research*. <https://doi.org/10.1093/nar/gkac1003>
- **Snakemake:** Mölder et al. (2021) *F1000Research*. <https://doi.org/10.12688/f1000research.29032.2>

---

## License

AGPL-3.0 — see [LICENSE](LICENSE) for details.
