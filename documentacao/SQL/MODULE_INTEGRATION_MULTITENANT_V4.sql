/* =========================================================================
   MODULE_INTEGRATION_MULTITENANT_V4 — Fase 4 (chave natural tenant-safe).
   -------------------------------------------------------------------------
   Índices únicos COMPOSTOS (farmbox_*_id, credential_id) nos pais materializados,
   filtrados por farmbox_*_id NOT NULL + deleted_at NULL (não afeta linhas manuais
   source='app' com farmbox_*_id NULL). É a chave que o materialize reescrito usa
   no MERGE ON (id-space por credencial). Aditivo (não existia índice em farmbox_*_id).
   Rodar: sqlcmd -d GCS_FARM_TEST -I -b (índices filtrados exigem QUOTED_IDENTIFIER).
   ========================================================================= */
SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FARM_PRODUCT_fb_cred' AND object_id=OBJECT_ID('dbo.FARM_PRODUCT'))
  CREATE UNIQUE INDEX UX_FARM_PRODUCT_fb_cred ON dbo.FARM_PRODUCT(farmbox_input_id, credential_id)
    WHERE farmbox_input_id IS NOT NULL AND deleted_at IS NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FARM_APPLICATION_fb_cred' AND object_id=OBJECT_ID('dbo.FARM_APPLICATION'))
  CREATE UNIQUE INDEX UX_FARM_APPLICATION_fb_cred ON dbo.FARM_APPLICATION(farmbox_application_id, credential_id)
    WHERE farmbox_application_id IS NOT NULL AND deleted_at IS NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FARM_MONITORING_fb_cred' AND object_id=OBJECT_ID('dbo.FARM_MONITORING'))
  CREATE UNIQUE INDEX UX_FARM_MONITORING_fb_cred ON dbo.FARM_MONITORING(farmbox_monitoring_id, credential_id)
    WHERE farmbox_monitoring_id IS NOT NULL AND deleted_at IS NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FARM_COUNT_fb_cred' AND object_id=OBJECT_ID('dbo.FARM_COUNT'))
  CREATE UNIQUE INDEX UX_FARM_COUNT_fb_cred ON dbo.FARM_COUNT(farmbox_count_id, credential_id)
    WHERE farmbox_count_id IS NOT NULL AND deleted_at IS NULL;
GO
