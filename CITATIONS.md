# Prokfinder: citations

If you use Prokfinder, please cite it (see [`CITATION.cff`](CITATION.cff)) **and the programs and databases it ran
for you**. The ones used in each run are listed, with their versions and DOIs, in `FINAL-RESULTS/versions.tsv` (also
copied to `GENOME-DATABASE/versions.tsv`).

## Prokfinder

- Castro da Rocha JP, Almeida ELM. Prokfinder: selection, download and curation of prokaryote genomes.
  https://github.com/LBCM-UFV/prokfinder-pipeline (a manuscript is in preparation).

## Reference databases

- **NCBI Datasets** (genome assemblies and their metadata; programs `datasets` and `dataformat`)

  > O'Leary NA, Cox E, Holmes JB, Anderson WR, Falk R, Hem V, Tsuchiya MTN, Schuler GD, Zhang X, Torcivia J, et al.
  > Exploring and retrieving sequence and metadata for species across the tree of life with NCBI Datasets.
  > Scientific Data. 2024;11(1):732. doi: [10.1038/s41597-024-03571-y](https://doi.org/10.1038/s41597-024-03571-y)

- **BacDive** (phenotypes of the strains)

  > Schober I, Koblitz J, Sardà Carbasse J, Ebeling C, Schmidt ML, Podstawka A, Gupta R, Ilangovan V, Chamanara J,
  > Overmann J, et al. BacDive in 2025: the core database for prokaryotic strain data. Nucleic Acids Research.
  > 2025;53(D1):D748-D756. doi: [10.1093/nar/gkae959](https://doi.org/10.1093/nar/gkae959)

  > Reimer LC, Sardà Carbasse J, Koblitz J, Ebeling C, Podstawka A, Overmann J. BacDive in 2022: the knowledge base
  > for standardized bacterial and archaeal data. Nucleic Acids Research. 2022;50(D1):D741-D746.
  > doi: [10.1093/nar/gkab961](https://doi.org/10.1093/nar/gkab961)

- **GTDB** (taxonomy; its data are licensed CC BY-SA 4.0: attribution is required)

  > Parks DH, Chaumeil PA, Mussig AJ, Rinke C, Chuvochina M, Hugenholtz P. GTDB release 10: a complete and systematic
  > taxonomy for 715 230 bacterial and 17 245 archaeal genomes. Nucleic Acids Research. 2026;54(D1):D743-D754.
  > doi: [10.1093/nar/gkaf1040](https://doi.org/10.1093/nar/gkaf1040)

  > Parks DH, Chuvochina M, Rinke C, Mussig AJ, Chaumeil PA, Hugenholtz P. GTDB: an ongoing census of bacterial and
  > archaeal diversity through a phylogenetically consistent, rank normalized and complete genome-based taxonomy.
  > Nucleic Acids Research. 2022;50(D1):D785-D794. doi: [10.1093/nar/gkab776](https://doi.org/10.1093/nar/gkab776)

## Programs

- **SeqKit** (contig filtering and genome structure)

  > Shen W, Sipos B, Zhao L. SeqKit2: A Swiss army knife for sequence and alignment processing. iMeta.
  > 2024;3(3):e191. doi: [10.1002/imt2.191](https://doi.org/10.1002/imt2.191)

- **TaxonKit** (NCBI taxon names and lineages in `setup` and `search-genomes --ncbi-taxon`)

  > Shen W, Ren H. TaxonKit: A practical and efficient NCBI taxonomy toolkit. Journal of Genetics and Genomics.
  > 2021;48(9):844-850. doi: [10.1016/j.jgg.2021.03.006](https://doi.org/10.1016/j.jgg.2021.03.006)

- **Pyrodigal** and **Prodigal** (gene prediction)

  > Larralde M. Pyrodigal: Python bindings and interface to Prodigal, an efficient method for gene prediction in
  > prokaryotes. Journal of Open Source Software. 2022;7(72):4296.
  > doi: [10.21105/joss.04296](https://doi.org/10.21105/joss.04296)

  > Hyatt D, Chen GL, LoCascio PF, Land ML, Larimer FW, Hauser LJ. Prodigal: prokaryotic gene recognition and
  > translation initiation site identification. BMC Bioinformatics. 2010;11:119.
  > doi: [10.1186/1471-2105-11-119](https://doi.org/10.1186/1471-2105-11-119)

- **CheckM2** (completeness and contamination; the quality filter)

  > Chklovski A, Parks DH, Woodcroft BJ, Tyson GW. CheckM2: a rapid, scalable and accurate tool for assessing
  > microbial genome quality using machine learning. Nature Methods. 2023;20(8):1203-1212.
  > doi: [10.1038/s41592-023-01940-w](https://doi.org/10.1038/s41592-023-01940-w)

- **BUSCO** (single-copy orthologs; reported)

  > Tegenfeldt F, Kuznetsov D, Manni M, Berkeley M, Zdobnov EM, Kriventseva EV. OrthoDB and BUSCO update: annotation
  > of orthologs with wider sampling of genomes. Nucleic Acids Research. 2025;53(D1):D516-D522.
  > doi: [10.1093/nar/gkae987](https://doi.org/10.1093/nar/gkae987)

  > Manni M, Berkeley MR, Seppey M, Simão FA, Zdobnov EM. BUSCO Update: Novel and Streamlined Workflows along with
  > Broader and Deeper Phylogenetic Coverage for Scoring of Eukaryotic, Prokaryotic, and Viral Genomes. Molecular
  > Biology and Evolution. 2021;38(10):4647-4654. doi: [10.1093/molbev/msab199](https://doi.org/10.1093/molbev/msab199)

- **GTDB-Tk** (`gtdbtk ani_rep`, and the tree with `--use-gtdbtk-tree`)

  > Chaumeil PA, Mussig AJ, Hugenholtz P, Parks DH. GTDB-Tk v2: memory friendly classification with the genome
  > taxonomy database. Bioinformatics. 2022;38(23):5315-5316.
  > doi: [10.1093/bioinformatics/btac672](https://doi.org/10.1093/bioinformatics/btac672)

- **skani** (ANI inside `gtdbtk ani_rep` and skDER)

  > Shaw J, Yu YW. Fast and robust metagenomic sequence comparison through sparse chaining with skani. Nature Methods.
  > 2023;20(11):1661-1665. doi: [10.1038/s41592-023-02018-3](https://doi.org/10.1038/s41592-023-02018-3)

- **skDER** and **CiDDER** (dereplication)

  > Salamzade R, Kottapalli A, Kalan LR. skDER and CiDDER: two scalable approaches for microbial genome
  > dereplication. Microbial Genomics. 2025;11(7):001438.
  > doi: [10.1099/mgen.0.001438](https://doi.org/10.1099/mgen.0.001438)

- Software cited by its website and version (no article): `jq` (https://jqlang.org), GNU Awk
  (https://www.gnu.org/software/gawk), curl (https://curl.se) and R (R Core Team, https://www.r-project.org; the
  graphs use base R only).

## Infrastructure

Used by the Docker image (`docker/`) and to run on HPC clusters.

> The Bioconda Team, Grüning B, Dale R, Sjödin A, Chapman BA, Rowe J, Tomkins-Tinch CH, Valieris R, Köster J.
> Bioconda: sustainable and comprehensive software distribution for the life sciences. Nature Methods.
> 2018;15(7):475-476. doi: [10.1038/s41592-018-0046-7](https://doi.org/10.1038/s41592-018-0046-7)

> da Veiga Leprevost F, Grüning BA, Alves Aflitos S, Röst HL, Uszkoreit J, Barsnes H, Vaudel M, Moreno P, Gatto L,
> Weber J, et al. BioContainers: an open-source and community-driven framework for software standardization.
> Bioinformatics. 2017;33(16):2580-2582. doi: [10.1093/bioinformatics/btx192](https://doi.org/10.1093/bioinformatics/btx192)

> Kurtzer GM, Sochat V, Bauer MW. Singularity: Scientific containers for mobility of compute. PLOS ONE.
> 2017;12(5):e0177459. doi: [10.1371/journal.pone.0177459](https://doi.org/10.1371/journal.pone.0177459)

## Inspirations

- **BactoTraits**: the formatting and aggregation of the BacDive traits (its first script was rewritten in Bash in
  `modules/download-reference-db-bacdive.sh`).

  > Cébron A, Zeghal E, Usseglio-Polatera P, Meyer A, Bauda P, Lemmel F, Leyval C, Maunoury-Danger F. BactoTraits – A
  > functional trait database to evaluate how natural and man-induced changes influence the assembly of bacterial
  > communities. Ecological Indicators. 2021;130:108047.
  > doi: [10.1016/j.ecolind.2021.108047](https://doi.org/10.1016/j.ecolind.2021.108047)

- **Bactopia**: the architecture (a hub of independent modules and ready-made workflows) and the style of the help.

  > Petit RA, Read TD. Bactopia: a Flexible Pipeline for Complete Analysis of Bacterial Genomes. mSystems.
  > 2020;5(4):e00190-20. doi: [10.1128/mSystems.00190-20](https://doi.org/10.1128/mSystems.00190-20)

Planned tools and criteria (MIMAG, Nextflow, PhiSpy, geNomad, annotation) are added here when they enter the code.
