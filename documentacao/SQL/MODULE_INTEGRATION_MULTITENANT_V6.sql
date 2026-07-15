/* =========================================================================
   MODULE_INTEGRATION_MULTITENANT_V6 - Isolamento do LANDING raw por credencial.
   -------------------------------------------------------------------------
   ALVO: CONNECTOR_GCS_FARM (tabelas raw FARMBOX_*). Rodar:
     sqlcmd -d CONNECTOR_GCS_FARM -I -b -f 65001

   PROBLEMA (auditoria A4 / achados #1/#3): upsertRaw fazia MERGE ON so por
   farbox_id/record_id e os indices unicos UX_FARMBOX_* eram single-col. Mas o
   id do Farmbox e unico apenas DENTRO de uma conta (= por CREDENCIAL). Com 2
   credenciais, um farbox_id colidente casaria a linha da 1a conta e o MERGE a
   sobrescreveria trocando credential_id (clobber + vazamento cross-tenant); e
   o indice single-col rejeitaria 2 linhas vivas com o mesmo farbox_id.

   FIX: troca cada UX_FARMBOX_*(chave) por COMPOSTO (chave, credential_id)
   filtrado WHERE deleted_at IS NULL. Pareia com o MERGE ON ...AND credential_id
   do upsertRaw (farmbox.service.ts). credential_id ja esta backfillado (0 NULL
   no single-tenant) -> o composto constroi sem colisao.

   Aditivo/idempotente: cria o composto ANTES de dropar o single-col; so age em
   tabela que tem credential_id. Nao toca dados. Deploy-order-safe: se a coluna
   credential_id nao existir (V3 nao aplicado), a tabela e pulada.
   ========================================================================= */
SET NOCOUNT ON;
GO

DECLARE @t TABLE (tbl SYSNAME, ux SYSNAME, keycol SYSNAME);
INSERT INTO @t (tbl, ux, keycol) VALUES
 ('FARMBOX_APPLICATION',              'UX_FARMBOX_APP_id',          'farmbox_id'),
 ('FARMBOX_APPLICATION_PROGRESS',     'UX_FARMBOX_APP_PROG_id',     'farmbox_id'),
 ('FARMBOX_BATCH',                    'UX_FARMBOX_BATCH_id',        'farmbox_id'),
 ('FARMBOX_COUNT_DAY',                'UX_FARMBOX_COUNT_DAY_id',    'farmbox_id'),
 ('FARMBOX_COUNT_MONITORING',         'UX_FARMBOX_COUNT_MON_id',    'farmbox_id'),
 ('FARMBOX_FARM',                     'UX_FARMBOX_FARM_id',         'farmbox_id'),
 ('FARMBOX_HARVEST',                  'UX_FARMBOX_HARVEST_id',      'farmbox_id'),
 ('FARMBOX_INPUT',                    'UX_FARMBOX_INPUT_id',        'farmbox_id'),
 ('FARMBOX_INPUT_VALUE',              'UX_FARMBOX_INVAL_id',        'farmbox_id'),
 ('FARMBOX_MONITORING',              'UX_FARMBOX_MONITORING_id',    'farmbox_id'),
 ('FARMBOX_MONITORING_DAY_RESULT',    'UX_FARMBOX_MDR_record_id',   'record_id'),
 ('FARMBOX_MONITORING_NOTE',          'UX_FARMBOX_MON_NOTE_id',     'farmbox_id'),
 ('FARMBOX_MONITORING_TOLERANCE',     'UX_FARMBOX_MON_TOL_id',      'farmbox_id'),
 ('FARMBOX_MOVIMENTATION',            'UX_FARMBOX_MOVIM_id',        'farmbox_id'),
 ('FARMBOX_NOTE',                     'UX_FARMBOX_NOTE_id',         'farmbox_id'),
 ('FARMBOX_PHENOLOGICAL_STAGE_SAMPLE','UX_FARMBOX_PHENO_SAMP_id',   'farmbox_id'),
 ('FARMBOX_PLANTATION',               'UX_FARMBOX_PLANTATION_id',   'farmbox_id'),
 ('FARMBOX_PLOT',                     'UX_FARMBOX_PLOT_id',         'farmbox_id'),
 ('FARMBOX_PLUVIOMETER',              'UX_FARMBOX_PLUVIOMETER_id',  'farmbox_id'),
 ('FARMBOX_PLUVIOMETER_MONITORING',   'UX_FARMBOX_PLUVIO_MON_id',   'farmbox_id'),
 ('FARMBOX_REF_ACTIVITY_TYPE',        'UX_FARMBOX_REF_ACTTYPE_id',  'farmbox_id'),
 ('FARMBOX_REF_BEAK',                 'UX_FARMBOX_REF_BEAK_id',     'farmbox_id'),
 ('FARMBOX_REF_CULTURE',              'UX_FARMBOX_REF_CULTURE_id',  'farmbox_id'),
 ('FARMBOX_REF_EQUIPMENT',            'UX_FARMBOX_REF_EQUIP_id',    'farmbox_id'),
 ('FARMBOX_REF_INPUT_TYPE',           'UX_FARMBOX_REF_INTYPE_id',   'farmbox_id'),
 ('FARMBOX_REF_PHENOLOGICAL_STAGE',   'UX_FARMBOX_REF_PHENO_id',    'farmbox_id'),
 ('FARMBOX_REF_USER',                 'UX_FARMBOX_REF_USER_id',     'farmbox_id'),
 ('FARMBOX_REF_VARIETY',              'UX_FARMBOX_REF_VARIETY_id',  'farmbox_id'),
 ('FARMBOX_RESOURCE_SUBSCRIPTION',    'UX_FARMBOX_RES_SUB_id',      'farmbox_id'),
 ('FARMBOX_STORAGE',                  'UX_FARMBOX_STORAGE_id',      'farmbox_id'),
 ('FARMBOX_TRAP_MONITORING',          'UX_FARMBOX_TRAP_MON_id',     'farmbox_id');

DECLARE @tbl SYSNAME, @ux SYSNAME, @kc SYSNAME, @new SYSNAME, @sql NVARCHAR(MAX);
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT tbl, ux, keycol FROM @t;
OPEN cur;
FETCH NEXT FROM cur INTO @tbl, @ux, @kc;
WHILE @@FETCH_STATUS = 0
BEGIN
  IF OBJECT_ID('dbo.' + @tbl, 'U') IS NOT NULL
     AND COL_LENGTH('dbo.' + @tbl, 'credential_id') IS NOT NULL
  BEGIN
    SET @new = @ux + '_cred';
    -- 1) cria o COMPOSTO (idempotente) antes de dropar o antigo
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = @new AND object_id = OBJECT_ID('dbo.' + @tbl))
    BEGIN
      SET @sql = 'CREATE UNIQUE INDEX ' + QUOTENAME(@new) + ' ON dbo.' + QUOTENAME(@tbl)
               + ' (' + QUOTENAME(@kc) + ', credential_id) WHERE deleted_at IS NULL;';
      EXEC sys.sp_executesql @sql;
      PRINT 'criado ' + @new + ' em ' + @tbl;
    END
    -- 2) dropa o single-col antigo (so depois do composto existir)
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = @ux AND object_id = OBJECT_ID('dbo.' + @tbl))
    BEGIN
      SET @sql = 'DROP INDEX ' + QUOTENAME(@ux) + ' ON dbo.' + QUOTENAME(@tbl) + ';';
      EXEC sys.sp_executesql @sql;
      PRINT 'dropado ' + @ux + ' em ' + @tbl;
    END
  END
  ELSE PRINT 'pulado (sem credential_id): ' + @tbl;
  FETCH NEXT FROM cur INTO @tbl, @ux, @kc;
END
CLOSE cur; DEALLOCATE cur;
GO
