/* =========================================================================
   AGRICULTURA DE PRECISÃO — APLICAÇÃO AÉREA · LOG DE VOO (backend/DBA)
   ---------------------------------------------------------------------------
   Guarda o log do Air Tractor (AS4.01/ATT) decodificado no backend:
     • FLIGHT_LOG           — o voo: .log cru (VARBINARY), pontos, TRILHA (linha)
                              e COBERTURA aplicada (polígono = buffer da trilha
                              com barra aberta pela faixa) em GEOGRAPHY 4326,
                              + métricas agregadas.
     • FLIGHT_LOG_APP       — SPLIT: 1 linha por AP do Farmbox presente no log
                              (um log pode conter várias APs). coverage_geom =
                              recorte da cobertura nos talhões daquela AP.
     • FLIGHT_LOG_APP_FIELD — por talhão dentro da AP (aplicado × pretendido).
   Geometria no padrão da casa (GEOGRAPHY SRID 4326, igual FARM_FIELD_GEOMETRY /
   OPS_GEOMETRY_FEATURE). Idempotente.
   ========================================================================= */
SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;

IF OBJECT_ID('dbo.FLIGHT_LOG') IS NULL
BEGIN
  CREATE TABLE dbo.FLIGHT_LOG (
    id               BIGINT IDENTITY(1,1) CONSTRAINT PK_FLIGHT_LOG PRIMARY KEY,
    code             VARCHAR(40)    NULL,
    name             NVARCHAR(160)  NULL,
    file_name        NVARCHAR(255)  NULL,
    file_hash        CHAR(64)       NULL,           -- sha256 do .log (dedup)
    raw_data         VARBINARY(MAX) NULL,           -- arquivo .log original
    points_blob      VARBINARY(MAX) NULL,           -- pontos decodificados (JSON gzip) p/ re-render
    header           NVARCHAR(60)   NULL,           -- ex.: AS4.01/ATT 5.5.31.5
    pilot            NVARCHAR(120)  NULL,
    aircraft         NVARCHAR(60)   NULL,
    swath_m          DECIMAL(6,2)   NULL,           -- largura de faixa (detectada/confirmada)
    farm_id          BIGINT         NULL,           -- fazenda dominante
    track_geom       GEOGRAPHY      NULL,           -- MULTILINESTRING do voo
    applied_geom     GEOGRAPHY      NULL,           -- MULTIPOLYGON da cobertura aplicada
    points           INT            NULL,
    distance_km      DECIMAL(10,2)  NULL,
    applied_km       DECIMAL(10,2)  NULL,
    applied_area_ha  DECIMAL(12,2)  NULL,
    external_area_ha DECIMAL(12,2)  NULL,           -- cobertura fora de qualquer talhão
    speed_avg_kmh    DECIMAL(6,1)   NULL,
    speed_min_kmh    DECIMAL(6,1)   NULL,
    speed_max_kmh    DECIMAL(6,1)   NULL,
    flow_lpm         DECIMAL(8,2)   NULL,
    rate_lha         DECIMAL(8,2)   NULL,
    bbox             NVARCHAR(120)  NULL,           -- minLon,minLat,maxLon,maxLat
    application_ref  NVARCHAR(60)   NULL,           -- código informado no import (livre)
    status           VARCHAR(12)    NOT NULL CONSTRAINT DF_FLOG_status DEFAULT 'imported', -- imported | assigned
    uploaded_by      NVARCHAR(120)  NULL,
    imported_at      DATETIME2(3)   NOT NULL CONSTRAINT DF_FLOG_imp DEFAULT SYSUTCDATETIME(),
    created_at       DATETIME2(3)   NOT NULL CONSTRAINT DF_FLOG_ca  DEFAULT SYSUTCDATETIME(),
    updated_at       DATETIME2(3)   NULL,
    deleted_at       DATETIME2(3)   NULL,
    CONSTRAINT FK_FLOG_farm FOREIGN KEY (farm_id) REFERENCES dbo.FARM_FARMS(id),
    CONSTRAINT CK_FLOG_status CHECK (status IN ('imported','assigned'))
  );
  CREATE UNIQUE INDEX UX_FLIGHT_LOG_hash ON dbo.FLIGHT_LOG(file_hash) WHERE file_hash IS NOT NULL AND deleted_at IS NULL;
END
GO
SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;

/* Cadastro do voo (informado na importação): datas início/fim, aeronave (equipamento) e piloto (pessoa).
   O 'pilot'/'aircraft' texto continuam como o que foi DECODIFICADO do arquivo (fallback). Idempotente. */
IF COL_LENGTH('dbo.FLIGHT_LOG','started_at')      IS NULL ALTER TABLE dbo.FLIGHT_LOG ADD started_at      DATETIME2(3) NULL;
IF COL_LENGTH('dbo.FLIGHT_LOG','ended_at')        IS NULL ALTER TABLE dbo.FLIGHT_LOG ADD ended_at        DATETIME2(3) NULL;
IF COL_LENGTH('dbo.FLIGHT_LOG','equipment_id')    IS NULL ALTER TABLE dbo.FLIGHT_LOG ADD equipment_id    BIGINT NULL;
IF COL_LENGTH('dbo.FLIGHT_LOG','pilot_person_id') IS NULL ALTER TABLE dbo.FLIGHT_LOG ADD pilot_person_id BIGINT NULL;
-- tempo derivado do LOG (distância÷velocidade; o relógio do arquivo é ambíguo): voo e barra aberta, em segundos
IF COL_LENGTH('dbo.FLIGHT_LOG','flight_sec')  IS NULL ALTER TABLE dbo.FLIGHT_LOG ADD flight_sec  INT NULL;
IF COL_LENGTH('dbo.FLIGHT_LOG','applied_sec') IS NULL ALTER TABLE dbo.FLIGHT_LOG ADD applied_sec INT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_FLOG_equip')
  ALTER TABLE dbo.FLIGHT_LOG ADD CONSTRAINT FK_FLOG_equip FOREIGN KEY (equipment_id) REFERENCES dbo.MACHINE_OPERATION_EQUIPMENT(id);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_FLOG_pilot')
  ALTER TABLE dbo.FLIGHT_LOG ADD CONSTRAINT FK_FLOG_pilot FOREIGN KEY (pilot_person_id) REFERENCES dbo.MANAGEMENT_PEOPLES(id);
GO
SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;

IF OBJECT_ID('dbo.FLIGHT_LOG_APP') IS NULL
BEGIN
  CREATE TABLE dbo.FLIGHT_LOG_APP (
    id              BIGINT IDENTITY(1,1) CONSTRAINT PK_FLIGHT_LOG_APP PRIMARY KEY,
    flight_log_id   BIGINT    NOT NULL,
    application_id  BIGINT    NULL,               -- FARM_APPLICATION; NULL = cobertura externa
    is_external     BIT       NOT NULL CONSTRAINT DF_FLA_ext DEFAULT 0,
    coverage_geom   GEOGRAPHY NULL,               -- recorte da cobertura nos talhões desta AP
    applied_area_ha DECIMAL(12,2) NULL,
    applied_km      DECIMAL(10,2) NULL,
    volume_l        DECIMAL(12,2) NULL,
    rate_lha        DECIMAL(8,2)  NULL,
    time_share_pct  DECIMAL(5,1)  NULL,
    speed_avg_kmh   DECIMAL(6,1)  NULL,
    created_at      DATETIME2(3) NOT NULL CONSTRAINT DF_FLA_ca DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3) NULL,
    CONSTRAINT FK_FLA_log FOREIGN KEY (flight_log_id) REFERENCES dbo.FLIGHT_LOG(id),
    CONSTRAINT FK_FLA_app FOREIGN KEY (application_id) REFERENCES dbo.FARM_APPLICATION(id)
  );
  CREATE INDEX IX_FLIGHT_LOG_APP_log ON dbo.FLIGHT_LOG_APP(flight_log_id) WHERE deleted_at IS NULL;
END
GO
SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;

IF OBJECT_ID('dbo.FLIGHT_LOG_APP_FIELD') IS NULL
BEGIN
  CREATE TABLE dbo.FLIGHT_LOG_APP_FIELD (
    id                BIGINT IDENTITY(1,1) CONSTRAINT PK_FLIGHT_LOG_APP_FIELD PRIMARY KEY,
    flight_log_app_id BIGINT NOT NULL,
    field_id          BIGINT NOT NULL,
    applied_area_ha   DECIMAL(12,2) NULL,
    sought_area_ha    DECIMAL(12,2) NULL,
    pct_exec          DECIMAL(6,1)  NULL,
    created_at        DATETIME2(3) NOT NULL CONSTRAINT DF_FLAF_ca DEFAULT SYSUTCDATETIME(),
    deleted_at        DATETIME2(3) NULL,
    CONSTRAINT FK_FLAF_app   FOREIGN KEY (flight_log_app_id) REFERENCES dbo.FLIGHT_LOG_APP(id),
    CONSTRAINT FK_FLAF_field FOREIGN KEY (field_id) REFERENCES dbo.FARM_FIELDS(id)
  );
  CREATE INDEX IX_FLIGHT_LOG_APP_FIELD_app ON dbo.FLIGHT_LOG_APP_FIELD(flight_log_app_id) WHERE deleted_at IS NULL;
END
GO
SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;

SELECT 'FLIGHT_LOG' t, COUNT(*) n FROM dbo.FLIGHT_LOG
UNION ALL SELECT 'FLIGHT_LOG_APP', COUNT(*) FROM dbo.FLIGHT_LOG_APP
UNION ALL SELECT 'FLIGHT_LOG_APP_FIELD', COUNT(*) FROM dbo.FLIGHT_LOG_APP_FIELD;
