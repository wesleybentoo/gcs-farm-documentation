/* =========================================================================
   MONITORAMENTO — ACHADOS POR PARADA (ponto) + LIMITES DE CONTROLE — v1
   Fonte: CONNECTOR_GCS_FARM.dbo.FARMBOX_MONITORING.record →
     $.monitoring_stops[] (paradas com lat/lon) → $.monitoring_stop_results[]
     (achado por ponto: quantity + target{name, target_parameter{níveis}}).
   Alimenta o MAPA DE CALOR de pragas por ponto (últimos N dias, filtro por praga).
   Roda DEPOIS de MODULE_AGRO_V1 + MODULE_MONITOR_V1. Idempotente (rebuild).
   ========================================================================= */
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO

-- ponte praga Farmbox (target.id) → FARM_PEST
IF COL_LENGTH('dbo.FARM_PEST','farmbox_target_id') IS NULL ALTER TABLE dbo.FARM_PEST ADD farmbox_target_id INT NULL;
GO

/* ── 1) LIMITES DE CONTROLE por praga+parâmetro (nível de ação/dano) ──────
   FARM_PEST_THRESHOLD estava VAZIA e com shape que não casava; recria no
   formato do Farmbox (editável no nosso app). culture_id NULL = vale p/ todas. */
DROP TABLE IF EXISTS dbo.FARM_PEST_THRESHOLD;
GO
CREATE TABLE dbo.FARM_PEST_THRESHOLD (
    id           BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_PEST_THRESHOLD PRIMARY KEY,
    pest_id      BIGINT NOT NULL CONSTRAINT FK_FPTHR_pest REFERENCES dbo.FARM_PEST(id),
    culture_id   BIGINT NULL CONSTRAINT FK_FPTHR_culture REFERENCES dbo.FARM_CULTURE(id),
    param_name   NVARCHAR(80) NULL,          -- Adulto | Presença | Ninfa | ...
    phase        VARCHAR(12) NOT NULL CONSTRAINT DF_FPTHR_phase DEFAULT 'all',  -- veg | rep | all
    action_level DECIMAL(10,3) NULL,         -- nível de AÇÃO
    damage_level DECIMAL(10,3) NULL,         -- nível de DANO
    value_type   VARCHAR(20) NULL,           -- percentage_type | count...
    source       VARCHAR(12) NOT NULL CONSTRAINT DF_FPTHR_src DEFAULT 'app',
    active       BIT NOT NULL CONSTRAINT DF_FPTHR_active DEFAULT 1,
    created_at   DATETIME2(3) NOT NULL CONSTRAINT DF_FPTHR_created DEFAULT SYSUTCDATETIME(),
    updated_at   DATETIME2(3) NULL,
    deleted_at   DATETIME2(3) NULL
);
GO
CREATE UNIQUE INDEX UQ_FARM_PEST_THRESHOLD ON dbo.FARM_PEST_THRESHOLD(pest_id, param_name, phase, culture_id) WHERE deleted_at IS NULL;
GO

/* ── 2) ACHADOS POR PARADA (fonte do mapa de calor) ──────────────────────── */
DROP TABLE IF EXISTS dbo.FARM_MONITORING_STOP_RESULT;
GO
CREATE TABLE dbo.FARM_MONITORING_STOP_RESULT (
    id              BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_MON_STOP_RESULT PRIMARY KEY,
    monitoring_id   BIGINT NOT NULL CONSTRAINT FK_FMSR_mon REFERENCES dbo.FARM_MONITORING(id),
    farmbox_stop_id BIGINT NULL,
    latitude        DECIMAL(9,6) NULL,
    longitude       DECIMAL(9,6) NULL,
    stop_date       DATE NULL,
    pest_id         BIGINT NULL CONSTRAINT FK_FMSR_pest REFERENCES dbo.FARM_PEST(id),
    target_name     NVARCHAR(200) NULL,
    param_name      NVARCHAR(80) NULL,
    quantity        DECIMAL(12,3) NULL,
    source          VARCHAR(12) NOT NULL CONSTRAINT DF_FMSR_src DEFAULT 'farmbox',
    created_at      DATETIME2(3) NOT NULL CONSTRAINT DF_FMSR_created DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3) NULL
);
GO
CREATE INDEX IX_FMSR_mon  ON dbo.FARM_MONITORING_STOP_RESULT(monitoring_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FMSR_pest ON dbo.FARM_MONITORING_STOP_RESULT(pest_id) WHERE deleted_at IS NULL;
GO

/* ── 3) BACKFILL da ponte praga (target.id → FARM_PEST por nome) ──────────── */
;WITH tgt AS (
    SELECT DISTINCT res.target_id, res.target_name
      FROM CONNECTOR_GCS_FARM.dbo.FARMBOX_MONITORING fbm
      CROSS APPLY OPENJSON(fbm.record, '$.monitoring_results')
        WITH (target_id INT '$.target.id', target_name NVARCHAR(200) '$.target.name') res
     WHERE fbm.deleted_at IS NULL AND res.target_id IS NOT NULL
)
UPDATE pe SET farmbox_target_id = t.target_id
  FROM dbo.FARM_PEST pe
  JOIN tgt t ON LOWER(LTRIM(RTRIM(pe.name))) = LOWER(LTRIM(RTRIM(t.target_name)))
 WHERE pe.deleted_at IS NULL AND pe.farmbox_target_id IS NULL;
GO

/* ── 4) SEED dos limites (nível de ação/dano) a partir do raw ─────────────── */
;WITH params AS (
    SELECT res.target_name, res.param_name,
           MAX(res.veg_action) veg_action, MAX(res.veg_damage) veg_damage, MAX(res.vtype) vtype
      FROM CONNECTOR_GCS_FARM.dbo.FARMBOX_MONITORING fbm
      CROSS APPLY OPENJSON(fbm.record, '$.monitoring_results')
        WITH (target_name NVARCHAR(200) '$.target.name',
              param_name  NVARCHAR(80)  '$.target.target_parameter.name',
              veg_action  DECIMAL(10,3) '$.target.target_parameter.vegetative_action_level',
              veg_damage  DECIMAL(10,3) '$.target.target_parameter.vegetative_damage_level',
              vtype       VARCHAR(30)   '$.target.target_parameter.type_action_level') res
     WHERE fbm.deleted_at IS NULL AND res.param_name IS NOT NULL
     GROUP BY res.target_name, res.param_name
)
-- agrega por (pest, param): dois target_name podem mapear p/ a mesma praga → 1 linha só
INSERT INTO dbo.FARM_PEST_THRESHOLD (pest_id, param_name, phase, action_level, damage_level, value_type, source)
SELECT pe.id, p.param_name, 'all', MAX(p.veg_action), MAX(p.veg_damage), MAX(p.vtype), 'farmbox'
  FROM params p
  JOIN dbo.FARM_PEST pe ON LOWER(LTRIM(RTRIM(pe.name))) = LOWER(LTRIM(RTRIM(p.target_name))) AND pe.deleted_at IS NULL
 GROUP BY pe.id, p.param_name;
GO

/* ── 5) MATERIALIZA os achados por parada (rebuild) ───────────────────────── */
INSERT INTO dbo.FARM_MONITORING_STOP_RESULT (monitoring_id, farmbox_stop_id, latitude, longitude, stop_date, pest_id, target_name, param_name, quantity)
SELECT fm.id, st.stop_id, st.lat, st.lon, CAST(st.stop_date AS date),
       pe.id, res.target_name, res.param_name, res.quantity
  FROM CONNECTOR_GCS_FARM.dbo.FARMBOX_MONITORING fbm
  JOIN dbo.FARM_MONITORING fm ON fm.farmbox_monitoring_id = fbm.farmbox_id AND fm.deleted_at IS NULL
  CROSS APPLY OPENJSON(fbm.record, '$.monitoring_stops')
    WITH (stop_id BIGINT '$.id', lat DECIMAL(9,6) '$.latitude', lon DECIMAL(9,6) '$.longitude',
          stop_date DATETIME2 '$.date', results NVARCHAR(MAX) '$.monitoring_stop_results' AS JSON) st
  CROSS APPLY OPENJSON(st.results)
    WITH (quantity DECIMAL(12,3) '$.quantity',
          target_name NVARCHAR(200) '$.target.name',
          param_name  NVARCHAR(80)  '$.target.target_parameter.name') res
  LEFT JOIN dbo.FARM_PEST pe ON LOWER(LTRIM(RTRIM(pe.name))) = LOWER(LTRIM(RTRIM(res.target_name))) AND pe.deleted_at IS NULL
 WHERE fbm.deleted_at IS NULL;
GO
