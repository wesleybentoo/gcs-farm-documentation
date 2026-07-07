# SQL — GCS Connection Farm

SQL canônico dos bancos `CONNECTOR_GCS_FARM` (raw) e `GCS_FARM` (master). **Em sync com o banco vivo (0 drift — reconferido 03/07 rodando o `SETUP_FULL.sql` num banco novo `*_TEST`: mesmas contagens e mesmos nomes 1:1).** Atual (03/07): **154 tabelas** (47 CONNECTOR + 107 GCS_FARM), **23 views** (6 CONNECTOR + 17 GCS_FARM), 1 procedure.

> **Fase B (05/07): espelho tipado `FARMBOX_*` eliminado do `GCS_FARM`.** As 29 tabelas `FARMBOX_*` + 4 views `VW_FARMBOX_*` foram dropadas do master. O `CONNECTOR_GCS_FARM` (landing) permanece recebendo o JSON cru da API Farmbox (tabelas `FARMBOX_*` com coluna `record` JSON). O ETL agora lê o JSON cru **direto do CONNECTOR** (`JSON_VALUE`/`OPENJSON` sobre `record`) e grava **direto no domínio nativo `FARM_*`** — não há mais passo de espelho tipado dentro do `GCS_FARM`. As contagens acima (03/07) ainda refletem o estado pré-Fase B; revalidar após o próximo `SETUP_FULL.sql`.

## Arquivos
| Arquivo | O que é |
|---|---|
| `SETUP_FULL.sql` | **Núcleo canônico.** Build dos dois bancos (CONNECTOR → GCS_FARM): núcleo + FARM_* base + FERT_* + OPS_* + VRA. Re-executável. |
| `RESET_FULL.sql` | Dropa `CONNECTOR_GCS_FARM` e `GCS_FARM` inteiros (só local/teste; em produção, **nunca**). |
| `MODULE_AGRO_V1.sql` | **Módulo agronômico nativo** (FARM_* produtos/bulário/aplicações/monitoramento/pragas/contagem/estimativa). Roda **depois** do SETUP_FULL. |
| `FLIGHT_LOG.sql` | **Aplicação Aérea** (FLIGHT_LOG*). Roda depois do MODULE_AGRO (FK → FARM_APPLICATION). |
| `MODULE_MONITOR_V1.sql` | **Monitoramentos — config que comanda o app** (MONITOR_TOLERANCE/METHODOLOGY/FIXED_POINT/REQUEST + estende FARM_MONITORING + `VW_MONITOR_FIELD_STATUS`). Roda depois do MODULE_AGRO; idempotente; faz seed da tolerância do Farmbox (farm 2112) e da metodologia global. |
| `FERT_EXPORT_PROFILES.sql` / `FERT_CROP_EXPORT_SCOPE.sql` | Perfis/escopo de exportação de fertilidade. |
| `MATERIALIZE_FARM.sql` / `DROP_FARMBOX_MIRROR.sql` | Materialização FARM_* a partir do JSON cru / drop do espelho Farmbox (Fase B). |

> **Ordem de execução:** `SETUP_FULL` → `MODULE_AGRO_V1` → (`FLIGHT_LOG`, `MODULE_MONITOR_V1`, `FERT_*`). A DDL COMPLETA do domínio é a soma desses (módulos com FK para FARM_APPLICATION não cabem no SETUP_FULL). Ver `../AUDITORIA_2026-07-07.md`.

> **Fonte única:** o `SETUP_FULL.sql` é o **único** SQL de schema. Os recortes por módulo (`modulos/`) e as cópias legadas em `Arquivos Suporte/` foram **removidos (03/07)** — não há mais duplicata que possa dar drift.

## Como usar
- **Build do zero (dev/teste):** `RESET_FULL.sql` → `SETUP_FULL.sql`.
- **Produção (1ª vez):** rodar só o `SETUP_FULL.sql` (não dropa nada; cria o que falta).
- **Evolução / novo módulo:** edite **direto o `SETUP_FULL.sql`** (canônico) e aplique no banco. Sem recortes por módulo — tudo vive num arquivo só.

## Regra de ouro
**O `SETUP_FULL.sql` é a única fonte da verdade e tem que casar 1:1 com o banco.** Nada de objeto criado "só no banco" sem refletir aqui, e nenhuma cópia paralela do SQL. Ver também `../04_Guia_Arquitetura_e_Novos_Modulos.md`.

> Núcleo compartilhado (não é "módulo", vive no SETUP_FULL): CONFIG (inclui `CONFIG_SCHEDULER` + `CONFIG_SCHEDULER_LOG` — agendador central), MANAGEMENT (inclui `MANAGEMENT_USER_PREFERENCE`), FARM_* (fazenda/gleba/talhão/geometria + **calendário** `FARM_SEASON`/`_CYCLE`) e VRA.
>
> **Planejamento agrícola, cultivos & produtividade** (tudo no SETUP_FULL): `FARM_VARIETY`/`FARM_VARIETY_TRAIT`/`FARM_VARIETY_TRAIT_VALUE` (variedades + características configuráveis), `FARM_FIELD_PLANTING` (plantio/produtividade real), `FARM_FIELD_ROTATION` + `FARM_PLOT_ROTATION`/`_CROP` (rotação), `FARM_PLANTING_REVIEW` (outliers), `PROD_ESTIMATE_FORMULA` (fórmula da estimativa). Fertilidade ganhou `FERT_CROP_EXPORT`/`FERT_EXPORT_NUTRIENT` (exportação de nutrientes) e `FERT_AMENDMENT_APPLICATION` (corretivos). O amostrador da contagem é lido direto do JSON cru do `CONNECTOR_GCS_FARM` (`..._MONITORING_DAY_RESULT.record.monitors[]`). A DDL desses já está no `SETUP_FULL.sql`; **seeds** de `PROD_ESTIMATE_FORMULA`/`FERT_CROP_EXPORT` são **valores iniciais** (a formula/coeficiente pode ser editada no app e diverge do seed sem ser "drift" de schema).
