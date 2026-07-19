/* =========================================================================
   MODULE_MULTITENANT_V4 - Cadastros Solinftec por CLIENTE (client_group_id).
   -------------------------------------------------------------------------
   ALVO: CONNECTOR_GCS_FARM. Rodar: sqlcmd -d CONNECTOR_GCS_FARM -I -b -f 65001

   As tabelas SOLINFTEC_CAD_* já ganharam client_group_id/credential_id no
   MODULE_INTEGRATION_MULTITENANT (F2), mas a dedup/reconciliação de entradas
   era GLOBAL: o índice único UX_SOLINFTEC_CAD_ENTRY_nk cobria só (cad_key,
   natural_key). Com 2+ clientes isso COLIDE (um cliente sobrescreve/zera os
   cadastros do outro). Aqui o índice passa a incluir client_group_id, isolando
   os cadastros por cliente (um cadastro vale p/ o cliente inteiro, todas as
   fazendas). O CATÁLOGO (SOLINFTEC_CAD_CATALOG) segue GLOBAL (as 16 definições
   de cadastro são iguais p/ todos). Aditivo/idempotente.
   ========================================================================= */
SET NOCOUNT ON;
GO

-- troca a UNIQUE (cad_key,natural_key) por (cad_key,natural_key,client_group_id) filtrada
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_SOLINFTEC_CAD_ENTRY_nk' AND object_id=OBJECT_ID('dbo.SOLINFTEC_CAD_ENTRY'))
  DROP INDEX UX_SOLINFTEC_CAD_ENTRY_nk ON dbo.SOLINFTEC_CAD_ENTRY;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_SOLINFTEC_CAD_ENTRY_nk_cg' AND object_id=OBJECT_ID('dbo.SOLINFTEC_CAD_ENTRY'))
  CREATE UNIQUE INDEX UX_SOLINFTEC_CAD_ENTRY_nk_cg
    ON dbo.SOLINFTEC_CAD_ENTRY (cad_key, natural_key, client_group_id)
    WHERE natural_key IS NOT NULL AND deleted_at IS NULL;
GO

-- índice de leitura por (cliente, cadastro) — a tela lista por cad_key dentro do cliente
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_SOLINFTEC_CAD_ENTRY_cg_cad' AND object_id=OBJECT_ID('dbo.SOLINFTEC_CAD_ENTRY'))
  CREATE INDEX IX_SOLINFTEC_CAD_ENTRY_cg_cad
    ON dbo.SOLINFTEC_CAD_ENTRY (client_group_id, cad_key) WHERE deleted_at IS NULL;
GO

-- a view de lookup (usada pelo enrichDims do ETL) precisa expor client_group_id
-- p/ o enriquecimento dos dims MACHINE_OPERATION_* casar por (code, cliente).
CREATE OR ALTER VIEW dbo.SOLINFTEC_CAD_LOOKUP AS
SELECT e.cad_key, e.code, e.description, e.payload, e.client_group_id
FROM dbo.SOLINFTEC_CAD_ENTRY e
JOIN dbo.SOLINFTEC_CAD_CATALOG c ON c.cad_key = e.cad_key
WHERE c.is_lookup = 1 AND c.deleted_at IS NULL
  AND e.is_current = 1 AND e.deleted_at IS NULL;
GO
