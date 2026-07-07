# GCS Connection Farm — Guia de Arquitetura e Novos Módulos

**Data:** 2026-06-28 · Objetivo: padrão único para o sistema **crescer sem virar mistureba**. Todo módulo novo segue estas convenções.

## Princípios
1. **Duas camadas de dados:** dado externo entra **cru** no `CONNECTOR_GCS_FARM` (raw, intocado) e só depois é transformado para o `GCS_FARM` (master, tratado). Nunca o app lê o raw direto; nunca se "conserta" dado no raw.
2. **Camadas no back:** `routes` (finas — validam input e chamam service) → `services` (regra de negócio, SQL) → `models`/`config`. **Sem regra de negócio na rota.**
3. **Idempotência sempre:** reprocessar não pode duplicar. Fatos por `NOT EXISTS (raw_record_id)`; dimensões por `MERGE ... ON code`; raw marcado `processed=1`.
4. **Derivado é recalculável:** tabelas derivadas (ex.: `FIELD_WEATHER_HOURLY`) são reconstruíveis a partir da fonte; nunca a única cópia de um dado.
5. **Convenções de nome:** tabelas `PREFIXO_*` por domínio (`FARM_`, `FERT_`, `VRA_`, `OPS_`, `MACHINE_OPERATION_`, `WEATHER_`/`FIELD_WEATHER_`, `SOLINFTEC_`, `IRRICONTROL_`, `MANAGEMENT_`, `CONFIG_`); views de **leitura agregada** `VW_*` (as views **operacionais de integração** seguem o domínio do conector: `<CONECTOR>_PENDING_*`/`<CONECTOR>_STALE_*`, ex.: `SOLINFTEC_PENDING_DAYS`, `IRRICONTROL_PENDING_QUEUE`); procedures `usp_*`.
6. **Padrões transversais:** soft-delete (`deleted_at`); timestamps UTC; segredos **cifrados** em `CONFIG_API` (nunca retornar em claro — usar flags `has_*`); geometria em `geography` (SRID 4326); `requestTimeout` 120 s; `MERGE` via `VALUES`/OPENJSON em lotes ≤ 1000 (limite TVC do SQL Server).
7. **Permissão por página:** toda tela é um registro em `MANAGEMENT_PAGES`, liberada por perfil em `MANAGEMENT_ACCESS` (read/write/delete/admin) + overrides por usuário.

## Estrutura de pastas
- **Back (`gcs-backend/src`):** `routes/` (1 arquivo por domínio) · `services/` (lógica + ETLs) · `models/` (Sequelize) · `config/` (database, env) · `middleware/` (auth). Registro de rotas em `app.ts`.
- **Front (`gcs-farm-front/src`):** `pages/<dominio>/` (telas) · `farm/<x>Service.ts` (chamadas à API) · `components/` (UI/mapas reutilizáveis) · `layout/navConfig.ts` (menu) · `App.tsx` (mapa `IMPLEMENTED` de rotas reais).

---

## Receita A — novo módulo de negócio (ex.: Estoque)
1. **Banco** (no `SQL/SETUP_FULL.sql`): criar tabelas `ESTOQUE_*` no `GCS_FARM`, com FK p/ `FARM_FIELDS`/`FARM_FARMS` quando fizer sentido; views `VW_ESTOQUE_*` se precisar de leitura agregada. O reset (`SQL/RESET_FULL.sql`) já cobre (dropa o banco inteiro).
2. **Back:** `services/estoque.service.ts` (regra + SQL) + `routes/estoque.routes.ts` (fino) + registrar `app.use('/estoque', ...)` em `app.ts`.
3. **Front:** `farm/estoqueService.ts` (api.get/post/put/delete) + `pages/estoque/EstoquePage.tsx` + adicionar a rota ao mapa `IMPLEMENTED` em `App.tsx` + item em `navConfig.ts`.
4. **Permissão:** inserir a(s) página(s) em `MANAGEMENT_PAGES` e liberar no perfil (`MANAGEMENT_ACCESS`).
5. **Doc:** atualizar `01_Escopo_e_Modulos_App.md` e `02_Bancos_de_Dados.md`.

## Receita B — nova integração / ETL (ex.: novo conector)
1. **Credenciais:** linha em `CONFIG_API` (auth + segredo cifrado) e de/para em `CONFIG_CONNECTORS` se houver mapeamento de entidades.
2. **Raw** (no `CONNECTOR_GCS_FARM`): prefixar pelo **nome do conector em maiúsculas** — `<CONECTOR>_*` (1 por registro, com chave natural p/ dedup) + `<CONECTOR>_INGESTION_LOG` (UNIQUE por dia/recurso) + `<CONECTOR>_INTEGRATION_ERROR` + views `<CONECTOR>_PENDING_*`/`<CONECTOR>_STALE_*`. Ex.: `SOLINFTEC_INGESTION_LOG`, `IRRICONTROL_PENDING_QUEUE` (não existe prefixo literal `CONECTOR_`).
3. **Ingestão** (`services/conector.service.ts`): API→raw, paginada, idempotente, com log e tratamento de erro por stage. Datas D-1 no fuso America/Sao_Paulo quando aplicável.
4. **ETL** (`services/conectorEtl.service.ts` ou `etl.service.ts`): raw→master **set-based** (`OPENJSON`+`MERGE`/`NOT EXISTS`), marca `processed=1`. Derivados recalculáveis por janela **gap-aware**.
5. **Scheduler:** adicionar job(s) ao `CATALOG` e o runner ao `RUNNERS` em `scheduler.service.ts` (cadência `interval`/`daily`/`weekly`; **sempre** um job de **ETL** se a ingestão for agendada). `next_run_at` é derivado e em UTC.
6. **Front:** painel de integração (status, pendências, rodar agora) + entrada no Agendador.
7. **Doc:** atualizar `03_ETLs.md`.

## Receita C — mapa / dashboard comparativo (ex.: Satélite, Análise de Solo)
Padrão para telas com **N mapas lado a lado** (grade 1/2/4) onde a **câmera sincroniza** mas os **filtros são por painel**. Tudo reutilizável fica em `components/map/` + `farm/geo.ts`; cada mapa-componente recebe **props opcionais** que mantêm a tela standalone intacta.
1. **Hub de sincronia** (`components/map/mapSync.ts`): `createMapSyncHub()` retorna `{ register, unregister, broadcast, getLastView, snapshotActive }`. Só re-emite em **movimento do usuário** (`event.originalEvent` presente) — o `jumpTo` programático dispara `move` **sem** `originalEvent`, então não há laço. `unregister(id, map?)` tem **guarda de identidade** (só remove se for o mesmo `map` daquele `id`) p/ sobreviver à troca de componente/layout e ao duplo-mount do StrictMode. `getLastView()`/`snapshotActive()` deixam um painel **novo** abrir já na vista dos demais.
2. **Hooks reutilizáveis** (`components/map/hooks/`): `useMapSync(sync, syncId)` → `{ attach, detach }` (chamar `attach(map)` na init e `detach(map)` no cleanup, antes de `map.remove()`); `adoptInitialView(map, coords, firstFitRef, sync)` adota a vista do hub na 1ª vez, senão `fitBounds` nos talhões. `useMeasureTool`/`useDrawAreaTool(mapRef, enabled, idPrefix, loadedRef)` desenham fonte/camada GeoJSON e expõem distância / área+perímetro ao vivo (`idPrefix` evita colisão de ids entre painéis; medição usa `farm/geo.ts`: `haversine`, `polygonAreaM2`, `polygonPerimeterM`, `formatDist`, `formatArea`). `useFieldHover({ sourceId, fillLayerId, getLabel })` → realce via `feature-state` `hover` + popup com o nome do talhão.
3. **Host + painéis:** página-host monta a grade (ex.: `pages/agro/SatellitePage.tsx`); cada quadrante é o `pages/agro/GeoPanel.tsx`, que **escolhe o componente** por um seletor de ícones (estado vazio): Satélite / Análise de Solo / Operação / Irrigação / Meteorologia. 1º card **fixo** (`fixed`, sem remover); demais começam vazios e o `×` volta ao seletor. **Filtros são por painel** (estado preservado ao alternar/remover).
4. **Config em MODAL por card:** abre por um **ícone de engrenagem** adicionado como **controle nativo do MapLibre** (`components/map/gearControl.ts` → `GearControl`), logo abaixo do botão de expandir (`addControl(..., 'top-right')` após `NavigationControl`/`FullscreenControl`). O conteúdo do modal é o `Modal` do app (portal). **Label-resumo** pequena no canto (ex.: "Cor real · 28/06"). Ferramentas medir/desenhar = `ToggleControl` (mesmo padrão; `setActive(on)` reflete o estado React).
5. **Props opcionais que preservam standalone:** os mapas-componente (`SentinelMap`, `CoverageMap`, `WeatherMap`, `IrrigationMap`) aceitam `sync`/`syncId`/`fill`/`onConfig`/`children` opcionais; toda lógica de comparativo fica atrás de `if (sync)`/`if (onConfig)`, então as telas standalone seguem inalteradas. `fill` troca altura fixa por 100% (flex).
6. **Controles temados:** os controles do MapLibre são estilizados (claro/escuro) em `components/ui/ui.css` (bloco "Controles do MapLibre"), **escopados sob `.fieldmap-wrap`/`.fertmap-wrap`** p/ vencer o CSS do MapLibre independente da ordem de carga; ícones nativos invertidos no tema escuro; botões custom (`.gcs-mapbtn`) usam `currentColor` (= `var(--text)`) e `.is-on` = `var(--brand-orange)`.
7. **Doc:** atualizar `01_Escopo_e_Modulos_App.md` (a tela vira dashboard).

---

## Regras de ouro (não quebrar)
- **Métrica compartilhada = 1 função (fonte única):** todo número que aparece em mais de uma tela sai de **uma** implementação, nunca reescrito por tela. Ex.: o **@/ha real** (Produtividade, Evolução, Estimativa) usa `services/productivityCore.ts#wavg` (média **ponderada por área**, `Σ prod×área / Σ área`) sobre `FARM_FIELD_PLANTING.productivity`; a unidade vem sempre de `FARM_CULTURE.productivity_unit`. Nunca ponderar por nº de pontos/amostras. (Auditoria 02/07: as três telas batiam 412,51 @/ha no algodão 24/25.)
- **Derivado por fórmula editável = ao vivo:** a Estimativa avalia `PROD_ESTIMATE_FORMULA` a cada request (sem tabela de resultado). Depende de `FARM_FIELD_PLANTING` materializado (backfill do Farmbox) — módulo derivado do planejamento não aparece sem o plantio (JOIN interno).
- **Escopo de ETL:** `reference_date` reprocessa um dia (seguro); sem ela, processa `processed=0`.
- **1 job por vez** no scheduler (instância única, sem lock distribuído) — se escalar p/ N instâncias, adicionar lock.
- **Nunca** logar/retornar segredo de `CONFIG_API`.
- **Banco == SQL canônico:** toda mudança de schema vai para o `SQL/SETUP_FULL.sql` (e o `SQL/RESET_FULL.sql` cobre por dropar o banco). Não criar objeto "só no banco" sem refletir no SQL. *(Hoje: 0 drift, validado 03/07 rodando o setup num banco novo — manter assim.)*
- **Fonte única do SQL:** **um único arquivo** — `Documentação GCS_FARM/SQL/SETUP_FULL.sql` (+ `RESET_FULL.sql` p/ reset). Os recortes por módulo (`SQL/modulos/`) e as cópias legadas em `Arquivos Suporte/` foram **removidos (03/07)** — não recriar cópias paralelas do SQL.
- **Mapa comparativo:** sincronia de câmera só em movimento do usuário (`originalEvent`); `unregister` sempre com o `map` (guarda de identidade) p/ não expulsar o mapa novo sob StrictMode. Reuso obrigatório: hub/hooks de `components/map/` + medição em `farm/geo.ts` — não duplicar.
- **CSS de controle de mapa** sempre escopado sob `.fieldmap-wrap`/`.fertmap-wrap` (vence o CSS do MapLibre); novos botões nativos usam `.gcs-mapbtn` (ícone via `currentColor`).
- **Props de comparativo opcionais:** `sync`/`syncId`/`fill`/`onConfig`/`children` atrás de guardas — não quebrar a tela standalone ao tornar um mapa "comparável".

## Checklist de novo módulo
- [ ] Tabelas/Views no SQL canônico (e reset cobre)
- [ ] Service (regra) + Route (fina) + registro no `app.ts`
- [ ] Service no front + Página + rota `IMPLEMENTED` + `navConfig`
- [ ] Página em `MANAGEMENT_PAGES` + permissões no perfil
- [ ] Job + runner no scheduler (se houver ingestão/ETL)
- [ ] Idempotência + soft-delete + UTC conferidos
- [ ] `tsc` limpo nos dois projetos
- [ ] Docs `01`/`02`/`03` atualizados
