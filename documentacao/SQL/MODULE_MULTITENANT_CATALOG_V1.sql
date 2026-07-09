/* =========================================================================
   MODULE_MULTITENANT_CATALOG_V1 — escopo de GRUPO (copy-on-write) nos
   catálogos de CONFIGURAÇÃO. Adiciona o degrau "grupo" da escada de herança
   (talhão › fazenda › GRUPO › GLOBAL): client_group_id NULL = baseline GLOBAL;
   client_group_id = X = override do grupo X. A RESOLUÇÃO (mais-específico-vence)
   é feita no service; aqui só a estrutura + índices únicos cientes do escopo.
   Idempotente. Aplicar em GCS_FARM_TEST (homologar) e depois GCS_FARM.
   Requer sqlcmd -I (índices filtrados). Ver 07_Fase4_Isolamento_Multicliente.md.
   ========================================================================= */

/* ---- helper de padrão: ADD client_group_id (NULL) onde faltar ---- */
IF COL_LENGTH('dbo.MONITOR_TOLERANCE_DEFAULT','client_group_id') IS NULL
  ALTER TABLE dbo.MONITOR_TOLERANCE_DEFAULT ADD client_group_id BIGINT NULL;
GO
IF COL_LENGTH('dbo.MONITOR_TOLERANCE','client_group_id') IS NULL
  ALTER TABLE dbo.MONITOR_TOLERANCE ADD client_group_id BIGINT NULL;
GO
IF COL_LENGTH('dbo.MONITOR_METHODOLOGY','client_group_id') IS NULL
  ALTER TABLE dbo.MONITOR_METHODOLOGY ADD client_group_id BIGINT NULL;
GO
IF COL_LENGTH('dbo.FARM_PRODUCT_CARENCIA_DEFAULT','client_group_id') IS NULL
  ALTER TABLE dbo.FARM_PRODUCT_CARENCIA_DEFAULT ADD client_group_id BIGINT NULL;
GO
IF COL_LENGTH('dbo.FARM_PRODUCT_CARENCIA','client_group_id') IS NULL
  ALTER TABLE dbo.FARM_PRODUCT_CARENCIA ADD client_group_id BIGINT NULL;
GO
IF COL_LENGTH('dbo.FARM_PEST_THRESHOLD','client_group_id') IS NULL
  ALTER TABLE dbo.FARM_PEST_THRESHOLD ADD client_group_id BIGINT NULL;
GO
IF COL_LENGTH('dbo.FERT_INTERPRETATION_SET','client_group_id') IS NULL
  ALTER TABLE dbo.FERT_INTERPRETATION_SET ADD client_group_id BIGINT NULL;
GO
IF COL_LENGTH('dbo.FERT_EXPORT_SET','client_group_id') IS NULL
  ALTER TABLE dbo.FERT_EXPORT_SET ADD client_group_id BIGINT NULL;
GO

/* ---- FKs p/ CLIENTE_GRUPO (uma por tabela) ---- */
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_MONTOLDEF_cg')
  ALTER TABLE dbo.MONITOR_TOLERANCE_DEFAULT ADD CONSTRAINT FK_MONTOLDEF_cg FOREIGN KEY (client_group_id) REFERENCES dbo.CLIENTE_GRUPO(id);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_MONTOL_cg')
  ALTER TABLE dbo.MONITOR_TOLERANCE ADD CONSTRAINT FK_MONTOL_cg FOREIGN KEY (client_group_id) REFERENCES dbo.CLIENTE_GRUPO(id);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_MONMET_cg')
  ALTER TABLE dbo.MONITOR_METHODOLOGY ADD CONSTRAINT FK_MONMET_cg FOREIGN KEY (client_group_id) REFERENCES dbo.CLIENTE_GRUPO(id);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_FPCARDEF_cg')
  ALTER TABLE dbo.FARM_PRODUCT_CARENCIA_DEFAULT ADD CONSTRAINT FK_FPCARDEF_cg FOREIGN KEY (client_group_id) REFERENCES dbo.CLIENTE_GRUPO(id);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_FPCAR_cg')
  ALTER TABLE dbo.FARM_PRODUCT_CARENCIA ADD CONSTRAINT FK_FPCAR_cg FOREIGN KEY (client_group_id) REFERENCES dbo.CLIENTE_GRUPO(id);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_FPT_cg')
  ALTER TABLE dbo.FARM_PEST_THRESHOLD ADD CONSTRAINT FK_FPT_cg FOREIGN KEY (client_group_id) REFERENCES dbo.CLIENTE_GRUPO(id);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_FERTINTSET_cg')
  ALTER TABLE dbo.FERT_INTERPRETATION_SET ADD CONSTRAINT FK_FERTINTSET_cg FOREIGN KEY (client_group_id) REFERENCES dbo.CLIENTE_GRUPO(id);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_FERTEXPSET_cg')
  ALTER TABLE dbo.FERT_EXPORT_SET ADD CONSTRAINT FK_FERTEXPSET_cg FOREIGN KEY (client_group_id) REFERENCES dbo.CLIENTE_GRUPO(id);
GO

/* ---- índices únicos CIENTES DO ESCOPO (baseline global + override por grupo coexistem) ----
   NULL no índice único = 1 só linha global (SQL Server trata NULLs como iguais); e 1 linha
   por grupo. */

/* MONITOR_TOLERANCE_DEFAULT: (culture_id) -> (culture_id, client_group_id) */
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_MONITOR_TOLERANCE_DEFAULT' AND object_id=OBJECT_ID('dbo.MONITOR_TOLERANCE_DEFAULT'))
  DROP INDEX UQ_MONITOR_TOLERANCE_DEFAULT ON dbo.MONITOR_TOLERANCE_DEFAULT;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_MONTOLDEF_cg' AND object_id=OBJECT_ID('dbo.MONITOR_TOLERANCE_DEFAULT'))
  CREATE UNIQUE INDEX UQ_MONTOLDEF_cg ON dbo.MONITOR_TOLERANCE_DEFAULT(culture_id, client_group_id) WHERE deleted_at IS NULL;
GO
/* MONITOR_TOLERANCE: (farm_id,culture_id,variety_id) -> +client_group_id */
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_MONITOR_TOLERANCE' AND object_id=OBJECT_ID('dbo.MONITOR_TOLERANCE'))
  DROP INDEX UQ_MONITOR_TOLERANCE ON dbo.MONITOR_TOLERANCE;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_MONTOL_cg' AND object_id=OBJECT_ID('dbo.MONITOR_TOLERANCE'))
  CREATE UNIQUE INDEX UQ_MONTOL_cg ON dbo.MONITOR_TOLERANCE(farm_id, culture_id, variety_id, client_group_id) WHERE deleted_at IS NULL;
GO
/* MONITOR_METHODOLOGY: (farm_id) -> (farm_id, client_group_id) */
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_MONITOR_METHODOLOGY' AND object_id=OBJECT_ID('dbo.MONITOR_METHODOLOGY'))
  DROP INDEX UQ_MONITOR_METHODOLOGY ON dbo.MONITOR_METHODOLOGY;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_MONMET_cg' AND object_id=OBJECT_ID('dbo.MONITOR_METHODOLOGY'))
  CREATE UNIQUE INDEX UQ_MONMET_cg ON dbo.MONITOR_METHODOLOGY(farm_id, client_group_id) WHERE deleted_at IS NULL;
GO
/* FARM_PRODUCT_CARENCIA_DEFAULT: (category_id) -> (category_id, client_group_id) */
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_FPCARDEF_cat' AND object_id=OBJECT_ID('dbo.FARM_PRODUCT_CARENCIA_DEFAULT'))
  DROP INDEX UQ_FPCARDEF_cat ON dbo.FARM_PRODUCT_CARENCIA_DEFAULT;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_FPCARDEF_cg' AND object_id=OBJECT_ID('dbo.FARM_PRODUCT_CARENCIA_DEFAULT'))
  CREATE UNIQUE INDEX UQ_FPCARDEF_cg ON dbo.FARM_PRODUCT_CARENCIA_DEFAULT(category_id, client_group_id) WHERE deleted_at IS NULL;
GO
/* FARM_PRODUCT_CARENCIA: (product_id) -> (product_id, client_group_id) */
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_FPCAR_prod' AND object_id=OBJECT_ID('dbo.FARM_PRODUCT_CARENCIA'))
  DROP INDEX UQ_FPCAR_prod ON dbo.FARM_PRODUCT_CARENCIA;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_FPCAR_cg' AND object_id=OBJECT_ID('dbo.FARM_PRODUCT_CARENCIA'))
  CREATE UNIQUE INDEX UQ_FPCAR_cg ON dbo.FARM_PRODUCT_CARENCIA(product_id, client_group_id) WHERE deleted_at IS NULL;
GO
/* FERT_INTERPRETATION_SET: (code) + (1 default) -> por grupo */
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FERT_SET_code' AND object_id=OBJECT_ID('dbo.FERT_INTERPRETATION_SET'))
  DROP INDEX UX_FERT_SET_code ON dbo.FERT_INTERPRETATION_SET;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FERT_SET_code_cg' AND object_id=OBJECT_ID('dbo.FERT_INTERPRETATION_SET'))
  CREATE UNIQUE INDEX UX_FERT_SET_code_cg ON dbo.FERT_INTERPRETATION_SET(code, client_group_id) WHERE deleted_at IS NULL;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FERT_SET_default' AND object_id=OBJECT_ID('dbo.FERT_INTERPRETATION_SET'))
  DROP INDEX UX_FERT_SET_default ON dbo.FERT_INTERPRETATION_SET;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FERT_SET_default_cg' AND object_id=OBJECT_ID('dbo.FERT_INTERPRETATION_SET'))
  CREATE UNIQUE INDEX UX_FERT_SET_default_cg ON dbo.FERT_INTERPRETATION_SET(client_group_id) WHERE is_default=1 AND deleted_at IS NULL;
GO
/* FERT_EXPORT_SET: (code) + (1 default) -> por grupo */
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FERT_EXPORT_SET_code' AND object_id=OBJECT_ID('dbo.FERT_EXPORT_SET'))
  DROP INDEX UX_FERT_EXPORT_SET_code ON dbo.FERT_EXPORT_SET;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FERT_EXPSET_code_cg' AND object_id=OBJECT_ID('dbo.FERT_EXPORT_SET'))
  CREATE UNIQUE INDEX UX_FERT_EXPSET_code_cg ON dbo.FERT_EXPORT_SET(code, client_group_id) WHERE deleted_at IS NULL;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FERT_EXPORT_SET_onedefault' AND object_id=OBJECT_ID('dbo.FERT_EXPORT_SET'))
  DROP INDEX UX_FERT_EXPORT_SET_onedefault ON dbo.FERT_EXPORT_SET;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FERT_EXPSET_default_cg' AND object_id=OBJECT_ID('dbo.FERT_EXPORT_SET'))
  CREATE UNIQUE INDEX UX_FERT_EXPSET_default_cg ON dbo.FERT_EXPORT_SET(client_group_id) WHERE is_default=1 AND deleted_at IS NULL;
GO
