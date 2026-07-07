# SOLINFTEC — ETL de Clima e Grid por Talhão (IDW)

**Versão:** v1 · **Data:** 2026-06-28 · **Bancos:** CONNECTOR_GCS_FARM (raw) → GCS_FARM (master)

Documenta a reformulação do clima do SOLINFTEC: correção do timeout do ETL, o novo
modelo de "sensor solteiro" e o grid de clima por talhão (fonte da verdade para KPIs,
mapa de calor e cruzamento com a telemetria das máquinas).

---

## 1. Contexto — o erro que originou tudo

O job `solinftec.etl` (agendador) e o botão do Painel (`POST /solinftec/etl`) chamam o
**mesmo** `runEtl()` (`etl.service.ts`). O job estourava com
`Timeout: Request failed to complete in 120000ms` (120,5 s).

**Causa raiz:** o passo `enrichWeatherStationGeo` derivava o talhão de cada estação por
interseção espacial. O fallback "talhão mais próximo até 1 km" usava
`STDistance(...) ORDER BY STDistance`, que **não usa índice espacial** → calculava a
distância de todas as estações × 164 polígonos (até 2.521 vértices) a cada ETL → ~7 min.

## 2. Decisão de arquitetura — sensor "solteiro"

Abandonado o vínculo fixo estação→talhão. O sensor é apenas um **ponto (lat/long)** que
mede. A chuva/temperatura/etc. **por talhão** vem de **interpolação IDW** entre os
sensores — não de um rateio manual (que mentia em chuva de manga).

- `enrichWeatherStationGeo` agora só promove lat/long/tipo do cadastro p/ `WEATHER_STATION`.
- `WEATHER_STATION.field_id` / `farm_id` viraram **legado** (não mais populados).
- Cada métrica tem seu próprio conjunto de sensores: chuva ≈ todos; temp/umidade/etc.
  só as estações completas (grid mais ralo).

## 3. Tabelas (GCS_FARM)

### FIELD_WEATHER_HOURLY — dado bruto por talhão × dia × hora
Granularidade **horária** (as leituras já são horárias: 24/dia/estação). O diário sai
por agregação (chuva SUM, vento máx por MAX, demais AVG).

| Coluna | Tipo | Nota |
|---|---|---|
| field_id | BIGINT | → FARM_FIELDS |
| obs_date | DATE | dia |
| obs_hour | TINYINT | hora 0..23 |
| rain_mm | DECIMAL(9,4) | chuva (todos os sensores) |
| temp_c, humidity_pct, wind_kmh, wind_max_kmh, solar_radiation, dew_point_c, atm_pressure, leaf_wetness_pct | DECIMAL(9,4) | demais métricas |
| computed_at | DATETIME2 | |

PK (field_id, obs_date, obs_hour) · IX (obs_date) · FK field_id → FARM_FIELDS.

### FIELD_WEATHER_COVERAGE — confiança por talhão × métrica
Distância ao sensor mais próximo que **mede** cada métrica (+ nº de sensores). Constante
no tempo (sensores fixos); recalculada junto do grid. Ex. real: chuva ~2,6 km / 26
sensores (denso) vs temp/umidade ~5,8 km / 3 (ralo).

PK (field_id, metric).

## 4. Cálculo (weatherGrid.service.ts)

IDW **idêntico ao front** (`WeatherMap.idwAt`): peso `1/d^2,4`, distância² em graus,
amostrado no **centroide** do talhão (média do anel externo). Por isso o número gravado
é igual ao que o mapa desenha (validado: maxDiff ≤ 5e-5).

- `recomputeFieldWeatherHourly(start, end)` — MERGE idempotente por (field_id, obs_date, obs_hour), em lotes de 500 (TVC do SQL Server limita 1000).
- `recomputeCoverage()` — confiança por métrica.
- Disparado pelo ETL de chuva (`etlWeather`) com janela **gap-aware**: recalcula os dias
  com leitura ausentes no grid (rebuild/backfill) + os últimos 3 dias (correções recentes).

## 5. Endpoint

`GET /weather/field-weather?start=&end=&farm=&grain=day|hour`
- `grain=day` (padrão): agrega as horas por talhão (chuva soma, vento máx, demais média).
- `grain=hour`: devolve talhão × dia × hora (base p/ cruzar com `MACHINE_OPERATION_FACT`).
- Filtro por fazenda via talhão → gleba → fazenda.

`weatherOverview` (dashboard) puxa **todas as métricas por talhão do grid**; os KPIs do
painel passam a ser do grid (escopados por fazenda). KPIs medidos pelas estações seguem
suportados (derivam dos mesmos sensores, agora agregados por talhão).

## 6. Validação

- Bateria horária completa: **391.140 comparações** (14 dias × 24 h × 9 métricas × 164
  talhões), maxDiff ≤ 5e-5 → backend gravado == IDW do front, hora a hora.
- Teste do zero: limpou o clima do master + marcou o raw como não processado + rodou o
  ETL → reconstruiu 26 estações (com geo), 7.167 leituras, grid de 12/12 dias, cobertura
  164 × 9 — tudo fiel à fonte, ~41 s.

## 7. Arquivos

- Backend: `services/weatherGrid.service.ts` (novo), `services/etl.service.ts`,
  `services/weather.service.ts`, `routes/weather.routes.ts`.
- Front: `components/map/WeatherMap.tsx`, `farm/weatherService.ts`,
  `pages/meteorologia/MeteorologiaDashboardPage.tsx` (chip "Folha molhada").
- DDL: neste setup (`GCS_databases_full_setup_mssql.sql`, seção GCS_FARM master, após WEATHER_READING).
