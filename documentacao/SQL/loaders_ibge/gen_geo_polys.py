import json, io, os
SP = os.path.dirname(os.path.abspath(__file__))

def ring(r):
    return "(" + ",".join("%.6f %.6f" % (p[0], p[1]) for p in r) + ")"
def wkt(geom):
    t = geom['type']; c = geom['coordinates']
    if t == 'Polygon':
        return "POLYGON(" + ",".join(ring(r) for r in c) + ")"
    if t == 'MultiPolygon':
        return "MULTIPOLYGON(" + ",".join("(" + ",".join(ring(r) for r in poly) + ")" for poly in c) + ")"
    raise ValueError(t)

rows = []  # (codarea_int, wkt)
for uf in (29, 22):
    d = json.load(open(os.path.join(SP, 'malha_%d.geojson' % uf), encoding='utf-8'))
    for f in d['features']:
        cod = int(f['properties']['codarea'])
        rows.append((cod, wkt(f['geometry'])))

out = io.open(os.path.join(SP, 'poly_seed.sql'), 'w', encoding='utf-8')
out.write("SET NOCOUNT ON;\n")
CH = 100
for i in range(0, len(rows), CH):
    out.write("DECLARE @w NVARCHAR(MAX), @g geography;\n")
    for (cod, w) in rows[i:i+CH]:
        out.write("SET @w=N'%s'; SET @g=geography::STGeomFromText(@w,4326).MakeValid(); IF @g.STArea()>1e13 SET @g=@g.ReorientObject(); UPDATE dbo.GEO_UNIT SET geom=@g,updated_at=SYSUTCDATETIME() WHERE level='municipio' AND ibge_id=%d;\n" % (w, cod))
    out.write("GO\n")
out.write("SELECT COUNT(*) municipios_com_geom FROM dbo.GEO_UNIT WHERE level='municipio' AND geom IS NOT NULL;\n")
out.close()
print('polys:', len(rows), '| arquivo:', os.path.getsize(os.path.join(SP,'poly_seed.sql')), 'bytes')
