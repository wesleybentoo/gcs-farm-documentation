/* =========================================================================
   MODULE_INTEGRATION_MULTITENANT_V3 — Fase 4 (fundacao): id-space POR CREDENCIAL.
   -------------------------------------------------------------------------
   Decisao do usuario: a fronteira do id-space (onde farmbox_id/plot.id/culture_id
   sao unicos) e a CONTA Farmbox = a CREDENCIAL, nao o grupo. Um grupo pode ter
   varias contas (multi-token). Entao o materialize passa a chavear por
   credential_id (isolamento de id-space); client_group_id segue p/ ACESSO.

   Este arquivo e a FUNDACAO ADITIVA da F4 (dado atual e descartavel -> reimport):
     1) FARM_PROVIDER_CATALOG_MAP — de/para POR CREDENCIAL de cultura/variedade
        (mantem FARM_CULTURE/FARM_VARIETY GLOBAIS; resolve o gotcha id-space).
     2) credential_id (NULL) no raw FARMBOX_ /SOLINFTEC_ + CONFIG_CONNECTORS +
        nos pais FARM_* (PRODUCT/APPLICATION/MONITORING/COUNT/DAY_MONITOR/NOTE) +
        FARM_FIELD_PLANTING. Backfill leve (single-tenant GCS).
     3) DROP UX_FARM_VARIETY_fb (trava rigida do 2o tenant no farmbox_variety_id).

   NAO faz (fica na reescrita do materialize, com teste do 2o tenant):
     - indices unicos COMPOSTOS (farbox_*_id, credential_id) nos pais;
     - reescrita dos JOIN/MERGE do materialize + estimate engine + seasons.service.

   Rodar: sqlcmd -d GCS_FARM_TEST -I -b. IrriControl fora desta leva.
   ========================================================================= */
SET NOCOUNT ON;
GO

/* credenciais GCS (single-tenant atual) p/ o backfill */
DECLARE @fbCred  BIGINT = (SELECT TOP 1 id FROM dbo.INTEGRATION_CREDENTIAL WHERE provider='FARMBOX'   AND deleted_at IS NULL ORDER BY id);
DECLARE @solCred BIGINT = (SELECT TOP 1 id FROM dbo.INTEGRATION_CREDENTIAL WHERE provider='SOLINFTEC' AND deleted_at IS NULL ORDER BY id);

/* ---- 1) FARM_PROVIDER_CATALOG_MAP: de/para por credencial (cultura/variedade) ---- */
IF OBJECT_ID('dbo.FARM_PROVIDER_CATALOG_MAP','U') IS NULL
BEGIN
  CREATE TABLE dbo.FARM_PROVIDER_CATALOG_MAP (
    id               BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_PROVIDER_CATALOG_MAP PRIMARY KEY,
    client_group_id  BIGINT      NOT NULL,                       -- acesso (grupo dono)
    credential_id    BIGINT      NULL,                           -- id-space (conta Farmbox); NULL = legado
    provider         VARCHAR(20) NOT NULL CONSTRAINT DF_FPCM_provider DEFAULT 'farmbox',
    entity_type      VARCHAR(12) NOT NULL,                       -- 'culture' | 'variety'
    external_id      INT         NOT NULL,                       -- record.culture_id / variety_id (por-conta)
    culture_id       BIGINT      NULL,
    variety_id       BIGINT      NULL,
    created_at       DATETIME2(3) NOT NULL CONSTRAINT DF_FPCM_created DEFAULT SYSUTCDATETIME(),
    updated_at       DATETIME2(3) NULL,
    deleted_at       DATETIME2(3) NULL,
    CONSTRAINT FK_FPCM_group   FOREIGN KEY (client_group_id) REFERENCES dbo.CLIENTE_GRUPO(id),
    CONSTRAINT FK_FPCM_cred    FOREIGN KEY (credential_id)   REFERENCES dbo.INTEGRATION_CREDENTIAL(id),
    CONSTRAINT FK_FPCM_culture FOREIGN KEY (culture_id)      REFERENCES dbo.FARM_CULTURE(id),
    CONSTRAINT FK_FPCM_variety FOREIGN KEY (variety_id)      REFERENCES dbo.FARM_VARIETY(id),
    CONSTRAINT CK_FPCM_target  CHECK (
      (entity_type='culture' AND culture_id IS NOT NULL AND variety_id IS NULL) OR
      (entity_type='variety' AND variety_id IS NOT NULL AND culture_id IS NULL))
  );
  /* de/para unico POR CREDENCIAL (external_id escopado pela conta -> sem colisao entre contas) */
  CREATE UNIQUE INDEX UX_FPCM ON dbo.FARM_PROVIDER_CATALOG_MAP(credential_id, provider, entity_type, external_id) WHERE deleted_at IS NULL;
  CREATE INDEX IX_FPCM_culture ON dbo.FARM_PROVIDER_CATALOG_MAP(culture_id) WHERE deleted_at IS NULL;
  CREATE INDEX IX_FPCM_variety ON dbo.FARM_PROVIDER_CATALOG_MAP(variety_id) WHERE deleted_at IS NULL;
END
GO

/* 1b) backfill do mapa a partir das pontes 1:1 legadas (single-tenant GCS = credencial Farmbox) */
DECLARE @fbCred2 BIGINT = (SELECT TOP 1 id FROM dbo.INTEGRATION_CREDENTIAL WHERE provider='FARMBOX' AND deleted_at IS NULL ORDER BY id);
DECLARE @gcs BIGINT = (SELECT id FROM dbo.CLIENTE_GRUPO WHERE code='GCS' AND deleted_at IS NULL);
INSERT INTO dbo.FARM_PROVIDER_CATALOG_MAP (client_group_id, credential_id, provider, entity_type, external_id, culture_id)
SELECT @gcs, @fbCred2, 'farmbox', 'culture', c.farmbox_culture_id, c.id
  FROM dbo.FARM_CULTURE c
 WHERE c.farmbox_culture_id IS NOT NULL AND c.deleted_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM dbo.FARM_PROVIDER_CATALOG_MAP m WHERE m.credential_id=@fbCred2 AND m.provider='farmbox' AND m.entity_type='culture' AND m.external_id=c.farmbox_culture_id AND m.deleted_at IS NULL);
INSERT INTO dbo.FARM_PROVIDER_CATALOG_MAP (client_group_id, credential_id, provider, entity_type, external_id, variety_id)
SELECT @gcs, @fbCred2, 'farmbox', 'variety', v.farmbox_variety_id, v.id
  FROM dbo.FARM_VARIETY v
 WHERE v.farmbox_variety_id IS NOT NULL AND v.deleted_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM dbo.FARM_PROVIDER_CATALOG_MAP m WHERE m.credential_id=@fbCred2 AND m.provider='farmbox' AND m.entity_type='variety' AND m.external_id=v.farmbox_variety_id AND m.deleted_at IS NULL);
GO

/* ---- 2) credential_id (NULL) no RAW FARMBOX_/SOLINFTEC_ + backfill por provider ---- */
DECLARE @add NVARCHAR(MAX) = N'';
SELECT @add += 'ALTER TABLE CONNECTOR_GCS_FARM.dbo.' + QUOTENAME(t.name) + ' ADD credential_id BIGINT NULL;' + CHAR(13) + CHAR(10)
FROM CONNECTOR_GCS_FARM.sys.tables t
WHERE (t.name LIKE 'FARMBOX[_]%' OR t.name LIKE 'SOLINFTEC[_]%')
  AND NOT EXISTS (SELECT 1 FROM CONNECTOR_GCS_FARM.sys.columns c WHERE c.object_id=t.object_id AND c.name='credential_id');
IF LEN(@add) > 0 EXEC sys.sp_executesql @add;
GO
DECLARE @fbC BIGINT = (SELECT TOP 1 id FROM dbo.INTEGRATION_CREDENTIAL WHERE provider='FARMBOX' AND deleted_at IS NULL ORDER BY id);
DECLARE @solC BIGINT = (SELECT TOP 1 id FROM dbo.INTEGRATION_CREDENTIAL WHERE provider='SOLINFTEC' AND deleted_at IS NULL ORDER BY id);
DECLARE @bf NVARCHAR(MAX) = N'';
SELECT @bf += 'UPDATE CONNECTOR_GCS_FARM.dbo.' + QUOTENAME(t.name)
            + ' SET credential_id = ' + CONVERT(VARCHAR(20), CASE WHEN t.name LIKE 'FARMBOX[_]%' THEN @fbC ELSE @solC END)
            + ' WHERE credential_id IS NULL;' + CHAR(13) + CHAR(10)
FROM CONNECTOR_GCS_FARM.sys.tables t
WHERE (t.name LIKE 'FARMBOX[_]%' OR t.name LIKE 'SOLINFTEC[_]%')
  AND EXISTS (SELECT 1 FROM CONNECTOR_GCS_FARM.sys.columns c WHERE c.object_id=t.object_id AND c.name='credential_id');
IF LEN(@bf) > 0 EXEC sys.sp_executesql @bf;
GO

/* ---- 3) credential_id em CONFIG_CONNECTORS (de/para de talhao por conta) + backfill ---- */
IF COL_LENGTH('dbo.CONFIG_CONNECTORS','credential_id') IS NULL
  ALTER TABLE dbo.CONFIG_CONNECTORS ADD credential_id BIGINT NULL;
GO
DECLARE @fbC3 BIGINT = (SELECT TOP 1 id FROM dbo.INTEGRATION_CREDENTIAL WHERE provider='FARMBOX' AND deleted_at IS NULL ORDER BY id);
UPDATE dbo.CONFIG_CONNECTORS SET credential_id = @fbC3 WHERE type='farmbox' AND credential_id IS NULL;
GO

/* ---- 4) credential_id nos PAIS FARM_* + DAY_MONITOR + NOTE + FIELD_PLANTING (aditivo; re-materialize preenche) ---- */
IF COL_LENGTH('dbo.FARM_PRODUCT','credential_id')               IS NULL ALTER TABLE dbo.FARM_PRODUCT               ADD credential_id BIGINT NULL;
IF COL_LENGTH('dbo.FARM_APPLICATION','credential_id')           IS NULL ALTER TABLE dbo.FARM_APPLICATION           ADD credential_id BIGINT NULL;
IF COL_LENGTH('dbo.FARM_MONITORING','credential_id')            IS NULL ALTER TABLE dbo.FARM_MONITORING            ADD credential_id BIGINT NULL;
IF COL_LENGTH('dbo.FARM_COUNT','credential_id')                 IS NULL ALTER TABLE dbo.FARM_COUNT                 ADD credential_id BIGINT NULL;
IF COL_LENGTH('dbo.FARM_MONITORING_DAY_MONITOR','credential_id') IS NULL ALTER TABLE dbo.FARM_MONITORING_DAY_MONITOR ADD credential_id BIGINT NULL;
IF COL_LENGTH('dbo.FARM_MONITORING_NOTE','credential_id')       IS NULL ALTER TABLE dbo.FARM_MONITORING_NOTE       ADD credential_id BIGINT NULL;
IF COL_LENGTH('dbo.FARM_FIELD_PLANTING','credential_id')        IS NULL ALTER TABLE dbo.FARM_FIELD_PLANTING        ADD credential_id BIGINT NULL;
GO
/* client_group_id (ACESSO) nos catalogos de dado SEM farm_id proprio (produto, amostrador) */
IF COL_LENGTH('dbo.FARM_PRODUCT','client_group_id')             IS NULL ALTER TABLE dbo.FARM_PRODUCT               ADD client_group_id BIGINT NULL;
IF COL_LENGTH('dbo.FARM_MONITORING_DAY_MONITOR','client_group_id') IS NULL ALTER TABLE dbo.FARM_MONITORING_DAY_MONITOR ADD client_group_id BIGINT NULL;
GO

/* ---- 5) DROP da trava rigida do 2o tenant no farmbox_variety_id ---- */
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FARM_VARIETY_fb' AND object_id=OBJECT_ID('dbo.FARM_VARIETY'))
  DROP INDEX UX_FARM_VARIETY_fb ON dbo.FARM_VARIETY;
GO
