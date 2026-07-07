/* =========================================================================
   MATERIALIZAÇÃO  CONNECTOR (JSON cru) → FARM_*  (domínio nativo) — Fase B
   ---------------------------------------------------------------------------
   SEM espelho FARMBOX_* no GCS_FARM. Lê o JSON cru direto do CONNECTOR_GCS_FARM
   (cross-db) e grava no domínio próprio FARM_*. Rodar com sqlcmd -I
   (QUOTED_IDENTIFIER, por causa de JSON_VALUE/OPENJSON e índices filtrados).
   Espelho fiel de src/services/farmMaterialize.service.ts (roda no ETL).

   REGRA-CHAVE: as colunas TIPADAS do CONNECTOR são majoritariamente NULL
   (application/plantation/count typed = NULL). Só o `record` (JSON) é confiável
   → tudo sai de JSON_VALUE/OPENJSON. Resoluções:
     field_id = CONFIG_CONNECTORS(type='farmbox', code = record.plot.id).field_id
     cultura  = FARM_CULTURE.farmbox_culture_id  = record.culture_id
     variety  = FARM_VARIETY.farmbox_variety_id  = record.variety_id
     plantio  = FARM_FIELD_PLANTING.farmbox_plantation_id = plantation.farmbox_id
     produto  = FARM_PRODUCT.farmbox_input_id    = input.farmbox_id
   Idempotente: MERGE nos pais (chave natural farmbox_*_id) + DELETE/INSERT filhos.
   ========================================================================= */
SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;

/* ── 1) PRODUTOS (categorias + produtos, tudo do record) ──────────────────── */
INSERT INTO dbo.FARM_PRODUCT_CATEGORY (code, name)
SELECT DISTINCT UPPER(LTRIM(RTRIM(JSON_VALUE(i.record,'$.input_type_name')))), LTRIM(RTRIM(JSON_VALUE(i.record,'$.input_type_name')))
FROM CONNECTOR_GCS_FARM.dbo.FARMBOX_INPUT i
WHERE i.deleted_at IS NULL AND JSON_VALUE(i.record,'$.input_type_name') IS NOT NULL AND LTRIM(RTRIM(JSON_VALUE(i.record,'$.input_type_name'))) <> ''
  AND NOT EXISTS (SELECT 1 FROM dbo.FARM_PRODUCT_CATEGORY c WHERE c.code = UPPER(LTRIM(RTRIM(JSON_VALUE(i.record,'$.input_type_name')))));

MERGE dbo.FARM_PRODUCT AS tgt USING (
  SELECT i.farmbox_id AS fbid, LEFT(JSON_VALUE(i.record,'$.name'),200) AS name, LEFT(JSON_VALUE(i.record,'$.dosage_unit'),20) AS unit,
         c.id AS category_id, LEFT(JSON_VALUE(i.record,'$.manufacturer'),200) AS manufacturer,
         LEFT(JSON_VALUE(i.record,'$.register'),40) AS register_mapa, LEFT(JSON_VALUE(i.record,'$.formulation'),40) AS formulation
  FROM CONNECTOR_GCS_FARM.dbo.FARMBOX_INPUT i
  JOIN dbo.FARM_PRODUCT_CATEGORY c ON c.code = UPPER(LTRIM(RTRIM(JSON_VALUE(i.record,'$.input_type_name'))))
  WHERE i.deleted_at IS NULL AND JSON_VALUE(i.record,'$.name') IS NOT NULL
) src ON tgt.farmbox_input_id = src.fbid
WHEN MATCHED THEN UPDATE SET tgt.name=src.name, tgt.category_id=src.category_id, tgt.dose_unit=src.unit,
     tgt.manufacturer=src.manufacturer, tgt.register_mapa=src.register_mapa, tgt.formulation=src.formulation, tgt.updated_at=SYSUTCDATETIME(), tgt.deleted_at=NULL
WHEN NOT MATCHED THEN INSERT (name, category_id, dose_unit, manufacturer, register_mapa, formulation, source, farmbox_input_id)
     VALUES (src.name, src.category_id, src.unit, src.manufacturer, src.register_mapa, src.formulation, 'farmbox', src.fbid)
WHEN NOT MATCHED BY SOURCE AND tgt.source='farmbox' AND tgt.deleted_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM dbo.FARM_APPLICATION_INPUT ai WHERE ai.product_id = tgt.id) THEN UPDATE SET tgt.deleted_at=SYSUTCDATETIME();

/* ── 2) APLICAÇÕES (parent + insumos + alvos; farm_id derivado dos alvos) ──── */
MERGE dbo.FARM_APPLICATION AS tgt USING (
  SELECT a.farmbox_id AS fbid, LEFT(JSON_VALUE(a.record,'$.code'),30) AS code, LEFT(JSON_VALUE(a.record,'$.status'),20) AS status,
         LEFT(JSON_VALUE(a.record,'$.operation_type'),40) AS operation_type,
         TRY_CAST(JSON_VALUE(a.record,'$.date') AS date) AS app_date, TRY_CAST(JSON_VALUE(a.record,'$.end_date') AS date) AS end_date,
         (SELECT SUM(TRY_CAST(JSON_VALUE(p2.value,'$.applied_area') AS decimal(12,2))) FROM OPENJSON(a.record,'$.plantations') p2) AS total_area_ha,
         CASE WHEN EXISTS (SELECT 1 FROM OPENJSON(a.record,'$.equipments') e WHERE JSON_VALUE(e.value,'$.equipment.name') LIKE '%FERTIRR%') THEN 'ferti'
              WHEN EXISTS (SELECT 1 FROM OPENJSON(a.record,'$.equipments') e WHERE JSON_VALUE(e.value,'$.equipment.type')='air') THEN 'air'
              WHEN EXISTS (SELECT 1 FROM OPENJSON(a.record,'$.equipments') e WHERE JSON_VALUE(e.value,'$.equipment.type')='land') THEN 'land' ELSE NULL END AS eqmode,
         LEFT(JSON_VALUE(a.record,'$.responsible.name'),200) AS responsible_name, LEFT(JSON_VALUE(a.record,'$.observations'),4000) AS observations
  FROM CONNECTOR_GCS_FARM.dbo.FARMBOX_APPLICATION a WHERE a.deleted_at IS NULL
) src ON tgt.farmbox_application_id=src.fbid
WHEN MATCHED THEN UPDATE SET tgt.code=src.code, tgt.status=src.status, tgt.operation_type=src.operation_type,
     tgt.app_date=src.app_date, tgt.end_date=src.end_date, tgt.total_area_ha=src.total_area_ha,
     tgt.equipment_mode=src.eqmode, tgt.responsible_name=src.responsible_name, tgt.observations=src.observations, tgt.updated_at=SYSUTCDATETIME(), tgt.deleted_at=NULL
WHEN NOT MATCHED THEN INSERT (code, status, operation_type, app_date, end_date, total_area_ha, equipment_mode, responsible_name, observations, source, farmbox_application_id)
     VALUES (src.code, src.status, src.operation_type, src.app_date, src.end_date, src.total_area_ha, src.eqmode, src.responsible_name, src.observations, 'farmbox', src.fbid)
WHEN NOT MATCHED BY SOURCE AND tgt.source='farmbox' AND tgt.deleted_at IS NULL THEN UPDATE SET tgt.deleted_at=SYSUTCDATETIME();

DELETE FROM dbo.FARM_APPLICATION_INPUT;
INSERT INTO dbo.FARM_APPLICATION_INPUT (application_id, product_id, dosage, dosage_unit, quantity, quantity_unit)
SELECT fa.id, fp.id, TRY_CAST(JSON_VALUE(i.value,'$.applied_dosage_value') AS decimal(14,4)),
       LEFT(JSON_VALUE(i.value,'$.applied_dosage_unit'),20), TRY_CAST(JSON_VALUE(i.value,'$.applied') AS decimal(14,4)),
       LEFT(JSON_VALUE(i.value,'$.applied_unit'),20)
FROM CONNECTOR_GCS_FARM.dbo.FARMBOX_APPLICATION a
CROSS APPLY OPENJSON(a.record,'$.inputs') i
JOIN dbo.FARM_APPLICATION fa ON fa.farmbox_application_id = a.farmbox_id AND fa.deleted_at IS NULL
JOIN dbo.FARM_PRODUCT fp ON fp.farmbox_input_id = TRY_CAST(JSON_VALUE(i.value,'$.input.id') AS bigint) AND fp.deleted_at IS NULL
WHERE a.deleted_at IS NULL;

DELETE FROM dbo.FARM_APPLICATION_TARGET;
INSERT INTO dbo.FARM_APPLICATION_TARGET (application_id, field_id, planting_id, sought_area, applied_area, culture_id, variety_id, harvest_id, harvest_name)
SELECT fa.id, cc.field_id, fpl.id,
       TRY_CAST(JSON_VALUE(p.value,'$.sought_area') AS decimal(12,2)), TRY_CAST(JSON_VALUE(p.value,'$.applied_area') AS decimal(12,2)),
       cu.id, v.id, TRY_CAST(JSON_VALUE(cp.record,'$.harvest.id') AS int), LEFT(JSON_VALUE(cp.record,'$.harvest_name'),100)
FROM CONNECTOR_GCS_FARM.dbo.FARMBOX_APPLICATION a
CROSS APPLY OPENJSON(a.record,'$.plantations') p
JOIN dbo.FARM_APPLICATION fa ON fa.farmbox_application_id = a.farmbox_id AND fa.deleted_at IS NULL
JOIN CONNECTOR_GCS_FARM.dbo.FARMBOX_PLANTATION cp ON cp.farmbox_id = TRY_CAST(JSON_VALUE(p.value,'$.plantation.id') AS bigint) AND cp.deleted_at IS NULL
JOIN dbo.CONFIG_CONNECTORS cc ON cc.type='farmbox' AND cc.code = JSON_VALUE(cp.record,'$.plot.id') AND cc.field_id IS NOT NULL AND cc.deleted_at IS NULL
LEFT JOIN dbo.FARM_FIELD_PLANTING fpl ON fpl.farmbox_plantation_id = cp.farmbox_id AND fpl.deleted_at IS NULL
LEFT JOIN dbo.FARM_CULTURE cu ON cu.farmbox_culture_id = TRY_CAST(JSON_VALUE(cp.record,'$.culture_id') AS int)
LEFT JOIN dbo.FARM_VARIETY v ON v.farmbox_variety_id = TRY_CAST(JSON_VALUE(cp.record,'$.variety_id') AS int)
WHERE a.deleted_at IS NULL;

UPDATE fa SET fa.farm_id = x.farm_id
FROM dbo.FARM_APPLICATION fa
CROSS APPLY (SELECT TOP 1 p.farm_id FROM dbo.FARM_APPLICATION_TARGET t
             JOIN dbo.FARM_FIELDS ff ON ff.id=t.field_id JOIN dbo.FARM_PLOTS p ON p.id=ff.plot_id
             WHERE t.application_id=fa.id ORDER BY p.farm_id) x
WHERE fa.deleted_at IS NULL;

/* ── 3) PRAGAS (dedupe + COLLATE p/ não duplicar sob variações de caixa) ───── */
INSERT INTO dbo.FARM_PEST (name)
SELECT src.nm FROM (
  SELECT DISTINCT LTRIM(RTRIM(JSON_VALUE(res.value,'$.target.name'))) AS nm
  FROM CONNECTOR_GCS_FARM.dbo.FARMBOX_MONITORING m
  CROSS APPLY OPENJSON(m.record,'$.monitoring_stops') st
  CROSS APPLY OPENJSON(st.value,'$.monitoring_stop_results') res
  WHERE m.deleted_at IS NULL AND JSON_VALUE(res.value,'$.target.name') IS NOT NULL AND LTRIM(RTRIM(JSON_VALUE(res.value,'$.target.name'))) <> ''
) src
WHERE NOT EXISTS (SELECT 1 FROM dbo.FARM_PEST pe WHERE pe.name = src.nm COLLATE Latin1_General_CI_AS);

/* ── 4) MONITORAMENTO (cabeçalho + pontos + achados/índice por praga) ──────── */
MERGE dbo.FARM_MONITORING AS tgt USING (
  SELECT m.farmbox_id AS fbid, cc.field_id, fpl.id AS planting_id, TRY_CAST(JSON_VALUE(m.record,'$.date') AS date) AS monitoring_date,
         LEFT(JSON_VALUE(m.record,'$.methodology'),40) AS meth, TRY_CAST(JSON_VALUE(m.record,'$.samples') AS int) AS samples,
         LEFT(JSON_VALUE(m.record,'$.phenological_stage.name'),60) AS stage,
         LEFT(JSON_VALUE(m.record,'$.state'),20) AS mon_state, LEFT(JSON_VALUE(m.record,'$.recommendation'),4000) AS recommendation
  FROM CONNECTOR_GCS_FARM.dbo.FARMBOX_MONITORING m
  JOIN dbo.CONFIG_CONNECTORS cc ON cc.type='farmbox' AND cc.code = JSON_VALUE(m.record,'$.plantation.plot.id') AND cc.field_id IS NOT NULL AND cc.deleted_at IS NULL
  LEFT JOIN dbo.FARM_FIELD_PLANTING fpl ON fpl.farmbox_plantation_id = TRY_CAST(JSON_VALUE(m.record,'$.plantation.id') AS bigint) AND fpl.deleted_at IS NULL
  WHERE m.deleted_at IS NULL
) src ON tgt.farmbox_monitoring_id=src.fbid
WHEN MATCHED THEN UPDATE SET tgt.field_id=src.field_id, tgt.planting_id=src.planting_id, tgt.monitoring_date=src.monitoring_date,
     tgt.methodology=src.meth, tgt.samples=src.samples, tgt.phenological_stage=src.stage, tgt.mon_state=src.mon_state,
     tgt.recommendation=src.recommendation, tgt.updated_at=SYSUTCDATETIME(), tgt.deleted_at=NULL
WHEN NOT MATCHED THEN INSERT (field_id, planting_id, monitoring_date, methodology, samples, phenological_stage, mon_state, recommendation, source, farmbox_monitoring_id)
     VALUES (src.field_id, src.planting_id, src.monitoring_date, src.meth, src.samples, src.stage, src.mon_state, src.recommendation, 'farmbox', src.fbid)
WHEN NOT MATCHED BY SOURCE AND tgt.source='farmbox' AND tgt.deleted_at IS NULL THEN UPDATE SET tgt.deleted_at=SYSUTCDATETIME();

DELETE FROM dbo.FARM_MONITORING_FINDING;
DELETE FROM dbo.FARM_MONITORING_POINT;
INSERT INTO dbo.FARM_MONITORING_POINT (monitoring_id, seq, latitude, longitude)
SELECT fm.id, CAST(st.[key] AS int)+1, TRY_CAST(JSON_VALUE(st.value,'$.latitude') AS decimal(10,7)), TRY_CAST(JSON_VALUE(st.value,'$.longitude') AS decimal(10,7))
FROM CONNECTOR_GCS_FARM.dbo.FARMBOX_MONITORING m
CROSS APPLY OPENJSON(m.record,'$.monitoring_stops') st
JOIN dbo.FARM_MONITORING fm ON fm.farmbox_monitoring_id = m.farmbox_id AND fm.deleted_at IS NULL
WHERE m.deleted_at IS NULL;
INSERT INTO dbo.FARM_MONITORING_FINDING (monitoring_id, pest_id, infestation, infestation_level, quantity)
SELECT fm.id, pe.id, CAST(AVG(TRY_CAST(JSON_VALUE(res.value,'$.infestation') AS float)) AS decimal(12,3)),
       MAX(LEFT(JSON_VALUE(res.value,'$.infestation_level'),20)), CAST(SUM(TRY_CAST(JSON_VALUE(res.value,'$.quantity') AS float)) AS decimal(12,3))
FROM CONNECTOR_GCS_FARM.dbo.FARMBOX_MONITORING m
CROSS APPLY OPENJSON(m.record,'$.monitoring_stops') st
CROSS APPLY OPENJSON(st.value,'$.monitoring_stop_results') res
JOIN dbo.FARM_MONITORING fm ON fm.farmbox_monitoring_id = m.farmbox_id AND fm.deleted_at IS NULL
JOIN dbo.FARM_PEST pe ON pe.name = LTRIM(RTRIM(JSON_VALUE(res.value,'$.target.name'))) COLLATE Latin1_General_CI_AS
WHERE m.deleted_at IS NULL AND JSON_VALUE(res.value,'$.target.name') IS NOT NULL
GROUP BY fm.id, pe.id;

/* ── 5) CONTAGEM (cabeçalho + JSON cru dos pIDs + normalização) ────────────── */
MERGE dbo.FARM_COUNT AS tgt USING (
  SELECT cm.farmbox_id AS fbid, cc.field_id, fpl.id AS planting_id, TRY_CAST(JSON_VALUE(cm.record,'$.date') AS date) AS count_date,
         LEFT(COALESCE(JSON_VALUE(cm.record,'$.count_group.name'), JSON_VALUE(cm.record,'$.count_group')),150) AS cg,
         TRY_CAST(JSON_VALUE(cm.record,'$.latitude') AS decimal(10,7)) AS latitude, TRY_CAST(JSON_VALUE(cm.record,'$.longitude') AS decimal(10,7)) AS longitude,
         JSON_QUERY(cm.record,'$.count_monitoring_parameters') AS parameters
  FROM CONNECTOR_GCS_FARM.dbo.FARMBOX_COUNT_MONITORING cm
  JOIN CONNECTOR_GCS_FARM.dbo.FARMBOX_PLANTATION cp ON cp.farmbox_id = TRY_CAST(JSON_VALUE(cm.record,'$.plantation_id') AS bigint) AND cp.deleted_at IS NULL
  JOIN dbo.CONFIG_CONNECTORS cc ON cc.type='farmbox' AND cc.code = JSON_VALUE(cp.record,'$.plot.id') AND cc.field_id IS NOT NULL AND cc.deleted_at IS NULL
  LEFT JOIN dbo.FARM_FIELD_PLANTING fpl ON fpl.farmbox_plantation_id = TRY_CAST(JSON_VALUE(cm.record,'$.plantation_id') AS bigint) AND fpl.deleted_at IS NULL
  WHERE cm.deleted_at IS NULL
) src ON tgt.farmbox_count_id=src.fbid
WHEN MATCHED THEN UPDATE SET tgt.field_id=src.field_id, tgt.planting_id=src.planting_id, tgt.count_date=src.count_date,
     tgt.count_group=src.cg, tgt.latitude=src.latitude, tgt.longitude=src.longitude, tgt.parameters=src.parameters, tgt.deleted_at=NULL
WHEN NOT MATCHED THEN INSERT (field_id, planting_id, count_date, count_group, latitude, longitude, parameters, source, farmbox_count_id)
     VALUES (src.field_id, src.planting_id, src.count_date, src.cg, src.latitude, src.longitude, src.parameters, 'farmbox', src.fbid)
WHEN NOT MATCHED BY SOURCE AND tgt.source='farmbox' AND tgt.deleted_at IS NULL THEN UPDATE SET tgt.deleted_at=SYSUTCDATETIME();

DELETE FROM dbo.FARM_COUNT_PARAM;
INSERT INTO dbo.FARM_COUNT_PARAM (count_id, param_code, param_name, value)
SELECT fc.id, LEFT(JSON_VALUE(p.value,'$.count_parameter.id'),60), LEFT(JSON_VALUE(p.value,'$.count_parameter.name'),120),
       TRY_CAST(JSON_VALUE(p.value,'$.value') AS decimal(16,4))
FROM dbo.FARM_COUNT fc CROSS APPLY OPENJSON(fc.parameters) p
WHERE fc.parameters IS NOT NULL AND JSON_VALUE(p.value,'$.count_parameter.id') IS NOT NULL;

/* ── 6) AMOSTRADOR (day-result monitors → FARM_MONITORING_DAY_MONITOR) ─────────
   Materializado p/ o mapa de estimativa não pagar OPENJSON por request.
   Chave: plantation_id (farmbox) + result_date (elo com a contagem). ───────── */
DELETE FROM dbo.FARM_MONITORING_DAY_MONITOR;
INSERT INTO dbo.FARM_MONITORING_DAY_MONITOR (plantation_id, result_date, monitor_id, monitor_name)
SELECT TRY_CAST(JSON_VALUE(r.record,'$.plantation.id') AS bigint),
       TRY_CAST(JSON_VALUE(r.record,'$.date') AS date),
       TRY_CAST(JSON_VALUE(mo.value,'$.id') AS bigint), LEFT(JSON_VALUE(mo.value,'$.name'),200)
FROM CONNECTOR_GCS_FARM.dbo.FARMBOX_MONITORING_DAY_RESULT r
CROSS APPLY OPENJSON(r.record,'$.monitors') mo
WHERE r.deleted_at IS NULL AND JSON_VALUE(mo.value,'$.id') IS NOT NULL;

/* ── safras/rotação: detecção lida direto do CONNECTOR pelos serviços
   (seasons/rotation), sem materializar tabela extra. ──────────────────────── */
