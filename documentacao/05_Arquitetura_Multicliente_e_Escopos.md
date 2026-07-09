# 05 — Arquitetura Multicliente e Escopos Globais

**Data:** 2026-07-09 · **Status:** 🟡 **DESENHO APROVADO — nada aplicado no banco ainda.** Este documento consolida a arquitetura discutida para transformar o GCS FARM (hoje single-tenant: Fazenda Jacúba / GCS Agro, 7 fazendas num único `GCS_FARM`) em uma plataforma **multicliente**, com dados globais compartilhados e comparação entre regiões — sem que um cliente afete o outro. É a **Fase 1** do plano de ataque (ver §8).

---

## 1. A ideia central (a invariante que não pode quebrar)

> **Catálogo global é semente compartilhada; configuração do cliente é sobreposição isolada. Toda personalização de um cliente é gravada no escopo dele — nunca altera o baseline global nem o dado de outro cliente. O valor "de verdade" é sempre RESOLVIDO por herança (o mais específico vence), não armazenado num lugar só.**

Se essa invariante se mantém, o produto escala para N clientes sem um pisar no outro. Tudo abaixo é consequência dela.

### Padrões transversais (valem para todos os módulos)
1. **Catálogo × Configuração.** *Catálogo* = o que existe (identidade): culturas, pragas, doenças, estágios, categorias, princípios ativos, geografia. Compartilhado, curado no centro; o cliente **referencia**, não edita. *Configuração* = quanto/como/qual (valor aplicado): espaçamento, tolerância, doses, variedades escolhidas. **Sempre escopada**.
2. **Herança — mais específico vence.** Resolução por `COALESCE`/`ROW_NUMBER` numa escada: `talhão/plantio › gleba › fazenda › grupo/cliente › GLOBAL`. Cada configuração declara **quais degraus** suporta. NULL é o único sentinela de "herda" (⚠️ `''` **não** é NULL — normalizar vazio→NULL antes de gravar).
3. **Copy-on-write (regra de ouro do isolamento).** Editar um item global = **`INSERT` de uma linha nova no escopo do cliente**, **nunca** `UPDATE` na linha global. É isso que garante "o ajuste dele não afeta o todo".
4. **Derivar, não pedir cadastro.** Sempre que o dado puder ser derivado do que já existe (o **polígono** ou as **datas**), derive — em vez de exigir cadastro em cascata. Vale para geografia (do polígono) e para safra (das datas).
5. **Isolamento na base, não só na tela.** Toda consulta filtra pelo tenant (o `CLIENTE_GRUPO`), idealmente com **Row-Level Security** no SQL Server (falha fechada mesmo se uma rota esquecer o filtro).

---

## 2. Escopo 1 — Clientes (hierarquia + isolamento)

```
CLIENTE_GRUPO (conta / tenant — fronteira de isolamento)
   → FAZENDA (client_group_id)
      → GLEBA (farm_id)
         → TALHÃO (plot_id)  ← unidade atômica
```
- **`CLIENTE_GRUPO` é a fronteira**: nada de um grupo alcança o dado de outro. É o topo novo, acima da geografia operacional que já existe (`FARM_FARMS → FARM_PLOTS → FARM_FIELDS`).
- A geografia operacional (fazenda/gleba/talhão) **já existe** — a mudança é prepender `CLIENTE_GRUPO` e carregar `client_group_id` em `FARM_FARMS` (autoritativo; o resto herda pelo join que já existe).
- **Copy-on-write** garante que o ajuste de um cliente nunca toca o baseline nem outro cliente.

---

## 3. Escopo 2 — Geográfico (derivado do polígono do talhão)

Duas árvores de **contenção** que convergem no **município** + um **overlay** temático. Tudo é **catálogo global de referência** (malhas oficiais IBGE), e o talhão recebe um **carimbo derivado** por interseção espacial do polígono (`FARM_FIELD_GEOMETRY.geom`) — nada digitado.

### Árvore administrativa (contenção estrita)
```
planeta → continente → país → estado → município
```
> **Por que `planeta`?** Custo ~zero (uma linha) e deixa o topo honesto para o dia em que a fronteira for a Lua/Marte. Tudo abaixo (IBGE, bioma) é catálogo **terrestre**; outro planeta entraria com os próprios catálogos.

Modelagem sugerida: tabela **auto-referenciada** `GEO_UNIT(id, parent_id, level, codigo_ibge, nome, geom)` — flexível (novo nível sem tabela nova).

### Árvore regional (a régua analítica do cliente)
```
MACRO_REGIÃO ⊃ MICRO_REGIÃO ⊃ MUNICÍPIO
```
FK filho→pai: `MUNICIPIO.micro_regiao_id → MICRO_REGIAO.macro_regiao_id`. Eixo **independente** da administrativa; ambas terminam no município (que guarda `estado_id` **e** `micro_regiao_id`).

### Overlay de bioma (eixo à parte, N:N, espacial)
- Bioma **não é filho do município** — um município pode ter vários biomas (transição), e um bioma cobre milhares de municípios.
- **`municipio.bioma_predominante_id`** (conveniência, por maior área) **+ bioma preciso no TALHÃO** (interseção do polígono) — que pega o **talhão-outlier em zona de transição**.
- `BIOMA → CARACTERÍSTICAS` (atributos; é onde as classificações **Cerrado** de fertilidade encaixam). Mesmo padrão de overlay serve depois para **clima (Köppen)**, **solo**, **ZARC**.

### Ponto de partida no dado atual
- `FARM_FARMS` já tem `city` + `state` (manuais, inconsistentes) → viram **legado/fallback**, não a fonte.
- Nenhuma tabela tem `municipio/uf/regiao/bioma` hoje; a camada geográfica é nova.

---

## 4. Escopo 3 — Safras · Culturas · Configurações

### Safra — global por JANELA DE DATAS (derivação solta, sem vínculo)
- **`REF_SAFRA(code "25/26", data_inicio, data_fim)`** — catálogo global minúsculo. É o **eixo de comparação**.
- **NÃO há FK** entre a safra global e a safra da fazenda. A fazenda cadastra a safra dela (nome livre, ciclos, datas). A análise **pesca por overlap de data**: `WHERE fp.planting_date BETWEEN safra.inicio AND safra.fim`.
- **3 regras que tornam o join determinístico:**
  1. **Âncora = `data de plantio`** (não colheita) → a 2ª safra/safrinha (plantada jan-fev, colhida set) fica na safra certa mesmo colhendo depois do fim da janela.
  2. **Janelas contíguas e sem sobreposição** (fim 25/26 = 31/08/2026; início 26/27 = 01/09/2026) → cada plantio cai em exatamente uma safra.
  3. **Cultura = um único catálogo global** (id estável: "Soja é sempre Soja"); o ETL de cada cliente **mapeia a soja do Farmbox dele para o mesmo id global**.
- **Autonomia ("sem pedir bença"):** o cliente não pede criação de safra — cadastra a dele livremente; a comparação é derivada. Não há cadastro em cascata.
- **Órfão de data:** plantio que não cai em nenhuma janela global → sinalizar para revisão (não bloquear).
- **Superpoder:** como o balde é só uma janela de data, qualquer recorte de análise (ano civil, "2ª safra = plantios jan-mar", janela climática) vira um range e fatia tudo que tem data.

### Cultura — catálogo global de id estável
Base do agrupamento cross-cliente. `FARM_CULTURE` permanece global (sem `farm_id`); o ETL casa a cultura de cada tenant no mesmo id.

### Configuração — escada com override (copy-on-write)
Espaçamento, tolerância, doses…: `global › grupo › fazenda › gleba › variedade`. O app **já tem o precedente** disso em `MONITOR_TOLERANCE_DEFAULT` (global) + `MONITOR_TOLERANCE` (exceção por fazenda/variedade). A evolução é **generalizar** (um resolver único) e **somar o degrau `grupo/cliente`**.

---

## 5. Espaçamento — o caso concreto que dispara tudo isto

Origem do debate: o card **Stand de plantas** (Produtividade › Analítico) precisa de plantas/ha; o espaçamento digitado por contagem no Farmbox é inconsistente (`p2407` "Espaçamento entre linhas", valores de 40,5 a 75 milhões de cm). Solução curada, no padrão da escada:
- **`FARM_CULTURE.default_row_spacing_cm`** — padrão por cultura (Algodão **81**, Soja/Milho/Sorgo **40,5**), que **popula no cadastro** (herda).
- **`FARM_FIELD_PLANTING.row_spacing_cm`** — override por plantio (variedade-talhão) quando fugir do padrão.
- **Cálculo:** `plantio.override › cultura.default › fallback` — e o espaçamento do monitor deixa de entrar na conta.
- No mundo multicliente, o `default_row_spacing_cm` ganha o degrau de escopo (grupo/fazenda), igual ao resto. *(A fórmula do Farmbox `(p2038/5)*((10000/p2407)*100)` foi confirmada no dado cru — é idêntica à nossa.)*

---

## 6. Riscos conhecidos (da crítica adversarial) e mitigações

| # | Risco (hoje) | Mitigação (alvo) |
|---|---|---|
| R1 | **Isolamento é uma mentira**: o escopo vem de `?farm` (query do cliente); o JWT não tem tenant; omitir `?farm` = TODAS as fazendas. `MANAGEMENT_USER_FARM` (user→fazendas) existe mas **nenhuma leitura o aplica**. | Tenant + fazendas permitidas **no JWT**; middleware `resolveScope = requested ∩ entitled` (nunca ALL); RLS no SQL Server. **(Fase 4, fatia fina entregável já.)** |
| R2 | **IDOR**: rotas `WHERE id=:id` sem join de dono → ler/apagar registro de outro tenant por id sequencial. | `WHERE id=:id AND cliente_grupo_id=:tenant`; 404 no miss; RLS. |
| R3 | **Copy-on-write violado pelo precedente**: o editor de tolerância grava `farm_id=NULL` (global) e dá `UPDATE` no `*_DEFAULT`; threshold/carência não têm coluna de escopo → editar afeta todos (segurança agronômica). | Proibir escrita de app no baseline; toda escrita escopada exige dono não-nulo; adicionar degrau tenant. |
| R4 | **ETL Farmbox**: token único, `MERGE ON farmbox_id` sem tenant → dois clientes com contas Farmbox colidem no mesmo id-space; linhas ingeridas sem dono; LGPD (apagar dados do cliente) intratável. | Conector **por tenant**; carimbar `cliente_grupo_id` no landing; chave `(cliente_grupo_id, farmbox_id)`; MERGE por tenant. |
| R5 | **Governança do baseline**: catálogo global vem do Farmbox (espelho vivo) → melhorar o baseline reescreve retroativamente o valor "herdado" e torna registros derivados não-reproduzíveis; `source='app'/'farmbox'` está sobrecarregado. | Defaults **versionados/datados**; gravar o valor resolvido nos registros derivados; separar proveniência × dono × ciclo-de-vida. |

**Escopo do retrofit (não fazer big-bang):** `client_group_id` **só** em `FARM_FARMS` + os ~6-10 catálogos/config que precisam de escopo GLOBAL autônomo; o resto deriva tenancy pelo join de fazenda que já existe. Reavaliar shared-schema vs schema/DB-por-tenant dado o porte (poucos grupos agrícolas, não milhões de tenants).

---

## 7. Níveis de visualização (Fase 4)

| Nível | Enxerga | Uso |
|---|---|---|
| **GLOBAL** | Todos os clientes, agregado/anonimizado por região/bioma/safra/cultura | Benchmarking de mercado, curadoria do baseline (papel de plataforma) |
| **GRUPO** | Todas as fazendas do próprio `CLIENTE_GRUPO` | Visão consolidada do cliente |
| **FAZENDA** | Uma (ou um subconjunto) das fazendas do grupo | Operação no dia a dia |

O nível vem do **entitlement no JWT** (não do que o cliente pede). O comparativo global só expõe agregados que não vazam dado identificável entre clientes.

---

## 8. Plano de ataque faseado

1. **Documentação + Escopos** *(este documento)* — desenho versionado. ✅ Fase atual.
2. **Novo escopo no `GCS_FARM_TEST`** — DDL idempotente: `CLIENTE_GRUPO` + `client_group_id`; árvore geográfica + overlay bioma; `REF_SAFRA`; `default_row_spacing_cm`/`row_spacing_cm`. Seed mínimo. *(Só em TEST.)*
3. **Homologação + mapa de impacto** — testar o schema; enumerar o que alterar: ~24 rotas com `parseFarmIds(req.query.farm)`, ETL Farmbox, MERGEs sem tenant, escritas no baseline, uniqueness de catálogo. Lista priorizada.
4. **Níveis de acesso GLOBAL/GRUPO/FAZENDA** — **onde o isolamento vira real**: JWT com tenant + fazendas permitidas, `resolveScope`, anti-IDOR, RLS. *(Fatia fina — JWT+resolveScope — entregável já em 1 tenant e de-risca tudo.)*
5. **Adaptar telas** — respeitar o escopo (seletor no cabeçalho, filtros derivados do entitlement, comparativos globais onde o nível permitir).

> **Sequência recomendada:** puxar a *fatia fina* da Fase 4 (isolamento por identidade) para perto do início — é o maior risco (R1/R2) e é entregável hoje, sem schema novo.

---

## 9. Estado atual × alvo (resumo)

- **Hoje:** single-tenant; 7 fazendas num `GCS_FARM`; catálogos globais **sem** `farm_id`/tenant; escopo por `?farm` (não seguro); safra = 1 linha/fazenda (do Farmbox), não comparável; geografia só `city/state` manual; precedente de escopo em `MONITOR_TOLERANCE`.
- **Alvo:** `CLIENTE_GRUPO` no topo; catálogos globais compartilhados (geo/cultura/etc.); safra global por janela de datas; geografia derivada do polígono (admin + regional + bioma); config em escada com override; isolamento por identidade (JWT + RLS); comparação cross-cliente por região/bioma/safra/cultura, sem cascata e sem vazamento.

_Ver também: `01_Escopo_e_Modulos_App.md`, `02_Bancos_de_Dados.md`, `AUDITORIA_2026-07-08.md`._
