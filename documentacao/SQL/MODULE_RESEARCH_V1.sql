/* =========================================================================
   MÓDULO PESQUISA — ENSAIOS DE FAIXA (strip test / lado a lado) — v1
   Registro de ensaios de variedades por FAIXA dentro de um talhão: um ensaio
   (FARM_RESEARCH_TRIAL) por (talhão, ciclo) e N faixas (FARM_RESEARCH_STRIP),
   cada faixa = variedade + polígono (geom) + área + produtividade.
   ADITIVO — NÃO toca FARM_FIELD_PLANTING (a safra continua 1 plantio/talhão-ciclo);
   os serviços de produtividade/estimativa/rotação NÃO mudam.
   Roda DEPOIS do MODULE_AGRO + planejamento (FK→FARM_FIELDS/FARM_SEASON_CYCLE/
   FARM_VARIETY). Idempotente. Aplicar com sqlcmd -I (quoted identifiers).
   ========================================================================= */
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO

/* ── 1) ENSAIO (1 por talhão+ciclo) ──────────────────────────────────────── */
IF OBJECT_ID('dbo.FARM_RESEARCH_TRIAL','U') IS NULL
CREATE TABLE dbo.FARM_RESEARCH_TRIAL (
    id              BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_RESEARCH_TRIAL PRIMARY KEY,
    field_id        BIGINT NOT NULL CONSTRAINT FK_FRT_field REFERENCES dbo.FARM_FIELDS(id),
    season_cycle_id BIGINT NOT NULL CONSTRAINT FK_FRT_cycle REFERENCES dbo.FARM_SEASON_CYCLE(id),
    name            NVARCHAR(200) NULL,
    description     NVARCHAR(1000) NULL,
    trial_date      DATE NULL,
    status          VARCHAR(20) NOT NULL CONSTRAINT DF_FRT_status DEFAULT 'active',   -- active | closed
    source          VARCHAR(12) NOT NULL CONSTRAINT DF_FRT_src DEFAULT 'app',          -- app | farmbox
    created_at      DATETIME2(3) NOT NULL CONSTRAINT DF_FRT_created DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3) NULL,
    deleted_at      DATETIME2(3) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_FRT_field_cycle')
CREATE UNIQUE INDEX UQ_FRT_field_cycle ON dbo.FARM_RESEARCH_TRIAL(field_id, season_cycle_id) WHERE deleted_at IS NULL;
GO

/* ── 2) FAIXA (variedade + polígono + área + produtividade) ───────────────── */
IF OBJECT_ID('dbo.FARM_RESEARCH_STRIP','U') IS NULL
CREATE TABLE dbo.FARM_RESEARCH_STRIP (
    id                    BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_RESEARCH_STRIP PRIMARY KEY,
    trial_id              BIGINT NOT NULL CONSTRAINT FK_FRS_trial REFERENCES dbo.FARM_RESEARCH_TRIAL(id),
    variety_id            BIGINT NULL CONSTRAINT FK_FRS_variety REFERENCES dbo.FARM_VARIETY(id),
    geom                  GEOGRAPHY NULL,                 -- polígono da faixa (SRID 4326); NULL = área total (usa o talhão)
    area_ha               DECIMAL(18,4) NULL,
    productivity          DECIMAL(12,3) NULL,
    farmbox_plantation_id INT NULL,                       -- dedup do histórico
    notes                 NVARCHAR(1000) NULL,
    source                VARCHAR(12) NOT NULL CONSTRAINT DF_FRS_src DEFAULT 'app',
    created_at            DATETIME2(3) NOT NULL CONSTRAINT DF_FRS_created DEFAULT SYSUTCDATETIME(),
    updated_at            DATETIME2(3) NULL,
    deleted_at            DATETIME2(3) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_FRS_trial')
CREATE INDEX IX_FRS_trial ON dbo.FARM_RESEARCH_STRIP(trial_id) WHERE deleted_at IS NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_FRS_fb')
CREATE UNIQUE INDEX UQ_FRS_fb ON dbo.FARM_RESEARCH_STRIP(farmbox_plantation_id) WHERE farmbox_plantation_id IS NOT NULL AND deleted_at IS NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='SIX_FARM_RESEARCH_STRIP')
CREATE SPATIAL INDEX SIX_FARM_RESEARCH_STRIP ON dbo.FARM_RESEARCH_STRIP(geom) USING GEOGRAPHY_AUTO_GRID;
GO

SELECT 'FARM_RESEARCH_TRIAL' t, COUNT(*) n FROM dbo.FARM_RESEARCH_TRIAL
UNION ALL SELECT 'FARM_RESEARCH_STRIP', COUNT(*) FROM dbo.FARM_RESEARCH_STRIP;
GO
