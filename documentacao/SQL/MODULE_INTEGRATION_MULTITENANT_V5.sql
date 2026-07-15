/* =========================================================================
   MODULE_INTEGRATION_MULTITENANT_V5 — Fase 5 (agendador por credencial).
   -------------------------------------------------------------------------
   CONFIG_SCHEDULER ganha credential_id (NULL = job GLOBAL: *.etl, weather,
   semanal). A reconciliacao (scheduler.service) passa a criar 1 linha por
   (credential_id, job_key) copiando a cadencia de INTEGRATION_CREDENTIAL_CONFIG.
   Fonte de verdade unica (markRunning/finishJob/UI seguem em CONFIG_SCHEDULER).
   Aditivo/idempotente. Rodar: sqlcmd -d GCS_FARM_TEST -I -b.
   ========================================================================= */
SET NOCOUNT ON;
GO

IF COL_LENGTH('dbo.CONFIG_SCHEDULER','credential_id') IS NULL
  ALTER TABLE dbo.CONFIG_SCHEDULER ADD credential_id BIGINT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_CONFIG_SCHEDULER_cred')
  ALTER TABLE dbo.CONFIG_SCHEDULER ADD CONSTRAINT FK_CONFIG_SCHEDULER_cred
    FOREIGN KEY (credential_id) REFERENCES dbo.INTEGRATION_CREDENTIAL(id);
GO

/* A chave unica (connector, job_key) bloquearia linhas por-credencial (mesmo
   job_key, credenciais diferentes). Troca por (connector, job_key, credential_id)
   filtrado — permite 1 job global (credential_id NULL) + 1 por credencial. */
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_CONFIG_SCHEDULER_cred_job' AND object_id=OBJECT_ID('dbo.CONFIG_SCHEDULER'))
  DROP INDEX IX_CONFIG_SCHEDULER_cred_job ON dbo.CONFIG_SCHEDULER;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_CONFIG_SCHEDULER_job' AND object_id=OBJECT_ID('dbo.CONFIG_SCHEDULER'))
  DROP INDEX UX_CONFIG_SCHEDULER_job ON dbo.CONFIG_SCHEDULER;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_CONFIG_SCHEDULER_job_cred' AND object_id=OBJECT_ID('dbo.CONFIG_SCHEDULER'))
  CREATE UNIQUE INDEX UX_CONFIG_SCHEDULER_job_cred ON dbo.CONFIG_SCHEDULER(connector, job_key, credential_id) WHERE deleted_at IS NULL;
GO
