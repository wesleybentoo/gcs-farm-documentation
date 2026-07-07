/* =========================================================================
   MÓDULO MONITORAMENTOS — CONFIG que comanda o app + eventos — v1
   Objetivo: dar ao nosso app de monitoramento a MESMA configuração que hoje o
   agrônomo faz no Farbox (tolerância por cultura/variedade, metodologia de
   execução, pontos fixos) + o fluxo de solicitação, reusando os EVENTOS que já
   materializamos (FARM_MONITORING*) e a carência derivada das aplicações.

   REUSO (NÃO recriar — já existem):
     FARM_FARMS, FARM_PLOTS, FARM_FIELDS, FARM_CULTURE, FARM_VARIETY,
     FARM_SEASON_CYCLE, FARM_FIELD_PLANTING, FARM_MONITORING(+POINT/FINDING/
     DAY_MONITOR), FARM_PEST(+THRESHOLD), FARM_APPLICATION(+TARGET/INPUT),
     FARM_PRODUCT (carencia_days), MANAGEMENT_PEOPLES.

   ORDEM: roda DEPOIS de MODULE_AGRO_V1.sql (usa FARM_APPLICATION, FARM_PRODUCT e
   FARM_MONITORING). NAO cabe no SETUP_FULL (FK -> modulo agronomico). Idempotente.
   Convenção: id BIGINT IDENTITY, soft-delete, created/updated_at, `source`.
   ========================================================================= */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ── TEARDOWN (idempotente) — só objetos NOVOS deste módulo ──────────────── */
DROP VIEW  IF EXISTS dbo.VW_MONITOR_FIELD_STATUS;
-- solta a FK que FARM_MONITORING (tabela preservada) aponta p/ MONITOR_REQUEST, senão o DROP abaixo falha
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_FMON_request')
    ALTER TABLE dbo.FARM_MONITORING DROP CONSTRAINT FK_FMON_request;
DROP TABLE IF EXISTS dbo.MONITOR_REQUEST;
DROP TABLE IF EXISTS dbo.MONITOR_FIXED_POINT;
DROP TABLE IF EXISTS dbo.MONITOR_METHODOLOGY;
DROP TABLE IF EXISTS dbo.MONITOR_TOLERANCE;
GO

/* ───────── 1) TOLERÂNCIA entre monitoramentos (dias) ─────────────────────
   Escopo: fazenda + cultura + variedade. Resolução (mais específico vence):
     variedade+fazenda › variedade › default+fazenda › default(todas).
   farm_id NULL = todas as fazendas ; variety_id NULL = "todas as variedades". */
CREATE TABLE dbo.MONITOR_TOLERANCE (
    id          BIGINT IDENTITY(1,1) CONSTRAINT PK_MONITOR_TOLERANCE PRIMARY KEY,
    farm_id     BIGINT NULL CONSTRAINT FK_MTOL_farm    REFERENCES dbo.FARM_FARMS(id),
    culture_id  BIGINT NOT NULL CONSTRAINT FK_MTOL_culture REFERENCES dbo.FARM_CULTURE(id),
    variety_id  BIGINT NULL CONSTRAINT FK_MTOL_variety REFERENCES dbo.FARM_VARIETY(id),
    days        INT    NOT NULL,
    source      VARCHAR(12) NOT NULL CONSTRAINT DF_MTOL_src DEFAULT 'app',   -- app | farmbox
    active      BIT NOT NULL CONSTRAINT DF_MTOL_active DEFAULT 1,
    created_at  DATETIME2(3) NOT NULL CONSTRAINT DF_MTOL_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3) NULL,
    deleted_at  DATETIME2(3) NULL
);
GO
-- 1 tolerância por (fazenda, cultura, variedade). No SQL Server o índice único trata
-- NULL como valor único → garante 1 default por cultura (farm/variety NULL) sem duplicar.
CREATE UNIQUE INDEX UQ_MONITOR_TOLERANCE ON dbo.MONITOR_TOLERANCE(farm_id, culture_id, variety_id)
    WHERE deleted_at IS NULL;
GO

/* ───────── 2) METODOLOGIA de monitoramento (padrão de execução) ──────────
   farm_id NULL = padrão GLOBAL (todas as fazendas) ; linha por fazenda sobrepõe. */
CREATE TABLE dbo.MONITOR_METHODOLOGY (
    id                  BIGINT IDENTITY(1,1) CONSTRAINT PK_MONITOR_METHODOLOGY PRIMARY KEY,
    farm_id             BIGINT NULL CONSTRAINT FK_MMET_farm REFERENCES dbo.FARM_FARMS(id),
    default_method      VARCHAR(20) NOT NULL CONSTRAINT DF_MMET_method DEFAULT 'route',   -- route | fixed_stops | free_stops
    lock_method         BIT NOT NULL CONSTRAINT DF_MMET_lockm  DEFAULT 0,                 -- fixa o método na criação
    samples_per_stop    INT NOT NULL CONSTRAINT DF_MMET_samples DEFAULT 10,
    lock_samples        BIT NOT NULL CONSTRAINT DF_MMET_locks  DEFAULT 0,
    phenology_required  BIT NOT NULL CONSTRAINT DF_MMET_phen   DEFAULT 1,
    phenology_frequency VARCHAR(12) NOT NULL CONSTRAINT DF_MMET_phenfreq DEFAULT 'per_field', -- per_stop | per_field
    active              BIT NOT NULL CONSTRAINT DF_MMET_active DEFAULT 1,
    created_at          DATETIME2(3) NOT NULL CONSTRAINT DF_MMET_created DEFAULT SYSUTCDATETIME(),
    updated_at          DATETIME2(3) NULL,
    deleted_at          DATETIME2(3) NULL
);
GO
CREATE UNIQUE INDEX UQ_MONITOR_METHODOLOGY ON dbo.MONITOR_METHODOLOGY(farm_id) WHERE deleted_at IS NULL;
GO
-- padrão global inicial (imagem "Metodologia de Monitoramento")
INSERT INTO dbo.MONITOR_METHODOLOGY (farm_id, default_method, samples_per_stop, phenology_required, phenology_frequency)
SELECT NULL, 'route', 10, 1, 'per_field'
WHERE NOT EXISTS (SELECT 1 FROM dbo.MONITOR_METHODOLOGY WHERE farm_id IS NULL AND deleted_at IS NULL);
GO

/* ───────── 3) PONTOS FIXOS (paradas fixas) por talhão ────────────────────
   Usados quando default_method='fixed_stops' (tela "EDITAR PONTOS FIXOS"). */
CREATE TABLE dbo.MONITOR_FIXED_POINT (
    id          BIGINT IDENTITY(1,1) CONSTRAINT PK_MONITOR_FIXED_POINT PRIMARY KEY,
    field_id    BIGINT NOT NULL CONSTRAINT FK_MFP_field REFERENCES dbo.FARM_FIELDS(id),
    seq         INT NOT NULL,
    latitude    DECIMAL(9,6) NOT NULL,
    longitude   DECIMAL(9,6) NOT NULL,
    label       NVARCHAR(80) NULL,
    active      BIT NOT NULL CONSTRAINT DF_MFP_active DEFAULT 1,
    created_at  DATETIME2(3) NOT NULL CONSTRAINT DF_MFP_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3) NULL,
    deleted_at  DATETIME2(3) NULL
);
GO
CREATE INDEX IX_MONITOR_FIXED_POINT_field ON dbo.MONITOR_FIXED_POINT(field_id) WHERE deleted_at IS NULL;
GO

/* ───────── 4) SOLICITAÇÃO de monitoramento (botão "SOLICITAR") ────────────
   Ao cumprir, aponta o FARM_MONITORING gerado (fulfilled_monitoring_id). */
CREATE TABLE dbo.MONITOR_REQUEST (
    id                      BIGINT IDENTITY(1,1) CONSTRAINT PK_MONITOR_REQUEST PRIMARY KEY,
    field_id                BIGINT NOT NULL CONSTRAINT FK_MREQ_field    REFERENCES dbo.FARM_FIELDS(id),
    planting_id             BIGINT NULL CONSTRAINT FK_MREQ_planting REFERENCES dbo.FARM_FIELD_PLANTING(id),
    culture_id              BIGINT NULL CONSTRAINT FK_MREQ_culture  REFERENCES dbo.FARM_CULTURE(id),
    requested_by            BIGINT NULL CONSTRAINT FK_MREQ_reqby    REFERENCES dbo.MANAGEMENT_PEOPLES(id),
    requested_at            DATETIME2(3) NOT NULL CONSTRAINT DF_MREQ_reqat DEFAULT SYSUTCDATETIME(),
    status                  VARCHAR(12) NOT NULL CONSTRAINT DF_MREQ_status DEFAULT 'pending', -- pending | assigned | done | cancelled
    assigned_monitor_id     BIGINT NULL CONSTRAINT FK_MREQ_monitor  REFERENCES dbo.MANAGEMENT_PEOPLES(id),
    fulfilled_monitoring_id BIGINT NULL CONSTRAINT FK_MREQ_mon       REFERENCES dbo.FARM_MONITORING(id),
    note                    NVARCHAR(1000) NULL,
    created_at              DATETIME2(3) NOT NULL CONSTRAINT DF_MREQ_created DEFAULT SYSUTCDATETIME(),
    updated_at              DATETIME2(3) NULL,
    deleted_at              DATETIME2(3) NULL
);
GO
CREATE INDEX IX_MONITOR_REQUEST_status ON dbo.MONITOR_REQUEST(status, field_id) WHERE deleted_at IS NULL;
GO

/* ───────── 5) EVENTO — estende FARM_MONITORING (idempotente) ─────────────
   Campos que o histórico/app usam além do que já existe (methodology, samples,
   phenological_stage, mon_state, monitor, recommendation já existem). */
IF COL_LENGTH('dbo.FARM_MONITORING','duration_min') IS NULL ALTER TABLE dbo.FARM_MONITORING ADD duration_min INT NULL;
IF COL_LENGTH('dbo.FARM_MONITORING','stops_count')  IS NULL ALTER TABLE dbo.FARM_MONITORING ADD stops_count  INT NULL;
IF COL_LENGTH('dbo.FARM_MONITORING','started_at')   IS NULL ALTER TABLE dbo.FARM_MONITORING ADD started_at   DATETIME2(3) NULL;
IF COL_LENGTH('dbo.FARM_MONITORING','ended_at')     IS NULL ALTER TABLE dbo.FARM_MONITORING ADD ended_at     DATETIME2(3) NULL;
IF COL_LENGTH('dbo.FARM_MONITORING','request_id')   IS NULL ALTER TABLE dbo.FARM_MONITORING ADD request_id   BIGINT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_FMON_request')
    ALTER TABLE dbo.FARM_MONITORING ADD CONSTRAINT FK_FMON_request FOREIGN KEY (request_id) REFERENCES dbo.MONITOR_REQUEST(id);
GO

/* ───────── 6) SEED da tolerância a partir do Farmbox (307 linhas) ────────
   Mapeia ids Farmbox→nossos via pontes (farmbox_culture_id / farmbox_variety_id).
   O Farmbox tem 1 fazenda (Celeiro Sementes) → seed entra como farm_id NULL
   (todas). Dedup por (cultura, variedade) pegando o mais recente. Idempotente. */
;WITH raw AS (
    -- as colunas tipadas do landing vêm NULL; o dado está no record JSON.
    -- farm_id 2112 = "Celeiro Sementes - BA" (nossa operação); as demais fazendas do Farmbox são ignoradas.
    SELECT TRY_CAST(JSON_VALUE(t.record,'$.culture_id') AS INT) AS fb_culture,
           TRY_CAST(JSON_VALUE(t.record,'$.variety_id') AS INT) AS fb_variety,
           TRY_CAST(JSON_VALUE(t.record,'$.days')       AS INT) AS days,
           TRY_CAST(JSON_VALUE(t.record,'$.farm_id')    AS INT) AS fb_farm,
           t.api_updated_at, t.id
      FROM CONNECTOR_GCS_FARM.dbo.FARMBOX_MONITORING_TOLERANCE t
     WHERE t.deleted_at IS NULL
), src AS (
    SELECT c.id AS culture_id, v.id AS variety_id, r.days,
           ROW_NUMBER() OVER (PARTITION BY c.id, v.id ORDER BY r.api_updated_at DESC, r.id DESC) rn
      FROM raw r
      JOIN dbo.FARM_CULTURE c  ON c.farmbox_culture_id  = r.fb_culture  AND c.deleted_at IS NULL
      LEFT JOIN dbo.FARM_VARIETY v ON v.farmbox_variety_id = r.fb_variety AND v.deleted_at IS NULL
     WHERE r.days IS NOT NULL AND r.fb_farm = 2112
       AND (r.fb_variety IS NULL OR v.id IS NOT NULL)   -- variety informada que não resolveu → pula
)
INSERT INTO dbo.MONITOR_TOLERANCE (farm_id, culture_id, variety_id, days, source)
SELECT NULL, s.culture_id, s.variety_id, s.days, 'farmbox'
  FROM src s
 WHERE s.rn = 1
   AND NOT EXISTS (
        SELECT 1 FROM dbo.MONITOR_TOLERANCE m
         WHERE m.farm_id IS NULL AND m.culture_id = s.culture_id AND m.deleted_at IS NULL
           AND ((m.variety_id IS NULL AND s.variety_id IS NULL) OR m.variety_id = s.variety_id));
GO

/* ───────── 7) VIEW — status por talhão (alimenta mapa + lista) ───────────
   Por plantio vigente: última monitoria, tolerância resolvida, dias além da
   tolerância e carência (última aplicação + carencia_days do produto). O app
   pinta as faixas (em dia / ≤3 / ≤5 / +15 / carência) a partir de days_over. */
CREATE VIEW dbo.VW_MONITOR_FIELD_STATUS AS
SELECT
    p.id                AS planting_id,
    p.field_id,
    f.code              AS field_code,
    f.name              AS field_name,
    pl.farm_id,
    sc.id               AS season_cycle_id,
    sc.cycle_no,
    sc.culture_id,
    cu.name             AS culture_name,
    p.variety_id,
    vr.name             AS variety_name,
    lm.last_monitoring_date,
    tol.days            AS tolerance_days,
    CASE WHEN lm.last_monitoring_date IS NULL THEN NULL
         ELSE DATEDIFF(DAY, lm.last_monitoring_date, CAST(SYSDATETIME() AS date)) END AS days_since,
    CASE WHEN lm.last_monitoring_date IS NULL OR tol.days IS NULL THEN NULL
         ELSE DATEDIFF(DAY, lm.last_monitoring_date, CAST(SYSDATETIME() AS date)) - tol.days END AS days_over,
    car.carencia_until,
    CAST(CASE WHEN car.carencia_until IS NOT NULL AND car.carencia_until >= CAST(SYSDATETIME() AS date) THEN 1 ELSE 0 END AS bit) AS in_carencia,
    CASE
        WHEN car.carencia_until IS NOT NULL AND car.carencia_until >= CAST(SYSDATETIME() AS date) THEN 'carencia'
        WHEN tol.days IS NULL OR lm.last_monitoring_date IS NULL THEN 'sem_referencia'
        WHEN DATEDIFF(DAY, lm.last_monitoring_date, CAST(SYSDATETIME() AS date)) - tol.days <= 0 THEN 'em_dia'
        ELSE 'atrasado'
    END AS state
FROM dbo.FARM_FIELD_PLANTING p
JOIN dbo.FARM_FIELDS f       ON f.id = p.field_id AND f.deleted_at IS NULL
JOIN dbo.FARM_PLOTS pl       ON pl.id = f.plot_id
JOIN dbo.FARM_SEASON_CYCLE sc ON sc.id = p.season_cycle_id
LEFT JOIN dbo.FARM_CULTURE cu ON cu.id = sc.culture_id
LEFT JOIN dbo.FARM_VARIETY vr ON vr.id = p.variety_id
OUTER APPLY (
    SELECT MAX(m.monitoring_date) AS last_monitoring_date
      FROM dbo.FARM_MONITORING m
     WHERE m.field_id = p.field_id AND m.deleted_at IS NULL
       AND (m.planting_id = p.id OR m.planting_id IS NULL)
) lm
OUTER APPLY (
    SELECT TOP 1 t.days
      FROM dbo.MONITOR_TOLERANCE t
     WHERE t.deleted_at IS NULL AND t.active = 1 AND t.culture_id = sc.culture_id
       AND (t.farm_id = pl.farm_id OR t.farm_id IS NULL)
       AND (t.variety_id = p.variety_id OR t.variety_id IS NULL)
     ORDER BY CASE WHEN t.variety_id IS NOT NULL THEN 0 ELSE 1 END,
              CASE WHEN t.farm_id    IS NOT NULL THEN 0 ELSE 1 END
) tol
OUTER APPLY (
    -- carência = última aplicação no talhão + carencia_days do BULÁRIO do produto
    -- (FARM_PRODUCT_LABEL, por cultura). Vazio hoje → carencia_until NULL até o bulário ser preenchido.
    SELECT MAX(DATEADD(DAY, lbl.carencia_days, a.app_date)) AS carencia_until
      FROM dbo.FARM_APPLICATION_TARGET tg
      JOIN dbo.FARM_APPLICATION a        ON a.id = tg.application_id AND a.deleted_at IS NULL AND a.app_date IS NOT NULL
      JOIN dbo.FARM_APPLICATION_INPUT ai ON ai.application_id = a.id AND ai.deleted_at IS NULL
      JOIN dbo.FARM_PRODUCT_LABEL lbl    ON lbl.product_id = ai.product_id AND lbl.deleted_at IS NULL
                                        AND lbl.carencia_days IS NOT NULL
                                        AND (lbl.culture_id = sc.culture_id OR lbl.culture_id IS NULL)
     WHERE tg.field_id = p.field_id AND tg.deleted_at IS NULL
) car
WHERE p.deleted_at IS NULL AND p.active = 1 AND ISNULL(p.status,'') <> 'CLOSED';
GO
