# Glossary

Plain-language explanations of the technical terms used in SnakeMergeAnnotation's documentation and interface.

---

**Genome annotation**
The process of identifying and describing the genes in a genome and their functions — for example, determining that a stretch of DNA corresponds to a gene that produces a certain protein, and what that protein's function is.

**Base tool (`base_tool`)**
The annotation tool whose output is used as the local reference for the all-vs-all BLASTp comparison. All other tools' annotations are compared against this one when deciding what gets merged. Common choices are `patric` (for genomic data with known taxonomy) or `bakta` (works without external logins or taxonomy).

**BLASTp**
A tool that compares protein sequences against each other to find the most similar ones. It's used here to compare the proteins predicted by different tools and decide whether they represent "the same protein."

**CDS (Coding Sequence)**
A stretch of DNA that actually codes for a protein (i.e., that will be "translated" into a sequence of amino acids).

**Query coverage (`min_qcov`)**
The percentage of the original sequence covered by the alignment in a BLASTp comparison. 100% coverage (`1.0`) means the entire sequence was compared, with no parts missing.

**Docker / Docker image / Container**
Docker is a technology that packages a program together with everything it needs to run (libraries, dependencies, system tools), so it behaves the same way on any computer. An "image" is that ready-made package; a "container" is a running instance of that image.

**Frameshift**
An error that occurs when the "reading" of the DNA gets shifted out of place, causing the predicted protein from that point onward to be incorrect. The pipeline avoids transferring annotations in these cases.

**Gram-positive / Gram-negative (`gram: "+"` / `"-"`)**
A classification of bacteria based on a feature of the cell wall, identified through a lab test called Gram staining. Some annotation tools use this information to adjust their predictions. When the organism's identity is unknown (e.g., metagenomic data), this can be set to `"?"` or `"unknown"`.

**HP / Hypothetical protein**
A protein identified in the genome whose function is not yet known. One of this pipeline's main goals is to reduce the number of hypothetical proteins by assigning them a function whenever another annotation tool already knows what it is.

**Identity (`min_pident`)**
The percentage of similarity between two compared protein sequences. 100% means the sequences are identical; lower values allow for small differences.

**KEGG (KO, Pathways, Reactions, rclass)**
A database that organizes genes and proteins in terms of metabolic pathways and biochemical functions. "KO" (KEGG Orthology) groups genes with equivalent functions; "Pathways" are the metabolic pathways themselves.

**GO (Gene Ontology)**
A standardized system of terms used to describe a gene or protein's function, its role in biological processes, and its location within the cell.

**MAG (Metagenome-Assembled Genome)**
A genome reconstructed directly from metagenomic sequencing data (a mixed sample containing DNA from many organisms), rather than from a pure, isolated culture of a single organism. MAGs typically have unknown or uncertain taxonomy, which is why tools like PATRIC and PGAP are disabled by default for this kind of data.

**PFAM**
A database of protein "domains" — recurring segments found across different proteins that are associated with specific functions.

**PGAP (Prokaryotic Genome Annotation Pipeline)**
An NCBI annotation tool for prokaryotic genomes, used in SnakeMergeAnnotation as one of the tools that can enrich or serve as the base annotation. It requires known taxonomy, so it's typically disabled for metagenomic (MAG) data.

**Snakemake**
A tool that organizes and runs the pipeline's steps in the correct order, handling dependencies between them (for example, only starting the merge step once all annotations are complete) and allowing an interrupted run to resume without repeating steps that already finished.

**Snakemake flags used in this pipeline**
- `--jobs` — maximum number of Snakemake jobs (genomes/rules) allowed to run at the same time.
- `--resources mem_mb=... heavy_slots=... light_slots=...` — caps total memory usage and limits how many resource-heavy vs. lightweight rules can run simultaneously.
- `--keep-going` — if one job fails, the rest of the workflow keeps running instead of stopping entirely.
- `--rerun-incomplete` — re-runs any step left incomplete by a previous, interrupted run.
- `--latency-wait <seconds>` — waits the given number of seconds for output files to appear before treating a step as failed; useful on network filesystems or clusters, where files can take a moment to show up.

**Taxonomy ID (`taxonomy_id`)**
A standardized identification number (from NCBI) that identifies the species or taxonomic group of the organism being analyzed. Used by some tools to adjust the annotation to the type of organism. Not available/needed for metagenomic data with unknown taxonomy.

**Translation table (`translation_table` / `gcode`)**
The genetic code used to translate DNA into protein. Most bacteria use the standard table (11), but some groups use variants.
