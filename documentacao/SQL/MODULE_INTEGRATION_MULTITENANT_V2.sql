/* =========================================================================
   MODULE_INTEGRATION_MULTITENANT_V2 — Fase 2: CARIMBO DE TENANT no dado bruto.
   -------------------------------------------------------------------------
   Adiciona client_group_id (isolamento) ao RAW (CONNECTOR_GCS_FARM: FARMBOX_*
   e SOLINFTEC_*) e ao de/para CONFIG_CONNECTORS (no master), com DEFAULT 1
   (grupo GCS — realidade single-tenant) + backfill EM LOTES e indice de/para
   incluindo o grupo.

   ADITIVO/idempotente. Verificado por 2 revisores adversariais (workflow F2):
   todos os writes usam lista EXPLICITA de colunas; sem SELECT-estrela nem INSERT
   posicional; sem sequelize.sync(alter). Coluna nullable nova NAO entra em nenhum
   INSERT/MERGE atual -> zero regressao no single-tenant.

   DECISOES / FRONTEIRA:
   - So client_group_id no raw. farm_id continua DERIVADO do CONFIG_CONNECTORS
     (plot->field->farm) no materialize; NAO e materializado no raw (evita
     backfill via de/para, que seria trabalho de F4). Decisao explicita.
   - DEFAULT (1): novas linhas nascem carimbadas =1 sem tocar codigo. F3 REMOVE
     esses defaults (DF_*_cg) quando a ingestao passar a carimbar por credencial
     e ANTES do 2o tenant ingerir (senao mascara falta de stamp).
   - Indice de/para fica NAO-UNICO nesta fase (pode haver >1 linha por type,code).
     A unicidade por tenant (se aplicavel) e avaliada na F4.
   - O uso do client_group_id nos JOIN/DELETE do materialize (tenant-safe) e F4.

   ATENCAO OPERACIONAL: CONNECTOR_GCS_FARM e COMPARTILHADO (nao ha connector de
   teste). O ALTER ADD (coluna nullable) e metadata-only/instantaneo; o backfill
   roda EM LOTES (TOP 50000) p/ nao segurar lock em tabela grande. Rodar de
   preferencia com o scheduler/ingestao ocioso.

   Rodar: sqlcmd -d <MASTER> -I -b   (a Secao 3-4 alveja o master corrente;
   as Secoes 1-2 usam nome 3-part p/ o connector CONNECTOR_GCS_FARM).
   IrriControl fora desta leva.
   ========================================================================= */
SET NOCOUNT ON;
GO

/* ---- 1) RAW: client_group_id BIGINT NULL DEFAULT (1) em FARMBOX_ e SOLINFTEC_ ---- */
DECLARE @add NVARCHAR(MAX) = N'';
SELECT @add += 'ALTER TABLE CONNECTOR_GCS_FARM.dbo.' + QUOTENAME(t.name)
             + ' ADD client_group_id BIGINT NULL CONSTRAINT ' + QUOTENAME('DF_' + t.name + '_cg') + ' DEFAULT (1);' + CHAR(13) + CHAR(10)
FROM CONNECTOR_GCS_FARM.sys.tables t
WHERE (t.name LIKE 'FARMBOX[_]%' OR t.name LIKE 'SOLINFTEC[_]%')
  AND NOT EXISTS (SELECT 1 FROM CONNECTOR_GCS_FARM.sys.columns c WHERE c.object_id = t.object_id AND c.name = 'client_group_id');
IF LEN(@add) > 0 EXEC sys.sp_executesql @add;
GO

/* ---- 2) RAW: backfill client_group_id = 1 (GCS) EM LOTES onde NULL ---- */
DECLARE @bf NVARCHAR(MAX) = N'';
SELECT @bf += 'WHILE 1=1 BEGIN UPDATE TOP (50000) CONNECTOR_GCS_FARM.dbo.' + QUOTENAME(t.name)
            + ' SET client_group_id = 1 WHERE client_group_id IS NULL; IF @@ROWCOUNT = 0 BREAK; END;' + CHAR(13) + CHAR(10)
FROM CONNECTOR_GCS_FARM.sys.tables t
WHERE (t.name LIKE 'FARMBOX[_]%' OR t.name LIKE 'SOLINFTEC[_]%')
  AND EXISTS (SELECT 1 FROM CONNECTOR_GCS_FARM.sys.columns c WHERE c.object_id = t.object_id AND c.name = 'client_group_id');
IF LEN(@bf) > 0 EXEC sys.sp_executesql @bf;
GO

/* ---- 3) CONFIG_CONNECTORS (master): client_group_id NULL DEFAULT (1) + backfill ---- */
IF COL_LENGTH('dbo.CONFIG_CONNECTORS', 'client_group_id') IS NULL
  ALTER TABLE dbo.CONFIG_CONNECTORS ADD client_group_id BIGINT NULL CONSTRAINT DF_CONFIG_CONNECTORS_cg DEFAULT (1);
GO
UPDATE dbo.CONFIG_CONNECTORS SET client_group_id = 1 WHERE client_group_id IS NULL;
GO

/* ---- 4) de/para com o grupo: indice NAO-UNICO (type, code, client_group_id).
        O composto cobre (type,code) como prefixo mais a esquerda -> nenhum JOIN
        atual regride; nao-filtrado p/ nao exigir QUOTED_IDENTIFIER nos writers. ---- */
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_CONFIG_CONNECTORS_type_code' AND object_id = OBJECT_ID('dbo.CONFIG_CONNECTORS'))
  DROP INDEX IX_CONFIG_CONNECTORS_type_code ON dbo.CONFIG_CONNECTORS;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_CONFIG_CONNECTORS_type_code_cg' AND object_id = OBJECT_ID('dbo.CONFIG_CONNECTORS'))
  CREATE INDEX IX_CONFIG_CONNECTORS_type_code_cg ON dbo.CONFIG_CONNECTORS(type, code, client_group_id);
GO
