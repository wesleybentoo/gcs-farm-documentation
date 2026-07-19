/* =========================================================================
   MODULE_MULTITENANT_V5 - Telemetria Solinftec por CLIENTE (client_group_id).
   -------------------------------------------------------------------------
   ALVO: GCS_FARM (master). Rodar: sqlcmd -d GCS_FARM -I -b

   O ETL do Solinftec (etl.service) materializava dims/fatos GLOBAIS: os dims
   (MACHINE_OPERATION_*) eram unicos por `code` (colidem entre clientes) e os
   fatos (MACHINE_OPERATION_FACT) + leituras de clima (WEATHER_READING) NAO
   tinham dono — a unica amarra de tenant era via field_id->fazenda, deixando a
   telemetria sem talhao (~38%) e todo o clima (por estacao) sem cliente.

   O raw (SOLINFTEC_OPERATION/WEATHER) JA carrega client_group_id (F2/F3). Aqui:
   1) adiciona client_group_id nas dims/fatos/clima do master;
   2) re-chaveia os dims de UNIQUE(code) -> UNIQUE(code, client_group_id) para
      dois clientes reusarem o mesmo code sem colidir;
   3) backfill do que ja existe -> GCS (id 1) (idempotente; no greenfield e no-op).
   O ETL passa a propagar o.client_group_id -> fato/dim, e o farmFilter escopa
   por fact.client_group_id. Aditivo/idempotente.
   ========================================================================= */
SET NOCOUNT ON;
GO

/* ---- 1) client_group_id nas dims, fato e clima ---- */
IF COL_LENGTH('dbo.MACHINE_OPERATION_EQUIPMENT','client_group_id') IS NULL ALTER TABLE dbo.MACHINE_OPERATION_EQUIPMENT ADD client_group_id BIGINT NULL;
IF COL_LENGTH('dbo.MACHINE_OPERATION_OPERATOR','client_group_id') IS NULL  ALTER TABLE dbo.MACHINE_OPERATION_OPERATOR  ADD client_group_id BIGINT NULL;
IF COL_LENGTH('dbo.MACHINE_OPERATION_OPERATION','client_group_id') IS NULL ALTER TABLE dbo.MACHINE_OPERATION_OPERATION ADD client_group_id BIGINT NULL;
IF COL_LENGTH('dbo.MACHINE_OPERATION_STOP_REASON','client_group_id') IS NULL ALTER TABLE dbo.MACHINE_OPERATION_STOP_REASON ADD client_group_id BIGINT NULL;
IF COL_LENGTH('dbo.MACHINE_OPERATION_FACT','client_group_id') IS NULL      ALTER TABLE dbo.MACHINE_OPERATION_FACT      ADD client_group_id BIGINT NULL;
IF COL_LENGTH('dbo.WEATHER_STATION','client_group_id') IS NULL             ALTER TABLE dbo.WEATHER_STATION             ADD client_group_id BIGINT NULL;
IF COL_LENGTH('dbo.WEATHER_READING','client_group_id') IS NULL             ALTER TABLE dbo.WEATHER_READING             ADD client_group_id BIGINT NULL;
GO

/* ---- 2) backfill do que ja existe -> GCS (id 1). No greenfield e no-op. ---- */
UPDATE dbo.MACHINE_OPERATION_EQUIPMENT SET client_group_id = 1 WHERE client_group_id IS NULL;
UPDATE dbo.MACHINE_OPERATION_OPERATOR  SET client_group_id = 1 WHERE client_group_id IS NULL;
UPDATE dbo.MACHINE_OPERATION_OPERATION SET client_group_id = 1 WHERE client_group_id IS NULL;
UPDATE dbo.MACHINE_OPERATION_STOP_REASON SET client_group_id = 1 WHERE client_group_id IS NULL;
UPDATE dbo.MACHINE_OPERATION_FACT       SET client_group_id = 1 WHERE client_group_id IS NULL;
UPDATE dbo.WEATHER_STATION              SET client_group_id = 1 WHERE client_group_id IS NULL;
UPDATE dbo.WEATHER_READING              SET client_group_id = 1 WHERE client_group_id IS NULL;
GO

/* ---- 3) re-chaveia os dims: UNIQUE(code) -> UNIQUE(code, client_group_id) ---- */
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_MO_EQUIP_code' AND object_id=OBJECT_ID('dbo.MACHINE_OPERATION_EQUIPMENT')) DROP INDEX UX_MO_EQUIP_code ON dbo.MACHINE_OPERATION_EQUIPMENT;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_MO_EQUIP_code_cg' AND object_id=OBJECT_ID('dbo.MACHINE_OPERATION_EQUIPMENT')) CREATE UNIQUE INDEX UX_MO_EQUIP_code_cg ON dbo.MACHINE_OPERATION_EQUIPMENT (code, client_group_id) WHERE deleted_at IS NULL;

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_MO_OPER_code' AND object_id=OBJECT_ID('dbo.MACHINE_OPERATION_OPERATOR')) DROP INDEX UX_MO_OPER_code ON dbo.MACHINE_OPERATION_OPERATOR;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_MO_OPER_code_cg' AND object_id=OBJECT_ID('dbo.MACHINE_OPERATION_OPERATOR')) CREATE UNIQUE INDEX UX_MO_OPER_code_cg ON dbo.MACHINE_OPERATION_OPERATOR (code, client_group_id) WHERE deleted_at IS NULL;

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_MO_OP_code' AND object_id=OBJECT_ID('dbo.MACHINE_OPERATION_OPERATION')) DROP INDEX UX_MO_OP_code ON dbo.MACHINE_OPERATION_OPERATION;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_MO_OP_code_cg' AND object_id=OBJECT_ID('dbo.MACHINE_OPERATION_OPERATION')) CREATE UNIQUE INDEX UX_MO_OP_code_cg ON dbo.MACHINE_OPERATION_OPERATION (code, client_group_id) WHERE deleted_at IS NULL;

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_MO_STOP_code' AND object_id=OBJECT_ID('dbo.MACHINE_OPERATION_STOP_REASON')) DROP INDEX UX_MO_STOP_code ON dbo.MACHINE_OPERATION_STOP_REASON;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_MO_STOP_code_cg' AND object_id=OBJECT_ID('dbo.MACHINE_OPERATION_STOP_REASON')) CREATE UNIQUE INDEX UX_MO_STOP_code_cg ON dbo.MACHINE_OPERATION_STOP_REASON (code, client_group_id) WHERE deleted_at IS NULL;

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_WEATHER_STATION_code' AND object_id=OBJECT_ID('dbo.WEATHER_STATION')) DROP INDEX UX_WEATHER_STATION_code ON dbo.WEATHER_STATION;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_WEATHER_STATION_code_cg' AND object_id=OBJECT_ID('dbo.WEATHER_STATION')) CREATE UNIQUE INDEX UX_WEATHER_STATION_code_cg ON dbo.WEATHER_STATION (code, client_group_id) WHERE deleted_at IS NULL;
GO

/* ---- 4) indices de leitura por tenant ---- */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_MO_FACT_cg' AND object_id=OBJECT_ID('dbo.MACHINE_OPERATION_FACT')) CREATE INDEX IX_MO_FACT_cg ON dbo.MACHINE_OPERATION_FACT (client_group_id);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_WEATHER_READING_cg' AND object_id=OBJECT_ID('dbo.WEATHER_READING')) CREATE INDEX IX_WEATHER_READING_cg ON dbo.WEATHER_READING (client_group_id);
GO
