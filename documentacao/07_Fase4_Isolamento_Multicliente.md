# Fase 4 — Isolamento Multicliente (GLOBAL / GRUPO / FAZENDA)

> Estado: **implementado e homologado no `GCS_FARM_TEST`**. Produção (`GCS_FARM`) ainda
> NÃO alterada — a migração de schema + deploy do código é um passo deliberado (ver §7).
> Ver também `05_Arquitetura_Multicliente_e_Escopos.md` (desenho) e
> `06_Fase3_Homologacao_e_Mapa_de_Impacto.md` (mapa de impacto que originou esta fase).

## 1. O que a Fase 4 entrega

O isolamento de tenant deixa de ser "confiança no cliente" (o front mandava `?farm`, o
back não checava) e passa a ser **imposto no backend por identidade**. Três níveis de acesso:

| Tier | Enxerga | Uso |
|------|---------|-----|
| **GLOBAL**  | todas as fazendas não deletadas | super admin da plataforma |
| **GRUPO**   | todas as fazendas do próprio grupo (tenant) | **default** — preserva o comportamento atual |
| **FAZENDA** | só as fazendas mapeadas em `MANAGEMENT_USER_FARM` (∩ grupo) | acesso restrito por fazenda |

## 2. Âncora de identidade (DDL — seção D do MODULE_MULTITENANT_V1)

`MANAGEMENT_USERS` ganhou:
- `client_group_id BIGINT NULL` (FK `CLIENTE_GRUPO`) — o **tenant** do usuário, âncora DIRETA
  (não derivada do mapeamento de fazendas, que pode estar incompleto);
- `access_scope VARCHAR(10) NOT NULL DEFAULT 'GRUPO'` (CHECK GLOBAL|GRUPO|FAZENDA) — o tier.

Seed idempotente: cada usuário recebe o grupo das fazendas que mais mapeia (fallback = grupo GCS).
No GCS_FARM_TEST os 3 usuários ficaram GCS/GRUPO. DDL **aditiva e idempotente** (2 colunas
nullable + FK + CHECK + UPDATEs de seed) — segura para rodar em produção.

**Gotcha real (homologado):** as 7 fazendas GCS são `{1,2,3,4,5,6,12}`, mas os usuários só
estão mapeados a `{1..6}` em `MANAGEMENT_USER_FARM` (Celeiro PI = 12 é órfã). Por isso o tier
default é **GRUPO** (vê TODAS as fazendas do grupo) e não FAZENDA — assim o comportamento atual
é preservado (nenhuma fazenda some) e ainda há isolamento entre clientes.

## 3. Resolução do escopo (backend)

- **Login/refresh** (`auth.routes.ts`) gravam `{cg, scope}` no JWT (`security.ts` → `JwtPayload`).
- **`authRequired`** (`middleware/auth.ts`) virou **assíncrono** e **relê tenant+tier AO VIVO do
  banco** a cada request (mata a janela de staleness do JWT: rebaixar/realocar um usuário vale já
  no próximo request, não só no refresh; também 401 se o usuário foi inativado/excluído). Ele
  popula `req.user.{sub,username,cg,scope}` e `req.allowedFarmIds` via `resolveAllowedFarms`:
  - GLOBAL → todas as fazendas não deletadas;
  - GRUPO → fazendas do grupo (`client_group_id = :cg`);
  - FAZENDA → `MANAGEMENT_USER_FARM` ∩ grupo.
  - **FAIL-CLOSED:** GRUPO/FAZENDA com `cg` NULL ⇒ `[]` (não vê nada). O escape antigo
    `:cg IS NULL OR ...` foi REMOVIDO — era o furo que fazia um usuário novo (cg NULL) ver tudo.
- **`utils/query.ts`**: `scopeFarmIds(allowed, raw)` = `raw ∩ allowed`, ou `allowed` se `raw`
  vazio, ou **`[-1]`** (sentinela fail-closed — NUNCA "todas") se a interseção é vazia.
  `scopedFarms(req)` = atalho `scopeFarmIds(req.allowedFarmIds, parseFarmIds(req.query.farm))`.
- **`utils/scopeGuard.ts`** (novo): helpers compartilhados p/ rotas por id/escrita —
  `farmIdOfField`/`farmIdOfPlanting`, `inFarmScope(req, farmId)`, `assertFieldScope(req, fieldId)`
  (lança 403 se o talhão não é do usuário).
- **`/me`** expõe `client_group_id` + `access_scope` + `allowed_farm_ids` para o front se adaptar.

## 4. Varredura de escopo (o coração do trabalho)

Trocado `parseFarmIds(req.query.farm)` → `scopedFarms(req)` em **11 rotas de lista**
(applications, estimate, fertilidade, irrigation, monitoramento, operations, ops, productivity,
research, seasons, weather). Além disso, **IDOR fechado em TODA rota por id / escrita**:

- **farms/plots/fields** (`farm.routes.ts`): CRUD + bulk-delete/bulk-move + import-farmbox
  (guard no `farmId` de destino; fazenda nova nasce com o `cg` do criador).
- **monitoramento**: detalhe `/history/:id`; `/request` (create checa talhão, cancel só no escopo).
- **fertilidade**: history-years/points, config, map, points, export (nunca confia no `farms` do
  body — cruza com o entitlement), plans (lista + por id), amendments — todos escopados; fim do
  sentinela `farmId=0 ⇒ ALL`.
- **research**: trials por id (get/compare/put/delete) + strips + create (checa o talhão).
- **weather**: escrita manual de clima por safra (`season-climate/:plantingId`) + guarda de payload.
- **aereo**: módulo inteiro (flightLog + aereoAnalysis) escopado por `FLIGHT_LOG.farm_id` e por
  talhão-alvo da AP.
- **ops**: toda rota por id passa por `assertOpsScope` (programa com fazenda ⇒ fazenda ∈ permitidas;
  programa SEM fazenda ⇒ tenant do dono == `cg` do usuário); `listPrograms` idem.
- **users**: `PUT /users/:id/farms` só concede fazenda que o próprio ator enxerga (anti-escalonamento);
  usuário novo herda o `cg` do criador.

## 5. Auditoria adversarial (2 rodadas, via workflow)

- **1ª rodada** (26 agentes): 13 achados reais confirmados (2 críticos). Raiz = as listas foram
  escopadas mas **as rotas por id/detalhe/escrita não** (mesma classe de IDOR).
- **2ª rodada** (verificação + varredura): +15 rotas não escopadas em outros módulos **e 2
  regressões introduzidas por mim**: (a) `getConfig` filtrava `n > 0` e descartava o sentinela
  `-1` → caía no ramo GLOBAL; (b) `operations.farmFilter` com `[-1]` vazava os fatos sem talhão.
- **Todos corrigidos** (`tsc` limpo; homologado por SQL contra dados reais: TESTE→0 / GCS→N em
  monitoramento, fertilidade (18.887 amostras / 1 plano), voos; `scopeFarmIds` 6/6 casos).

## 6. Backlog restante (LATENTE — só explorável com um 2º cliente real)

Hoje há **um único tenant efetivo** (GCS): o grupo TESTE não tem usuário nem dados. Logo os itens
abaixo não são exploráveis em produção hoje; devem ser fechados **antes de onboardar o 2º cliente**:

1. **Governança de catálogo global** — culturas/variedades são catálogo global por design; editar
   afeta todos os tenants. Precisa de gate "só GLOBAL" (casa com a atribuição de tier na Fase 5).
2. **`farm_id` direto no `MACHINE_OPERATION_FACT`** (rung 5 / ETL) — ~38% dos fatos têm `field_id`
   NULL (apoio/deslocamento) e hoje passam via `field_id IS NULL OR ...` (preserva o total do
   tenant único; vazaria p/ o 2º tenant). Fix = coluna de tenant no fato, populada no ETL.
3. **Ops menores** — subquery de paradas do `operationByField` sem `farmFilter`; converter programa
   para "sem fazenda" (coberto pelo gate de owner-cg).
4. **Aéreo (baixo)** — agregado `soughtHa` que cruza alvos fora do escopo; `assignFlightLog` não
   revalida a AP do payload.

## 7. Promoção para produção (pendente, decisão deliberada)

A DDL da seção D é **aditiva/idempotente** — segura p/ o `GCS_FARM`. O código novo só passa a valer
após o **deploy/restart** do backend. Como todos os 3 usuários reais são GCS/GRUPO, o efeito prático
é nulo (continuam vendo as 7 fazendas). Sequência recomendada quando for promover:
`aplicar seção D no GCS_FARM` → `deploy do backend` → smoke de login + `/farms` + uma tela por módulo.
