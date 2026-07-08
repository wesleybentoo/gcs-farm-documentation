/* =========================================================================
   METEOROLOGIA — RESUMO DE CLIMA POR SAFRA (rollup por plantio) — v1
   Uma linha por PLANTIO (FARM_FIELD_PLANTING = safra+ciclo+cultura+variedade+
   talhão) com os TOTAIS/estatísticas de clima da janela do plantio, prontos p/
   exportação. precip/temperaturas/umidade/radiação/dias-de-chuva são AGREGADOS
   da FIELD_WEATHER_HOURLY (grid IDW por talhão×hora) sobre a janela; irrigação é
   MANUAL por ora (sem fonte automática). source=auto|manual (manual não é
   sobrescrito pelo recompute). Aditivo. Roda depois de MODULE_AGRO + planejamento
   + o grid de clima (FIELD_WEATHER_HOURLY). Idempotente. Aplicar com sqlcmd -I.
   ========================================================================= */
SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON;
GO

IF OBJECT_ID('dbo.WEATHER_SEASON_SUMMARY','U') IS NULL
CREATE TABLE dbo.WEATHER_SEASON_SUMMARY (
    id                  BIGINT IDENTITY(1,1) CONSTRAINT PK_WEATHER_SEASON_SUMMARY PRIMARY KEY,
    field_planting_id   BIGINT NOT NULL CONSTRAINT FK_WSS_planting REFERENCES dbo.FARM_FIELD_PLANTING(id),
    field_id            BIGINT NOT NULL CONSTRAINT FK_WSS_field REFERENCES dbo.FARM_FIELDS(id),  -- denormalizado p/ filtro/mapa
    window_start        DATE NULL,          -- janela considerada (datas do plantio)
    window_end          DATE NULL,
    precip_mm           DECIMAL(9,2) NULL,  -- SUM(rain_mm) na janela
    irrigation_mm       DECIMAL(9,2) NULL,  -- manual (sem fonte automática ainda)
    temp_avg_c          DECIMAL(5,2) NULL,
    temp_min_c          DECIMAL(5,2) NULL,
    temp_max_c          DECIMAL(5,2) NULL,
    humidity_avg_pct    DECIMAL(5,2) NULL,
    solar_radiation_avg DECIMAL(9,2) NULL,
    rain_days           INT NULL,           -- nº de dias com chuva > 0 na janela
    source              VARCHAR(10) NOT NULL CONSTRAINT DF_WSS_src DEFAULT 'auto'
                          CONSTRAINT CK_WSS_src CHECK (source IN ('auto','manual')),
    computed_at         DATETIME2(3) NULL,  -- quando o auto foi calculado do grid
    created_at          DATETIME2(3) NOT NULL CONSTRAINT DF_WSS_created DEFAULT SYSUTCDATETIME(),
    updated_at          DATETIME2(3) NULL,
    deleted_at          DATETIME2(3) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UQ_WSS_planting')
CREATE UNIQUE INDEX UQ_WSS_planting ON dbo.WEATHER_SEASON_SUMMARY(field_planting_id) WHERE deleted_at IS NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_WSS_field')
CREATE INDEX IX_WSS_field ON dbo.WEATHER_SEASON_SUMMARY(field_id) WHERE deleted_at IS NULL;
GO

SELECT 'WEATHER_SEASON_SUMMARY' t, COUNT(*) n FROM dbo.WEATHER_SEASON_SUMMARY;
GO
