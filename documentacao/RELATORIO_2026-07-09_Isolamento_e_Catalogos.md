# Relatório — Isolamento multicliente + escopo de catálogos (2026-07-09, sessão autônoma)

> Para revisão. Tudo commitado/pushado; DDL aplicado em TEST **e** `GCS_FARM` (prod). O **deploy
> do backend (CI) ainda é o passo de vocês** — o código novo só passa a rodar em prod após o deploy.
> Enquanto isso, o prod roda o código antigo (que ignora as colunas novas) — **nada quebra**.

## 1. O que ficou pronto e no ar (commitado/pushado)

**Isolamento por identidade (Fase 4) — completo e homologado:**
- `MANAGEMENT_USERS.client_group_id` (tenant) + `access_scope` (GLOBAL/GRUPO/FAZENDA). `authRequired`
  resolve tenant+tier **ao vivo do banco** e monta `allowedFarmIds` por tier (GLOBAL=todas; GRUPO=fazendas
  do grupo; FAZENDA=mapeadas∩grupo; fail-closed).
- `scopeFarmIds`/`scopedFarms` (fail-closed, sentinela `[-1]`, nunca "todas") em **11 rotas de lista**.
- **IDOR fechado** em farms/plots/fields (+bulk/import), monitoramento, fertilidade, research, weather,
  aéreo (módulo inteiro), ops (por programa) e `PUT /users/:id/farms`.
- 2 auditorias adversariais → 28 achados + 2 regressões minhas, **todos corrigidos**, `tsc` limpo,
  homologado por SQL contra dados reais.

**Catálogos GLOBAIS IMUTÁVEIS (cultura/variedade/característica):** escrita só p/ tier GLOBAL
(`globalWritesOnly`); leitura livre. **ti@ e ai.faz@ promovidos a GLOBAL** (TEST+prod) p/ o cadastro
não travar. wesley/ivandro seguem GRUPO.

**Catálogos de CONFIG — escopo de grupo (copy-on-write / escada de herança):**
- **DDL (MODULE_MULTITENANT_CATALOG_V1.sql) aplicada em TEST + prod:** `client_group_id` (NULL=baseline
  global) + 9 índices únicos cientes de escopo nos 8 catálogos (tolerância default/exceção, metodologia,
  threshold de praga, carência default/produto, set de níveis críticos, set de exportação).
  **Backward-compatible:** o código/ETL atuais gravam `cg` NULL e o índice `(chave, cg)` com NULL protege
  o baseline — validado por SQL (baseline único, override de grupo coexiste, mais-específico-vence).
- **METODOLOGIA = template copy-on-write pronto e homologado:** `getMethodology(cg)` resolve
  (override do grupo > baseline global); `saveMethodology` faz copy-on-write (GRUPO cria/edita a linha
  do próprio grupo, baseline intacto). Testado: GLOBAL→10, cg1→25(override), cg2→10(herdado), baseline preservado.

**Front preparado p/ os níveis:** `AuthUser` carrega `accessScope`/`clientGroupId`/`allowedFarmIds`
(via `/me`); `useAuth().isGlobal`. Base p/ as telas respeitarem o tier.

**Camada geográfica (Fase 2b) no prod:** GEO_UNIT/malhas/biomas copiados do TEST + carimbo (207 talhões,
Cerrado) — produtividade com rollup macro/micro/bioma funcionando; código resiliente se a geo faltar.

## 2. O que FALTA (próxima sessão) — ativação copy-on-write dos demais catálogos

**Descoberta central:** todo catálogo de config tem **acoplamento de engine** — ativar a escrita por grupo
SEM ajustar a leitura do engine = regressão (a edição do GRUPO "some" do engine). Metodologia foi o único
sem acoplamento (o read dela É o engine). Por isso os outros ficaram **só DDL-preparados** (serviço
inalterado = **zero regressão hoje**), e cada um precisa do **par (write copy-on-write + config-read + engine-read)**:

| Catálogo | Engine a ajustar (resolver pelo grupo do dado) |
|---|---|
| Tolerância (default/exceção) | `VW_MONITOR_FIELD_STATUS` — resolver tolerância pelo grupo do talhão (farm→cg) |
| Threshold de praga | `getPestHeatmap` / checagem de limites |
| Carência | checagem de carência em `applications` |
| Níveis críticos (set/faixas) | `getFieldMap`/`getScale`/`getPoints` — resolvem o set por `code`; preferir o set do grupo |
| Perfis de exportação (set/coef) | `exportacao`/`cropExport` — idem set por grupo |

Padrão a seguir (igual à metodologia): `effectiveCg(req)` no write (GLOBAL=baseline null; GRUPO=cg) +
resolução mais-específico-vence no config-read + no engine-read por grupo do dado. Front: badge
"herdado do global" vs "customizado do grupo" + read-only p/ não-GLOBAL nos catálogos globais.

## 3. Deploy / operação
- **Falta o deploy do backend em produção (CI)** — commit `developer` mais recente. Só então o
  isolamento + os gates valem em prod. DB do prod já está pronto (schema + seeds + GLOBAL admins).
- `.env` local segue apontando p/ `GCS_FARM_TEST` (dev/homologação).
- **Smoke pós-deploy sugerido:** login (ti@ e wesley@) → `/farms` (7 fazendas) → 1 tela por módulo →
  editar metodologia como wesley (GRUPO) e conferir que vira override do grupo, não o baseline.

## 4. Regressão / ETL
- Rodada verificação adversarial (workflow) de regressão nos services/ETL/páginas — resultado anexado
  em seguida; ETL grava `cg` NULL (baseline), compatível com os índices novos.
