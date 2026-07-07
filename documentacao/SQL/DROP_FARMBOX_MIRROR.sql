/* =========================================================================
   DROP do ESPELHO FARMBOX_* do GCS_FARM  (Fase B — passo final)
   ---------------------------------------------------------------------------
   Remove as 29 tabelas espelho + as 4 views que as liam. O domínio FARM_* e o
   CONNECTOR_GCS_FARM (landing) NÃO são tocados. Idempotente/dinâmico.

   ⚠️ PRÉ-REQUISITO: o backend precisa já estar rodando o código da Fase B
   (materialização e serviços lendo o CONNECTOR direto). Se o código antigo
   (que grava/le o espelho) ainda estiver ativo, o ETL/telas quebram. Ordem:
     1) subir o código Fase B (restart)  →  2) rodar ESTE script.

   Validado no GCS_FARM_TEST: pós-drop, applications/estimate/seasons/rotation
   e o ETL completo rodam sem referência ao espelho.
   ========================================================================= */
SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;

-- 1) views que leem o espelho (nenhuma usada pelo app)
DROP VIEW IF EXISTS dbo.VW_FARMBOX_FIELD_NOTES_WITH_IMAGES;
DROP VIEW IF EXISTS dbo.VW_FARMBOX_HARVEST_UNMAPPED;
DROP VIEW IF EXISTS dbo.VW_FARMBOX_MONITORING_INFEST;
DROP VIEW IF EXISTS dbo.VW_FARMBOX_PLANTATION_SUMMARY;

-- 2) derruba as FKs das tabelas FARMBOX_* (evita ordem de dependência)
DECLARE @sql nvarchar(max) = '';
SELECT @sql += 'ALTER TABLE dbo.' + QUOTENAME(OBJECT_NAME(parent_object_id)) + ' DROP CONSTRAINT ' + QUOTENAME(name) + ';' + CHAR(10)
FROM sys.foreign_keys WHERE OBJECT_NAME(parent_object_id) LIKE 'FARMBOX[_]%';
IF LEN(@sql) > 0 EXEC sp_executesql @sql;

-- 3) derruba as tabelas espelho
SET @sql = '';
SELECT @sql += 'DROP TABLE IF EXISTS dbo.' + QUOTENAME(name) + ';' + CHAR(10)
FROM sys.tables WHERE name LIKE 'FARMBOX[_]%';
IF LEN(@sql) > 0 EXEC sp_executesql @sql;

-- 4) verificação
SELECT 'FARMBOX_* tabelas restantes' t, COUNT(*) n FROM sys.tables WHERE name LIKE 'FARMBOX[_]%'
UNION ALL SELECT 'views FARMBOX restantes', COUNT(*) FROM sys.views WHERE name LIKE '%FARMBOX%'
UNION ALL SELECT 'FARM_* (dominio) intactas', COUNT(*) FROM sys.tables WHERE name LIKE 'FARM[_]%';
