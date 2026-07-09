# 06 — Fase 3: Homologação do novo DBA + Mapa de Impacto (multicliente)

**Data:** 2026-07-09 · **Status:** 🟡 Análise concluída — **nenhuma alteração de código feita ainda.** Insumo para as Fases 4 (isolamento) e 5 (telas). Base: `05_Arquitetura_Multicliente_e_Escopos.md`; escopo novo já no `GCS_FARM_TEST` (Fase 2). Backend `gcs-backend`, front `gcs-farm-front`.

---

## 1. Homologação do novo schema (GCS_FARM_TEST) — ✅ passou

| Prova | Resultado |
|---|---|
| **Isolamento por `CLIENTE_GRUPO`** | Filtrando por `client_group_id`: `GCS` = 7 fazendas / 207 talhões / 1.529 plantios; `TESTE` = 1 / 0 / 0. Particiona limpo. |
| **Safra por DATA (25/26), sem FK** | Plantios com `planting_date` na janela 01/09/2025–31/08/2026 agrupados por cultura global: Soja 117, Algodão 60, Braquiária 41, Milho 32, Café 3… **803 "órfãos de data"** (anteriores a 23/24) — sinalizáveis; somem semeando janelas mais antigas em `REF_SAFRA`. |
| **Rollup geográfico** | Carimbo do polígono: **Extremo Oeste Baiano › Santa Maria da Vitória › Cerrado (175)** e **Sudoeste Piauiense › Alto Médio Gurguéia › Cerrado (32)**. Comparação por macro/micro/bioma funcionando. |

**Conclusão:** o modelo (tenant + safra-por-data + geografia derivada) se sustenta com dado real. Único ajuste sugerido: semear mais janelas históricas em `REF_SAFRA` para reduzir os 803 órfãos.

---

## 2. Raiz do impacto

> **A identidade não carrega tenant.** `signToken`/`verifyToken` (`src/utils/security.ts`) emitem `{ sub, username }`; `authRequired` só repassa isso; **não há `client_group_id` em lugar nenhum**. O modelo `ManagementUserFarm` existe (`src/models/index.ts`) mas tem **0 leituras**. O escopo vem 100% de `req.query.farm` via `parseFarmIds` (`src/utils/query.ts`), onde **omitir `farm` = TODAS as fazendas do banco**. Isso quebra os 4 invariantes de uma vez. **P0-1 (tenant no JWT) bloqueia toda a escada** — nenhuma escrita/leitura escopada é possível antes dele.

---

## 3. Mapa de impacto ranqueado

### 🔴 P0 — bloqueiam a multi-tenancy / segurança (fazer primeiro, em ordem)

| # | Item | Arquivos | Mudança |
|---|---|---|---|
| 1 | **Tenant na identidade** (alicerce) | `security.ts`, `auth.routes.ts:39,56`, `middleware/auth.ts`, `models/index.ts` | No login/refresh resolver `CLIENTE_GRUPO` via `MANAGEMENT_USER_FARM`→`FARM_FARMS`; assinar `clientGroupId` no JWT; enriquecer `req.user`. Única fonte de tenant. |
| 2 | **`resolveScope` + `scopeFarmIds`** | `middleware/auth.ts` (novo), `utils/query.ts`, `app.ts:57-80` | `allowedFarmIds` do `MANAGEMENT_USER_FARM` filtrado pelo grupo; default = permitidas (**nunca ALL**); com query = `raw ∩ allowed`. Encadear após `authRequired` nas ~13 rotas de dados. |
| 3 | **Trocar `parseFarmIds`→`scopeFarmIds`** nas 12 rotas de leitura | applications/estimate/farm/fertilidade/irrigation/monitoramento/operations/ops/productivity/research/seasons/weather `.routes.ts` | Substituir cada `parseFarmIds(req.query.farm\|farm_id\|farmId)`; unifica o nome do parâmetro. |
| 4 | **IDOR farm/plot/field** | `farm.routes.ts` (GET /farms, /plots; by-id GET/PUT/DELETE; bulk) | Filtrar por `client_group_id`+`allowedFarmIds` mesmo sem query (o seletor do cabeçalho hoje lista clientes alheios); by-id carrega dono e retorna 404 fora do escopo. |
| 5 | **Carência (reentrada/colheita) copy-on-write** ⚠️ segurança | `monitoramento.service.ts:720-751`, `:253` | `upsertCarenciaDefault/Product` gravam baseline global. Degrau `client_group_id` não-nulo (da identidade), copy-on-write, baseline read-only. Alimenta `VW_MONITOR_FIELD_STATUS.in_carencia` (bloqueio de colheita). |
| 6 | **Tolerância copy-on-write** | `monitoramento.service.ts:78-137,59-64` | `setDefault`/`upsertException` gravam `farm_id NULL` (baseline). Escopo não-nulo; `getTolerance` resolve escada tenant›baseline; `clearExceptions` hoje apaga de todos. |
| 7 | **Threshold de praga copy-on-write + IDOR by-id** | `monitoramento.service.ts:618-677,470-476` | Adicionar `client_group_id` a `FARM_PEST_THRESHOLD` + à unique; app escreve degrau do tenant; `update/deleteThreshold` validam dono. |
| 8 | **Tenant chegando aos services de escrita** | `monitoramento.routes.ts`, `catalog.routes.ts`, `catalog.service.ts` | Propagar `req.user.clientGroupId` como dono obrigatório a `setDefault/upsertException/saveMethodology/createThreshold/upsertCarencia*`, `saveVariety`. Sem isso o `client_group_id` vira NULL(=global). |
| 9 | **ETL Farmbox: token/conector por cliente** | `farmbox.service.ts:419` | `CONFIG_API` por grupo; iterar ingestão por `client_group`, propagando o tenant no run. |
| 10 | **ETL: carimbar tenant no landing + chave do MERGE** | `farmbox.service.ts:227-258` | `MERGE` do landing casa só por `farmbox_id` (ids por-instância); adicionar `client_group_id` às `FARMBOX_*` e à chave. |
| 11 | **ETL: MERGE `FARM_*` + `NOT MATCHED BY SOURCE` com tenant** | `farmMaterialize.service.ts:33-162` | Casa só por id Farmbox → clientes colidem. Carimbar `client_group_id` em cada `FARM_*` + chave; **`NOT MATCHED BY SOURCE` sem filtro de tenant soft-deleta o acervo dos outros clientes** a cada run por-cliente. |
| 12 | **ETL: `CONFIG_CONNECTORS` plot→talhão sem tenant** | `farmMaterialize.service.ts:100,153`, `farmboxMapping.service.ts:40,51` | `cc.code=plot.id` sem `client_group_id`; `plot.id` é por-instância → aplicação/monitoramento cai no talhão de outro cliente. |
| 13 | **Uniqueness de Variedade com tenant** | `catalog.service.ts:250-259,195-205` | `FARM_VARIETY` ganha `client_group_id` (NULL=seed global); unique `(culture_id,name,ISNULL(cg,0))` filtrado; `listVarieties` filtra global∪tenant. |

### 🟠 P1 — habilitam operação correta + ligam as capacidades novas

- **ETL:** cursor incremental por `(endpoint, client_group_id)` (`farmbox.service.ts:549`); backfill de planejamento (safra/plantio) por tenant (`seasons.service.ts:181-266`).
- **Config:** metodologia por tenant (hoje singleton `farm_id NULL`, `monitoramento.service.ts:148-193`); separar baseline(seed) de override(app) no threshold (`:640-677`) — habilita migração sem perder edições.
- **IDOR menor:** config/scheduler/media por `:id` sem dono (`farmbox/scheduler/media.routes.ts`).
- **Catálogo:** reclassificação de plantio herda `client_group_id` ao criar variedade (`plantingReview.service.ts:130`); **cultura permanece GLOBAL** — só restringir escrita a role de catálogo + índice filtrado (`catalog.service.ts`).
- **Capacidades novas (usar o que já está no TEST):**
  - **REF_SAFRA por data na Produtividade** (`productivity.service.ts`) — benchmark inter-fazenda por safra global (sem FK).
  - **Cascata de espaçamento no Stand** (`productivity.service.ts:143-182`) — usar `plantio.row_spacing_cm › cultura.default › medido › fallback`.
  - **Rollup por macro/micro/bioma na Produtividade** (`productivity.service.ts:121-137`) — LEFT JOIN `GEO_UNIT`/`REF_BIOMA` a partir do carimbo do talhão.
  - **Front:** seletor de escopo GLOBAL/GRUPO/FAZENDA + `accessibleFarms` por entitlement (`FarmProvider.tsx`, `FarmSwitcher.tsx`).

### 🟡 P2 — paridade e refinamento

- ETL: estado em memória por tenant (paralelismo — `currentRun`/`etlState` são singletons).
- Rollup regional na **Estimativa** (paridade com Produtividade).
- REF_SAFRA por data no **Clima por Safra**.
- Front: safra global (`REF_SAFRA`) no cabeçalho quando escopo=GRUPO/GLOBAL.
- Guarda-corpo: confirmar catálogos que **não** ganham tenant (`FARM_PEST`, `FARM_PRODUCT_CATEGORY`, `FARM_PHENOLOGICAL_STAGE`) + índices únicos filtrados por `deleted_at IS NULL`.

---

## 4. Quick wins (entregáveis já em 1 tenant, sem multi-tenancy completa)

1. Escopar `GET /farms` e `GET /plots` por grupo/allowed (fecha o IDOR do seletor de cabeçalho) — só depende do P0-1.
2. Unificar o parâmetro num único `scopeFarmIds(req, raw)` — elimina rota esquecida sem interseção.
3. **Cascata de espaçamento no Stand** — `row_spacing_cm`/`default_row_spacing_cm` já existem; corrige o stand/ha hoje.
4. **REF_SAFRA por janela de data na Produtividade** — sem FK, `REF_SAFRA` já existe.
5. **Rollup GEO/bioma na Produtividade** — `municipio_geo_id`/`bioma_id` já carimbados; hoje órfãos.
6. Tornar índices únicos dos catálogos globais **filtrados por `deleted_at IS NULL`** — melhora o re-run do ETL.

---

## 5. Riscos de não fazer (resumo)

- **Vazamento total de leitura cross-tenant** (omitir `?farm=` = todas as fazendas do banco) em todos os módulos.
- **IDOR** de leitura/escrita por `:id` em farm/plot/field.
- **Risco agronômico/legal** — carência de reentrada/colheita é baseline global; editar afeta o bloqueio de colheita de todos os clientes.
- **Config agronômica cruzada** — tolerância/threshold/metodologia globais; `clearExceptions`/`deleteThreshold` apagam de todos.
- **Corrupção de dados no ETL** ao ligar o 2º cliente Farmbox (colisão de id + `NOT MATCHED BY SOURCE` soft-deletando o acervo alheio).
- **Cadastro travado/vazado** (variedade sem tenant → 409 pro 2º cliente ou exposição).
- **Capacidades novas órfãs** — sem ligar REF_SAFRA/espaçamento/GEO, os carimbos já gravados não servem pra nada.

---

## 6. Sequência recomendada

**P0-1 é o gargalo** (tenant no JWT) — nada de escopo funciona antes dele. Depois: `resolveScope` (P0-2) → fechar leitura/IDOR (P0-3, P0-4) → copy-on-write da config, começando pela **carência** por ser segurança (P0-5..8) → ETL tenant-aware (P0-9..12) → uniqueness de variedade (P0-13). Em paralelo, os **quick wins de capacidade** (espaçamento, REF_SAFRA, rollup GEO) entregam valor imediato em 1 tenant e exercitam o schema novo. Front (P1/P2) fecha o ciclo.
