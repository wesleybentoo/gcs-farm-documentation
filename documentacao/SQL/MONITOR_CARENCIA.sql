/* =========================================================================
   CARENCIA DE INSUMOS — default por CATEGORIA de produto + override por produto
   Dois prazos (Farmbox): Reentrada (pessoa entrar no talhao) e Colheita.
   - FARM_PRODUCT_CARENCIA_DEFAULT: padrao por categoria de produto.
   - FARM_PRODUCT_CARENCIA: override por produto (bulario).
   Resolucao (na view): override(produto) > default(categoria). O bloqueio de
   MONITORAMENTO usa a REENTRADA. Idempotente.
   Aplicar com sqlcmd -I (quoted identifiers p/ os indices filtrados).
   ========================================================================= */
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON; SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.FARM_PRODUCT_CARENCIA_DEFAULT','U') IS NULL
CREATE TABLE dbo.FARM_PRODUCT_CARENCIA_DEFAULT (
    id             BIGINT IDENTITY(1,1) CONSTRAINT PK_FPCARDEF PRIMARY KEY,
    category_id    BIGINT NOT NULL CONSTRAINT FK_FPCARDEF_cat REFERENCES dbo.FARM_PRODUCT_CATEGORY(id),
    reentrada_days INT NULL,
    colheita_days  INT NULL,
    source         VARCHAR(12) NOT NULL CONSTRAINT DF_FPCARDEF_src DEFAULT 'app',
    created_at     DATETIME2(3) NOT NULL CONSTRAINT DF_FPCARDEF_created DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3) NULL,
    deleted_at     DATETIME2(3) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_FPCARDEF_cat')
CREATE UNIQUE INDEX UQ_FPCARDEF_cat ON dbo.FARM_PRODUCT_CARENCIA_DEFAULT(category_id) WHERE deleted_at IS NULL;
GO

IF OBJECT_ID('dbo.FARM_PRODUCT_CARENCIA','U') IS NULL
CREATE TABLE dbo.FARM_PRODUCT_CARENCIA (
    id             BIGINT IDENTITY(1,1) CONSTRAINT PK_FPCAR PRIMARY KEY,
    product_id     BIGINT NOT NULL CONSTRAINT FK_FPCAR_prod REFERENCES dbo.FARM_PRODUCT(id),
    reentrada_days INT NULL,
    colheita_days  INT NULL,
    source         VARCHAR(12) NOT NULL CONSTRAINT DF_FPCAR_src DEFAULT 'app',
    created_at     DATETIME2(3) NOT NULL CONSTRAINT DF_FPCAR_created DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3) NULL,
    deleted_at     DATETIME2(3) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_FPCAR_prod')
CREATE UNIQUE INDEX UQ_FPCAR_prod ON dbo.FARM_PRODUCT_CARENCIA(product_id) WHERE deleted_at IS NULL;
GO

/* SEED conservador do default por categoria (so p/ categorias ainda sem default):
   Reentrada = 1 dia p/ defensivos; 0 p/ nao-quimicos. Colheita = 0 (preencher pelo bulario). */
INSERT INTO dbo.FARM_PRODUCT_CARENCIA_DEFAULT (category_id, reentrada_days, colheita_days, source)
SELECT c.id,
       CASE WHEN c.code IN ('ACARICIDA','FUNGICIDA','HERBICIDA','INSETICIDA','REGULADOR')
                 OR c.code LIKE 'NEMATICIDA%' OR c.code LIKE '%LEO MINERAL%' THEN 1 ELSE 0 END,
       0, 'default'
  FROM dbo.FARM_PRODUCT_CATEGORY c
 WHERE NOT EXISTS (SELECT 1 FROM dbo.FARM_PRODUCT_CARENCIA_DEFAULT d WHERE d.category_id = c.id AND d.deleted_at IS NULL);
GO

SELECT c.name categoria, d.reentrada_days, d.colheita_days
  FROM dbo.FARM_PRODUCT_CARENCIA_DEFAULT d JOIN dbo.FARM_PRODUCT_CATEGORY c ON c.id=d.category_id
 WHERE d.deleted_at IS NULL ORDER BY c.name;
GO
