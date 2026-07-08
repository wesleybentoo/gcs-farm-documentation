/* =========================================================================
   FENOLOGIA — CATÁLOGO DE ESTÁGIOS FENOLÓGICOS (por cultura) — v1
   Fundação: transforma a string solta FARM_MONITORING.phenological_stage num
   catálogo normalizado por cultura (código + ordem + classificação veg/rep +
   descrição agronômica + flag ignora-infestação), materializado do Farmbox
   (FARMBOX_REF_PHENOLOGICAL_STAGE). Liga FARM_MONITORING ao catálogo por FK.
   Aditivo/idempotente. Roda depois de MODULE_AGRO (FK→FARM_CULTURE) e do
   materialize do monitoramento. Aplicar com sqlcmd -I.
   ========================================================================= */
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO

/* ── 1) CATÁLOGO por cultura ──────────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARM_PHENOLOGICAL_STAGE','U') IS NULL
CREATE TABLE dbo.FARM_PHENOLOGICAL_STAGE (
    id                  BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_PHENOLOGICAL_STAGE PRIMARY KEY,
    culture_id          BIGINT NULL CONSTRAINT FK_FPS_culture REFERENCES dbo.FARM_CULTURE(id),
    code                NVARCHAR(200) NOT NULL,         -- nome do estágio no Farmbox: código curto p/ grãos (VE/V1/R5.1) OU rótulo descritivo p/ outras culturas (ex.: 'F4 - Maturação - Início...')
    position            INT NULL,                        -- ordem dentro da cultura
    classification      VARCHAR(12) NULL,                -- vegetative | reproductive | null
    description         NVARCHAR(1000) NULL,             -- texto agronômico do estágio
    ignore_infestations BIT NOT NULL CONSTRAINT DF_FPS_ign DEFAULT 0,  -- regra: ignora pragas neste estágio
    farmbox_stage_id    INT NULL,                        -- ponte com o Farmbox
    source              VARCHAR(12) NOT NULL CONSTRAINT DF_FPS_src DEFAULT 'farmbox',
    created_at          DATETIME2(3) NOT NULL CONSTRAINT DF_FPS_created DEFAULT SYSUTCDATETIME(),
    updated_at          DATETIME2(3) NULL,
    deleted_at          DATETIME2(3) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_FPS_fb')
CREATE UNIQUE INDEX UQ_FPS_fb ON dbo.FARM_PHENOLOGICAL_STAGE(farmbox_stage_id) WHERE farmbox_stage_id IS NOT NULL AND deleted_at IS NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_FPS_culture_pos')
CREATE INDEX IX_FPS_culture_pos ON dbo.FARM_PHENOLOGICAL_STAGE(culture_id, position) WHERE deleted_at IS NULL;
GO
-- code único por cultura (evita duplicar VE/R1 na mesma cultura no re-materialize)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_FPS_culture_code')
CREATE UNIQUE INDEX UQ_FPS_culture_code ON dbo.FARM_PHENOLOGICAL_STAGE(culture_id, code) WHERE deleted_at IS NULL;
GO

/* ── 2) LIGAÇÃO no monitoramento (mantém a string; adiciona a FK normalizada) ── */
IF COL_LENGTH('dbo.FARM_MONITORING','phenological_stage_id') IS NULL
  ALTER TABLE dbo.FARM_MONITORING ADD phenological_stage_id BIGINT NULL
    CONSTRAINT FK_FARM_MONITORING_stage REFERENCES dbo.FARM_PHENOLOGICAL_STAGE(id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_FARM_MONITORING_stage')
CREATE INDEX IX_FARM_MONITORING_stage ON dbo.FARM_MONITORING(phenological_stage_id) WHERE phenological_stage_id IS NOT NULL;
GO

SELECT 'FARM_PHENOLOGICAL_STAGE' t, COUNT(*) n FROM dbo.FARM_PHENOLOGICAL_STAGE;
GO
