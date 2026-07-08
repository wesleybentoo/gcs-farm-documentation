# Auditoria de Dados — 2026-07-08 (módulos entregues hoje)

Auditoria de **saúde de dados** dos três módulos construídos nesta rodada — **Pesquisa** (Ensaios de Faixa), **Clima por Safra** (`WEATHER_SEASON_SUMMARY`) e **Fenologia** (catálogo + guia de campo + mídia). Metodologia em duas camadas: (1) **reconciliação no banco vivo** (`GCS_FARM`) — órfãos, chaves duplicadas, geometria inválida, divergência de FK, referências penduradas, sanidade de valores e cobertura; (2) **crítica adversarial de código** (workflow multi-agente, 3 críticos lendo a DDL + os serviços) para o que a contagem de linhas não enxerga — corridas de upsert, lógica de agregação, unidades, constraints ausentes. Nada foi alterado no banco nem no código; este documento lista **achados e recomendações**.

## Veredito rápido

| Módulo | Integridade (banco vivo) | Achados | Pior severidade |
|---|---|---|---|
| **Pesquisa** (50 ensaios / 119 faixas) | **Limpa** — 0 órfãos, 0 dup, 0 geom inválida, 0 FK quebrada | 1 resíduo de teste, 1 corrida TOCTOU, caveats de geom/overflow | Média |
| **Clima por Safra** (98 linhas, 100% auto) | **Limpa** — 0 órfãos, 0 dup, 0 janela invertida, 0 valor absurdo | **totais parciais sem sinal de cobertura**, janela não clampada | **Alta** |
| **Fenologia** (216 estágios; 95,7% dos monitoramentos linkados) | **Limpa** — 0 dup (cultura,código), 0 mídia órfã, 0 confusão pendurada, 0 FK divergente | **classificação veg/rep presa**, guia órfão em revive, **guia 100% vazio (curadoria)** | **Alta** |

**Diagnóstico comum:** **não há corrupção de dados** — a integridade referencial está intacta nos três módulos. O que existe é (a) **qualidade/semântica de dado** (números que parecem uma coisa e são outra — sobretudo o Clima por Safra) e (b) **arestas de design** que só mordem em cenários específicos (concorrência, revive de estágio, input absurdo). O item de maior impacto real é o **Clima por Safra**: o cálculo está *correto*, mas a *cobertura de telemetria* o torna enganoso hoje.

---

## 1. Pesquisa (Ensaios de Faixa)

**Números vivos:** 50 ensaios, 119 faixas. Todas as faixas têm variedade; 116/119 têm geometria, 118 têm área, 112 têm produtividade. **Integridade 100% limpa** (nenhuma faixa órfã, nenhum ensaio sem faixa no backfill, nenhuma geom inválida, nenhum `farmbox_plantation_id` duplicado, nenhum ensaio sem cultura).

| # | Sev. | Tipo | Achado | Recomendação |
|---|---|---|---|---|
| 1.1 | Média | design | **1 ensaio não caracteriza strip test.** O ensaio `id=50` é `source=app`, `name=NULL`, **1 faixa / 1 variedade** — resíduo de smoke-test da construção do módulo. `listTrials` filtra só por `deleted_at`, então ele aparece igual a um ensaio real. O backfill *tem* a guarda `≥2 variedades distintas` (`COUNT(DISTINCT)`), mas o caminho do app (`createTrial`/`upsertStrip`) **não tem** guarda equivalente. | Limpar o `id=50`; filtrar/badge por nº de faixas na listagem (`stripCount`/`varietyCount` já são devolvidos ao front); guarda leve no `createTrial` para não persistir ensaio vazio. |
| 1.2 | Média | integridade | **Corrida TOCTOU no `createTrial`.** `IF EXISTS(...) SELECT id; ELSE INSERT` sem transação/lock contra o índice único filtrado `UQ_FRT_field_cycle`. Dois `POST /research/trials` concorrentes para o mesmo (talhão, ciclo) passam os dois no `IF EXISTS` e o 2º estoura duplicate-key → **400 "falha ao criar o ensaio"** em vez de retornar o id existente idempotentemente. | `IF EXISTS(... WITH (UPDLOCK, HOLDLOCK) ...)` ou capturar o erro de chave duplicada e re-`SELECT`. Mesma forma no backfill (baixo risco, execução serial única). |
| 1.3 | Baixa | dado | **Geometria super-dimensionada.** 6 faixas têm polígono `geom` > 1,5× a `area_ha` registrada — casos em que o `geo_points` do Farmbox guarda o **talhão inteiro**, não a faixa. **`area_ha` é o número confiável** e o `compare()` já a usa (geom só é fallback quando `area_ha` é NULL), então nenhuma conta é corrompida — apenas o polígono no mapa engana. | Expor uma flag de divergência (`geomAreaHa/areaHa` fora de 0,66–1,5) para o mapa não ser lido como o contorno da faixa. |
| 1.4 | Baixa | dado | **`numLit` (cap 1e12) pode estourar `productivity DECIMAL(12,3)`** (máx. 9 dígitos inteiros): produtividade em [1e9, 1e12) passa no cap e o INSERT dá erro aritmético em vez de nular. Impacto = erro em input absurdo, nunca corrupção silenciosa. | Cap por coluna (produtividade < 1e9). |

**Confirmado seguro:** escrita de geom **à prova de injeção** (coords numéricas via `sanitizePolygon`; `notes` com `N'...'` + escape de aspas); guarda de `≥2 variedades` do backfill correta.

---

## 2. Clima por Safra (`WEATHER_SEASON_SUMMARY`)

**Números vivos:** 98 linhas, **todas `auto`**, 0 manuais, 0 com irrigação. Sanidade **toda limpa** (0 janela invertida, 0 temp_min>max, 0 umidade fora de 0-100, 0 precip negativa, 0 rain_days > dias-da-janela, 0 órfã, 0 duplicada) **exceto 3 janelas > 400 dias**. O `MERGE WITH (HOLDLOCK)` e o reject de patch vazio estão **corretos**.

| # | Sev. | Tipo | Achado | Recomendação |
|---|---|---|---|---|
| 2.1 | **Alta** | dado | **Totais de janela PARCIAL expostos como totais de safra, sem sinal de cobertura.** O `FIELD_WEATHER_HOURLY` (fonte do auto) só tem telemetria de **2026-06-06 a 2026-07-18** (~6 semanas, 208 talhões). O `INNER JOIN` soma só os dias sobrepostos → o número guardado é o pedaço do ciclo que cai nessa janela, **não a safra inteira**. Prova viva: **46/98 linhas < 50 mm, nenhuma > 300 mm** (uma safra real de soja/algodão dá 500-900 mm). Não há coluna nem campo que sinalize a cobertura. | Adicionar **`days_with_data`** e **`window_days`** à tabela (populadas na `MERGE` via `COUNT(DISTINCT obs_date)` e o span da janela); expor no `listSeasonClimate`; a UI marca **"parcial"** quando `days_with_data/window_days` < ~90%. Sem isso o número não é interpretável como total de safra. |
| 2.2 | Média | integridade | **Janela nunca clampada.** `window_end = COALESCE(closed_date, harvest_prediction_date, hoje)` sem teto → 3 plantios com data ruim (colheita ~5 anos após o plantio) geram janelas de **1806 dias** aceitas em silêncio (a agregação varre anos). | Clampar (cap de N dias por cultura ou global ~400) e/ou `CHECK (window_end >= window_start)`; sinalizar anomalia quando o span estoura o máximo. (A raiz é a data do plantio em `FARM_FIELD_PLANTING` — o rollup deveria se recusar a mediar sobre isso.) |
| 2.3 | Baixa (latente) | dado | **`NULLIF(x,0)` é redundante hoje — não é bug.** O crítico levantou que `NULLIF` descartaria zeros legítimos (radiação noturna, ~0 °C), mas a **verificação no grid refutou**: `FIELD_WEATHER_HOURLY` tem **0 linhas com `solar_radiation`/`temp_c`/`humidity_pct` = 0** — à noite a radiação é gravada **NULL** (horas 0/3/18/21 são NULL, nunca 0). Logo o `NULLIF(x,0)` nunca dispara (no-op). Fica só como **smell latente**: se um dia o grid passar a emitir 0 físico, aí sim enviesaria. (Confirma a revisão anterior: no grid, 0 = ausente, já vira NULL upstream.) | Remover o `NULLIF(,0)` por higiene (é redundante) — sem urgência, não altera nenhum número atual. |
| 2.4 | Baixa | perf | `FIELD_WEATHER_HOURLY` é **varrido 2×** por recompute (CTE `daily` para rain_days + CTE `agg` para o resto, mesmo join). | Um único rollup diário e somar dele (1 varredura). Baixo impacto hoje; cresce com a tabela horária. |
| 2.5 | Baixa | design | Upsert **manual** usa o fallback "hoje" na janela no INSERT → diverge da janela que o recompute usaria (wall-clock diferente), sem reconciliação (manual nunca é sobrescrito). | Quando `closed_date` e `harvest_prediction_date` são NULL, deixar `window_end` NULL (nos dois caminhos) em vez de "hoje". |

**Confirmado seguro:** `MERGE HOLDLOCK` casa o índice único filtrado `UQ_WSS_planting` (sem TOCTOU); auto usa `INNER JOIN` (plantio sem telemetria não gera linha nem zera existente); reject de patch vazio evita flip auto→manual sem dado. **Irrigação 0 / manual 0** é esperado (fonte de irrigação ainda não ligada; nenhum lançamento manual feito).

> **Nota de escopo:** o `01_Escopo` já carrega a ressalva "o grid só tem telemetria a partir de ~jun/2026 → safras antigas ficam manuais/vazias". Esta auditoria a **quantifica** (janela real, 0 linhas > 300 mm) e aponta o conserto mínimo: **expor cobertura**.

---

## 3. Fenologia (catálogo + guia de campo + mídia)

**Números vivos:** 216 estágios (todos `source=farmbox`, 0 `app`), 10 culturas. **12.613/13.174 monitoramentos linkados (95,7%)** — os 561 restantes são todos `planting_id IS NULL` (gap de cadastro pré-existente, **não** é bug de fenologia). **Integridade 100% limpa** (0 dup (cultura,código), 0 mídia órfã, 0 blob não-referenciado, 0 FK de estágio apagado, 0 `confused_with_ids` pendurado).

| # | Sev. | Tipo | Achado | Recomendação |
|---|---|---|---|---|
| 3.1 | **Alta** | design | **Classificação veg/rep está PRESA.** Os **17 estágios sem classificação** (Café 6, Feijão/Milho/Soja 2, +5 culturas) são todos `source=farmbox` → `updateStageCore` bloqueia (só `app` edita) **e** a `MERGE` do ETL **re-NULLifica** a classificação todo run (o diff guard `ISNULL(tgt,'')<>ISNULL(s,'')` zera de volta quando o Farmbox não tem). Ou seja: nem o agrônomo edita, nem um ajuste direto no banco sobrevive. **Bloqueia a fenologia acionável** (limites veg/rep, cruzamento com estimativa). | Levar `classification` para a **camada curada** que o ETL não possui: coluna `classification_override` com `COALESCE` no `list` e fora do `UPDATE`/diff da `MERGE`; ou permitir `updateStageCore` editar `classification` em estágio Farmbox **e** excluí-la do conjunto que a `MERGE` reescreve. |
| 3.2 | Média | integridade | **Guia + mídia órfãos num revive.** A `MERGE` casa só `farmbox_stage_id AND deleted_at IS NULL`. Se um estágio Farmbox soft-deleted **reaparece** (cultura re-mapeada, rollback de ETL, `deleted_at` transitório), o `WHEN NOT MATCHED` **insere um id novo** — o guia curado (`id_tips`/dias/`confused_with_ids`) e as linhas de `FARM_PHENOLOGICAL_STAGE_MEDIA` ficam presos ao id velho (soft-deleted) e somem do catálogo vivo. | No `WHEN NOT MATCHED`, primeiro **reviver** (`UPDATE deleted_at=NULL`) a linha soft-deleted de mesmo `farmbox_stage_id` antes de inserir id novo, para curadoria e mídia seguirem o estágio. |
| 3.3 | Baixa | integridade | `confused_with_ids` só é podado na **leitura** — não na escrita (`updateStageGuide` filtra só auto-referência) nem no `deleteStage` (não varre os irmãos que apontam pro id apagado). O JSON pode reter ids mortos e ser re-persistido. | Podar por liveness no `updateStageGuide` e varrer o id apagado dos irmãos no `deleteStage`. |
| 3.4 | Baixa | integridade | `deleteStage` nula `FARM_MONITORING.phenological_stage_id` **sem `AND deleted_at IS NULL`** → mexe em monitoramentos já soft-deleted (o re-link é escopado a `deleted_at IS NULL`, não restaura o histórico apagado). Baixo impacto hoje (só estágios `app` são deletáveis; nenhum linkado). | Adicionar `AND deleted_at IS NULL` ao UPDATE, simétrico ao re-link. |
| 3.5 | Baixa | design | `addStageMedia` não valida que `media_id` é `FARM_MEDIA` **vivo**; a FK ignora `deleted_at` → se um blob for soft-deleted, `/media/:id` dá 404 (thumbnail quebrado) sem sinal de integridade. | Dropar `deleted_at` de `FARM_MEDIA` (conteúdo é imutável/dedup por sha256, reutilizável) **ou** bloquear soft-delete de blob ainda referenciado. |
| 3.6 | Info | adoção | **Guia de campo 100% vazio em produção:** 0 dicas, 0 faixas de dias, 0 mídia, 0 confusões, 0 linhas em `FARM_MEDIA`. A **infra está correta e completa** (bind VARBINARY sem blowup de hex, `/media/:id` com ETag+cache imutável, validação de upload 8 MB imagem / 60 MB vídeo, `stageExists` pré-check contra blob órfão). Falta **CURADORIA** — o "X do Agro" (ajudar o monitor novato, offline) ainda não foi realizado. | Não é bug. Semear alguns estágios de referência das culturas principais para provar a ponta (app de campo) fim-a-fim. |

**Confirmado seguro:** a `MERGE` **preserva** as colunas de guia (nunca as referencia no UPDATE); `bind` de VARBINARY correto (sem `0x`-hex inline); dedup por sha256 antes do insert.

---

## Ações priorizadas

**Alta** — o que engana o usuário hoje:
1. **Clima por Safra — expor cobertura** (`days_with_data` + `window_days`) e marcar linhas "parcial" na UI (achado 2.1). Sem isso, um total parcial lê-se como total de safra.
2. **Fenologia — destravar a classificação veg/rep** (override curado fora da `MERGE`, achado 3.1), habilitando a fenologia acionável.

**Média:**
3. Clima: clampar/validar a janela (2.2).
4. Pesquisa: fechar a corrida do `createTrial` (1.2) e limpar/filtrar o ensaio `id=50` (1.1).
5. Fenologia: revive-em-vez-de-inserir na `MERGE` para não orfanar guia/mídia (3.2).

**Baixa / higiene:**
6. Pesquisa: flag de divergência geom×área (1.3); cap de produtividade por coluna (1.4).
7. Fenologia: podar `confused_with_ids` na escrita/delete (3.3); `deleted_at IS NULL` no `deleteStage` (3.4); política de `deleted_at` em `FARM_MEDIA` (3.5).
8. Clima: rollup diário único (2.4); janela manual sem fallback "hoje" (2.5); remover `NULLIF(,0)` redundante (2.3, só higiene).

**Adoção (não é código):**
9. **Curar o guia de fenologia** — semear dicas/fotos/dias das culturas principais (3.6) para realizar o valor de campo offline.

> Nenhum destes é bloqueante de produção. Os módulos estão **íntegros e no ar**; os itens Alta são de **interpretação de dado** (Clima) e de **habilitar evolução futura** (Fenologia veg/rep).
