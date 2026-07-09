import json, io, os
SP = os.path.dirname(os.path.abspath(__file__))
d = json.load(open(os.path.join(SP, 'municipios.json'), encoding='utf-8'))

ufs = {}      # uf_id -> (sigla, nome, regiao_sigla)
mesos = {}    # meso_id -> (nome, uf_sigla)
micros = {}   # micro_id -> (nome, meso_id, uf_sigla)
munis = []    # (muni_id, nome, micro_id, uf_sigla)
skipped = 0
for m in d:
    mic = m.get('microrregiao')
    if not mic:
        skipped += 1; continue
    mes = mic['mesorregiao']; uf = mes['UF']
    ufs[uf['id']] = (uf['sigla'], uf['nome'], uf['regiao']['sigla'])
    mesos[mes['id']] = (mes['nome'], uf['sigla'])
    micros[mic['id']] = (mic['nome'], mes['id'], uf['sigla'])
    munis.append((m['id'], m['nome'], mic['id'], uf['sigla']))

def q(s):
    return "N'" + str(s).replace("'", "''") + "'"

rows = []  # (lvl, ibge, nome, uf, regiao, parent_ibge)
for uid, (sig, nome, reg) in ufs.items():
    rows.append(('estado', uid, nome, sig, reg, None))
for mid, (nome, ufs_) in mesos.items():
    rows.append(('mesorregiao', mid, nome, ufs_, None, None))
for mid, (nome, meso, ufs_) in micros.items():
    rows.append(('microrregiao', mid, nome, ufs_, None, meso))
for (mid, nome, micro, ufs_) in munis:
    rows.append(('municipio', mid, nome, ufs_, None, micro))

out = io.open(os.path.join(SP, 'geo_seed.sql'), 'w', encoding='utf-8')
out.write("SET NOCOUNT ON;\n")
out.write("IF OBJECT_ID('tempdb..#stg') IS NOT NULL DROP TABLE #stg;\n")
out.write("CREATE TABLE #stg (lvl VARCHAR(16), ibge INT, nome NVARCHAR(150), uf CHAR(2) NULL, regiao CHAR(2) NULL, parent_ibge INT NULL);\n")
B = 900
for i in range(0, len(rows), B):
    chunk = rows[i:i+B]
    vals = []
    for (lvl, ibge, nome, uf, reg, pib) in chunk:
        vals.append("('%s',%d,%s,%s,%s,%s)" % (
            lvl, ibge, q(nome),
            q(uf) if uf else 'NULL',
            q(reg) if reg else 'NULL',
            str(pib) if pib is not None else 'NULL'))
    out.write("INSERT #stg(lvl,ibge,nome,uf,regiao,parent_ibge) VALUES\n" + ",\n".join(vals) + ";\n")

out.write("""
DECLARE @br BIGINT = (SELECT id FROM dbo.GEO_UNIT WHERE level='pais' AND nome=N'Brasil');
INSERT dbo.GEO_UNIT(parent_id,level,ibge_id,nome,uf,regiao_sigla)
 SELECT @br,'estado',s.ibge,s.nome,s.uf,s.regiao FROM #stg s
  WHERE s.lvl='estado' AND NOT EXISTS(SELECT 1 FROM dbo.GEO_UNIT g WHERE g.level='estado' AND g.ibge_id=s.ibge);
INSERT dbo.GEO_UNIT(parent_id,level,ibge_id,nome,uf)
 SELECT p.id,'mesorregiao',s.ibge,s.nome,s.uf FROM #stg s
  JOIN dbo.GEO_UNIT p ON p.level='estado' AND p.uf=s.uf
  WHERE s.lvl='mesorregiao' AND NOT EXISTS(SELECT 1 FROM dbo.GEO_UNIT g WHERE g.level='mesorregiao' AND g.ibge_id=s.ibge);
INSERT dbo.GEO_UNIT(parent_id,level,ibge_id,nome,uf)
 SELECT p.id,'microrregiao',s.ibge,s.nome,s.uf FROM #stg s
  JOIN dbo.GEO_UNIT p ON p.level='mesorregiao' AND p.ibge_id=s.parent_ibge
  WHERE s.lvl='microrregiao' AND NOT EXISTS(SELECT 1 FROM dbo.GEO_UNIT g WHERE g.level='microrregiao' AND g.ibge_id=s.ibge);
INSERT dbo.GEO_UNIT(parent_id,level,ibge_id,nome,uf)
 SELECT p.id,'municipio',s.ibge,s.nome,s.uf FROM #stg s
  JOIN dbo.GEO_UNIT p ON p.level='microrregiao' AND p.ibge_id=s.parent_ibge
  WHERE s.lvl='municipio' AND NOT EXISTS(SELECT 1 FROM dbo.GEO_UNIT g WHERE g.level='municipio' AND g.ibge_id=s.ibge);
DROP TABLE #stg;
SELECT level, COUNT(*) n FROM dbo.GEO_UNIT GROUP BY level;
SELECT 'municipios_sem_pai' k, COUNT(*) n FROM dbo.GEO_UNIT WHERE level='municipio' AND parent_id IS NULL;
""")
out.close()
print('rows:', len(rows), '| skipped(no micro):', skipped, '| ufs:', len(ufs), 'mesos:', len(mesos), 'micros:', len(micros), 'munis:', len(munis))
