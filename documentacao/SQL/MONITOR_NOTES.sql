/* =========================================================================
   MONITORAMENTO — NOTAS GEORREFERENCIADAS COM FOTOS — v1
   Fonte: CONNECTOR_GCS_FARM.dbo.FARMBOX_MONITORING_DAY_RESULT.record →
     $.notes[] = anotações de campo do dia do monitoramento, com lat/lon, data,
     descrição (ocorrência), user_name e $.image_addresses[] (URLs S3 das fotos).
     location_type='Fields::Plantation' + location_id = plantation (Farmbox).
   Alimenta o CLIQUE-NO-PONTO / camada de fotos do MAPA DE CALOR.
   Roda DEPOIS de MODULE_AGRO_V1 + MODULE_MONITOR_V1. Idempotente (rebuild).
   ========================================================================= */
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO

DROP TABLE IF EXISTS dbo.FARM_MONITORING_NOTE;
GO
CREATE TABLE dbo.FARM_MONITORING_NOTE (
    id                    BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_MON_NOTE PRIMARY KEY,
    farmbox_note_id       BIGINT NULL,
    farmbox_plantation_id BIGINT NULL,
    field_id              BIGINT NULL CONSTRAINT FK_FMNOTE_field REFERENCES dbo.FARM_FIELDS(id),
    planting_id           BIGINT NULL CONSTRAINT FK_FMNOTE_plant REFERENCES dbo.FARM_FIELD_PLANTING(id),
    note_date             DATETIME2(3) NULL,
    latitude              DECIMAL(9,6) NULL,
    longitude             DECIMAL(9,6) NULL,
    description           NVARCHAR(1000) NULL,
    user_name             NVARCHAR(200) NULL,
    image_urls            NVARCHAR(MAX) NULL,   -- JSON array de URLs S3
    image_count           INT NOT NULL CONSTRAINT DF_FMNOTE_imgc DEFAULT 0,
    source                VARCHAR(12) NOT NULL CONSTRAINT DF_FMNOTE_src DEFAULT 'farmbox',
    created_at            DATETIME2(3) NOT NULL CONSTRAINT DF_FMNOTE_created DEFAULT SYSUTCDATETIME(),
    deleted_at            DATETIME2(3) NULL
);
GO
CREATE INDEX IX_FMNOTE_field ON dbo.FARM_MONITORING_NOTE(field_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FMNOTE_date  ON dbo.FARM_MONITORING_NOTE(note_date) WHERE deleted_at IS NULL;
GO

/* ── MATERIALIZA as notas georreferenciadas (rebuild) ─────────────────────── */
INSERT INTO dbo.FARM_MONITORING_NOTE
    (farmbox_note_id, farmbox_plantation_id, field_id, planting_id, note_date, latitude, longitude, description, user_name, image_urls, image_count)
SELECT nt.note_id, pl.plid, fp.field_id, fp.id,
       nt.note_date, nt.lat, nt.lon, NULLIF(LTRIM(RTRIM(nt.description)),''), nt.user_name,
       COALESCE(nt.image_addresses,'[]'),
       CASE WHEN nt.image_addresses IS NULL THEN 0 ELSE (SELECT COUNT(*) FROM OPENJSON(nt.image_addresses)) END
  FROM CONNECTOR_GCS_FARM.dbo.FARMBOX_MONITORING_DAY_RESULT dr
  CROSS APPLY OPENJSON(dr.record,'$.notes')
    WITH (note_id BIGINT '$.id', lat DECIMAL(9,6) '$.latitude', lon DECIMAL(9,6) '$.longitude',
          note_date DATETIME2 '$.date', description NVARCHAR(1000) '$.description', user_name NVARCHAR(200) '$.user_name',
          location_id BIGINT '$.location_id', location_type NVARCHAR(60) '$.location_type',
          image_addresses NVARCHAR(MAX) '$.image_addresses' AS JSON) nt
  CROSS APPLY (SELECT CASE WHEN nt.location_type = 'Fields::Plantation' THEN nt.location_id
                          ELSE TRY_CAST(JSON_VALUE(dr.record,'$.plantation.id') AS bigint) END AS plid) pl
  LEFT JOIN dbo.FARM_FIELD_PLANTING fp ON fp.farmbox_plantation_id = pl.plid AND fp.deleted_at IS NULL
 WHERE dr.deleted_at IS NULL AND nt.lat IS NOT NULL AND nt.lon IS NOT NULL;
GO

SELECT 'FARM_MONITORING_NOTE' t, COUNT(*) n,
       SUM(CASE WHEN image_count > 0 THEN 1 ELSE 0 END) com_foto,
       SUM(CASE WHEN field_id IS NOT NULL THEN 1 ELSE 0 END) com_talhao
  FROM dbo.FARM_MONITORING_NOTE;
GO
