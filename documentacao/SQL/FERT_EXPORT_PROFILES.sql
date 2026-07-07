/* =========================================================================
   FERTILIDADE — PERFIS de Exportação de Nutrientes  (espelha os níveis críticos)
   ---------------------------------------------------------------------------
   Dá ao FERT_CROP_EXPORT o mesmo padrão de PERFIL/VISÃO do FERT_INTERPRETATION_SET:
     - nova FERT_EXPORT_SET (o perfil pesquisado: ICL, Embrapa, Fundação MT…);
     - FERT_CROP_EXPORT ganha set_id (FK) e a unique passa a incluí-lo → vários
       valores pesquisados coexistem por cultura×nutriente×base.
   Migração: hoje só há base ICL (5 sources = ICL + variações por cultura); tudo
   vai para 1 perfil ICL (is_default); o texto em `source` fica como detalhe.
   Idempotente. Rodar com sqlcmd -I.
   ========================================================================= */
SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;

/* 1) FERT_EXPORT_SET — o perfil (espelho de FERT_INTERPRETATION_SET) */
IF OBJECT_ID('dbo.FERT_EXPORT_SET') IS NULL
BEGIN
  CREATE TABLE dbo.FERT_EXPORT_SET (
    id          BIGINT IDENTITY(1,1) CONSTRAINT PK_FERT_EXPORT_SET PRIMARY KEY,
    code        VARCHAR(40)   NOT NULL,
    name        NVARCHAR(120) NOT NULL,
    agronomist  NVARCHAR(200) NULL,
    description NVARCHAR(500) NULL,
    is_default  BIT NOT NULL CONSTRAINT DF_FES_default DEFAULT 0,
    active      BIT NOT NULL CONSTRAINT DF_FES_active  DEFAULT 1,
    created_at  DATETIME2(3) NOT NULL CONSTRAINT DF_FES_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3) NULL,
    deleted_at  DATETIME2(3) NULL
  );
  CREATE UNIQUE INDEX UX_FERT_EXPORT_SET_code ON dbo.FERT_EXPORT_SET(code) WHERE deleted_at IS NULL;
END

/* 2) perfil ICL (default) — base pesquisada inicial.
   Literais montados com NCHAR() para serem INDEPENDENTES do codepage do sqlcmd:
   aplicar sem `-f 65001` NÃO corrompe mais os acentos (ç=231, ã=227, õ=245, —=8212). */
IF NOT EXISTS (SELECT 1 FROM dbo.FERT_EXPORT_SET WHERE code='ICL' AND deleted_at IS NULL)
  INSERT INTO dbo.FERT_EXPORT_SET (code, name, agronomist, description, is_default)
  VALUES ('ICL',
          N'ICL (Nutri' + NCHAR(231) + NCHAR(227) + N'o Mineral)',
          N'ICL ' + NCHAR(8212) + N' Nutri' + NCHAR(231) + NCHAR(227) + N'o mineral de plantas',
          N'Coeficientes de exporta' + NCHAR(231) + NCHAR(227) + N'o/extra' + NCHAR(231) + NCHAR(227)
            + N'o da literatura ICL (base inicial; inclui convers' + NCHAR(245) + N'es por cultura).',
          1);

/* 2b) self-heal: corrige o perfil ICL se já foi aplicado com codepage errado (mojibake).
   Cobre name, agronomist E description (as três colunas usam literais acentuados). */
UPDATE dbo.FERT_EXPORT_SET
   SET name        = N'ICL (Nutri' + NCHAR(231) + NCHAR(227) + N'o Mineral)',
       agronomist  = N'ICL ' + NCHAR(8212) + N' Nutri' + NCHAR(231) + NCHAR(227) + N'o mineral de plantas',
       description = N'Coeficientes de exporta' + NCHAR(231) + NCHAR(227) + N'o/extra' + NCHAR(231) + NCHAR(227)
                     + N'o da literatura ICL (base inicial; inclui convers' + NCHAR(245) + N'es por cultura).',
       updated_at  = SYSUTCDATETIME()
 WHERE code='ICL' AND deleted_at IS NULL
   AND (name LIKE '%Ã%' OR name LIKE '%Â%' OR agronomist LIKE '%Ã%' OR agronomist LIKE '%â%'
        OR description LIKE '%Ã%' OR description LIKE '%Â%');

/* 2c) invariante de UM único padrão, garantida pelo BANCO: no máximo uma linha ativa
   com is_default=1. Torna impossível (mesmo sob concorrência) haver dois perfis padrão. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FERT_EXPORT_SET_onedefault' AND object_id=OBJECT_ID('dbo.FERT_EXPORT_SET'))
  CREATE UNIQUE INDEX UX_FERT_EXPORT_SET_onedefault ON dbo.FERT_EXPORT_SET(is_default)
    WHERE is_default = 1 AND deleted_at IS NULL;

/* 3) set_id em FERT_CROP_EXPORT (FK) */
IF COL_LENGTH('dbo.FERT_CROP_EXPORT','set_id') IS NULL
  ALTER TABLE dbo.FERT_CROP_EXPORT ADD set_id BIGINT NULL CONSTRAINT FK_FCE_set REFERENCES dbo.FERT_EXPORT_SET(id);
GO
SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;

/* 4) backfill: toda linha existente → perfil ICL */
UPDATE ce SET ce.set_id = s.id
FROM dbo.FERT_CROP_EXPORT ce
CROSS JOIN (SELECT TOP 1 id FROM dbo.FERT_EXPORT_SET WHERE code='ICL' AND deleted_at IS NULL) s
WHERE ce.set_id IS NULL;

/* 5) set_id NOT NULL (após backfill; idempotente) */
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('dbo.FERT_CROP_EXPORT') AND name='set_id' AND is_nullable=1)
   AND NOT EXISTS (SELECT 1 FROM dbo.FERT_CROP_EXPORT WHERE set_id IS NULL AND deleted_at IS NULL)
  ALTER TABLE dbo.FERT_CROP_EXPORT ALTER COLUMN set_id BIGINT NOT NULL;

/* 6) troca a unique natural: agora inclui set_id (permite N perfis) */
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FERT_CROP_EXPORT_nat' AND object_id=OBJECT_ID('dbo.FERT_CROP_EXPORT'))
  DROP INDEX UX_FERT_CROP_EXPORT_nat ON dbo.FERT_CROP_EXPORT;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_FERT_CROP_EXPORT_set_nat' AND object_id=OBJECT_ID('dbo.FERT_CROP_EXPORT'))
  CREATE UNIQUE INDEX UX_FERT_CROP_EXPORT_set_nat ON dbo.FERT_CROP_EXPORT(set_id, culture_id, nutrient_id, basis) WHERE deleted_at IS NULL;
GO
SET QUOTED_IDENTIFIER ON; SET NOCOUNT ON;

/* ── verificação ─────────────────────────────────────────────────────────── */
SELECT 'FERT_EXPORT_SET' t, COUNT(*) n FROM dbo.FERT_EXPORT_SET WHERE deleted_at IS NULL
UNION ALL SELECT 'crop_export c/ set_id', COUNT(*) FROM dbo.FERT_CROP_EXPORT WHERE set_id IS NOT NULL AND deleted_at IS NULL
UNION ALL SELECT 'crop_export SEM set_id', COUNT(*) FROM dbo.FERT_CROP_EXPORT WHERE set_id IS NULL AND deleted_at IS NULL;
