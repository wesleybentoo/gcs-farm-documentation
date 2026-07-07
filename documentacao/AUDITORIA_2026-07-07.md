# Auditoria da Documentação — 2026-07-07

Auditoria de sincronia entre **o que existe hoje** (banco vivo, backend, front) e **o que a documentação afirma**. Metodologia: schema vivo lido via `INFORMATION_SCHEMA` nos dois bancos; rotas Express enumeradas do código; telas do front lidas de `App.tsx` + `navConfig.ts`; comparado contra `documentacao/01_Escopo_e_Modulos_App.md`, `02_Bancos_de_Dados.md`, `03_ETLs.md` e os scripts `documentacao/SQL/`. (Workflow multi-agente + verificação.)

## Veredito rápido

| Pergunta | Resposta | Severidade |
|---|---|---|
| **O SQL de hoje é o que está documentado?** | **Parcialmente.** Views (13+6) e a procedure batem 100%. As **tabelas estão sub-documentadas**: o banco vivo tem 104 (GCS_FARM) + 47 (CONNECTOR); a doc 02 enumera menos. Nada documentado está errado/ausente do banco — a doc só está **desatualizada** (faltam módulos recentes). | Média |
| **A API de hoje é a que está na documentação?** | **Quase.** ~92% dos grupos estão descritos. **2 grupos inteiros faltam na doc:** `/aereo` (Aplicação Aérea) e `/applications` (Mapa de Aplicações). Nada descrito na doc deixou de existir. | Média |
| **O front de hoje é o que está no escopo?** | **Quase 100%.** Única lacuna material: **Aplicação Aérea** (3 telas reais) não está no escopo. A doc não "inventa" telas. | Média/Baixa |

**Diagnóstico comum:** não há inconsistência *perigosa* (a doc não descreve nada que não exista). O que há é **defasagem**: os módulos criados depois do último carimbo da doc (03/07) ainda não entraram — sobretudo **Aplicação Aérea**, **Mapa de Aplicações**, o **Módulo Agronômico nativo** (`MODULE_AGRO_V1`) e `FERT_EXPORT_SET`.

---

## 1. SQL — banco vivo × scripts canônicos × doc 02

**Verdade (banco vivo, `INFORMATION_SCHEMA`):**

| Banco | Tabelas | Views | Procedures |
|---|---|---|---|
| GCS_FARM | **104** | 13 | 1 (`usp_fert_resolve_field_geo`) |
| CONNECTOR_GCS_FARM | **47** | 6 | 0 |

**Em sincronia (100%):** todas as views (13 no GCS_FARM, 6 no CONNECTOR) e a procedure. As 4 `VW_FARMBOX_*` que a doc diz terem sido dropadas na "Fase B" estão de fato fora do banco vivo (dropadas por `SQL/DROP_FARMBOX_MIRROR.sql`) — consistente.

**Fora de sincronia (sub-documentação de tabelas):**
- **GCS_FARM:** a doc 02 enumera ~80 tabelas e declara ~78; o vivo tem **104**. Faltam na doc:
  - **~20 tabelas `FARM_*` do Módulo Agronômico** (`MODULE_AGRO_V1.sql`): `FARM_PRODUCT*`, `FARM_ACTIVE_INGREDIENT`, `FARM_ART`, `FARM_APPLICATION*`, `FARM_MONITORING*`, `FARM_PEST*`, `FARM_COUNT*`, `FARM_ESTIMATE`, `FARM_HARVEST_YIELD` (a doc só cita `FARM_COUNT` e `FARM_PRODUCT` soltos).
  - **3 tabelas `FLIGHT_LOG*`** (`FLIGHT_LOG.sql`, Aplicação Aérea) — a doc 02 não tem seção.
  - **`FERT_EXPORT_SET`** — falta no bloco FERT_* (a subcontagem "FERT 20 tabelas" deveria ser 21).
- **CONNECTOR:** a **contagem 47 bate**, mas a doc só enumera ~33 dos 47 `FARMBOX_*` raw — **14 nomes ficam invisíveis** na lista.

**Nada documentado está ausente do banco** (o diff doc→SQL deu vazio nos dois bancos).

> Nota: a memória de 03/07 registrava 107 tab / 17 views no GCS_FARM — números **pré-Fase B**. O banco vivo hoje (pós-drop do espelho Farmbox) é 104 / 13. Recomenda-se recarimbar o inventário do doc 02 para a realidade viva.

**Ações (SQL):**
1. Adicionar ao doc 02 uma seção **Módulo Agronômico nativo** listando as tabelas `FARM_*` de `MODULE_AGRO_V1.sql`.
2. Adicionar seção **Aplicação Aérea** (`FLIGHT_LOG`, `FLIGHT_LOG_APP`, `FLIGHT_LOG_APP_FIELD`).
3. Incluir `FERT_EXPORT_SET` no bloco FERT_*.
4. Enumerar as 14 `FARMBOX_*` raw faltantes no CONNECTOR e recarimbar as contagens para 104/13/1 (GCS_FARM) e 47/6/0 (CONNECTOR).
5. Deixar explícito que `SETUP_FULL.sql` **+** `MODULE_AGRO_V1.sql` **+** `FLIGHT_LOG.sql` **+** `FERT_*` são as fontes de DDL (o doc chama SETUP_FULL de "fonte única", o que já não é literal para tabelas).

---

## 2. API — rotas reais × doc 01/03

O backend monta **~28 grupos de rota** (`app.ts`). A documentação descreve a API por **módulo/funcionalidade** (não enumera rotas), e ~92% dos grupos estão cobertos.

**Grupos inteiros SEM descrição na doc:**
- **`/aereo`** (Aplicação Aérea — logs de voo do Air Tractor): ~14 endpoints (import `.log`, analyze, assign a AP, aircraft/pilots, analysis refs/apps/detalhe). Só existe como DDL em `SQL/FLIGHT_LOG.sql`. (A memória dizia "só front" — mas o backend REST **já existe**.)
- **`/applications`** (Mapa de Produtos Aplicados do Farmbox): `GET /refs`, `GET /overview`.

**Discrepâncias menores (cobertas só por glob `/x/*`):**
- `GET /solinftec/auth-token` (diagnóstico) não citado.
- Submódulos de **Fertilidade** com nomes concretos ausentes: `/fertilidade/nutrient-export`, `/export-sets`, `/culture-scopes`, `/crop-export`, `/amendments` (a doc usa `/fertilidade/*` genérico).
- `PUT /scheduler/jobs/:id` (editar cadência) não listado.
- CRUDs de `/cadastros`, `/ops` e auxiliares de `/farmbox` cobertos só por glob.

**Nada descrito na doc deixou de existir no código** (`documentedButMissing` vazio).

**Ações (API):** adicionar seções para **Aplicação Aérea** e **Mapa de Aplicações** no doc 01; documentar o pipeline de decode do log de voo no doc 03; expandir os nomes reais dos submódulos de Fertilidade; incluir uma **tabela-apêndice de grupos de API** (mountPrefix) para nenhum router novo ficar sem menção.

---

## 3. Front — telas reais × escopo (doc 01)

O escopo (`01_Escopo_e_Modulos_App.md`, carimbo 2026-07-03) está **quase totalmente sincronizado**: Dashboard, Satélite, Fertilidade completa, Produtividade (incl. Estimativa), Operação, Meteorologia, Painel de Operações, Planejamento (Safras/Rotação), Admin (incl. Culturas/Variedades), Integrações — todos batendo com o status real/stub.

**Única lacuna material:** o grupo **Agricultura de Precisão › Aplicação Aérea** — 3 telas **reais** e funcionando (Logs de Voo, Visualizar Voo, Análise da AP) — **não está no escopo** (só aparece nos DDLs).

**Menores:** `Perfil` (`/app/perfil`, menção parcial) e `LandingPage` (`/`) não listadas como rotas fora do `navConfig`; a doc agrupa "Mapas / Planejamento de Coleta" sob Fertilidade, mas no front estão sob **Agricultura de Precisão**.

**Nenhuma tela documentada como implementada deixa de existir** (`documentedButMissing` vazio).

**Ações (Front):** adicionar a seção **Agricultura de Precisão → Aplicação Aérea** (3 telas); corrigir o agrupamento; listar `Perfil` e `LandingPage`; atualizar o carimbo/"Resumo do estado".

---

## 4. Postman

Coleção gerada a partir das rotas reais do backend (**28 módulos, 206 endpoints**), **agrupada por módulo** (um folder por `mountPrefix`), em:
`suporte/Postman - APIs/GCS_FARM_API.postman_collection.json`

- Variáveis `{{baseUrl}}` (default `http://localhost:3000`) e `{{token}}` (JWT).
- Auth **Bearer `{{token}}`** herdada pela coleção; `/auth/*` marcado como público.
- Fluxo: `POST /auth/login` → copiar o `token` → colar em `{{token}}` → os demais módulos já autenticam.
- Bodies de exemplo em POST/PUT; uploads (`.log`, `.xlsx`, KML) marcados como `form-data` com campo `file`.

_(cobertura: ver a própria coleção — um folder por módulo/mountPrefix.)_

---

## Resumo das ações priorizadas

**Alta** — fechar a defasagem dos módulos recentes:
1. Doc 02: seção Módulo Agronômico (`FARM_*`) + seção Aplicação Aérea (`FLIGHT_LOG*`) + `FERT_EXPORT_SET`; recarimbar inventário para 104/13/1 e 47/6/0.
2. Doc 01: adicionar Aplicação Aérea (3 telas + API `/aereo`) e Mapa de Aplicações (`/applications`).

**Média:**
3. Enumerar as 14 `FARMBOX_*` raw faltantes no CONNECTOR (doc 02).
4. Corrigir o agrupamento "Agricultura de Precisão" no doc 01.
5. Citar `auth-token`, `PUT /scheduler/jobs/:id` e os nomes reais dos submódulos de Fertilidade.

**Baixa:**
6. Listar `Perfil` e `LandingPage` como rotas fora do `navConfig`.
7. Documentar no doc 03 o pipeline de decode do log de voo (parser AS4.01/ATT no servidor).
