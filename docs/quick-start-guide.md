# Quick Start Guide — Basic Mode (Graphical Interface)

This guide is for anyone **with no command-line experience** who wants to use SnakeMergeAnnotation through the graphical interface.

## What you'll need

- A computer with Docker installed ([how to install](https://docs.docker.com/get-docker/))
- Python installed, with Snakemake (`pip install snakemake`)
- Your genome files in `.fasta`, `.fa`, or `.fna` format
- A free account at [bv-brc.org](https://www.bv-brc.org) (only needed for the PATRIC step)

No programming knowledge or terminal use is required beyond the installation step below.

---

## Step 1 — Install the prerequisites

Open a terminal (Command Prompt on Windows; Terminal on Mac/Linux) and run:

```
pip install snakemake
```

Also make sure Docker is installed and running (you'll see the Docker "whale" icon active in your taskbar/menu bar).

## Step 2 — Download the databases

The annotation tools need reference databases. This only needs to be done once.

**Bakta database** (light version, ~3.9 GB, recommended):
```
docker run --rm \
    -v "/path/to/databases/bakta_db:/db" \
    engbio/bakta:v1 \
    bakta_db --output /db download --type light
```

**DFAST database** (~15 GB total):
```
docker run --rm \
    -v "/path/to/databases/dfast_db:/dfast_core/db" \
    engbio/dfast:v1 \
    python /dfast_core/scripts/file_downloader.py --protein dfast

docker run --rm \
    -v "/path/to/databases/dfast_db:/dfast_core/db" \
    engbio/dfast:v1 \
    python /dfast_core/scripts/file_downloader.py --cdd Cog

docker run --rm \
    -v "/path/to/databases/dfast_db:/dfast_core/db" \
    engbio/dfast:v1 \
    python /dfast_core/scripts/file_downloader.py --hmm TIGR
```

> Tip: write down the full path where you saved these databases — you'll need it in Step 4.

## Step 3 — Open the interface

From the terminal, inside the project folder, run:

```
python app.py
```

Open your browser (Chrome, Firefox, etc.) and go to:

```
http://localhost:5000
```

## Step 4 — Fill in the tabs

The interface has four main tabs:

1. **Home** — set the folder containing your genome files and the folder where results will be saved.
2. **Tools** — configure each annotation tool (Bakta, Prokka, DFAST, PATRIC) according to the type of organism. This is where you enter the full path to the databases you downloaded in Step 2. For PATRIC, enter your bv-brc.org username and password.
3. **Merge** — set the criteria for how similar two proteins need to be to be considered "the same" across different tools. If you're not sure, leave the default values.
4. **Run** — click run and follow progress in real time through the Logs panel.

## Demo mode

If you just want to see the pipeline in action before using your own data, use the **"Use sample/demo data"** button on the Home tab. This automatically fills in the fields with a small demo genome (from the `examples/` folder), letting you run the full workflow in a few minutes without downloading all the large databases first.

## What to do once it's finished

When the run completes, open the output folder you specified on the Home tab. You'll find a `README.txt` (or `summary.html`) file pointing directly to:

- The main result (final enriched annotation)
- The publication-ready table
- The hypothetical protein reduction plots

## Running into problems?

If something goes wrong, check the **[troubleshooting guide](troubleshooting.md)**.
