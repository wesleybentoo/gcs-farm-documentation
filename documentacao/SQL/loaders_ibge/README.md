# Loaders IBGE — carga reprodutível da camada geográfica (Fase 2b)

Scripts que carregam a **hierarquia** e os **polígonos** oficiais do IBGE em `GEO_UNIT` / `REF_BIOMA`
(criados por `../MODULE_GEO_V1.sql`) e derivam o carimbo geográfico dos talhões por point-in-polygon.
Fonte 100% oficial (APIs `servicodados.ibge.gov.br` + shapefile de biomas do `geoftp.ibge.gov.br`).
Aplicado no `GCS_FARM_TEST`. Python 3 + `pyshp` (`pip install pyshp`). Coloque os arquivos baixados
na mesma pasta dos scripts (eles leem/gravam ali).

## Ordem

1. **Estrutura:** aplicar `../MODULE_GEO_V1.sql`.

2. **Hierarquia** (27 UF / 137 mesorregiões=MACRO / 558 microrregiões=MICRO / 5.570 municípios):
   ```
   curl -s "https://servicodados.ibge.gov.br/api/v1/localidades/municipios" -o municipios.json
   python gen_geo_seed.py          # gera geo_seed.sql (staging + inserts resolvendo pai por ibge_id)
   sqlcmd ... -f 65001 -I -i geo_seed.sql
   ```

3. **Polígonos municipais** (por UF onde há talhões — ex.: BA=29, PI=22):
   ```
   curl -s "https://servicodados.ibge.gov.br/api/v3/malhas/estados/29?intrarregiao=municipio&formato=application/vnd.geo+json&qualidade=intermediaria" -o malha_29.geojson
   curl -s "https://servicodados.ibge.gov.br/api/v3/malhas/estados/22?intrarregiao=municipio&formato=application/vnd.geo+json&qualidade=intermediaria" -o malha_22.geojson
   python gen_geo_polys.py         # gera poly_seed.sql (UPDATE GEO_UNIT.geom; MakeValid + reorient se invertido)
   sqlcmd ... -I -i poly_seed.sql
   -- depois: CREATE SPATIAL INDEX SIX_GEO_UNIT_geom ON GEO_UNIT(geom) USING GEOGRAPHY_AUTO_GRID; (requer -I)
   ```

4. **Biomas** (6 polígonos continentais, escala 5.000k):
   ```
   curl -s "https://geoftp.ibge.gov.br/informacoes_ambientais/estudos_ambientais/biomas/vetores/Biomas_5000mil.zip" -o biomas.zip
   unzip -o biomas.zip -d biomas_shp
   python gen_biomas.py            # gera biomas_seed.sql (orienta anéis CCW; UPDATE REF_BIOMA.geom)
   sqlcmd ... -I -i biomas_seed.sql
   -- CREATE SPATIAL INDEX SIX_REF_BIOMA_geom ON REF_BIOMA(geom) USING GEOGRAPHY_AUTO_GRID;
   ```

5. **Derivação** (carimbo no talhão + predominante no município), por point-in-polygon do centroide
   (`geom.EnvelopeCenter()`); município usa também maior-área p/ flag `geo_crosses_boundary`.

## Notas / gotchas
- Malhas em **SIRGAS 2000** (≈ WGS84) → tratadas como SRID 4326.
- **Orientação de anel:** shapefile usa horário p/ exterior; `geography` quer anti-horário → `gen_biomas.py`
  força CCW (shoelace) e o SQL faz `MakeValid()` + `ReorientObject()` se a área passar de meia-esfera.
- DBF do IBGE é **latin-1** (não utf-8) → `shapefile.Reader(..., encoding='latin-1')`.
- Spatial index exige `SET QUOTED_IDENTIFIER ON` → passar **`-I`** no sqlcmd.
- Malha de biomas a 5.000k é grossa: ~2 municípios de borda podem ficar sem `bioma_predominante`
  (aceitável nesse nível; usar escala maior se precisar de precisão de divisa).

## Resultado da 1ª carga (GCS_FARM_TEST)
5.570 municípios (0 órfãos) · 641 polígonos municipais BA+PI · 6 biomas (áreas batendo:
Cerrado ~2.027 mil km², Amazônia ~4.081) · **209 talhões carimbados** (Jaborandi-BA 175,
Monte Alegre-PI 16, Gilbués-PI 16; 6 cruzam divisa) · **207 talhões bioma=Cerrado**.
