/* =========================================================================
   FERTILIDADE — ESCOPO do coeficiente de exportação (2º nível)
   ---------------------------------------------------------------------------
   Hoje FERT_CROP_EXPORT guarda 1 valor por (perfil, cultura, nutriente, basis).
   Passa a suportar 3 granularidades por nutriente, resolvidas do + específico:
     1) Variedade específica   -> variety_id preenchido
     2) Nível de tecnologia    -> tech_value preenchido (a tecnologia PRINCIPAL da variedade)
     3) Padrão da cultura      -> variety_id e tech_value NULL   (comportamento atual)

   A tecnologia principal da variedade fica em FARM_VARIETY.primary_tech (uma das
   tecnologias da característica "Tecnologia") — usada na resolução do cálculo.

   Idempotente. Aditivo: linhas existentes ficam com escopo "padrão" (colunas NULL).
   ========================================================================= */
SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;

/* 1) FARM_VARIETY.primary_tech — tecnologia principal (desempata multi-tecnologia) */
IF COL_LENGTH('dbo.FARM_VARIETY','primary_tech') IS NULL
  ALTER TABLE dbo.FARM_VARIETY ADD primary_tech NVARCHAR(120) NULL;
GO
SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;

/* 2) FERT_CROP_EXPORT: colunas de escopo */
IF COL_LENGTH('dbo.FERT_CROP_EXPORT','variety_id') IS NULL
  ALTER TABLE dbo.FERT_CROP_EXPORT ADD variety_id BIGINT NULL
    CONSTRAINT FK_FCE_variety FOREIGN KEY (variety_id) REFERENCES dbo.FARM_VARIETY(id);
GO
SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;

IF COL_LENGTH('dbo.FERT_CROP_EXPORT','tech_value') IS NULL
  ALTER TABLE dbo.FERT_CROP_EXPORT ADD tech_value NVARCHAR(120) NULL;
GO
SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;

/* 3) colunas computadas persistidas p/ a unique de escopo (colapsam os NULL) */
IF COL_LENGTH('dbo.FERT_CROP_EXPORT','k_variety') IS NULL
  ALTER TABLE dbo.FERT_CROP_EXPORT ADD k_variety AS (ISNULL(variety_id, CONVERT(BIGINT,0))) PERSISTED;
GO
SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;

IF COL_LENGTH('dbo.FERT_CROP_EXPORT','k_tech') IS NULL
  ALTER TABLE dbo.FERT_CROP_EXPORT ADD k_tech AS (ISNULL(tech_value, N'')) PERSISTED;
GO
SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;

/* 4) troca a unique: agora inclui o escopo (variedade/tecnologia/padrão coexistem) */
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FERT_CROP_EXPORT_set_nat' AND object_id=OBJECT_ID('dbo.FERT_CROP_EXPORT'))
  DROP INDEX UX_FERT_CROP_EXPORT_set_nat ON dbo.FERT_CROP_EXPORT;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FERT_CROP_EXPORT_scope' AND object_id=OBJECT_ID('dbo.FERT_CROP_EXPORT'))
  CREATE UNIQUE INDEX UX_FERT_CROP_EXPORT_scope
    ON dbo.FERT_CROP_EXPORT(set_id, culture_id, nutrient_id, basis, k_variety, k_tech)
    WHERE deleted_at IS NULL;
GO
SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;

/* ── verificação ─────────────────────────────────────────────────────────── */
SELECT 'crop_export total'  t, COUNT(*) n FROM dbo.FERT_CROP_EXPORT WHERE deleted_at IS NULL
UNION ALL SELECT 'escopo padrão',   COUNT(*) FROM dbo.FERT_CROP_EXPORT WHERE deleted_at IS NULL AND variety_id IS NULL AND tech_value IS NULL
UNION ALL SELECT 'escopo tecnologia', COUNT(*) FROM dbo.FERT_CROP_EXPORT WHERE deleted_at IS NULL AND variety_id IS NULL AND tech_value IS NOT NULL
UNION ALL SELECT 'escopo variedade',  COUNT(*) FROM dbo.FERT_CROP_EXPORT WHERE deleted_at IS NULL AND variety_id IS NOT NULL;
