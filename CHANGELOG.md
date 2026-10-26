# Changelog

All notable changes to Prokfinder. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the versions follow [Semantic Versioning](https://semver.org/). Changes waiting for a release are listed under
**Unreleased**; at a release, that section gets the version number and the date.

Versions 0.1 to 0.4 were not published as GitHub releases; they are reconstructed from the commit history.

## [Unreleased] - 0.5.0-dev

### Added
- `run-on-cluster --prepend-path <dir>`: puts a folder first in the PATH of the job, after the modules (e.g., a conda
  environment with a newer skDER/CiDDER than the cluster module).
- `download-wf` writes `FINAL-RESULTS/versions.tsv` (programs, reference databases, CheckM2 database, BUSCO lineages
  and GTDB-Tk reference package used) and `FINAL-RESULTS/parameters.tsv` (command line, genome selection and the
  effective value of every option).
- Gene prediction once per genome with Pyrodigal (translation table 11 or 4 chosen as GTDB-Tk does; meta mode only
  for genomes < 100 kbp); the proteins are used by CheckM2, BUSCO, GTDB-Tk and CiDDER.
- BUSCO (proteins mode, lineage chosen by the NCBI domain) on the genomes that pass CheckM2; reported, not filtered
  (`--skip-busco`).
- Dereplication with CiDDER (`--derep-method cidder`) besides skDER; all results in `OUTPUT/GENOME-DEREPLICATION`.
- GTDB taxonomy in three steps: GTDB tables, then GTDB-Tk `ani_rep` (by default, when GTDB-Tk is installed), then
  the GTDB tree with `--use-gtdbtk-tree`. `GENOME-TAXONOMY/taxonomy-classification.tsv` records the method, ANI,
  aligned fraction and thresholds of each genome; a new run with `--use-gtdbtk-tree` only places the genomes that
  are still unclassified.
- Status of each genome in GTDB in the metadata: `GTDB_SPECIES_REPRESENTATIVE`, `GTDB_REPRESENTATIVE_GENOME`,
  `GTDB_TYPE_MATERIAL`, `GTDB_TYPE_SPECIES_OF_GENUS`.
- `--gtdb-taxon-file`; a GTDB taxon name that is not in the GTDB tables is an invalid filter value.
- Global option `--memory`; `run-on-cluster` passes the CPUs and RAM of the job to the programs, refuses `-p` or
  `--memory` larger than the job and asks for at least 4 CPUs and 4 GB (8 GB with `download-wf`).
- PBS job, node, queue, CPUs, RAM and walltime written to `prokfinder.log`.
- `NULL-VALUES-<DB>.tsv` in each reference database: every empty or invalid value converted to NULL (source table,
  column, original value, rule, occurrences).
- Docker image with every program (`docker/`), published to Docker Hub by a GitHub Actions workflow.
- NCBI domain of each genome (`GENOME_DOMAIN_NCBI`).
- `setup` downloads the ready-made reference databases from Zenodo (one package per database, MD5 checked; registry in
  `refdb-zenodo.tsv`, another one with `--refdb-registry`). `setup --from-source` builds them from the NCBI, BacDive
  and GTDB sources, as `setup` did before. A database installed from a package whose format is out of date, or with
  a newer package in the registry, is replaced by the new package; an interrupted package download is resumed.
  `--ncbi-complete-metadata` needs `--from-source`.
- `setup --from-source` with the databases already installed is a full update (everything downloaded again from the
  sources, each database replaced only when its new copy is complete), after a warning and a `[y/N]` confirmation;
  `run-on-cluster` asks before submitting the job and passes `--yes` to it. Without a terminal, `--yes` is needed.
- Automated tests (`tests/run-tests.sh`, bats-core): shared functions, command line, genome search, the rebuild
  of the reference tables by `setup` and every `download-wf` step (with re-execution), on a small fixture of the
  reference databases and a few genomes (`tests/data`), with real seqkit and Pyrodigal and fake CheckM2, BUSCO,
  GTDB-Tk, skDER and CiDDER (`tests/bin`), without network; real runs only with `--level e2e`. GitHub Actions runs them on every push and pull request
  (`.github/workflows/tests.yml`).
- One run per results folder: active PBS jobs or processes are detected and can be cancelled.
- GPL-3.0 license, `CITATION.cff`, `CLAUDE.md`, `AGENTS.md`, `llms.txt` and the generated `catalog.json`.

### Changed
- `download-wf` order: download, contigs, structure (seqkit), genes, completeness (CheckM2 + BUSCO), taxonomy,
  hierarchy, dereplication, summary.
- The taxonomy used by Prokfinder is GTDB only.
- CiDDER reads the Pyrodigal proteins when it is 1.3.7 or newer; with an older one (the cluster module is 1.3.6) one
  warning is logged and CiDDER predicts the genes again from the genomes (`CIDDER_INPUT = genomes`); with 1.3.7 or
  newer a failure on the proteins is no longer hidden by that fallback.
- BUSCO, CheckM2 and GTDB-Tk run with their own conda environment first in the PATH.
- `run-on-cluster --test` has a walltime of 1 hour.
- CheckM2 runs with `--lowmem` (slower, with a warning) when `--memory` is below 18 GB; `run-on-cluster` with
  `download-wf` still needs at least 8 GB and warns between 8 and 18 GB.
- Reference table formats: NCBI 3, BacDive 3, GTDB 4 (`setup` rebuilds them from the files already downloaded).
- The hierarchy leaves no longer get their own metadata table; `REPRESENTATIVE_GENOME` is only in
  `genome-metadata.tsv`.

### Removed
- NCBI taxonomy filters `-t/--taxid`, `-f/--taxid-file`, `--ncbi-taxon`, `-N/--ncbi-taxon-file`.
- `--gtdbtk` (replaced by the default ANI step and `--use-gtdbtk-tree`).
- `--meta-for-mags` (MAGs are predicted in single mode).
- `setup --force-refdb`: `setup` replaces the Zenodo packages by the newer ones, and `setup --from-source` over
  installed databases is the full update.

### Fixed
- Genome download: the NCBI `fetch.txt` lines end with CRLF, so no genome was downloaded.
- BUSCO failed on the cluster with "No module named 'busco'" (python3 of another module first in the PATH).
- `GTDB_TYPE_MATERIAL` values such as "not used as type" are now NULL.
- `run-on-cluster --test` ignored `-o`: the test job is now written to `<results_dir>/PBS-JOBS`.
- BacDive tables written with jq >= 1.7 had numbers such as `67.0` where older jq writes `67`; every jq now writes
  the same tables.

## [0.4.0] - 2026-10-18

### Added
- `--check`: dependencies of the search and of the complete pipeline, and the state of the reference databases.
- One flag per BacDive trait (`-O`, `-M`, `--gram-stain`, `--motility`, `--spore-formation`, `--energy-source`,
  `--electron-donor`, `--carbon-source`).
- `SEARCH-GENOMES-ERRORS.tsv` with every invalid filter value, and `--force-search` to ignore them.
- List files read as TSV (first column; a header line is skipped); `-i/-I` accept regular expressions.

### Changed
- Shorter help, one per sub-command; the search no longer requires the programs of `download-wf`.

### Removed
- `-B/--bacdive-class`.

### Fixed
- Exit code 141 (SIGPIPE) with large list files.

## [0.3.1] - 2026-10-16

### Changed
- The complete NCBI metadata table is optional (`setup --ncbi-complete-metadata`).

## [0.3.0] - 2026-10-15

### Added
- Sub-commands `setup`, `search-genomes`, `download-wf` and `run-on-cluster`.
- Selection expression with AND/OR and parentheses; one `SELECTED_BY_*` column per filter.
- BacDive tables per strain and per NCBI TaxID (BactoTraits style).
- `setup --force-refdb` installs each database in a temporary folder.

### Changed
- Parameters given only by flags (no environment variables).
- Programs written in Go limited to the CPUs of the PBS job (GOMAXPROCS).

## [0.2.0] - 2026-10-14

### Added
- Shared reference databases folder (`~/prokfinder-refdb`), results folder `prokfinder-results` (`-o`).
- PBS execution options.

## [0.1.0] - 2026-10-13

### Added
- First modular version: reference databases (NCBI, BacDive, GTDB), genome selection, download, contig filtering,
  quality control (seqkit, CheckM2), GTDB taxonomy, taxonomic hierarchy, dereplication (skDER) and final summary.
