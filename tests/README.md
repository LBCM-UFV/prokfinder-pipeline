# Testes do Prokfinder

Testes automáticos com [bats-core](https://github.com/bats-core/bats-core) (`conda install -c conda-forge bats-core`,
já incluído em `docker/env-prokfinder.yml`).

```bash
tests/run-tests.sh                      # níveis unit, cli e module (rápidos, sem rede)
tests/run-tests.sh --level unit         # só um nível (ou vários: --level unit,cli; ou --level all)
tests/run-tests.sh -- --filter format_tsv   # opções passadas ao bats (aqui: só os testes com "format_tsv" no nome)
tests/run-tests.sh --update-expected    # reescreve tests/expected/ com os resultados atuais (revisar com git diff)
```

## Níveis

| Nível | Pasta | O que testa | Dados | Quando roda |
|---|---|---|---|---|
| unit | `unit/` | funções do `lib/common.sh` (regra de NULL, `format_tsv`, `add_metadata_columns`, caches, caminhos dos bancos) | tabelas mínimas escritas no próprio teste | sempre (segundos) |
| cli | `cli/` | linha de comando do `main-prokfinder.sh` (ajuda, erros, AND/OR, recursos), `run-on-cluster --dry-run`, sintaxe, shellcheck, cabeçalhos dos módulos, `catalog.json` | nenhum | sempre |
| module | `module/` | cada módulo sobre a fixture de `data/` (recortes das tabelas de referência, poucos genomas, programas falsos em `bin/`) | `data/` | sempre (sem rede) |
| e2e | `e2e/` | execuções reais: `setup` das fontes, `download-wf` com CheckM2, BUSCO, GTDB-Tk | bancos reais, rede | só quando pedido (`--level e2e`), no cluster |

No GitHub, `.github/workflows/tests.yml` roda `tests/run-tests.sh` a cada push (`main`, `restructure-pipeline`,
`docker`) e pull request; o resultado aparece como ✓/✗ em cada commit (aba Actions).

Os níveis unit, cli e module nunca usam a rede nem os bancos de referência reais: cada teste roda numa pasta
temporária própria, com `HOME` apontando para dentro dela.

## Estrutura

```
run-tests.sh          ponto de entrada
helpers/common.bash   carregado por todo teste: pasta temporária, pf_eval (código com lib/common.sh carregado),
                      make_refdb_markers, asserções (assert_success, assert_output_contains...) e
                      assert_expected_tsv (comparação com tests/expected/)
unit/  cli/  module/  e2e/
data/refdb/           mini-banco de referência (mesma estrutura do ~/prokfinder-refdb): só as linhas dos genomas da
                      fixture, copiadas das tabelas reais
data/refdb-raw/       os arquivos brutos das mesmas linhas (relatórios do NCBI, taxdump reduzido, cepas do BacDive,
                      .tsv.gz do GTDB), dos quais o setup refaz as tabelas
data/FIXTURE.txt      de onde e quando a fixture foi copiada
data/make-fixture.sh  gera data/refdb e data/refdb-raw a partir de um banco completo (no cluster, num job PBS)
bin/                  programas falsos (datasets, checkm2, busco, gtdbtk, skder, cidder) - fase 3
expected/             resultados esperados das tabelas (normalizados: linhas ordenadas, colunas variáveis removidas)
```

## A fixture (tests/data)

Genomas: todas as montagens dos gêneros Thermus e Pyrococcus (GTDB e NCBI), o GCA_964347835.1 (arqueia de espécie
sem nome no GTDB, `s__CAYFZR01 sp964347835`, sem dados no BacDive) e três controles: *Deinococcus radiodurans* R1
(mesófilo do filo de Thermus), *Thermotoga maritima* MSB8 e *Methanocaldococcus jannaschii* DSM 2661 (termófilos fora
de Thermus/Pyrococcus). Espécies com muitas cepas no BacDive (como *E. coli*) são evitadas: para refazer a linha de
uma espécie, todas as suas cepas precisam estar na fixture.

O nível module confere que a busca na fixture dá os mesmos números do banco completo (166 Thermus; 142 com
`--temp-growth 45:`) e que o `setup` refaz, a partir de `refdb-raw`, tabelas idênticas às de `refdb`.

Refazer a fixture (depois de mudar o formato de um banco, `PF_REFDB_FORMAT_*`): no cluster, rodar
`tests/data/make-fixture.sh --refdb ~/prokfinder-refdb -o <pasta>` num job PBS (lê ~20 GB; leva de minutos a ~1 h),
copiar `refdb`, `refdb-raw`, `FIXTURE.txt` e `fixture-accession-numbers.txt` para `tests/data/`, depois
`tests/run-tests.sh --update-expected` e revisar o `git diff`.

## Escrever um teste

```bash
@test "o que o teste confere" {
    run bash "${PF_MAIN}" search-genomes -T 45:80 -O rod     # $status e $output (stdout + stderr)
    assert_failure 1
    assert_output_contains "AND or OR is missing"
}
```

- Uma função do `common.sh`: `run pf_eval 'format_tsv 1 < in.tsv'` (roda num `bash` filho, porque o `common.sh`
  instala um `trap EXIT`, que substituiria o do bats).
- Uma tabela gerada pelo Prokfinder: `assert_expected_tsv search/thermus.tsv <tabela> [colunas a ignorar]`; na
  primeira vez, ou quando a saída muda de propósito, `tests/run-tests.sh --update-expected` e revisar o `git diff`.
- Um problema conhecido ainda não corrigido: `skip "known bug: ..."` no início do teste, para ele aparecer no
  relatório sem quebrar a execução.
