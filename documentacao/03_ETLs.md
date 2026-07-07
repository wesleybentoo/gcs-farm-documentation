# GCS Connection Farm — Documentação dos ETLs

**Data:** 2026-07-07 (rev. Fase B + Aplicação Aérea) · **Back:** `gcs-backend` (Node/Express/TS/Sequelize, SQL Server).

> **Fase B (05/07/2026):** o espelho tipado `FARMBOX_*` dentro do `GCS_FARM` foi **eliminado** (29 tabelas + 4 views `VW_FARMBOX_*` dropadas). O ETL Farmbox agora lê o JSON cru direto do `CONNECTOR_GCS_FARM` e grava direto no domínio nativo `FARM_*`. Scripts canônicos: `MATERIALIZE_FARM.sql`, `DROP_FARMBOX_MIRROR.sql`, `MODULE_AGRO_V1.sql`. Detalhes na seção 2.

Cobre os pipelines de **ingestão** (API externa → raw no `CONNECTOR_GCS_FARM`) e **ETL** (raw → master `GCS_FARM`), além do **agendador** que os orquestra.

## Base
- Duas conexões Sequelize (`src/config/database.ts`), mesma instância: `connectorDb`→CONNECTOR, `masterDb`→GCS_FARM. **`requestTimeout: 120 s`** (default tedious é 15 s, que estourava em lotes grandes).
- ETLs rodam **set-based e cross-database** na conexão `masterDb`, referenciando o raw por nome de **3 partes** (`CONNECTOR_GCS_FARM.dbo.*`). Só DML — não criam objetos.
- **Bootstrap** (`server.ts`): valida conexões → `seedSystem()` (idempotente) → `app.listen` → `startScheduler()`.
- **Idempotência padrão:** fatos via `NOT EXISTS (raw_record_id)`; dims via `MERGE ... ON code`; raw marcado `processed=1` ao fim.
- **Escopo:** com `reference_date` (`YYYY-MM-DD`) processa o(s) dia(s) daquela data (via INGESTION_LOG; re-rodar é seguro); **sem** `reference_date`, processa tudo pendente (`processed=0`).

---

## 1. SOLINFTEC

### 1a. Ingestão (API → raw) — `solinftec.service.ts`
- **Auth:** `POST {url}/auth/token` (credenciais da `CONFIG_API`, decifradas). Token expira em ~1 min → cacheado e **re-encadeado por página** (`data.token`); re-autentica 1× em falha.
- **Pull paginado** (`POST {url}/pull`, header `X-Auth-Token`, `size=10000`): `identifier 21=WEATHER`, `22=OPERATION`. Weather filtra por `data=DD/MM/YYYY`; operation exige **todos** os parâmetros (senão a API retorna 500). Datas em **America/Sao_Paulo** (D-1 via `brYesterdayIso`).
- **Destino raw:** `SOLINFTEC_RESPONSE` (página), `SOLINFTEC_WEATHER` / `SOLINFTEC_OPERATION` (1 por registro, com dedup). Log em `SOLINFTEC_INGESTION_LOG` (UNIQUE por dia, reabre incrementando `attempt`); erros em `SOLINFTEC_INTEGRATION_ERROR`.

### 1b. ETL (raw → master) — `etl.service.ts` → `runEtl(source, referenceDate)`
**`etlWeather`** (`OPENJSON` + `CROSS APPLY`):
1. `MERGE WEATHER_STATION` (dim por `code`=`equipment_code`).
2. `INSERT WEATHER_READING` — 1 por `raw_record_id`, **24 métricas** (10 base + 7 min + 7 max, `TRY_CONVERT`); idempotência por `NOT EXISTS`.
3. Marca raw `processed=1`.
4. `enrichWeatherStationGeo()` — promove lat/long/`geom`/tipo do cadastro `WEATHER_STATION_GEO` para a estação. **O vínculo estação→talhão por interseção espacial foi APOSENTADO** (era a causa de um timeout de 120 s; `STDistance ... ORDER BY` não usava índice espacial). O sensor virou "ponto solteiro".
5. `recomputeFieldWeatherHourly(...)` — recalcula o **grid de clima** numa janela **gap-aware** (dias com leitura ausentes no grid + últimos 3 dias).

**`etlOperation`:**
1. `MERGE` das 4 dims (`MACHINE_OPERATION_EQUIPMENT/_OPERATOR/_OPERATION/_STOP_REASON`).
2. `INSERT MACHINE_OPERATION_FACT` — 1 por `raw_record_id`; `field_id` por `TRY_CAST(FARM_FIELDS.code)=TRY_CAST(CD_TALHAO)`.
3. **Backfill self-healing** — vincula `field_id` de fatos antigos (talhão importado depois).
4. Marca raw `processed=1`.
5. `enrichDimsFromCadastros()` — de/para (`SOLINFTEC_CAD_LOOKUP`) **só nas dims** (escala mesmo com milhões de fatos). Também chamado após `/cadastros/import`.

### 1c. Grid de clima — `weatherGrid.service.ts`
- IDW (`POW=2.4`, idêntico ao front) no **centroide** do talhão; 9 métricas (chuva=SUM; vento máx=MAX; demais=AVG≠0). Grava `FIELD_WEATHER_HOURLY` (`MERGE` em lotes de 500) e `FIELD_WEATHER_COVERAGE` (confiança por métrica). Endpoint `GET /weather/field-weather?grain=day|hour`. Validado: grid == front (maxDiff ≤ 5e-5). Detalhes em `SOLINFTEC_CLIMA_Grid_v1.md`.

### Gatilhos Solinftec
| Etapa | Job (scheduler) | Rota manual | Escopo |
|---|---|---|---|
| Ingestão weather | `solinftec.weather` (daily 05:00) | `/solinftec/integrate[/weather]`, `/pull/weather` | D-1 BR ou `reference_date` |
| Ingestão operation | `solinftec.operation` (daily 05:10) | `/solinftec/integrate[/operation]`, `/pull/operation` | D-1 BR ou `reference_date` |
| ETL raw→master | `solinftec.etl` (daily 05:20) | `/solinftec/etl` | `reference_date` ou `processed=0` |

> Nota (consumo): `GET /operations/by-operation` aceita filtro por **hora-do-dia** (`hours` CSV via `parseHours`); `operationByField` acrescenta `AND DATEPART(HOUR, f.record_start) IN (:hours)` em todas as queries do período, mas **só** quando o conjunto é subconjunto próprio (1..23 horas selecionadas) — aditivo, tela atual inalterada.

---

## 2. FARMBOX

### 2a. Ingestão (API → raw) — `farmbox.service.ts`
- **Auth:** header `Authorization: <token cru>` (sem `Bearer`), cifrado em `CONFIG_API name='FARMBOX'`. Base `https://farmbox.cc/api/v1`. Envelope paginado `{ "<recurso>": [...], pagination, deleted_since }`.
- **Robustez:** `PER_PAGE=30`, `PAGE_TIMEOUT=90s`, concorrência 3, 4 retries com backoff (respeita `Retry-After`; a API responde 500 sob carga). `updated_since/until` em **epoch ms**.
- **Catálogo `ENDPOINTS`** (29): por endpoint, tabela raw, `type` FULL/INCREMENTAL, flags, colunas a promover. Refs (`FARMBOX_REF_*`) são FULL e sem `processed`.
- **Upsert raw** (`MERGE` por chave natural; em MATCH não-ref seta `processed=0` p/ reenfileirar o ETL). `deleted_since` → soft-delete no raw do CONNECTOR (propagado ao `FARM_*` na materialização).
- **Background:** `startFarmboxIngestion` (fire-and-forget, `202`), progresso ao vivo em memória (`/farmbox/progress`), `stop`/`resume`/`restart`. **1 run por vez.**
- **Sync incremental por grupo** (`aplicacoes`, `monitoramentos`, `semanal`, `tudo`): cursor `updated_since` = `MAX(started_at)` da última ingestão OK **por endpoint**.
- **Webhook** (`farmboxWebhook.service.ts`): assina `application` na Farmbox; recebe `created/updated/destroyed` em `POST /webhooks/farmbox` (valida secret). `destroyed`→soft-delete; `created/updated`→`MERGE` no raw com `processed=0`.

### 2b. ETL (raw → master) — `farmboxEtl.service.ts` → `farmMaterialize.service.ts`
- **Arquitetura pós-Fase B (05/07/2026): o espelho tipado `FARMBOX_*` dentro do GCS_FARM foi ELIMINADO** (29 tabelas + 4 views `VW_FARMBOX_*` dropadas via `DROP_FARMBOX_MIRROR.sql`). O ETL agora lê o JSON **cru** direto do `CONNECTOR_GCS_FARM` (tabelas `FARMBOX_*` com coluna `record`, via `JSON_VALUE`/`OPENJSON` sobre `record`) e grava **direto** no domínio nativo `FARM_*` do GCS_FARM. Não há mais passo intermediário de "espelho". *(Nota histórica: até a Fase B existia um espelho tipado `FARMBOX_*` no master; foi removido.)*
- **4 fases** (`farmboxEtl.service.ts` orquestra; `farmMaterialize.service.ts` materializa): **(1)** auto-map plot→talhão em `CONFIG_CONNECTORS`; **(2)** materializar `FARM_*` a partir do CONNECTOR (`MERGE` em lote via `OPENJSON`); **(3)** fertilidade por geo; **(4)** detectar programações. Background, 1 por vez.
- **Gotcha das colunas tipadas:** as colunas tipadas do CONNECTOR são majoritariamente **NULL** — só o `record` (JSON) é confiável; toda extração parte dele.
- Contexto 1×/execução: `connectorId`, `fieldByPlot` (mapeia `plot_id`→talhão GCS), `harvestByName`.
- **Resolução de ids:** `field_id` via `CONFIG_CONNECTORS(type='farmbox', code=record.plot.id).field_id`; pontes `FARM_CULTURE.farmbox_culture_id`, `FARM_VARIETY.farmbox_variety_id`, `FARM_FIELD_PLANTING.farmbox_plantation_id`, `FARM_PRODUCT.farmbox_input_id`. Refs=FULL; demais processam `processed=0` (incremental) no CONNECTOR, com `deleted_at IS NULL`.
- **Mapeamento automático plot→talhão** (`farmboxMapping.service.ts`): na fase (1) de todo ETL completo, `autoMapFarmboxFields()` casa o plot do CONNECTOR→`FARM_FIELDS` por **geometria** (centroide ∈ talhão, `STIntersects`/índice) gravando em `CONFIG_CONNECTORS`, e preenche os `field_id` NULL em cascata (plantation←mapping; monitoring/note←plantation). Plot sem talhão fica registrado com `field_id` NULL (não reprocessa).
- **Resolução geo da Fertilidade (`resolveFertilityByGeo`, fase 3)**: cruza o ponto de coleta (`FERT_SAMPLE`/`FERT_SAMPLE_POINT.geom`) com o contorno do talhão (`STIntersects`) e preenche os `field_id` NULL. Roda em **todos os caminhos de criação de talhão** — cadastro manual e import KML/Shape (`POST/PUT /fields`), import do Farmbox (`importFarmboxPlots`) — e como **rede de segurança ao fim de todo ETL completo** (junto do `autoMapFarmboxFields`). Assim a fertilidade **se autocura** igual ao Farmbox (a tela depende 100% de `field_id`; sem isso o grid fica vazio). Backlog resolvível medido = 0; os NULL que sobram são pontos com GPS fora de qualquer contorno.
- **Disparo automático + performance:** o ETL roda ao fim de **cada ingestão** (só se ingeriu linhas) e em **cada webhook** (escopado em `applications` → run rápido). `ensureFarmboxEtl` não bloqueia (1 por vez; se já roda, marca rerun-pendente e coalesce). `field_id` (denormalizado) existe só em PLANTATION/MONITORING/MONITORING_NOTE.

### 2c. Planejamento agrícola & Estimativa (derivados do Farmbox)
- **Backfill de planejamento** (`seasons.service.ts#backfillPlanningFromFarmbox`) — set-based e idempotente; materializa a partir do JSON cru de plantations no CONNECTOR (`record`): `FARM_CULTURE` (culturas sem match por nome) → `FARM_SEASON_CYCLE` (safra×ciclo×cultura) → `FARM_VARIETY` (dedup cultura+nome) → `FARM_FIELD_PLANTING` (1 por ciclo+talhão, com `productivity`/`area_ha`/`variety_id`/`farmbox_plantation_id`), **só para safras já cadastradas** (`FARM_SEASON.farmbox_harvest_id`). Plantios com `field_id` NULL (plot não mapeado) são pulados.
  - **Disparo:** automático ao **registrar safras** (`POST /seasons/import-farmbox`) e pela rota manual `POST /seasons/backfill-planning`. **NÃO roda dentro do ETL principal.** Consequência operacional: um **plantio/safra novo** só aparece na Produtividade/Estimativa **após o backfill** (as queries fazem JOIN interno em `FARM_FIELD_PLANTING`); já contagens novas de um plantio **já materializado** aparecem só de abrir a tela. Recomenda-se rodar o backfill após cada ingestão do Farmbox se novos plantios entram continuamente.
- **Amostrador da contagem** — a estimativa resolve o amostrador a partir do JSON cru do CONNECTOR (`..._MONITORING_DAY_RESULT.record.monitors[]`), a única ponte contagem→monitor (a contagem não grava usuário). Atribui o amostrador por `plantation_id`+data (mesmo-dia ≈ 24% = alta confiança; ±7 dias ≈ 49% = aproximado).
- **Estimativa = cálculo ao vivo** — `estimate.service.ts` avalia a fórmula ativa (`PROD_ESTIMATE_FORMULA`) sobre as contagens em `FARM_COUNT` **a cada request** (sem tabela de resultado/cache). Normaliza metragem (valor por metro quando o nome traz "/6m" etc.), resolve parâmetros externos por plantation (ex.: população da soja no Stand inicial OU final) e por **conceito** (nome) quando o `pID` exato falta, e aplica **override por variedade** (característica com `override_pid`, fallback ao medido). O **@/ha real** usa a mesma média **ponderada por área** de Produtividade/Evolução (núcleo `productivityCore.ts#wavg`).
- **Rotação a partir do Farmbox** — importação **opt-in** (não agendada): `rotation.service.ts` detecta programações do Farmbox e grava em `FARM_FIELD_ROTATION` quando o usuário confirma.
- **"Não cadastrados" (detecção opt-in, mesmo padrão em 3 domínios):** além das **programações** (`countUnmappedFarmboxProgrammings`, `rotation.service.ts`), o ETL/consulta detecta **safras** do Farmbox sem `FARM_SEASON` (`listUnmappedFarmboxHarvests`, `seasons.service.ts` → import via `POST /seasons/import-farmbox`) e **talhões** do Farmbox sem `FARM_FIELDS` (`listUnmappedFarmboxPlots`, `farmboxPlots.service.ts` → import via `importFarmboxPlots`). Em todos, o ETL só **detecta/loga**; a criação é confirmada pelo usuário no banner (não escreve sozinho).

### Gatilhos Farmbox
| Etapa | Job (scheduler) | Rota manual | Escopo |
|---|---|---|---|
| Ingestão (grupos) | `farmbox.aplicacoes` (30min), `farmbox.monitoramentos` (60min), `farmbox.semanal` (dom 03:00) | `/farmbox/sync {group}`, `/integrate`, resume/restart | cursor `updated_since`/endpoint; FULL p/ refs |
| Webhook | `farmbox.webhook` (realtime) | `/webhooks/farmbox` | evento único |
| **ETL raw→master** | `farmbox.etl` (daily 03:30) **+ automático ao fim de cada ingestão/webhook** | `/farmbox/etl` | `processed=0` (incremental) |

---

## 3. IRRICONTROL
- **Ingestão/ETL pendentes** (API de pivôs bloqueada — **502/403**, tokens por fazenda). No scheduler, jobs **desabilitados e sem runner** (`irricontrol.snapshot` 15min, `irricontrol.operations` daily 04:30). Tabelas raw `IRRICONTROL_*` já existem, prontas para quando for liberado.
- **STUB do app — `irrigation.service.ts` + `irrigation.routes.ts`** (montado em `app.ts`; o router aplica `authRequired`). `GET /irrigation/overview?start=&end=&farm=1,2&hours=8,9` (`start`/`end` `YYYY-MM-DD`; `farm` CSV via `parseFarmIds`; `hours` via `parseHours`). Devolve **contrato final** já consumido pelo painel Irrigação: os talhões das fazendas selecionadas (vazio = todas) **com geometria** (`FARM_FIELDS`⋈`FARM_PLOTS`, `deleted_at IS NULL`, filtro `p.farm_id IN (:farms)`; geometria via `geometry.service`). **SEM novas tabelas.**
- Campos `status`/`appliedMm`/`pct` = **null**, `availableDates=[]` e `kpis={pivots:0,running:0,appliedMm:0}` até a ingestão/ETL existir. Quando o módulo for normalizado, o ponto exato da query real é o **`TODO(IrriControl ETL)`** no `.map(...)` de `irrigationOverview` (preencher por talhão no período via `CONNECTOR_GCS_FARM.IRRICONTROL_*` com `BETWEEN :start AND :end` + `DATEPART(HOUR, ...) IN (:hours)` e `availableDates`) — assinatura/forma não mudam. Front: `farm/irrigacaoService.ts` + `components/map/IrrigationMap.tsx` ("Irrigação — dados em breve").

---

## 3b. APLICAÇÃO AÉREA (log de voo) — `flightLog.service.ts` + `flightLogDecode.ts`

> **Não é um ETL agendado.** Diferente de Solinftec/Farmbox (que puxam de API externa em janelas de tempo pelo scheduler), este pipeline roda **sob demanda, por upload**: cada arquivo `.log` do Air Tractor é decodificado e materializado no ato do `POST`. Não há job no `CONFIG_SCHEDULER`, não há cursor `updated_since`, não há `processed=0` — a unidade de trabalho é **um arquivo**. Todo o fluxo opera **só na conexão `masterDb` (GCS_FARM)** — não é cross-database e não toca o `CONNECTOR_GCS_FARM`.

### 3b.1. Entrada — `POST /aereo/logs` (multipart)
- Rota `aereo.routes.ts` (router com `authRequired`), upload via `multer` em **memória** (`memoryStorage`, limite `MAX_UPLOAD_MB` ou 20 MB). Campo do arquivo = `file`; metadados opcionais no corpo: `name`, `applicationRef`, `swathM`, `startedAt`/`endedAt`, `equipmentId`, `pilotPersonId` (o `uploadedBy` vem de `req.user`).
- O buffer do arquivo vai direto para `importFlightLog` — **sem** camada raw/ingestão; o `.log` cru é guardado na própria linha (`raw_data`).

### 3b.2. Decode do binário — `flightLogDecode.ts` (`decodeFlightLog`)
- Formato **AS4.01/ATT** do GPS do Air Tractor (MapStar / Satloc-AgNav). Stream de registros `[0xA5][tamanho][payload]`. Varre buscando o marcador de **posição** `A5 2B 01` (comprimento **43 bytes**) e lê, por offset: `+5` f32 tempo · `+9` f64 **lat** · `+17` f64 **lon** · `+25` f32 alt(m) · `+29` f32 vel(m/s) · `+33` f32 rumo · `+42` byte **flag da barra** (`2` = aplicando). A **vazão** vem em registro próprio (comprimento 9, canal `0x20`, f32 em `+4`), associado ao último ponto com barra aberta.
- Sanidade geográfica dos pontos (lat/lon dentro da faixa BR) descarta lixo binário. Deriva: distância total e **aplicada** (Haversine), velocidade média/mín/máx, tempo de voo/aplicado (por distância÷velocidade — o relógio do log é ambíguo), `bbox`/centro, **largura de faixa** (`detectSwath`, autocorrelação do cross-track dos pontos aplicando) e, com vazão suficiente, **vazão mediana (L/min)** e **taxa (L/ha)**.

### 3b.3. Materialização — `importFlightLog` → `FLIGHT_LOG`
- **Dedup** por `sha256(arquivo)` (`file_hash`): reenvio do mesmo `.log` → **409**. `< 10` pontos reconhecidos → **400** (log inválido).
- **Geometria (GEOGRAPHY)** montada a partir dos pontos como WKT (`wktMultiLineString`, com simplificação por distância p/ limitar tamanho): `track_geom` = trilha completa (só referência; o render usa o blob); `applied_geom` = centro dos trechos aplicando **bufferizado** por metade da faixa (`STBuffer(swath/2)`), com `Reduce`/`MakeValid`/`ReorientObject` p/ manter a área tratável e válida. A **`applied_area_ha`** é `STArea/10000` da cobertura.
- **`points_blob`** = pontos compactos `[lat,lon,alt,spd,hdg,boom,flow]` serializados em JSON e **gzip** (`gzipPoints`), usados para re-render no mapa sem reprocessar o binário.
- **Fazenda dominante:** após inserir, um `UPDATE` seta `farm_id` pela fazenda de **maior área coberta** (interseção `applied_geom` × `FARM_FIELD_GEOMETRY`⋈`FARM_FIELDS`⋈`FARM_PLOTS`, `ORDER BY SUM(STIntersection.STArea) DESC`) — não pelo centro do envelope (que cairia fora de cobertura côncava/multipart).

### 3b.4. Analyze — `analyzeFlightLog` (`GET /aereo/logs/:id/analyze`)
- Passo **de leitura** (não grava): cruza `applied_geom` com `FARM_FIELD_GEOMETRY` (índice espacial `SIX_FARM_FIELD_GEOMETRY`) para listar os **talhões tocados** (área aplicada por talhão > 0,1 ha) e ranqueia as **APs candidatas** (`FARM_APPLICATION_TARGET`⋈`FARM_APPLICATION` que miram ≥1 talhão tocado): ordena por nº de talhões cobertos › não-finalizada › data mais recente (`app_date DESC`), e devolve a **AP dominante** sugerida + contexto (logs já existentes por AP, área buscada total). A geometria diz **quais** talhões foram cobertos (confiável); a AP correta é escolha do usuário.

### 3b.5. Assign — `assignFlightLog` (`POST /aereo/logs/:id/assign`)
- Recebe grupos `{ applicationId, fieldIds[] }` (um talhão só pode ir para **uma** AP no mesmo voo). Em transação: limpa split anterior, e por grupo **recorta a cobertura** = `applied_geom ∩ UnionAggregate(geom dos talhões atribuídos)`, grava `FLIGHT_LOG_APP` (`coverage_geom`, área/volume/taxa/velocidade derivados) e, por talhão, `FLIGHT_LOG_APP_FIELD` com **aplicado × buscado** (`pct_exec = aplicado/buscado`).
- **Reconciliação:** a área atribuída é a **área da união** das coberturas por AP (dedup de sliver na fronteira, não a soma); o restante vira `external_area_ha` (aplicado fora dos talhões buscados) e o log passa a `status='assigned'`. As visões `listApplicationsWithLogs`/`getApplicationRollup` fazem o rollup construtivo por AP (união de cobertura entre logs, sem dupla contagem; volume acumula em sobreposição).

### Gatilhos Aplicação Aérea
| Etapa | Job (scheduler) | Rota | Escopo |
|---|---|---|---|
| Import (decode→geometria→blob) | **nenhum — sob demanda** | `POST /aereo/logs` (multipart) | 1 arquivo `.log` por chamada; dedup por `file_hash` |
| Analyze (talhões tocados + AP candidata) | — | `GET /aereo/logs/:id/analyze` | leitura; interseção espacial |
| Assign (recorte por AP + reconciliação) | — | `POST /aereo/logs/:id/assign` | grupos AP→talhões; transação |

> Tabelas próprias (só no `masterDb`/GCS_FARM): `FLIGHT_LOG` (metadados + `raw_data`/`points_blob` + `track_geom`/`applied_geom`), `FLIGHT_LOG_APP` (cobertura recortada por AP) e `FLIGHT_LOG_APP_FIELD` (aplicado×buscado por talhão). Refs do cadastro: aeronaves em `MACHINE_OPERATION_EQUIPMENT` (grupo `AVIAO-BAHIA`), pilotos em `MANAGEMENT_PEOPLES`.

---

## 4. AGENDADOR CENTRAL — `scheduler.service.ts`
- **Tabelas:** `CONFIG_SCHEDULER` (definição: connector, job_key, kind, cadence_type/value, enabled, last_*, next_run_at, sort_order) e `CONFIG_SCHEDULER_LOG` (histórico: status, rows_loaded, duration_ms, trigger_by, message).
- **Engine:** `setInterval` a cada ~30 s; pega `TOP 1` job devido (`enabled=1`, `next_run_at <= agora`) e roda **1 por vez** (lock em memória, instância única). Desliga com `SCHEDULER=off`.
- **`next_run_at` sempre em UTC** (`computeNextRun`: interval=agora+N; daily=próximo HH:MM; weekly=DOW HH:MM). `repairNextRuns` recalcula no boot. `seedScheduler` semeia o catálogo sem sobrescrever edições do usuário.
- **Disparo:** refatorado em **`claimJob(id)`** (pré-checagem do lock `runningJobId` + busca do job + reserva) e **`executeJob`** (com `markRunning` **dentro do try** → falha ali não deixa o lock preso; libera `runningJobId` no `finally`; erro grava `last_status=ERROR` + `last_message`).
  - **`runJobNow(id, 'schedule'|'manual')`** aguarda o término — usado pelo **ticker** (`tick()`, `trigger_by='schedule'`).
  - **`startJobNow`** dispara em **BACKGROUND** (`void executeJob(...)`) e responde na hora — usado pela rota `POST /scheduler/jobs/:id/run` (manual), que responde **202** (ok) / **409** (sem lock/sem runner). Corrige o "Falha ao disparar o job" (timeout de 15 s do axios em ETLs longos); o front acompanha por **polling** (`GET /jobs` → `last_status` + histórico).
- **Runners por `job_key`:** Solinftec chama integração/ETL; Farmbox dispara o grupo e aguarda o lock próprio terminar (poll 2 s).

### Catálogo de jobs
| job_key | conector | cadência | enabled | ação |
|---|---|---|---|---|
| `farmbox.aplicacoes` | farmbox | interval 30 | ✓ | sync grupo aplicações |
| `farmbox.monitoramentos` | farmbox | interval 60 | ✓ | sync grupo monitoramentos |
| `farmbox.semanal` | farmbox | weekly dom 03:00 | ✓ | sync resto |
| `farmbox.webhook` | farmbox | realtime | ✓ | (sem runner; é o webhook) |
| `solinftec.weather` | solinftec | daily 05:00 | ✓ | ingestão weather D-1 |
| `solinftec.operation` | solinftec | daily 05:10 | ✓ | ingestão operation D-1 |
| `solinftec.etl` | solinftec | daily 05:20 | ✓ | `runEtl('both')` |
| `irricontrol.snapshot` | irricontrol | interval 15 | ✗ | (sem runner) |
| `irricontrol.operations` | irricontrol | daily 04:30 | ✗ | (sem runner) |

> Notas: (1) o `farmboxScheduler.service.ts` foi **removido** — quem agenda Farmbox é este scheduler central. (2) O **ETL Farmbox** roda **automaticamente** ao fim de cada ingestão (full/grupo) e em cada evento de webhook (`ensureFarmboxEtl`, com *rerun* se chegar raw novo durante a execução), além do job diário `farmbox.etl` como backstop. Mantém o master fresco quase em tempo real.
