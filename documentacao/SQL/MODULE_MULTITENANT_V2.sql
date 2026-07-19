/* =========================================================================
   MODULE_MULTITENANT_V2 - client_group_id OBRIGATORIO em FARM_FARMS.
   -------------------------------------------------------------------------
   ALVO: GCS_FARM (master). Rodar: sqlcmd -d GCS_FARM -I -b

   Regra: TODA fazenda pertence a um cliente (CLIENTE_GRUPO) — nao pode ser NULL.
   O MODULE_MULTITENANT_V1 criou client_group_id NULLABLE; aqui fechamos:
     1) backfill de qualquer fazenda sem cliente -> grupo GCS (baseline);
     2) ALTER COLUMN NOT NULL.
   Em build do zero a FARM_FARMS esta vazia -> o NOT NULL aplica sem backfill;
   o seed-admin (ensureFarms) ja cria as fazendas com client_group_id. A FK
   FK_FARM_FARMS_cliente_grupo (V1) + NOT NULL = todo farm tem cliente valido.
   Aditivo/idempotente. Roda DEPOIS do MODULE_MULTITENANT_V1.
   ========================================================================= */
SET NOCOUNT ON;
GO

DECLARE @gcs BIGINT = (SELECT TOP 1 id FROM dbo.CLIENTE_GRUPO WHERE code='GCS' AND deleted_at IS NULL ORDER BY id);
IF @gcs IS NOT NULL
  UPDATE dbo.FARM_FARMS SET client_group_id=@gcs, updated_at=SYSUTCDATETIME() WHERE client_group_id IS NULL;
GO

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('dbo.FARM_FARMS') AND name='client_group_id' AND is_nullable=1)
   AND NOT EXISTS (SELECT 1 FROM dbo.FARM_FARMS WHERE client_group_id IS NULL)
  ALTER TABLE dbo.FARM_FARMS ALTER COLUMN client_group_id BIGINT NOT NULL;
GO
