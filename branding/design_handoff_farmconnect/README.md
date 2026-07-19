# Handoff: FarmConnect — Marca + UI + Telas

## Overview
FarmConnect é uma plataforma de **agricultura digital** que conecta todas as fontes de dado de uma fazenda (telemetria de máquinas, logs de pulverização, análises de solo, imagens de satélite, mapas de taxa variável, irrigação e sensores) e — o diferencial — **atua como decisor**: a partir dos dados, entrega estratégias, planos de ação e recomendações com IA.

Este pacote contém a **marca completa** (logo, paleta, tipografia) e um **sistema de UI** com telas prontas: login, landing page e o app shell (navegação + estados). O objetivo é reformatar o app web já existente para este novo layout/branding.

Posicionamento da marca: *"A fazenda conectada que decide com você."* Assinatura: **by GCS Agro**.

## About the Design Files
Os arquivos `.dc.html` neste bundle são **referências de design criadas em HTML** — protótipos que mostram aparência e comportamento pretendidos, **não código de produção para copiar diretamente**. Eles usam um pequeno runtime próprio (`support.js`, um mini-framework de componentes) só para o protótipo funcionar isoladamente — **ignore esse runtime**.

A tarefa é **recriar estes designs no ambiente do codebase existente** (React/Vue/etc.), usando os padrões, componentes e bibliotecas já estabelecidos ali. Toda a estilização usa **estilos inline** nos protótipos apenas por conveniência do formato; no codebase real, traduza para o sistema de estilo em uso (CSS Modules, Tailwind, styled-components, tokens, etc.).

## Fidelity
**Alta fidelidade (hifi).** Cores, tipografia, espaçamentos, raios e interações são finais e devem ser recriados fielmente. Todos os valores exatos estão em *Design Tokens* abaixo.

## Marca (Branding)

### Nome e wordmark
- Texto: **FarmConnect** (uma palavra, duas maiúsculas internas: "Farm" + "Connect").
- Wordmark: "Farm" na cor de texto (`--fg`) + "Connect" na cor de acento (`--accent`). Fonte **Space Grotesk 600**, `letter-spacing: -0.02em` a `-0.035em` conforme o tamanho.
- Monograma / app icon: **FC** — "F" em `--fg`/branco e "C" em `--accent`, Space Grotesk 600.

### Símbolo
Uma **malha de nós conectados** (rede radial): um nó central (hub) com 4 satélites ligados por linhas retas, mais um 5º nó no topo destacado na cor de acento. Conceito: cada nó é uma fonte de dado; o nó de acento é o hub que reúne tudo e vira decisão.

SVG canônico (viewBox 0 0 48 48) — `NODE` = cor dos nós, `ACCENT` = nó de destaque:
```html
<svg width="48" height="48" viewBox="0 0 48 48" fill="none">
  <g stroke="NODE" stroke-width="2" stroke-linecap="round">
    <line x1="24" y1="24" x2="24" y2="9"/>
    <line x1="24" y1="24" x2="38.3" y2="19.4"/>
    <line x1="24" y1="24" x2="32.8" y2="36.1"/>
    <line x1="24" y1="24" x2="15.2" y2="36.1"/>
    <line x1="24" y1="24" x2="9.7" y2="19.4"/>
  </g>
  <!-- anel externo opcional (contorno), stroke-width 1.4 opacity .4 ligando os satélites -->
  <g fill="NODE">
    <circle cx="24" cy="24" r="3"/>
    <circle cx="38.3" cy="19.4" r="2.8"/>
    <circle cx="32.8" cy="36.1" r="2.8"/>
    <circle cx="15.2" cy="36.1" r="2.8"/>
    <circle cx="9.7" cy="19.4" r="2.8"/>
  </g>
  <circle cx="24" cy="9" r="4" fill="ACCENT"/>
</svg>
```
Variações no sistema (ver `FarmConnect Logo System.dc.html`): **primária** (malha sólida), **contorno** (nós vazados), **constelação** (rede assimétrica), **selo** (dentro de tile arredondado rx=11), **mínima/favicon** (hub + 3 satélites, para 16–24px).
- Uso sobre claro: nós em `#1a2320`, acento `#12946b`.
- Uso sobre escuro: nós em `#eaf2ee`, acento `#2fcf9a`.
- Uso sobre acento (esmeralda): tudo branco (`#fff`).
- **Descartado pelo cliente:** conceito "F em nós" — não usar.

### Tipografia
- **Space Grotesk** (600): marca, títulos, números/métricas grandes.
- **Inter** (400/500/600/700): interface, corpo, labels, botões.
- Monospace do sistema (`ui-monospace`): apenas metadados/valores técnicos e códigos hex nos guias.
- Ambas via Google Fonts. Sem serifa (requisito do cliente).

## Design Tokens

### Paleta escolhida: **Graphite & Emerald**
Base grafite neutra (deixa dados/gráficos respirarem) + esmeralda como ação/decisão/positivo. Acento entra apenas em ações, seleção e recomendações.

Escala esmeralda: `50 #E6F5EF` · `100 #BFE8D7` · `300 #5CC9A5` · **`500 #12946B` (base)** · `700 #0B6B4E` · `900 #083F2F`.

### Tokens semânticos (light / dark)
| Token | Light | Dark |
|---|---|---|
| `--bg` (fundo app) | `#F1F3F2` | `#0C1210` |
| `--surface` (cards/superfície) | `#FFFFFF` | `#121A17` |
| `--surface2` (superfície 2 / hover) | `#E9EDEC` | `#1B2723` |
| `--border` | `#DBE1DF` | `#263630` |
| `--fg` (texto) | `#1A2320` | `#EAF2EE` |
| `--muted` (texto secundário) | `#64716C` | `#8BA097` |
| `--accent` | `#12946B` | `#2FCF9A` |
| `--accent-strong` (hover) | `#0F8A64` | `#5BE0B4` |
| `--primary-soft` (fundo suave do acento) | `#E2F2EC` | `#16332A` |
| `--on-accent` (texto sobre acento) | `#FFFFFF` | `#0C1210` |

### Cores funcionais (light / dark)
| Função | Light | Dark | Soft (light / dark) |
|---|---|---|---|
| Sucesso `--ok` | `#1A9E73` | `#35C98F` | `#E4F5EE` / `#12271F` |
| Alerta `--warn` | `#C08A2C` | `#D9B24E` | `#F7EFDB` / `#2A2415` |
| Erro `--err` | `#C8452F` | `#E06A52` | `#F9E7E2` / `#2C1A15` |
| Info `--info` | `#3F77B0` | `#6AA3D9` | `#E6EEF7` / `#152230` |

> **Nota tema/acento:** o acento é **automático por tema** (light `#12946B`, dark `#2FCF9A`). Não fixar o acento claro no dark — foi um bug corrigido. Se oferecer troca de acento, sobrepor por cima do valor do tema; alternativas curadas: `#12946B`, `#0F857A`, `#C9A253`, `#BD6A48`.

### Espaçamento e forma
- **Border radius:** botões/inputs `10–11px`; cards `14–16px`; containers grandes/hero `18–22px`; pills/badges `999px`; ícones em tile `8–12px`.
- **Padding típico:** cards `16–26px`; botões médios `11px 18px`; inputs `11–12px` (com ícone à esquerda, `padding-left: 36–38px`).
- **Gaps de layout:** grids de cards `14–16px`; seções verticais `18px`.
- **Larguras de conteúdo:** app `max-width 1080px`; landing `1160px`; guias `1120px`.

### Sombras
- Card elevado / modal: `0 40px 80px -40px rgba(0,0,0,.4)` (e até `0 40px 90px -30px rgba(0,0,0,.6)` no modal).
- Toast: `0 16px 36px -16px rgba(0,0,0,.4)`.
- FAB / botão flutuante: `0 10px 24px -10px` com o acento a ~70%.

### Transições
- Tema: `background .35s ease, color .35s ease`.
- Switch/checkbox/radio: `.15s`; chevrons de select: `transform .2s`.
- Sidebar recolher: `grid-template-columns .22s ease`.
- Toast entrada: `fctoastin .25s ease` (fade + translateX 20px→0).
- Skeleton: shimmer `1.3s` linear infinito (gradiente 90deg deslizando).

## Screens / Views

### 1. Login (`FarmConnect Login.dc.html`)
- **Purpose:** autenticar o usuário (agrônomo/consultor ou gestor).
- **Layout:** grid 2 colunas `1fr 1fr`, altura 100vh. Esquerda = formulário; direita = painel de marca. (Em mobile, colapsar para 1 coluna e ocultar o painel de marca.)
- **Coluna do formulário:** topo com wordmark + toggle de tema (pill). Centro: card de largura máx `376px` com:
  - H1 "Bem-vindo de volta" (Space Grotesk 600, 29px) + subtítulo muted.
  - Dois botões sociais lado a lado (**Google**, **SSO**), 1fr cada, borda `--border`, radius 11px.
  - Divisor "ou entre com e-mail".
  - Campo **E-mail** (ícone envelope à esquerda) e **Senha** (ícone cadeado + botão olho para mostrar/ocultar).
  - Checkbox custom "Manter conectado" (marcado por padrão).
  - Botão **Entrar** full-width, acento, com spinner em loading (label vira "Entrando…", ~1,6s simulado).
  - Link "Não tem conta? Falar com a GCS".
  - Rodapé "© 2026 FarmConnect · by GCS Agro".
- **Painel de marca (direita):** fundo `linear-gradient(150deg,#0B3D2E,#0C1210)`, textura de linhas diagonais, símbolo grande flutuando (opacity .16, `fcfloat` 6s), depoimento (Space Grotesk 500, 26px), autor "João Ricardo · Gestor · Fazenda Santa Clara · 1.240 ha", e 3 métricas (6 fontes conectadas / +18% eficiência de N / 4 min dado ao vivo).

### 2. Landing page (`FarmConnect Landing.dc.html`)
- **Purpose:** apresentar o produto e converter em "Agendar demo".
- **Header** sticky, blur, `max-width 1160px`: wordmark + nav (Recursos, Como funciona, Planos) + toggle tema + "Entrar" + botão "Agendar demo".
- **Hero:** grid `1.05fr 0.95fr`. Esquerda: badge pill, H1 52px (Space Grotesk 600, "decide" em acento), parágrafo, 2 CTAs ("Agendar demo" sólido + "Ver em 2 min" outline), 3 métricas (+2,4M ha / 6 fontes / +18%). Direita: mock do painel (janela com traffic-lights, 3 mini-métricas, faixa de satélite/NDVI, cartão "Recomendação da IA"), com glow radial de acento atrás.
- **Faixa de integrações:** "Conecta com o que sua fazenda já usa" + chips (John Deere Ops, Climate, Sentinel-2, Trimble, Sensores IoT).
- **Recursos:** grid de 6 cards com ícone (tile `--primary-soft`), título e descrição: Telemetria de máquinas, Satélite & NDVI, Taxa variável, Solo & irrigação, Decisor com IA, Relatórios & manejo.
- **Como funciona:** 3 passos numerados (círculos de acento): Conecte suas fontes → Veja tudo integrado → Receba o plano.
- **CTA final:** bloco gradiente escuro (mesmo do login) com H2 "Pronto para decidir com dados?", 2 botões (branco + translúcido) e símbolo flutuante.
- **Footer:** wordmark + "© 2026 FarmConnect · by GCS Agro".

### 3. App shell (`FarmConnect App Shell.dc.html`)
- **Purpose:** casca de navegação do app + demonstração de estados (dados / carregando / vazio) e toasts.
- **Layout:** grid `236px 1fr` (recolhido `72px 1fr`, transição .22s). Sidebar sticky altura 100vh.
- **Sidebar:** wordmark no topo (label some quando recolhido, `opacity 0`); itens de nav com ícone + label: Visão geral, Telemetria, Pulverização, Satélite, Solo & sensores, Irrigação, (divisor), Plano de ação; rodapé fixo "Configurações". Item ativo: texto `--accent-strong`, fundo `--primary-soft`, weight 600.
- **Topbar** sticky, blur: botão hambúrguer (recolhe a sidebar), breadcrumb "Santa Clara / <seção>", busca (ícone), sino de notificações (com dot de erro — dispara toast), toggle tema, avatar "JR".
- **Conteúdo:** título da seção + subtítulo; ações à direita: "Simular carregando", "Estado vazio", "Gerar plano" (dispara toast). Três estados exclusivos:
  - **Dados** (padrão): 4 cards de métrica (Máquinas 8/12, Pulverizado 148 ha, Umidade 62%, NDVI 0,74 ▲) + grid `1.5fr 1fr` com "Mapa de taxa variável" (placeholder listrado) e card "Recomendações" (3 itens + botão "Aplicar plano").
  - **Carregando:** blocos skeleton com shimmer (4 métricas + 2 painéis), auto-volta para Dados em ~2,2s.
  - **Vazio:** card com borda tracejada, símbolo em tile, "Nenhuma fonte conectada ainda", descrição e 2 botões (Conectar fonte / Ver dados de exemplo).
- **Toasts:** canto inferior direito, largura 340px, empilhados; borda esquerda 3px na cor da função; ícone circular; título + mensagem + botão fechar; auto-dismiss ~4,2s. 4 variantes ciclam: sucesso, alerta, info, erro.

## Componentes de UI (referência: `FarmConnect UI Kit.dc.html`)
Catálogo completo com estados reais. Pontos de atenção (pedidos explícitos do cliente):
- **Sem o azul padrão do navegador** em seleção. Checkbox, radio e switch são **customizados** em esmeralda.
  - Checkbox: box 19–20px, radius 6px, borda 2px; marcado = fundo `--accent` + check branco (SVG path `M5 12l4.5 4.5L19 7`).
  - Radio: círculo 20px, borda 2px; marcado = borda de acento + dot central 9px de acento (scale 0.3→1).
  - Switch: trilho 44×26px radius 999px; knob branco 20px; ligado = fundo `--accent`, knob `translateX(18px)`.
- **Select estilizado** (sem a caixa/dropdown nativo do SO): é um `<button>` + painel próprio com overlay de clique-fora, itens com hover `--surface2`, chevron que gira 180° ao abrir. Usado no formulário e dentro do modal.
- **Botões:** primário (acento), secundário (borda), fantasma (hover surface2), perigo (`--err`), texto. Tamanhos P/M/G. **Com ícone** à esquerda e à direita, **só-ícone** (40px) e **FAB** (52px, circular, sombra de acento). Ícones são SVG stroke `currentColor` width 2 (estilo Lucide/Feather).
- **Segmented control:** trilho `--surface2` radius 10px, opção ativa vira `--surface` com sombra sutil.
- **Cards:** métrica, feature (ícone+CTA), satélite (com faixa listrada), tarefa (ícone + 2 botões).
- **Badges/chips:** status com dot (ok/warn/err/info em cor + soft), sólidos (Novo/Beta), removível (× em círculo), contador numérico.
- **Alertas:** 4 tipos, fundo soft + borda na cor da função (via `color-mix`), ícone circular.
- **Abas + tabela:** abas com underline de acento no ativo; tabela de talhões (Talhão / Cultura / NDVI / Status com badge), header `--surface2`, linhas com hover.
- **Barra de progresso:** trilho `--surface2`, preenchimento de acento, radius 999px.
- **Dropdown/menu:** botão + painel com overlay clique-fora, item destrutivo em `--err`.
- **Modal:** overlay `rgba(6,12,10,.55)` + blur; card centrado max 440px; header (título + subtítulo + ×), corpo (select estilizado + checkbox custom), footer com Cancelar/Gerar.

### Mapa (satélite) — seção do UI Kit
- Container radius 18px, altura mín ~460px, fundo escuro com textura de linhas cruzadas (placeholder de imagem de satélite — **plugar camada real depois**, ex.: Mapbox/Leaflet + tiles Sentinel-2).
- Manchas coloridas translúcidas = zonas (ok/warn/err) sugerindo NDVI.
- **Controles sobrepostos** (todos em painéis glass: `color-mix(surface 86%, transparent)` + `backdrop-filter: blur(8px)` + borda translúcida):
  - Topo-esquerda: segmented de camadas (Satélite / NDVI / Solo).
  - Abaixo: dropdown de talhão (Todos / 04 / 07 / 12) + chips de filtro (cultura, data).
  - Topo-direita: botões só-ícone (layers, fullscreen).
  - Direita-centro: zoom +/− (estado `zoom` 4–20).
  - Pins: hub com anim `fcping`, pin de alerta.
  - Base-esquerda: legenda gradiente NDVI (`linear-gradient(90deg,#C8452F,#D9B24E,#1A9E73)`) + "zoom N".
  - Base-direita: botão "Gerar mapa de taxa variável".

## Interactions & Behavior
- **Toggle de tema:** alterna light/dark; persistir preferência do usuário (localStorage ou perfil). Padrão light.
- **Sidebar recolher:** hambúrguer alterna 236px↔72px; labels fazem fade (opacity), ícones permanecem.
- **Select/dropdown/menu:** abrem com overlay `position:fixed; inset:0` capturando clique-fora para fechar; fechar também ao escolher item.
- **Senha:** botão olho alterna `type` password/text.
- **Login submit:** entra em loading (spinner, "Entrando…"), ~1,6s; ligar à autenticação real.
- **Skeleton:** "Simular carregando" mostra shimmer ~2,2s e volta a Dados; no app real, exibir durante fetch.
- **Estado vazio:** quando não há fontes/dados; CTAs levam a conectar fonte.
- **Toasts:** empilham no canto; auto-dismiss ~4,2s; fechável no ×; usar para confirmações (plano aplicado), avisos e erros.
- **Hover:** botões escurecem para `--accent-strong` (primário) ou ganham borda de acento (secundário); itens de lista/menu vão para `--surface2`.

## State Management
- `theme` (light|dark) — global, persistido.
- `accent` — opcional, sobrepõe o acento do tema.
- Sidebar: `collapsed` (bool); `nav` (seção ativa).
- App: `view` ('data' | 'loading' | 'empty').
- Toasts: fila `[{id, kind, title, msg}]`; push/dismiss; timeout de auto-remoção.
- Login: `email`, `pw`, `showPw`, `remember`, `loading`.
- Selects/menus: flags de aberto/fechado + valor selecionado.
- Sliders (UI kit): valores numéricos ligados a label e barra de progresso.
- Zoom do mapa: inteiro 4–20.
- **Data fetching:** telemetria/solo/satélite/etc. vêm de integrações externas (John Deere Ops, Climate, Sentinel-2, Trimble, IoT). As recomendações vêm do motor de decisão/IA. Definir loading e empty states por fonte.

## Assets
- **Fontes:** Space Grotesk + Inter (Google Fonts). Trocar pelos webfonts self-hosted no codebase se preferível.
- **Ícones:** SVG inline estilo stroke (Lucide/Feather). Recomenda-se usar a lib de ícones já adotada no codebase, mantendo `stroke-width: 2`.
- **Logo/símbolo:** SVG próprio (acima) — nenhum arquivo binário necessário; recriar como componente `<Logo>` / `<LogoMark>` parametrizável por cor.
- **Ícone do Google:** SVG multicolor inline no botão social.
- **Imagens de satélite/mapa:** placeholders (texturas CSS). Substituir por camada de mapa real.
- Nenhuma imagem rasterizada é usada; tudo é SVG/CSS.

## Files
Protótipos de referência incluídos neste bundle:
- `FarmConnect Login.dc.html` — tela de login.
- `FarmConnect Landing.dc.html` — landing page.
- `FarmConnect App Shell.dc.html` — casca do app (sidebar + topbar + estados + toasts).
- `FarmConnect UI Kit.dc.html` — catálogo de componentes (botões, forms, seleção, sliders, cards, badges, alertas, abas, tabela, progresso, dropdown, modal, mapa).
- `FarmConnect Brand Guide.dc.html` — guia de marca (logo, símbolo, paleta, tipografia, aplicação no painel).
- `FarmConnect Logo System.dc.html` — variações do símbolo + redução responsiva/favicon.
- `FarmConnect Palettes.dc.html` — as 3 direções de paleta exploradas (contexto; a escolhida é Graphite & Emerald).

> **Ignorar** o arquivo `support.js` (runtime dos protótipos) — não faz parte do design nem deve ir para produção.

## Screenshots
Renders de referência em `screenshots/`:
- `01-login.png` / `02-login-dark.png` — tela de login (light e dark).
- `03-landing.png` — landing page.
- `04-app-shell.png` — casca do app (sidebar + topbar + estado de dados).
- `05-ui-kit.png` — catálogo de componentes.
- `06-brand-guide.png` — guia de marca.

Para qualquer tela, abrir o `.dc.html` correspondente no navegador dá a versão interativa e permite alternar light/dark pelo toggle.
