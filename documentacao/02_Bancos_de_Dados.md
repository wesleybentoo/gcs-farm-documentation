# GCS Connection Farm — Documentação dos Bancos de Dados

**Data:** 2026-06-28 · **Atualizado:** 2026-07-07 (módulo agronômico nativo `FARM_*`, aplicação aérea `FLIGHT_LOG*`, `FERT_EXPORT_SET`, inventário pós-Fase B) · **SGBD:** SQL Server (uma instância, dois bancos).
DDL completa e comentada: `SQL/SETUP_FULL.sql` (base) **+** `SQL/MODULE_AGRO_V1.sql` (domínio agronômico nativo `FARM_*`) **+** `SQL/FLIGHT_LOG.sql` (aplicação aérea) **+** `SQL/FERT_EXPORT_PROFILES.sql` (perfis de exportação de nutrientes). `SETUP_FULL.sql` **não é mais** fonte única literal das tabelas — o schema vivo é a soma desses scripts.

## Arquitetura em duas camadas
- **`CONNECTOR_GCS_FARM` (raw / landing):** guarda o dado **cru** que cada integração devolveu (JSON original + logs de ingestão). Fonte da verdade do que chegou; não se enriquece.
- **`GCS_FARM` (master / tratado):** dado **normalizado/tipado** + configuração + gestão de acesso + módulos agronômicos. É onde o app lê.
- **Fluxo:** API externa → *ingestão* grava raw no CONNECTOR → *ETL* (set-based, cross-database por nome de 3 partes) transforma raw → master. Ver `03_ETLs.md`.

Inventário (foto do schema **vivo**, pós-Fase B): **CONNECTOR** **47 tabelas / 6 views / 0 proc** (inclui a landing `FARMBOX_*` com JSON cru — permanece). **GCS_FARM** **104 tabelas / 13 views / 1 proc**. Na **Fase B (05/07/2026)** o espelho tipado do Farmbox foi eliminado do master: **DROP de todas as tabelas espelho `FARMBOX_*`** (removidas dinamicamente por `SQL/DROP_FARMBOX_MIRROR.sql` — `FROM sys.tables WHERE name LIKE 'FARMBOX[_]%'`) **+ as 4 views `VW_FARMBOX_*`** (a foto de 03/07 era 107 tabelas / 17 views / 1 proc — as views fecham exatamente: 17 − 4 = 13). No mesmo período entraram tabelas nativas novas (módulo agronômico `FARM_*` em `SQL/MODULE_AGRO_V1.sql` e aplicação aérea `FLIGHT_LOG*` em `SQL/FLIGHT_LOG.sql`); o total de tabelas do master hoje é **104** (número lido do banco vivo, não reconstruído pela conta da transição). *(Crescimento desde 28/06: Painel de Operações (OPS_*), planejamento agrícola, variedades/características, produtividade/estimativa, exportação de nutrientes e corretivos, módulo agronômico nativo `FARM_*` e logs de voo; redução na Fase B: remoção do espelho Farmbox — CONNECTOR→`FARM_*` direto.)*

Convenções gerais: **soft-delete** (`deleted_at`, paranoid); raw com flag **`processed`** (0=pendente) + `processed_at`; segredos **cifrados** em `CONFIG_API` (DMK/cert); geometria em **`geography`** (SRID 4326); timestamps em UTC.

---

## CONNECTOR_GCS_FARM (raw)

### Solinftec (9 tabelas + 2 views)
- `SOLINFTEC_RESPONSE` — 1 linha por página de resposta da API (body JSON + totais).
- `SOLINFTEC_WEATHER` — 1 registro meteorológico cru (dedup por `equipment_code + local_datetime`).
- `SOLINFTEC_OPERATION` — 1 registro de operação de máquina cru (dedup por `record_id`).
- `SOLINFTEC_INGESTION_LOG` — execuções de ingestão; UNIQUE `(api_identifier, reference_date)` (reabre o dia incrementando `attempt`).
- `SOLINFTEC_INTEGRATION_ERROR` — erros por stage (AUTH/PULL/PARSE/PERSIST).
- `SOLINFTEC_CAD_CATALOG` / `SOLINFTEC_CAD_ENTRY` / `SOLINFTEC_CAD_IMPORT` / `SOLINFTEC_CAD_IMPORT_ERROR` — cadastros (dimensões) importados por planilha; `CAD_ENTRY` guarda o payload por linha (ex.: `WEATHER_STATION_GEO` com lat/long).
- Views: `SOLINFTEC_CAD_LOOKUP` (de/para code→descrição), `SOLINFTEC_PENDING_DAYS` (dias pendentes de ETL).

### IrriControl (5 tabelas + 2 views) — *ingestão/ETL ainda não implementados (API 403/502)*
- `IRRICONTROL_PIVOT_SNAPSHOT` / `_PIVOT_HISTORY` / `_PIVOT_OPERATION` — leituras de pivôs (raw, previstas).
- `IRRICONTROL_INGESTION_LOG` / `_INTEGRATION_ERROR`.
- Views: `IRRICONTROL_PENDING_QUEUE`, `IRRICONTROL_STALE_INGESTIONS`.
- O endpoint `GET /irrigation/overview` (stub com contrato final) **não cria tabelas novas**: lê os talhões das fazendas a partir de `FARM_FIELDS`+`FARM_PLOTS` (+ contorno via `FARM_FIELD_GEOMETRY`/`geometry.service`) e devolve `status`/`appliedMm`/`pct` = null e `availableDates` = []. A query real sobre `IRRICONTROL_*` (normalização raw→master + período/hora) segue **pendente**.

### Farmbox (raw, 33 tabelas + 2 views)
Cada tabela guarda o JSON cru (coluna `record`) + chave natural (`farmbox_id`/`record_id`). Lista **exaustiva** (schema vivo):
- **Transacionais:** `FARMBOX_APPLICATION`, `FARMBOX_APPLICATION_PROGRESS`, `FARMBOX_MONITORING`, `FARMBOX_MONITORING_DAY_RESULT`, `FARMBOX_MONITORING_NOTE`, `FARMBOX_MONITORING_TOLERANCE`, `FARMBOX_PLANTATION`, `FARMBOX_MOVIMENTATION`, `FARMBOX_COUNT_DAY`, `FARMBOX_COUNT_MONITORING`, `FARMBOX_TRAP_MONITORING`, `FARMBOX_PLUVIOMETER`, `FARMBOX_PLUVIOMETER_MONITORING`, `FARMBOX_HARVEST`, `FARMBOX_BATCH`, `FARMBOX_STORAGE`, `FARMBOX_NOTE`, `FARMBOX_PHENOLOGICAL_STAGE_SAMPLE`, `FARMBOX_INPUT`, `FARMBOX_INPUT_VALUE`.
- **Estrutura/dimensões espelhadas:** `FARMBOX_FARM`, `FARMBOX_PLOT`.
- **Referências FULL (`FARMBOX_REF_*`):** `FARMBOX_REF_CULTURE`, `FARMBOX_REF_VARIETY`, `FARMBOX_REF_EQUIPMENT`, `FARMBOX_REF_USER`, `FARMBOX_REF_INPUT_TYPE`, `FARMBOX_REF_ACTIVITY_TYPE`, `FARMBOX_REF_PHENOLOGICAL_STAGE`, `FARMBOX_REF_BEAK`.
- **Ingestão/controle:** `FARMBOX_INGESTION_LOG`, `FARMBOX_INTEGRATION_ERROR`, `FARMBOX_RESOURCE_SUBSCRIPTION` (webhook).
- Views: `FARMBOX_PENDING_PROCESSING`, `FARMBOX_STALE_INGESTIONS`.

> Observação: as tabelas `CONFIG_*` (`CONFIG_API`, `CONFIG_CONNECTORS`, `CONFIG_SCHEDULER`, `CONFIG_SCHEDULER_LOG`) existem **apenas no GCS_FARM** (não há `CONFIG_*` no CONNECTOR); o conector, quando precisa, lê a CONFIG por nome de 3 partes (`GCS_FARM.dbo.CONFIG_*`).

---

## GCS_FARM (master)

### Config & Conectores (CONFIG_*)
- `CONFIG_API` — credenciais/URLs por API; segredos cifrados (auth NONE/BASIC/TOKEN/APIKEY/OAUTH2).
- `CONFIG_CONNECTORS` — de/para conector→entidade (ex.: farmbox `plot_id`→talhão GCS).
- `CONFIG_SCHEDULER` — registro de **jobs** do agendador central das integrações: `connector`+`job_key` (UNIQUE), `label`, `cadence_type` (`interval`/`daily`/`weekly`/`cron`/`realtime`/`manual`)+`cadence_value`, `enabled`, e estado da última execução (`last_run_at`/`last_status`/`last_rows`/`last_duration_ms`/`last_message`/`next_run_at`). Soft-delete (`deleted_at`).
- `CONFIG_SCHEDULER_LOG` — **histórico** por execução (FK `job_id` → `CONFIG_SCHEDULER`): `started_at`/`finished_at`, `status`, `rows_loaded`, `duration_ms`, `trigger_by` (manual/ticker), `message`. Ver `03_ETLs.md`.

### Gestão de acesso (MANAGEMENT_*, 11 tabelas + 1 view)
- `MANAGEMENT_USERS` (← `MANAGEMENT_PEOPLES`, `MANAGEMENT_TYPE_USERS`, `MANAGEMENT_SECTORS`) — usuários/pessoas/perfis/setores.
- `MANAGEMENT_MODULES` / `MANAGEMENT_PAGES` — catálogo de telas.
- `MANAGEMENT_ACCESS` (permissões por perfil×página: read/write/delete/admin), `MANAGEMENT_USER_ACCESS_OVERRIDE` (exceções por usuário), `MANAGEMENT_USER_FARM` (escopo de fazendas), `MANAGEMENT_ACCESS_LOG` (login).
- `MANAGEMENT_USER_PREFERENCE` — preferências de UI por usuário (1 linha por usuário; PK = `user_id`). `preferences` em **JSON livre** (tema claro/escuro + fazenda selecionada; check `ISJSON`). Lido/gravado por `GET`/`PUT /me/preferences` (merge parcial via `MERGE`), sem model Sequelize (query crua).
- View `MANAGEMENT_EFFECTIVE_ACCESS` — permissão efetiva (perfil + overrides).

### Estrutura da fazenda (FARM_*)
- `FARM_FARMS` → `FARM_PLOTS` (glebas) → `FARM_FIELDS` (talhões). Área da fazenda = soma das glebas.
- `FARM_FIELD_GEOMETRY` — contorno (polígono `geography`) **versionado** (`version`, `is_current`), área em ha; base de todos os mapas/grids.
- `FARM_CULTURE` (tem `productivity_unit` — sc/@/t — e `color_hex`), `FARM_SEASON`, `FARM_SEASON_CYCLE` (calendário agrícola: safra × ciclo × cultura); view `VW_FARM_SEASON_CYCLE`.

### Planejamento agrícola, cultivos & produtividade (FARM_*, PROD_*)
Materializados a partir do Farmbox (backfill em `seasons.service.ts`, ver `03_ETLs.md`) e editáveis no app.
- `FARM_VARIETY` — variedades/híbridos por cultura (`culture_id`, `name`, `kind` ∈ `cultivar`/`hibrido`/`linhagem` (CHECK), `farmbox_variety_id`). Catálogo de **características configurável**: `FARM_VARIETY_TRAIT` (traço por cultura — ex.: Peso de Capulho, Peso de Mil Grãos, Tecnologia; com `override_pid` opcional que liga o traço a um `count_parameter` da estimativa) → `FARM_VARIETY_TRAIT_VALUE` (valor do traço por variedade).
- `FARM_FIELD_PLANTING` — **plantio** = 1 por (`season_cycle_id`, `field_id`) (índice único), com `variety_id`, `area_ha`, datas (plantio/emergência/colheita), `productivity` (rendimento real na unidade da cultura), `status`, `source` (`FARMBOX`), `farmbox_plantation_id`. É o **elo** entre a contagem/estimativa e o talhão/safra/variedade, e a fonte do @/ha real (Produtividade/Evolução/Estimativa).
- `FARM_FIELD_ROTATION` — programação de rotação **por pivô/safra** (override do plano de gleba; `source` FARMBOX/MANUAL).
- `FARM_PLOT_ROTATION` (+ `FARM_PLOT_ROTATION_CROP`) — programação de rotação por gleba (janela ano inicial→final, culturas por ano).
- `FARM_PLANTING_REVIEW` — revisão de produtividade fora da curva (outliers acima/abaixo da mediana da cultura; correção auditável).
- `PROD_ESTIMATE_FORMULA` — **fórmula de estimativa por cultura** (1 por `culture_id`+`count_group`, índice único `UX_PROD_EST_FORMULA`): `formula` (expressão sobre os `pID` = `count_parameter.id` da contagem Farmbox), `output_unit`, `correction_factor`, `min_valid`/`max_valid`, `require_all_params`, `active`. Avaliada **ao vivo** pelo `estimate.service.ts` (sem tabela de resultado).
- Views deste domínio: `VW_FARM_FIELD_PLANTING` (plantio achatado), `VW_FARM_PLOT_ROTATION` (rotação por gleba achatada) e `VW_FARM_ROTATION_DEVIATION` (desvio plano×realizado por gleba/pivô — base do "pivô que escapou").

### Painel de Operações (OPS_*, 11 tabelas)
Programações de operação a campo (abertura de área, expansão, tratos), full-stack (`ops.routes.ts`/`ops.service.ts`; front `pages/painel-operacoes/*`). Hierarquia **Programa → Etapa → Subetapa → lançamento**:
- `OPS_PROGRAM` — programa (`kind` ∈ `agricola`/`estrutura`/`manutencao`; agrícola exige `season_id`+`culture_id`, CHECK `CK_OPS_PROGRAM_agri`), `visibility`, `color`, `deadline`. `OPS_PROGRAM_MEMBER` (responsáveis — `display_name`, `user_id` opcional), `OPS_PROGRAM_FIELD` (pivôs-alvo do programa → `FARM_FIELDS`).
- `OPS_TASK` — etapa (frota, meta, prazo, equipe); alvo por pivô em `OPS_TASK_TARGET` (`field_id`) OU feição KML. `OPS_SUBTASK` — subetapa (equipe própria, `source` manual/solinftec/irricontrol/farmbox, `measure` ha/mm/dose/marco/percent, meta/unidade). `OPS_SUBTASK_ENTRY` — **lançamento/ledger** (data, quantidade, `field_id` opcional → avanço por pivô; idempotência `UX_OPS_ENTRY_src`).
- `OPS_TEAM` — equipes (GCS/terceirizada). `OPS_GEOMETRY_LAYER` (+ `OPS_GEOMETRY_FEATURE`) — camadas KML importadas (geom `geography` 4326, spatial index; parser futuro). `OPS_FILE` — arquivos anexos.
- Progresso é **derivado** (não armazenado): entry→subetapa→etapa (média ponderada)→programa. Mapa centrado no pivô (hover lista as operações do pivô; clique = histórico + lançar avanço por pivô), card por gleba, filtro por operação. `OPS_TASK`/`OPS_SUBTASK` têm `updated_at` (para PUT).

### Operação de máquinas (MACHINE_OPERATION_*, 5 tabelas + 1 view)
- `MACHINE_OPERATION_FACT` — fato (1 por registro raw); FKs para as dims e `field_id` (casado por `CD_TALHAO`=`FARM_FIELDS.code`).
- Dims: `_EQUIPMENT`, `_OPERATOR`, `_OPERATION`, `_STOP_REASON` (enriquecidas pelos cadastros Solinftec).
- View `MACHINE_OPERATION_SUMMARY`.

### Clima (WEATHER_* + FIELD_WEATHER_*, 4 tabelas)
- `WEATHER_STATION` — sensor como **ponto puro** (code, lat/long, `geom`, tipo). **Sem** field_id/farm_id (legado removido em 28/06): não há vínculo estação→talhão; o clima por talhão vem do grid IDW.
- `WEATHER_READING` — leitura horária por estação (1 por raw; 24 métricas: 10 base + 7 min + 7 max).
- `FIELD_WEATHER_HOURLY` — **grid de clima por talhão × dia × hora** (IDW), todas as métricas. Fonte da verdade dos KPIs/mapa de calor.
- `FIELD_WEATHER_COVERAGE` — confiança por talhão×métrica (distância ao sensor mais próximo). Ver `SOLINFTEC_CLIMA_Grid_v1.md`.

### Fertilidade (FERT_*, 21 tabelas + 5 views + 1 proc)
- Catálogo: `FERT_LAB`, `FERT_PARAMETER`, `FERT_INTERPRETATION_SET` (visões PADRÃO/CERRADO/MACRO_FOCO), `FERT_INTERPRETATION` (faixas/classes, com contexto de argila), `FERT_SET_PARAMETER`.
- Amostras: `FERT_SAMPLE` → `FERT_SAMPLE_POINT` → `FERT_POINT_DEPTH` → `FERT_RESULT` (valor por parâmetro/profundidade).
- Importação: `FERT_IMPORT` / `FERT_IMPORT_ERROR`.
- Planejamento: `FERT_SAMPLE_PLAN` (+ `analysis_type`), `FERT_DEPTH_PROFILE` / `_ITEM`.
- Cálculo (corretivos — modelo genérico): `FERT_CALC_MODEL` / `_INPUT` / `_RESULT` *(estrutura pronta, motor genérico pendente)*.
- **Exportação de nutrientes:** `FERT_EXPORT_SET` — **perfil** de coeficientes pesquisado (ex.: ICL, Embrapa, Fundação MT; espelha `FERT_INTERPRETATION_SET`, com `is_default` e agrônomo/fonte); `FERT_CROP_EXPORT` — coeficientes de exportação por perfil×cultura×nutriente (`set_id`→`FERT_EXPORT_SET`; kg/t exportado; base ICL/Embrapa, editável na tela Configurações); `FERT_EXPORT_NUTRIENT` — catálogo de nutrientes. A tela **Exportação de Nutrientes** cruza a produtividade real (`FARM_FIELD_PLANTING`) × coeficiente do perfil para estimar a extração por talhão/cultura.
- **Adubação de corretivos:** `FERT_AMENDMENT_APPLICATION` — recomendação/dose de corretivos (Calcário/Gesso/Fosfato) por talhão.
- Views `VW_FERT_RESULT_CLASSIFIED`, `VW_FERT_SAMPLE_LATEST`, `VW_FERT_SAMPLE_WIDE`, `VW_FERT_POINT_STATUS`, `VW_FERT_CROP_EXPORT` (apoia a tela de Exportação de Nutrientes); proc **`usp_fert_resolve_field_geo`** (resolve ponto→talhão por geo).

### VRA — Taxa Variável (VRA_*, 7 tabelas + 2 views) — *schema pronto, API pendente*
- `VRA_ZONE_SET` / `VRA_ZONE` (zonas), `VRA_PRESCRIPTION` / `_DOSE` / `_PRODUCT` (prescrições), `VRA_MAP_TYPE`, `VRA_EXPORT_FORMAT`; views `VW_VRA_ZONE_CURRENT`, `VW_VRA_PRESCRIPTION_MAP`.

### Farmbox no master — sem espelho (removido na Fase B, 05/07/2026)
> **Estado ATUAL:** **não há mais espelho tipado `FARMBOX_*` dentro do `GCS_FARM`.** Na Fase B, **todas as tabelas espelho `FARMBOX_*`** (DROP dinâmico sobre `sys.tables WHERE name LIKE 'FARMBOX[_]%'`) **+ as 4 views `VW_FARMBOX_*`** foram **DROPADAS** (ver `SQL/DROP_FARMBOX_MIRROR.sql`). O dado cru do Farmbox continua na landing `CONNECTOR_GCS_FARM` (tabelas `FARMBOX_*` com coluna `record` = JSON, ver seção do CONNECTOR acima) e o ETL agora lê esse JSON **direto** (`JSON_VALUE`/`OPENJSON` sobre `record`) e grava **direto** no domínio nativo `FARM_*` do `GCS_FARM` (ver `SQL/MATERIALIZE_FARM.sql` e `03_ETLs.md`). Não existe mais camada intermediária tipada.
- **Resolução de ids** (raw → domínio): `field_id` via `CONFIG_CONNECTORS(type='farmbox', code=record.plot.id).field_id`; pontes `FARM_CULTURE.farmbox_culture_id`, `FARM_VARIETY.farmbox_variety_id`, `FARM_FIELD_PLANTING.farmbox_plantation_id`, `FARM_PRODUCT.farmbox_input_id`.
- **Contagem de campo** (base da **estimativa de produtividade**): a extinta `FARMBOX_COUNT_MONITORING` foi substituída por `FARM_COUNT` (materializada do CONNECTOR); os `parameters` (JSON `{count_parameter:{id,name}, value}`) continuam sendo os `pID` das fórmulas de `PROD_ESTIMATE_FORMULA`, avaliadas ao vivo pelo `estimate.service.ts`.
- **Amostrador** (ponte contagem→monitor): não vem mais de `FARMBOX_MONITORING_DAY_MONITOR`, e sim do JSON cru `CONNECTOR..._MONITORING_DAY_RESULT.record.monitors[]` (`monitor_id`/`monitor_name` por `plantation_id`+`result_date`); a contagem não grava usuário, então a estimativa atribui o amostrador por mesmo-dia (alta confiança) ou ±7 dias (aprox.).
- **Safras não mapeadas:** a antiga view `VW_FARMBOX_HARVEST_UNMAPPED` deixou de existir; as safras do Farmbox ainda sem `FARM_SEASON` são detectadas direto do CONNECTOR (`seasons.service.ts`, ver `03_ETLs.md`).
- Módulo agronômico nativo que sucede o Farmbox: ver a seção **Módulo Agronômico nativo** abaixo (DDL em `SQL/MODULE_AGRO_V1.sql`).

### Módulo Agronômico nativo (FARM_*, 22 tabelas) — sucede o Farmbox
Domínio próprio que substitui o espelho `FARMBOX_*` (DDL em `SQL/MODULE_AGRO_V1.sql`). Cada tabela tem `source` (`farmbox`/`app`) e ponte `farmbox_*_id` para backfill idempotente; reusa Safra/Ciclo/Cultura/Variedade/Talhão/Equipamento já existentes. Convenção: `id BIGINT IDENTITY`, soft-delete, `created/updated_at`.
- **Catálogo de alvos:** `FARM_PEST` — pragas/doenças/daninhas/inimigos naturais (base de bulário e monitoramento). `FARM_PEST_THRESHOLD` — nível de ação (índice de controle) por cultura×praga.
- **Produtos:** `FARM_PRODUCT_CATEGORY` — categorias (herbicida/fungicida/fertilizante…). `FARM_PRODUCT` — produto comercial (dose/formulação/registro MAPA; ponte `farmbox_input_id`). `FARM_PRODUCT_TEST` — produto experimental/ensaio; `FARM_PRODUCT_TRIAL` — ensaios de dose/método/gota do produto de teste (performance herdada pelo comercial via `test_product_id`). `FARM_ACTIVE_INGREDIENT` — catálogo próprio de princípios ativos; `FARM_PRODUCT_INGREDIENT` — N:N produto↔princípio ativo (+concentração). `FARM_PRODUCT_REF` — referência a cadastros externos de produto (DBA/ERP). `FARM_PRODUCT_LABEL` — **bulário** (dose min/max, calda, gota, carência/reentrada por produto×cultura×praga×modo de equipamento; base da recomendação automática).
- **Aplicações:** `FARM_ART` — Anotação de Responsabilidade Técnica (agrônomo/CREA/validade). `FARM_APPLICATION` — aplicação (data/equipamento/modo terrestre|aéreo|ferti/ART; ponte `farmbox_application_id`). `FARM_APPLICATION_INPUT` — produto + dose por aplicação. `FARM_APPLICATION_TARGET` — onde foi aplicada (talhão/plantio + área pretendida/aplicada, contexto cultura/variedade/safra desnormalizado).
- **Monitoramento:** `FARM_MONITORING` — monitoramento por talhão/plantio (metodologia/estágio/amostrador; ponte `farmbox_monitoring_id`). `FARM_MONITORING_POINT` — pontos/paradas com coordenada. `FARM_MONITORING_FINDING` — o índice medido (infestação por alvo). `FARM_MONITORING_DAY_MONITOR` — amostrador (quem monitorou) por `plantation_id`+dia (elo com a contagem).
- **Contagem & estimativa:** `FARM_COUNT` — contagem em campo (base da estimativa; `parameters` JSON com os pIDs medidos). `FARM_COUNT_PARAM` — parâmetros medidos na contagem (pID normalizado). `FARM_ESTIMATE` — estimativa calculada (snapshot por contagem; `formula_id`→`PROD_ESTIMATE_FORMULA`).
- **Produtividade (colheita):** `FARM_HARVEST_YIELD` — registro detalhado de colheita por plantio (área/quantidade/produtividade/umidade; o rollup fica em `FARM_FIELD_PLANTING.productivity`).

### Aplicação Aérea — Logs de Voo (FLIGHT_LOG*, 3 tabelas)
Log do Air Tractor (AS4.01/ATT) decodificado no backend (DDL em `SQL/FLIGHT_LOG.sql`). Geometria em `geography` SRID 4326 (padrão da casa).
- `FLIGHT_LOG` — o **voo**: .log cru (`raw_data VARBINARY`), pontos decodificados (`points_blob`), trilha (`track_geom` MULTILINESTRING) e cobertura aplicada (`applied_geom` MULTIPOLYGON = buffer da trilha com barra aberta), + métricas agregadas (distância/área/velocidade/vazão/taxa) e cadastro do voo (datas, `equipment_id`→`MACHINE_OPERATION_EQUIPMENT`, `pilot_person_id`→`MANAGEMENT_PEOPLES`). Dedup por `file_hash`.
- `FLIGHT_LOG_APP` — **split**: 1 linha por AP do Farmbox presente no log (`application_id`→`FARM_APPLICATION`; `is_external` p/ cobertura fora de talhão); `coverage_geom` = recorte da cobertura nos talhões daquela AP + área/volume/taxa.
- `FLIGHT_LOG_APP_FIELD` — por talhão dentro da AP (`field_id`→`FARM_FIELDS`; área aplicada × pretendida, `pct_exec`).

---

## Relacionamentos-chave
- `FARM_FARMS` 1—N `FARM_PLOTS` 1—N `FARM_FIELDS` 1—1(vigente) `FARM_FIELD_GEOMETRY`.
- `FARM_FIELDS` é o eixo central: referenciado por `MACHINE_OPERATION_FACT.field_id`, `FIELD_WEATHER_HOURLY.field_id`, `FIELD_WEATHER_COVERAGE.field_id`, fertilidade e VRA.
- `MACHINE_OPERATION_FACT` → dims por `code`; raw `SOLINFTEC_OPERATION.id` ← `raw_record_id`.
- `WEATHER_READING.station_id` → `WEATHER_STATION`; `WEATHER_READING.raw_record_id` ← `SOLINFTEC_WEATHER.id`.
- Acesso: `MANAGEMENT_USERS` → perfil/setor; permissões via `MANAGEMENT_ACCESS` + overrides; escopo via `MANAGEMENT_USER_FARM`.
- **Planejamento/produtividade:** `FARM_FIELD_PLANTING` (`season_cycle_id`→`FARM_SEASON_CYCLE`→`FARM_SEASON`/`FARM_CULTURE`; `field_id`→`FARM_FIELDS`; `variety_id`→`FARM_VARIETY`) casa com o Farmbox por `farmbox_plantation_id` ⇔ contagem materializada em `FARM_COUNT.plantation_id` (pós-Fase B; antes vinha do extinto `FARMBOX_COUNT_MONITORING`). A **estimativa** avalia a fórmula por ponto de contagem e valida contra `FARM_FIELD_PLANTING.productivity`; sem o plantio materializado, a contagem fica invisível (JOIN interno) — ver backfill em `03_ETLs.md`.

Para colunas, tipos, PKs, FKs, índices e checks exatos, consultar os scripts de DDL desta pasta: `SQL/SETUP_FULL.sql` (base) + `SQL/MODULE_AGRO_V1.sql` (agronômico `FARM_*`) + `SQL/FLIGHT_LOG.sql` (aplicação aérea) + `SQL/FERT_EXPORT_PROFILES.sql` (perfis de exportação).
