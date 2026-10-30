# Changelog

All notable changes to Prokfinder. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the versions follow [Semantic Versioning](https://semver.org/). Changes waiting for a release are listed under
**Unreleased**; at a release, that section gets the version number and the date.

Versions 0.1 to 0.4 were not published as GitHub releases; they are reconstructed from the commit history.

## [Unreleased]

### Added
- `setup --from-zenodo` (only installs or updates the Zenodo databases) and `setup --update-taxdump-file` (only
  downloads the current NCBI taxdump and normalizes the NCBI TaxIDs again). The three options of `setup` are
  alternatives.
- Module `normalize-ncbi-taxids.sh`: downloads the NCBI taxdump into `<refdb>/NCBI/TAXDUMP` (replaced as a whole, under
  a lock) and checks the NCBI TaxIDs of the NCBI and BacDive tables against it. The result is written next to the
  tables (`<source>-taxid-status.tsv`, `bacdive-taxid-status.tsv`, with `TAXID_STATUS` CURRENT/MERGED/DELETED/INVALID,
  the current TaxID, its species and rank); a DELETED or INVALID TaxID of an assembly is rescued by the organism name
  (RESCUED/AMBIGUOUS/UNRESOLVED) and listed in `NCBI/taxid-unresolved.tsv`. The checkpoint
  `TAXID-NORMALIZATION-COMPLETED.txt` is written last.
- The NCBI tables have the paired assembly of the other database (`ASSEMBLY_PAIRED_ASSEMBLY_ACCESSION`,
  `ASSEMBLY_PAIRED_ASSEMBLY_REFSEQ_GENBANK_ARE_DIFFERENT`, and `NCBI_REFSEQ_ASSEMBLY_ACCESSION` in the GenBank table or
  `NCBI_GENBANK_ASSEMBLY_ACCESSION` in the RefSeq table; NULL when there is none or when NCBI says they are different).
- `search-genomes` writes `NCBI_TAXID_STATUS`, `NCBI_UPDATED_TAXID` and `NCBI_SPECIES_TAXID` (the normalized NCBI
  TaxID) in the genome metadata. The NCBI taxdump date is recorded in `versions.tsv` (`ncbi-taxdump`, with its citation).

### Changed
- Reference table formats: NCBI 3 → 4 (no lineage columns `NCBI_<RANK>` and `NCBI_<RANK>_TAXID`; the paired assembly
  columns above) and BacDive 3 → 4 (no `ncbi_tax_id_rank`: the rank is in `bacdive-taxid-status.tsv`). Tables of the
  older format are rebuilt from the raw files already downloaded (`setup`), or replaced by new Zenodo packages (**the
  Zenodo packages of format 3 are obsolete**).
- `setup` without options does what is missing (installs the databases, downloads the taxdump and normalizes) and only
  warns when the registry has a newer Zenodo package (before, it replaced the package); `--from-zenodo` replaces it.
- `search-genomes` and `download-wf` stop when the NCBI TaxIDs were not normalized (run `setup` or `setup
  --update-taxdump-file`) and warn when the normalization is from a previous day.
- `search-genomes -t/-f/--ncbi-taxon/-N`: the TaxID filters match the current TaxID of the assembly or any ancestor of it
  in the NCBI taxonomy (`nodes.dmp`), at any rank (before, only the 8 ranks of the lineage columns), and never use the
  global `~/.taxonkit` taxdump. The BacDive link uses the current TaxIDs.
- `setup --from-source` does not use taxonkit and does not download the taxdump (it removes the checkpoint of the
  normalization; run `setup` afterwards). It cannot be given together with `search-genomes` or `download-wf` in the same
  command, as `--from-zenodo`.

### Removed
- `download-reference-db-ncbi.sh --taxdump-dir` and `download-reference-db-bacdive.sh --taxdump-dir`.

## [0.5.0] - 2026-10-29

### Changed
- The help (`-h`) is written in boxes, one per group of options, as in `fastq-dl` and Bactopia; the descriptions of
  `setup`, `search-genomes` and `run-on-cluster` are one line.
- `-o, --results-dir` is now `-o, --output-dir`. Without `-o`, a new `search-genomes` in an existing
  `./prokfinder-results` asks for confirmation before running there (also with `run-on-cluster`, before the job).
- `download-wf` keeps the genomes compressed (`.fna.gz`) by default; `--decompress` replaces `-z, --gzip`.
- `download-wf --derep-ani` and `--derep-mode` are ignored with a warning when `--derep-method cidder` is used (the
  warning was printed twice).
- `--derep-method cidder` reads the proteins of the complete genes only (`GENOME-GENES/COMPLETE-GENES/`, Pyrodigal with
  closed ends, as CiDDER does when it predicts the genes itself); the dereplication of the lineages already run is
  redone once. These proteins are always predicted, with every method, so that the non-fragmented genes can also serve
  as a quality mark for later uses (e.g., functional annotation). The help and the README explain when to use skDER (genetic identity) and CiDDER (gene repertoire).
- `search-genomes -a/-A` (accessions) compares the whole accession with the searched table: `GCA_` only with the
  GenBank table (default) and `GCF_` only with `-s refseq` (before, `GCF_x.1` selected its GenBank pair `GCA_x.1`).
  Accessions not in the table are left out with a warning that lists them, so a genome never enters twice through
  its GCA/GCF pair.
- The log line "Resources used by the programs" is written only inside a PBS job; on a personal computer it showed
  only the computer's RAM.

### Fixed
- `download-wf --derep-method cidder` with CiDDER < 1.3.7 (genome files given with `--genomes`): CiDDER skips gzipped
  genomes, so they are decompressed into a temporary folder of the run first (the default is now `.fna.gz`).

### Removed
- `setup --yes` (the full update of `--from-source` is confirmed on the terminal; `run-on-cluster` asks before the
  job is submitted and the job does not ask again), `setup --ncbi-complete-metadata` and `setup --refdb-registry`.
- `search-genomes -c/--country` and `-C/--country-file`.

### Added
- `CITATIONS.md`: the references (with DOI) of the programs and databases Prokfinder uses and of its inspirations
  (BactoTraits, Bactopia); `CITATION.cff` lists the main ones in `references:`, and the README has a "Como citar"
  section.
- `versions.tsv` has a `CITATION` column (DOIs of each program and database); the end of `download-wf` and the
  `README.txt` of `GENOME-DATABASE` remind to cite them.
- `download-wf` runs skDER and CiDDER with `--determine-clusters` (the representatives do not change) and adds the
  columns `NEAREST_REPRESENTATIVE` and `NEAREST_REPRESENTATIVE_SIMILARITY` (skDER: ANI; CiDDER: % of shared protein
  clusters) to `genome-metadata.tsv`; the GTDB status of the genome stays in the taxonomy columns and does not change
  the choice of the representatives.
- A second Pyrodigal prediction with closed ends in `predict-genes-pyrodigal.sh` (always) and the column
  `PREDICTED_COMPLETE_GENES` (see above).
- `FINAL-RESULTS/genomes-left-out.tsv`: the genomes without GTDB taxonomy (`NOT_CLASSIFIED`) or whose taxon failed in
  the dereplication (`NOT_DEREPLICATED`), with what to do; the summary also warns about them.
- `search-genomes` filters `--genome-size <min:max>` (Mb), `--assembly-level` (contig, scaffold, chromosome,
  complete) and, by NCBI taxonomy, `-t/--taxid`, `-f/--taxid-file`, `--ncbi-taxon` and `-N/--ncbi-taxon-file` (names
  converted to TaxIDs with taxonkit; a name without TaxID is an invalid filter).
- `download-wf` writes `FINAL-RESULTS/versions.tsv` (programs, reference databases, CheckM2 database, BUSCO lineages
  and GTDB-Tk reference package used) and `FINAL-RESULTS/parameters.tsv` (command line, genome selection and the
  effective value of every option).
- `download-wf` step 11 (`modules/export-genome-database.sh`): `OUTPUT/GENOME-DATABASE/`, a self-contained genome
  database that can be moved and shared: `genomes/*.fna.gz`, `proteins/*.faa.gz`, `genes/*.gff.gz` (hard links when the
  file is already compressed, copies otherwise), `genome-database-metadata.tsv` (relative paths), `versions.tsv`,
  `parameters.tsv`, `README.txt` and `MD5SUMS.txt`. It has the representatives; `--export-all-hq` exports every genome
  that passed the quality filters.
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
