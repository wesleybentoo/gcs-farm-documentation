/* =========================================================================
   MODULE_MULTITENANT_V3 - Variedades hibridas (nativas + por cliente).
   -------------------------------------------------------------------------
   ALVO: GCS_FARM (master). Rodar: sqlcmd -d GCS_FARM -I -b

   FARM_VARIETY ganha client_group_id (NULLABLE):
     - NULL          = variedade NATIVA (catalogo global, gerida so pelo MASTER);
     - <id do grupo> = variedade DO CLIENTE (o usuario daquele grupo cria/edita/exclui as suas).
   Culturas e caracteristicas seguem GLOBAIS (so master). Variedades sao hibridas.

   Indice unico passa de (culture_id, name) para (culture_id, name, client_group_id)
   filtrado -> permite nativa + por-cliente com o mesmo nome, e clientes distintos
   com o mesmo nome, sem colidir (NULL conta como um valor: 1 nativa por culture+name).
   Aditivo/idempotente. Roda depois de SETUP_FULL + MODULE_MULTITENANT_V1.
   ========================================================================= */
SET NOCOUNT ON;
GO

IF COL_LENGTH('dbo.FARM_VARIETY','client_group_id') IS NULL
  ALTER TABLE dbo.FARM_VARIETY ADD client_group_id BIGINT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_FARM_VARIETY_cliente_grupo')
  ALTER TABLE dbo.FARM_VARIETY ADD CONSTRAINT FK_FARM_VARIETY_cliente_grupo
    FOREIGN KEY (client_group_id) REFERENCES dbo.CLIENTE_GRUPO(id);
GO

-- troca a UNIQUE (culture_id,name) por (culture_id,name,client_group_id) filtrada
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FARM_VARIETY_culture_name' AND object_id=OBJECT_ID('dbo.FARM_VARIETY'))
  DROP INDEX UX_FARM_VARIETY_culture_name ON dbo.FARM_VARIETY;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FARM_VARIETY_culture_name_cg' AND object_id=OBJECT_ID('dbo.FARM_VARIETY'))
  CREATE UNIQUE INDEX UX_FARM_VARIETY_culture_name_cg
    ON dbo.FARM_VARIETY (culture_id, name, client_group_id) WHERE deleted_at IS NULL;
GO

-- indice de leitura por escopo (nativa + do proprio grupo)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_FARM_VARIETY_cg' AND object_id=OBJECT_ID('dbo.FARM_VARIETY'))
  CREATE INDEX IX_FARM_VARIETY_cg ON dbo.FARM_VARIETY (client_group_id) WHERE deleted_at IS NULL;
GO
