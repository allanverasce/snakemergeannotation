# Troubleshooting

A list of common errors and situations when running SnakeMergeAnnotation, and how to resolve them. If your issue isn't listed here, open an [issue on the repository](https://github.com/allanverasce/snakemergeannotation/issues) describing the error and, if possible, pasting the relevant part of the log.

---

## Docker not found / "Cannot connect to the Docker daemon"

**Cause:** Docker is not installed, or is installed but not running.

**Fix:**
1. Confirm Docker is installed: [docs.docker.com/get-docker](https://docs.docker.com/get-docker/)
2. Open Docker Desktop (Windows/Mac) or check that the service is running (Linux: `sudo systemctl start docker`).
3. Try again.

---

## "Database not found" error (Bakta / DFAST)

**Cause:** the path set in `db_path` (in `config.yaml` or the Tools tab of the interface) doesn't match where the database was actually downloaded.

**Fix:**
- Double-check the full (absolute) path to the folder where the database was downloaded in [Quick Start Guide — Step 2](quick-start-guide.md#step-2--download-the-databases).
- For Bakta, the path should point to the correct subfolder (e.g., `bakta_db/db-light`), not just the root databases folder.

---

## PGAP database download fails or seems to hang

**Cause:** `python pgap.py --update` downloads a large database and can take a while depending on your connection; it can also fail silently if run from the wrong directory.

**Fix:**
- Make sure you're running the command from the software's root directory (where `pgap.py` lives).
- Let the download finish completely before running the pipeline — an interrupted PGAP download will cause the PGAP annotation step to fail later.
- If you don't have taxonomy information for your samples (e.g., metagenomic data), you likely don't need PGAP at all — see [Genomic data vs. metagenomic data](quick-start-guide.md#genomic-data-vs-metagenomic-data) and disable it instead of troubleshooting the download.

---

## PATRIC / BV-BRC step fails

**Most common cause:** incorrect username or password, an unconfirmed account, or missing taxonomy information.

**Fix:**
- Confirm you've already verified your free account at [bv-brc.org](https://www.bv-brc.org).
- Double-check the username and password exactly as registered (no extra spaces).
- PATRIC requires a known taxonomy (`taxonomy_id`). If you're working with metagenomic data and don't know the taxonomy, disable PATRIC instead — see [Genomic data vs. metagenomic data](quick-start-guide.md#genomic-data-vs-metagenomic-data).
- If submitting many genomes at once, batch submission can take a while — check the log at `logs/patric/all_samples.log` before assuming it failed.

---

## I'm working with metagenomic data (MAGs) and don't know what to disable

**Fix:** disable **PATRIC** and **PGAP** (both require known taxonomy), and set the following fields to `"unknown"`:
- Bakta: `genus`, `strain`, `gram`
- Prokka: `genus`
- DFAST: `organism`

See the full explanation in [Genomic data vs. metagenomic data](quick-start-guide.md#genomic-data-vs-metagenomic-data) and the matching command-line example in [Genomic vs. metagenomic usage examples](advanced-guide.md#genomic-vs-metagenomic-usage-examples).

---

## Run failed midway and doesn't resume correctly

**Cause:** a job was interrupted (e.g., power loss, manually killed process) and left an incomplete file.

**Fix:**
```
snakemake --configfile config.yaml --cores 8 --rerun-incomplete
```

If you're running with several extra flags (as in the genomic/metagenomic examples), keep `--rerun-incomplete` and add `--keep-going` so a single failed genome doesn't stop the rest of the batch.

---

## Out-of-memory error (e.g., process "killed" with no clear message)

**Cause:** the configured `mem_mb` value (or `heavy_slots`/`light_slots` resource caps) is lower than what's needed for that particular genome (common with large genomes).

**Fix:** increase the memory value, either in `config.yaml`:
```yaml
resources:
  mem_mb: 32000
```
or directly in the command:
```
snakemake --configfile config.yaml --cores 16 \
          --resources mem_mb=32000 heavy_slots=1 light_slots=4
```
or for a specific rule only:
```
snakemake --configfile config.yaml --cores 16 \
          --set-resources annotate_dfast:mem_mb=32000
```

---

## The run is very slow

**Possible causes and fixes:**
- Too few `threads`/`cores`/`--jobs` available: increase these according to what your machine can handle.
- Too many genomes running in parallel: lower `max_jobs` (merge step) or `--jobs` if your machine has limited memory, or raise them if you have more resources available.
- Downloading large databases (full Bakta ~84 GB, PGAP database): use the "light" Bakta database (~3.9 GB) if you don't need the more comprehensive annotation, and skip PGAP/PATRIC entirely for metagenomic runs.

---

## Getting "file not found" errors on a network filesystem or cluster

**Cause:** output files can take a moment to appear on network-mounted storage, and Snakemake may check for them too soon.

**Fix:** add `--latency-wait 60` (or a higher value) to give the filesystem more time to register new files.

---

## The graphical interface (`app.py`) won't open in the browser

**Fix:**
- Confirm that `python app.py` didn't show an error in the terminal before trying to access `http://localhost:5000`.
- Check whether another application is already using port 5000. If so, close it or adjust the port as instructed in the terminal output.

---

## I don't know where my final results are

Check the `README.txt` (or `summary.html`) file automatically generated in the output folder (`output_dir`) you configured — it points directly to the most important files. For the full output folder structure, see [Advanced Guide — Output Structure](advanced-guide.md#output-structure).
