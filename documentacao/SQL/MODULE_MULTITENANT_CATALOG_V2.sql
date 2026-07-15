/* =========================================================================
   MODULE_MULTITENANT_CATALOG_V2 - UQ de FARM_PEST_THRESHOLD por client_group_id.
   -------------------------------------------------------------------------
   ALVO: GCS_FARM / GCS_FARM_TEST (master). Rodar:
     sqlcmd -d GCS_FARM_TEST -I -b

   PROBLEMA (auditoria #2): o bloco 4c do materialize (farmMaterialize.service)
   grava 1 linha de limite POR client_group_id (NOT EXISTS filtrado por grupo),
   mas o indice unico UQ_FARM_PEST_THRESHOLD(pest_id, param_name, phase,
   culture_id) NAO inclui client_group_id -> era a UNICA tabela do
   MODULE_MULTITENANT_CATALOG_V1 que nao teve a UQ reconstruida. Com um 2o tenant
   compartilhando praga+cultura globais (FARM_PEST/FARM_CULTURE sao globais), o 4c
   tenta inserir a mesma tupla com outro client_group_id -> 2601/2627 -> a
   materializacao INTEIRA (transacao unica, todos os tenants) faz rollback.

   FIX: recria a UQ incluindo client_group_id (mesmo padrao das outras 7 tabelas
   do V1). Aditivo/idempotente. Nao toca dados.
   ========================================================================= */
SET NOCOUNT ON;
GO

IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_FARM_PEST_THRESHOLD' AND object_id=OBJECT_ID('dbo.FARM_PEST_THRESHOLD'))
  DROP INDEX UQ_FARM_PEST_THRESHOLD ON dbo.FARM_PEST_THRESHOLD;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_FARM_PEST_THRESHOLD_cg' AND object_id=OBJECT_ID('dbo.FARM_PEST_THRESHOLD'))
  CREATE UNIQUE INDEX UQ_FARM_PEST_THRESHOLD_cg
    ON dbo.FARM_PEST_THRESHOLD (pest_id, param_name, phase, culture_id, client_group_id)
    WHERE deleted_at IS NULL;
GO
