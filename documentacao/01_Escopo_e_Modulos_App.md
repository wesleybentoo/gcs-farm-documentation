# GCS Connection Farm — Escopo e Módulos do App (Front)

**Data:** 2026-06-28 · **Atualizado:** 2026-07-07 (Aplicação Aérea: Logs de Voo/Visualizar Voo/Análise da AP; Mapa de Produtos Aplicados; Painel de Operações; Produtividade/Evolução/Estimativa, Fertilidade Exportação/Corretivos/Configurações, Cultivos, Planejamento Agrícola) · **App:** `gcs-farm-front` (React + Vite + React Router + axios + MapLibre).

Documento de **usabilidade**: o que cada módulo disponível no front faz de fato, do ponto de vista do usuário, e quais endpoints do backend consome.

A navegação é **data-driven** a partir de `src/layout/navConfig.ts` (menu lateral + rotas `/app/...`). Em `src/App.tsx`, só as rotas no mapa `IMPLEMENTED` têm tela real; as demais folhas do menu caem no card genérico **"Página em construção"**.

**Menu (estado atual):** grupos visíveis, na ordem — Dashboard, **Agronômico** (Satélite + **Produtos Aplicados** + subgrupo Produtividade: Analítico/Evolução/Estimativa), **Fertilidade** (grupo próprio: Análise de Solo, Exportação de Nutrientes, Adubação de Corretivos, Configurações), **Agricultura de Precisão** (Mapas [VRA-placeholder], Planejamento de Coleta + subgrupo **Aplicação Aérea**: Logs de Voo/Visualizar Voo/Análise da AP), **Operação**, **Meteorologia**, **Irrigação** (grupo **visível**, mas todas as folhas caem em "Página em construção"), **Painel de Operações**, **Pesquisa** (Ensaios de Faixa), **Planejamento Agrícola**, **Administrador**, **Integrações**. Os grupos **Estoque, Oficina, RH e Relatórios ficam ocultos** (`hidden: true`). Ordem das folhas de Meteorologia: Previsão, Janela Aplicação, Registro Geral, Registro por Estação. *(Obs.: neste doc, Fertilidade/Agricultura de Precisão/Produtividade estão descritos sob "Agronômico" por afinidade temática, mas no menu são grupos de topo distintos. **Mapas** e **Planejamento de Coleta** ficam sob **Agricultura de Precisão** no menu — não sob Fertilidade — apesar de as rotas usarem o prefixo `agronomico/fertilidade/...`.)* **Fora do menu (`navConfig`), há duas rotas navegadas por link:** **Perfil** (`/app/perfil`) e a **LandingPage** (`/`, tela de login pública).

---

## 0. Base — autenticação e escopo de fazenda
- **Login** (`/`): usuário/senha → `POST /auth/login` (JWT + refreshToken + `user.name` via `ManagementPerson`). Token em `Authorization: Bearer` em toda requisição; renovação proativa (~2 min antes de expirar) e em 401 via `POST /auth/refresh`. Sessão em **`localStorage`** → persiste entre abas e reinício do navegador (não pede login de novo enquanto o refresh for válido). O cabeçalho (`UserMenu`) exibe o **nome** do usuário (não o e-mail).
- **Preferências do usuário** (`MANAGEMENT_USER_PREFERENCE`, `GET/PUT /me/preferences`, JSON com merge parcial): **tema** (claro/escuro) e **fazenda(s) selecionada(s)** são salvos por usuário (e em localStorage p/ aplicar na hora); `PreferencesSync` carrega ao autenticar (aplica tema+fazenda) e salva ao mudar.
- **Seletor global de fazenda** (`FarmProvider`, cabeçalho): `GET /farms`. **Multi-seleção**: "Todas as fazendas" (compilado) ou um subconjunto — N fazendas compilam como o "Todas" restrito ao conjunto. `selection: 'ALL' | number[]` → `scopedFarmIds: number[] | null`; alimenta o filtro de quase todas as telas (endpoints aceitam **`IN`** de fazendas, CSV via `farmCsv`). IDs `BIGINT` chegam como string → coerção `Number()`. Telas de CRUD/planejamento (Glebas, Planejamento) travam a fazenda só com 1 selecionada.
- **Convenção HTTP:** criação `POST`, atualização **`PUT`**, exclusão `DELETE` (soft-delete em vários casos).

---

## 1. Agronômico

### Satélite (`agronomico/satelite`) — IMPLEMENTADA
**Dashboard comparativo** (`SatellitePage`): grade **1/2/4 painéis** (igual à Análise de Solo), botão "Maximizar" para **modo imersivo** (esconde menu+cabeçalho via `body.sat-immersive`).
- **Painéis** (`GeoPanel`): o **1º card é fixo** (Satélite, sem botão de remover); os demais começam **vazios** com **seletor por ícones** entre **5 componentes** — Satélite, Análise de Solo, Operação, Irrigação, Meteorologia. O "×" remove o card e volta ao seletor.
- **Sincronia de câmera** (pan/zoom) entre todos os painéis via 1 hub (`createMapSyncHub`); **filtros são por painel**.
- **Configuração por card em modal** (componente `Modal`), aberto por um **ícone de engrenagem** adicionado como controle nativo do MapLibre, logo abaixo do botão de expandir. **Label-resumo** no canto sup. esquerdo com as escolhas (ex.: "Cor real · 28/06").
- **Painel Satélite** (`SatellitePanel`): imagens Sentinel-2 sobre os talhões. Config no modal: tipo de satélite (basemap), tipo de cor/índice (RGB, NDVI…), data (com % de nuvens por data), máx. nuvens, brilho/contraste, ver talhões / só traçado. Seleciona automaticamente a imagem mais recente disponível. Modo prévia (mosaico EOX) se Sentinel Hub não configurado.
- **Ferramentas no card de Satélite** (controles nativos, abaixo da engrenagem): **hover com nome do talhão**; **medir distância**; **desenhar polígono** (área ha/km²/m² + perímetro; só medição).
- Os cards Operação/Meteorologia/Irrigação reusam `CoverageMap`/`WeatherMap`/`IrrigationMap` (props opcionais `sync`/`fill`/`onConfig`), com filtros próprios (período + **horário** + variável/operação) no modal de config.
- Endpoints (por kind de painel): `GET /fields`, `/operations/by-operation`, `/weather/overview`, `/irrigation/overview`; imagens via Sentinel Hub externo.

### Fertilidade
> Possui **modo demonstração** (gera dados fake nos talhões reais quando `/fertilidade/*` não responde).

- **Análise de Solo** (`agronomico/fertilidade/visualizacao`) — IMPLEMENTADA. Compara análises por talhão em **1/2/4 mapas** sincronizados. Filtros: parâmetro (P, pH, K, Ca, Mg, S, V%, MO, CTC, Argila, Silte, Areia), **visão de interpretação** (PADRÃO / CERRADO / MACRO_FOCO), profundidade (0–20/20–40/40–60), ano/safra, fazenda. **Mapa de calor** (raster client-side por vizinho-mais-próximo + box-blur, classificado por faixa) ou cor por classe; toggle de pontos de coleta; legenda dinâmica. **KPIs por talhão/seleção:** distribuição % por faixa, Média, D.P., C.V. Ações: importar `.xlsx` (**várias planilhas de uma vez** — processadas em lote sequencial, com dedup por geolocalização e resumo por planilha), exportar (xlsx/pdf), editar visões/faixas. Endpoints: `GET /fertilidade/config|map|scale|points`, `POST /fertilidade/import|export`, `GET/PUT /fertilidade/sets/:set/bands`, `POST /fertilidade/sets`, `GET /fields`.
- **Planejamento de Coleta** (`.../planejamento`) — IMPLEMENTADA. *(No menu, esta folha fica sob **Agricultura de Precisão** — ver seção 1b — apesar do prefixo de rota `agronomico/fertilidade/...`.)* Planeja campanhas: pontos de **coletas anteriores** (por safra) ou **grade regular** (recortada pelos polígonos, densidade ha/ponto); **perfis de profundidade** múltiplos (cada um com densidade); **tipo de análise** (Química/Foliar/Nematóide/DRES); arrastar pontos; **medição de distância**; **etiquetas com QR + código de barras (Code128)** geradas no cliente; campanhas salvas (criar/editar). Endpoints: `GET /fertilidade/depth-profiles|history-years|history-points|plans|plans/:id`, `POST/PUT /fertilidade/plans`.
- **Exportação de Nutrientes** (`agronomico/fertilidade/exportacao`) — IMPLEMENTADA. Mapa por talhão da **extração de nutrientes** = produtividade real (`FARM_FIELD_PLANTING`) × **coeficiente por cultura** (`FERT_CROP_EXPORT`, base ICL/Embrapa). Hover com média/ha e total produzido por cultura; categorias de nutriente; **alerta de produtividade fora da curva** e nota de área sem coeficiente. Endpoints em `/fertilidade/*` (+ `/seasons/productivity-outliers`).
- **Adubação de Corretivos** (`agronomico/fertilidade/corretivos`) — IMPLEMENTADA. Mapa + **dose de corretivos** (Calcário/Gesso/Fosfato) por talhão + pontos (`FERT_AMENDMENT_APPLICATION`).
- **Configurações** (`agronomico/fertilidade/configuracoes`) — IMPLEMENTADA. Edita as **visões de interpretação / níveis críticos** e os **coeficientes de exportação** por cultura (`FERT_CROP_EXPORT`) de verdade.
- **Mapas (VRA)** (`.../mapas`) — placeholder. *(No menu, esta folha fica sob **Agricultura de Precisão** — ver seção 1b — apesar do prefixo de rota `agronomico/fertilidade/...`.)* Estrutura de taxa variável (Adubação/Calagem/Gessagem/Semeadura/Aplicação) com **criação desabilitada** (aguarda backend VRA). Só `GET /fields`.

### Produtividade (`agronomico/produtividade`)
- **Analítico / Mapa de Produtividade** (`agronomico/produtividade`) — IMPLEMENTADA. Produtividade média **real** por talhão/pivô (`FARM_FIELD_PLANTING.productivity`, na unidade da cultura), **ponderada por área** (`wavg`). Cultura obrigatória; safra/variedade; filtro por **quinzena de plantio**. Cards média por fazenda/gleba/variedade (também filtram), top melhores/piores, contador de plantios sem produtividade lançada. `GET /productivity/map|cultures`.
- **Evolução** (`agronomico/evolucao`) — IMPLEMENTADA. Gráfico de linhas da produtividade média **por safra** (mesma cultura ao longo das safras); níveis Cultura/Variedade/Fazenda/Gleba/Talhão; modo **extremos** (10 melhores/10 piores); evolução de um pivô a partir do mapa. `GET /productivity/evolution`.
- **Estimativa** (`agronomico/produtividade/estimativa`) — IMPLEMENTADA. Estima o rendimento por **ponto/talhão** a partir dos componentes da **contagem Farmbox** (fórmula por cultura, `PROD_ESTIMATE_FORMULA`), valida vs a colheita real (erro %), com histórico por amostragem e **assertividade por amostrador**. Filtros: cultura, safra, **variedade** (card/filtro), **amostragem** (Mais recente — prefere a última data COM GPS — ou 1ª/2ª/3ª… ordinal), **amostrador** (card/filtro). Mapa: pivô colorido pela média + **mapa de calor intra-pivô** (IDW dos pontos) + legenda Baixo/Médio/Alto; cards média por fazenda/gleba/variedade. Config da fórmula em modal (nomes amigáveis dos parâmetros; peso da variedade como override, com fallback ao medido). `GET /estimate/map|cultures|configs|catalog`, `POST/DELETE /estimate/configs`. **O @/ha real é idêntico ao de Produtividade/Evolução** (mesma fonte + ponderação por área, via núcleo compartilhado `productivityCore`).

### Produtos Aplicados (`agronomico/produtos-aplicados`) — IMPLEMENTADA
**Mapa de produtos aplicados** (`ProdutosAplicadosPage`): mostra por talhão as aplicações registradas no Farmbox (dose média/ha, dose acumulada, intervalo entre aplicações). **Categoria obrigatória**; demais filtros opcionais: produto, variedade, cultura, safra, equipamento, fazenda. As opções de filtro presentes nas aplicações vêm de `GET /applications/refs`; o mapa + KPIs + cards vêm de `GET /applications/overview` (`category` obrigatória).

### Monitoramento (`agronomico/monitoramento`)
> Espelha e substitui a configuração que o agrônomo faz no Farmbox (limites de controle, tolerância, metodologia) e evolui o mapa de pragas. Categorias de alvo: **Doenças, Ervas Daninhas, Inimigos Naturais, Pragas**. **9 culturas** (inclui **Pousio** = "Pré Plantio/Pós Colheita" do Farmbox).

- **Limites de Controle** — IMPLEMENTADA. Edita os níveis de ação/dano por **categoria de alvo → cultura → alvo/estágio**, cada linha com **Controle/Dano Vegetativo** e **Controle/Dano Reprodutivo** (`FARM_PEST_THRESHOLD`: `action/damage_level` + `rep_action/rep_damage_level` por `pest_id`×`param_name`×`culture_id`). Editável no app (o que o agrônomo altera vira `source='app'` e é preservado no re-seed do CSV Farmbox). Pré-carregado com o seed das 9 culturas / 4 categorias.
- **Carência de Insumos** — IMPLEMENTADA. **Default por categoria** de produto (`FARM_PRODUCT_CARENCIA_DEFAULT`) + **override por produto** (`FARM_PRODUCT_CARENCIA`), com os dois prazos do Farmbox — **Reentrada** (pessoa entrar no talhão) e **Colheita**. A reentrada resolvida (override › default) alimenta o bloqueio de monitoramento na `VW_MONITOR_FIELD_STATUS`.
- **Mapa de Calor** (evoluído) — IMPLEMENTADA. Densidade de achados por ponto (`FARM_MONITORING_STOP_RESULT`), com **seletor de parâmetro** (praga/alvo), **contorno dos talhões** e **camada de fotos de campo** (`FARM_MONITORING_NOTE`) — **clique no ponto** abre a nota georreferenciada com descrição, autor e fotos (URLs S3).

### Em construção
Visão Geral, Recomendações, Insights.

---

## 1b. Agricultura de Precisão
Grupo próprio do menu (após Fertilidade). Folhas diretas **Mapas** e **Planejamento de Coleta** (rotas com prefixo `agronomico/fertilidade/...`, descritas na seção 1 › Fertilidade por afinidade temática) + subgrupo **Aplicação Aérea**.

### Aplicação Aérea
> Serviço `aereo/aereoService.ts`; API `/aereo`. Ciclo: importar o log de GPS do avião → visualizar/atribuir talhões às APs → analisar a AP contra voo + meteorologia.

- **Logs de Voo** (`agricultura-precisao/aereo/logs`) — IMPLEMENTADA. Importa o **arquivo `.log` do GPS do avião** (Air Tractor / GPS MapStar, formato binário `AS4.01/ATT`): arrastar/soltar o `.log` + cadastro do voo (nome, início/fim data-hora, **aeronave** — do cadastro de equipamentos, aéreos marcados com ✈, `GET /aereo/aircraft` —, **piloto** — do cadastro de pessoas, `GET /aereo/pilots` —, e **faixa/barra em m**, com auto-detecção pela trilha quando em branco). O backend decodifica a trilha, monta a cobertura aplicada e devolve as métricas (pontos, cobertura em ha, faixa). **Tabela dos logs importados** com piloto/aeronave/início, km voado, km aplicado, área coberta e **status** (`a atribuir` / `N AP(s)` quando já atribuído); linha leva a **Visualizar Voo**; excluir remove também a atribuição às APs. Endpoints: `POST /aereo/logs` (multipart), `GET /aereo/logs`, `GET /aereo/aircraft`, `GET /aereo/pilots`, `DELETE /aereo/logs/:id`.
- **Visualizar Voo** (`agricultura-precisao/aereo/visualizar`) — IMPLEMENTADA. Seletor de voo no topo; **mapa da trilha** (`FlightMap`) com talhões, cobertura (toggle) e realce por AP; **KPIs** do voo (duração, vel. média/máx, km aplicado com barra aberta, cobertura em ha, taxa L/ha ~, vazão L/min ~, faixa m). **Atribuição de talhões às APs**: a pré-análise lista os talhões tocados pela cobertura (com AP sugerida — a dominante) e o usuário escolhe a AP de cada talhão (ou "externo — fora de AP"); um voo pode ter várias APs. Ao salvar, recorta a cobertura por AP e reconcilia. **Reconciliação construtiva** por AP (este voo × acumulado união de todos os voos × buscado × %), usando o rollup construtivo da AP. Endpoints: `GET /aereo/logs`, `GET /aereo/logs/:id`, `GET /aereo/logs/:id/analyze` (pré-análise + AP sugerida), `POST /aereo/logs/:id/assign` (recorta e reconcilia), `GET /aereo/applications/:id` (rollup construtivo da AP).
- **Análise da AP** (`agricultura-precisao/aereo/analise`) — IMPLEMENTADA. **Análise AP × Voo × Meteorologia** (`AnaliseAPPage`, título "Análise da AP (Voo × Meteorologia)"). Filtros safra/cultura + seletor de **AP aérea** (`GET /aereo/analysis/refs`, `GET /aereo/analysis/apps`). Mapa em tela cheia com **heatmaps** por modo (Velocidade, Altitude, Manobras, Vazão, **Fechamento de faixa** — mostra falha % e sobreposição %) e toggle "Em operação" (só barra aberta, esconde manobras). Overlays de cards: **Dados da AP** (número, ha planejados, pivôs, cultura, safra/status/data), **Produtos / calda** (L/ha aplicada × planejada, volume total, lista de produtos com dosagem), **Operação** (rend. operacional voo × pulverização, sobreposição, falha, vazão, calda, veloc., área pulverizada, % a mais do planejado, horas de voo/barra), **Meteorologia** (temp/umidade/vento médio/rajada da janela do voo, estação e nº de leituras) e, ao clicar num pivô, um card **Pivô** (tempo, área física/aplicada, sobreposição, vazão média, taxa de pulverização, veloc./altitude médias). O voo por trás vem dos logs atribuídos à AP (`GET /aereo/logs/:id`). Endpoint principal: `GET /aereo/analysis/:id` (detalhe AP × Voo × Meteorologia). *(Endpoints correlatos: `GET /aereo/applications` lista as APs que já têm log — visão construtiva entre logs.)*

---

## 2. Operação (máquinas)
> Dados da integração Solinftec + ETL.

- **Visão Geral do Dia** (`operacao/visao-geral-dia`) — IMPLEMENTADA. Filtros data+fazenda. KPIs: horas produtivas, eficiência %, área (ha), consumo (L), nº equipamentos, horas improdutivas. Donut de tempo, barras por equipamento, tabela por operação, top paradas. Endpoint: `GET /operations/overview`.
- **Visão por Operação** (`operacao/por-operacao`) — IMPLEMENTADA. Filtros período+operação+equipamento+fazenda. KPIs: área, horas, pivôs, velocidade/RPM/L-ha médios, consumo. **Mapa de cobertura por pivô** (cor por % coberto), rankings por máquina/operador, paradas. Endpoint: `GET /operations/by-operation` (aceita também filtro por **hora-do-dia** `hours` CSV — `DATEPART(HOUR) IN`; usado no card do dashboard Satélite).
- **Apontamentos** — em construção.

---

## 3. Meteorologia
> `weatherService.ts`. Variáveis: chuva, temperatura, umidade, vento, **folha molhada**, radiação, orvalho, pressão.

- **Registro Geral** (`meteorologia/visao-geral`) — IMPLEMENTADA. Visão consolidada do período. Filtros: período, **horário** (faixas), variável, fazenda. Para chuva, mapa em **"Superfície"** (interpolação IDW) ou **"Por pivô"** (grid por talhão). KPIs: estações, chuva média/máx, temp, umidade, vento, radiação, folha molhada — **todos vindos do grid do backend**. Endpoint: `GET /weather/overview`.
- **Registro por Estação** (`meteorologia/por-estacao`) — IMPLEMENTADA. Filtros período+estação+fazenda. KPIs + **gráficos por hora (24h)** (chuva/temp/umidade/vento) + tabela horária + mapa. Endpoint: `GET /weather/by-station`.
- **Previsão do Tempo** (`meteorologia/previsao`) — IMPLEMENTADA. Open-Meteo (via backend): atual + 24h + 7 dias; vento/UV/pressão/orvalho/sol. Endpoint: `GET /weather/forecast`.
- **Janela Aplicação** (`meteorologia/janela-aplicacao`) — IMPLEMENTADA. Pulverização por **Delta T** (Ideal/Atenção/Impróprio) por hora; timeline 24h, janelas contíguas, tabela. Endpoint: `GET /weather/application-window`.

---

## 4. Administrador
- **Usuários** (`admin/usuarios`) — CRUD + busca + escopo de fazendas por usuário. `/users`, `/user-types`, `/sectors`, `/users/:id/farms`.
- **Tipos de Usuário** (`admin/tipos-usuario`) — CRUD de perfis + **matriz de permissões** por página (Ler/Criar-Editar/Excluir/Admin). `/user-types`, `/user-types/:id/access`.
- **Departamentos** (`admin/departamentos`) — CRUD de setores. `/sectors`.
- **Fazendas** (`admin/fazendas`) — CRUD (atualiza seletor global). `/farms`.
- **Glebas** (`admin/glebas`) — CRUD por fazenda. `/plots`.
- **Talhões** (`admin/talhoes`) — CRUD com **geometria (polígono)**, área e mapa; **importação em massa** de shapefile(.zip)/KML/KMZ/GeoJSON; seleção em massa (mover/excluir). Mostra um **aviso enxuto** (link) quando há talhões do Farmbox não cadastrados, levando à tela dedicada. `/fields`, `/fields/bulk-delete`, `/fields/bulk-move`.
- **Não Cadastrados** (`admin/nao-cadastrados`) — tela dedicada de **bootstrap a partir do Farmbox**: lista os plots do Farmbox que ainda não viraram talhão no GCS (com contorno), em **abas por fazenda do Farmbox**. Mostra os **contornos no mapa** e permite **editar nome e gleba talhão a talhão** (sugestões de glebas existentes; "gleba padrão" + aplicar a todos), escolher a **fazenda destino** (existente ou nova) e **cadastrar** — criando fazenda/gleba/talhões com o contorno e ligando o de/para plot→talhão. Tem **badge de alerta no menu** (contador na folha + ponto no subgrupo Fazendas e no grupo Administrador, via `UnmappedProvider`) e **estado vazio** quando não há pendências. `/fields/farmbox-unmapped`, `/fields/import-farmbox`.
- **Perfil** (`/app/perfil`) — dados pessoais + troca de senha. **Preferências** (tema + fazenda) persistidas por usuário via `GET/PUT /me/preferences` (ver seção 0). `/me`, `/me/password`.
- **Cultivos › Culturas** (`admin/culturas`) — IMPLEMENTADA. CRUD de culturas (nome, **unidade de produtividade** sc/@/t, cor); dedup por nome, alinhado ao backfill do Farmbox. `/culturas`.
- **Cultivos › Variedades / Híbridos** (`admin/variedades`) — IMPLEMENTADA. CRUD de variedades/híbridos por cultura (**tipo** cultivar/híbrido/linhagem) + **catálogo de características configurável** (por cultura: peso de capulho, peso de mil grãos, tecnologia RR/Bollgard…; valor por variedade), com opção de **ligar uma característica a um parâmetro da estimativa** (override do valor medido). `/variedades`, `/variety-traits`.

---

## 4b. Planejamento Agrícola
- **Safras** (`planejamento/safras`) — IMPLEMENTADA. Lista/gerencia safras e detecta **safras do Farmbox ainda não cadastradas** (respeitando a fazenda selecionada); registra em **cascata** (ciclo → cultura → variedade → plantio, via `backfillPlanningFromFarmbox`). Traz **revisão de produtividade fora da curva** (outliers acima/abaixo da mediana da cultura → modal de correção). `GET /seasons`, `/seasons/farmbox-unmapped`, `/seasons/productivity-outliers`, `/seasons/cultures`; `POST /seasons/import-farmbox`, `/seasons/backfill-planning`, `/seasons/review-planting`.
- **Programação de Rotação** (`planejamento/rotacao-de-cultura`) — IMPLEMENTADA. Grade de rotação por gleba × safra (mais novas primeiro), **edição interativa no mapa por pivô** (persiste em `FARM_FIELD_ROTATION`), **% cumprido** e desvios por talhão, importar programações do Farmbox (opt-in), visualizar safras antigas read-only. Endpoints de rotação em `/seasons/*` (`rotation.service.ts`).
- **Planejador** — em construção.

---

## 4b.1 Pesquisa (Ensaios de Faixa / strip test)
Grupo próprio do menu (**Pesquisa**, ícone microscópio), entre Agricultura de Precisão e Planejamento Agrícola. Registra **ensaios lado a lado**: variedades/híbridos cultivados em **faixas** no mesmo talhão e ciclo, para comparar produtividade em igualdade de condições. **Aditivo** — não toca `FARM_FIELD_PLANTING` (a safra segue com 1 plantio "principal" por talhão/ciclo); o ensaio é um dataset paralelo.
- **Ensaios de Faixa** (`pesquisa/ensaios`) — IMPLEMENTADA. Lista de ensaios (cards por talhão/fazenda/safra/cultura, nº de faixas/variedades, origem App/Farmbox), respeitando fazenda + safra do cabeçalho; busca; **Novo ensaio** (talhão + ciclo). 
- **Editor do ensaio** (`pesquisa/ensaios/:id`, fora do menu) — IMPLEMENTADA. Aba **Faixas**: mapa (`ResearchStripMap` — contorno do talhão + faixas coloridas por variedade) + tabela de faixas com **edição inline** (variedade, área, produtividade, observações; fila serial de saves) e **modal de polígono** (desenhar com `PolygonDrawMap` ou **importar KML/KMZ/SHP/GeoJSON**; área calculada pela geometria). Aba **Comparação**: produtividade/área por variedade lado a lado, % de área, Δ vs melhor, destaque do melhor.
- **Modelo:** `FARM_RESEARCH_TRIAL` (1 por talhão+ciclo) + `FARM_RESEARCH_STRIP` (N faixas: variedade + `geom` GEOGRAPHY + área + produtividade + `farmbox_plantation_id`). Endpoints `/research/*` (`research.service.ts`/`research.routes.ts`): `GET refs|trials|trials/:id|trials/:id/compare`; `POST trials|trials/:id/strips|backfill-farmbox`; `PUT trials/:id`; `DELETE trials/:id|strips/:id`.
- **Histórico:** `backfillResearchFromFarmbox()` recuperou do Farmbox os strip tests reais (plantações com ≥2 variedades no mesmo talhão+ciclo → **49 ensaios / 118 faixas**, com polígono do `geo_points`, área e produtividade por faixa).

---

## 4c. Painel de Operações
Grupo próprio do menu (após Irrigação, antes de Planejamento Agrícola).
- **Programações** (`painel-operacoes`) — IMPLEMENTADA. Lista de **programas de operação a campo** (abertura de área, expansão, tratos) com abas Todas/Minhas/Públicas, filtro por tipo (Agrícola/Estrutura/Manutenção) e busca; cada card tem ações ⚙ mapa · 📊 dashboard · ✏ editar · 🗑 excluir. **Nova programação** (tipo/safra/cultura/alvo). **Detalhe** em `painel-operacoes/programa/<titulo>-<id>` (URL por **slug**), com toggle **Mapa | Dashboard**:
  - **Mapa** (`OpsMap`): pivôs-alvo coloridos pelo avanço (cor vibrante, % no rótulo). **Hover** lista o progresso de **todas as operações** do pivô. Em painel **agrícola**, **clique no pivô** abre histórico + **lançamento de avanço por pivô** (medições ha/mm/dose/%/marco). Card **"Progresso por gleba"** e **filtro por operação** ("Progresso das Atividades": Geral | operação). Agrícola esconde Importar KML/aba Arquivos.
  - **Dashboard** (`OperacaoDashboard`): progresso por operação/equipe, ritmo e previsão.
  - Modelo **Programa → Etapa → Subetapa → lançamento** (progresso derivado); alvo por pivô; equipes GCS/terceirizadas; fontes manual/Solinftec/IrriControl/Farmbox. Endpoints `/ops/*` (`opsApi.ts`; back `ops.routes.ts`/`ops.service.ts`).

---

## 5. Integrações
- **Configurações APIs** (`integracoes/apis`) — catálogo central de credenciais/URLs (auth NONE/BASIC/TOKEN/APIKEY/OAUTH2); segredos cifrados (flags `has_*`). `/configs`.
- **Agendador** (`integracoes/agendador`) — orquestração dos jobs: ON/OFF, cadência, última/próxima execução, **rodar agora**, editar cadência, histórico. Polling 12s. `/scheduler/jobs`, `/scheduler/jobs/:id/run|history`.
- **Solinftec › Painel** (`integracoes/solinftec`) — dispara **integração** (API→raw) e **ETL** (raw→GCS_FARM) por fonte (Ambas/Meteorologia/Operação) + data; mostra pendências e histórico. `/solinftec/ingestions|integrate|etl`.
- **Solinftec › Cadastros** (`.../cadastros`) — importação de planilhas de dimensões com **detecção automática de tipo**, grid dinâmico, edição/exclusão, **alerta de códigos órfãos**. `/cadastros/*`.
- **Farmbox › Painel** (`integracoes/farmbox`) — centro de ingestão (API→raw) + ETL, com progresso ao vivo, histórico, sync incremental por grupo, resume/restart. `/farmbox/*`.
- **Farmbox › Configurações** (`.../config`) — conexão, catálogo de endpoints e **webhook** (registrar/remover). `/farmbox/config|endpoints|webhook`.
- **Em construção:** IrriControl (Painel + Config), NUTec (Painel + Config). *(Aparecem no Agendador como conectores, mas sem tela/serviço próprios.)* IrriControl já tem um **stub** consumido pelo dashboard de Satélite (ver Agronômico › Satélite): `GET /irrigation/overview` retorna os talhões com geometria, porém `status/appliedMm/pct = null` e `availableDates = []` — o mapa (`IrrigationMap`) mostra **"Irrigação — dados em breve"** até a ingestão (API IrriControl bloqueada 502/403; query real `CONNECTOR_GCS_FARM.IRRICONTROL_*` pendente).

---

## 6. Roadmap (em construção)
Dashboard (3 modelos — **mockup**: Executivo/Fertilidade/Planejamento); Agronômico (Visão Geral, Recomendações, Insights); Operação (Apontamentos); Planejamento Agrícola (Planejador); Irrigação (Gestão de Lâmina, Programado × Executado, Evapotranspiração); Estoque; Oficina; RH; Relatórios; IrriControl; NUTec.

---

## Resumo do estado
**Atualizado:** 2026-07-07 (inclui Aplicação Aérea e Mapa de Produtos Aplicados).
**Telas reais:** Satélite (**dashboard comparativo 1/2/4** com 5 componentes por painel, câmera sincronizada e modo imersivo; Irrigação entra como **stub** "dados em breve"); **Produtos Aplicados (mapa de aplicações Farmbox por talhão)**; Fertilidade (Análise de Solo, Planejamento de Coleta, **Exportação de Nutrientes**, **Adubação de Corretivos**, **Configurações**, Mapas-placeholder); **Produtividade (Analítico, Evolução, Estimativa)**; **Agricultura de Precisão › Aplicação Aérea (Logs de Voo, Visualizar Voo, Análise da AP — import do `.log` do Air Tractor, atribuição talhão→AP e análise AP × Voo × Meteorologia com heatmaps)**; Operação (Visão do Dia, Por Operação); Meteorologia (Registro Geral, Por Estação, Previsão, Janela de Aplicação); **Planejamento Agrícola (Safras, Programação de Rotação)**; **Painel de Operações (Programações — mapa por pivô + dashboard)**; Admin (Usuários, Tipos, Departamentos, Fazendas, Glebas, Talhões, Não Cadastrados, **Culturas, Variedades/Híbridos**, Perfil); Integrações (Config APIs, Agendador, Solinftec Painel/Cadastros, Farmbox Painel/Config). **Rotas fora do `navConfig`:** Perfil (`/app/perfil`) e LandingPage (`/`).
**Base:** sessão em `localStorage` (persiste entre abas); multi-seleção de fazenda no cabeçalho (`IN`); **seletor de safra** no cabeçalho (single, por fazenda); preferências (tema+fazenda) persistidas por usuário; cabeçalho exibe o nome do usuário. Menu oculta Estoque/Oficina/RH/Relatórios.
**Produtividade — fonte única:** o "@/ha real" é o mesmo em Produtividade, Evolução e Estimativa (`FARM_FIELD_PLANTING.productivity`, média ponderada por área via `productivityCore`).
