import shapefile, io, os, unicodedata
SP = os.path.dirname(os.path.abspath(__file__))

def norm(s):
    s = unicodedata.normalize('NFKD', s).encode('ascii', 'ignore').decode()
    return s.strip().upper().replace(' ', '_')

WANT = {'CERRADO', 'AMAZONIA', 'MATA_ATLANTICA', 'CAATINGA', 'PAMPA', 'PANTANAL'}

def ccw(ring):  # ensure counter-clockwise (correct exterior for SQL geography)
    a = 0.0
    for i in range(len(ring) - 1):
        a += ring[i][0] * ring[i+1][1] - ring[i+1][0] * ring[i][1]
    return ring if a > 0 else ring[::-1]

r = shapefile.Reader(os.path.join(SP, 'biomas_shp', 'Biomas5000.shp'), encoding='latin-1')
out = io.open(os.path.join(SP, 'biomas_seed.sql'), 'w', encoding='utf-8')
out.write("SET NOCOUNT ON;\n")
n = 0
for sh, rec in zip(r.shapes(), r.records()):
    code = norm(rec['NOM_BIOMA'])
    if code not in WANT:
        continue
    pts = sh.points
    parts = list(sh.parts) + [len(pts)]
    polys = []
    for i in range(len(parts) - 1):
        ring = pts[parts[i]:parts[i+1]]
        if len(ring) < 4:
            continue
        ring = ccw(ring)
        polys.append("((" + ",".join("%.5f %.5f" % (p[0], p[1]) for p in ring) + "))")
    wkt = "MULTIPOLYGON(" + ",".join(polys) + ")"
    out.write("DECLARE @g%d geography = geography::STGeomFromText(N'%s',4326).MakeValid();\n" % (n, wkt))
    out.write("IF @g%d.STArea() > 1e14 SET @g%d = @g%d.ReorientObject();\n" % (n, n, n))
    out.write("UPDATE dbo.REF_BIOMA SET geom=@g%d, updated_at=SYSUTCDATETIME() WHERE code='%s';\n" % (n, code))
    n += 1
out.write("SELECT code, CASE WHEN geom IS NULL THEN 0 ELSE 1 END tem_geom, CAST(geom.STArea()/1e9 AS decimal(12,1)) area_mil_km2 FROM dbo.REF_BIOMA ORDER BY code;\n")
out.close()
print('biomas gerados:', n, '| arquivo:', os.path.getsize(os.path.join(SP, 'biomas_seed.sql')), 'bytes')
