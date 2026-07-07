/* =========================================================================
   MÓDULO AGRONÔMICO — DOMÍNIO PRÓPRIO (FARM_*) — v1 (PROPOSTA)
   Objetivo: sair da dependência do Farmbox. O que hoje só existe no espelho
   FARMBOX_* (produtos, aplicações, monitoramentos, contagens, estimativas,
   pragas, colheita) passa a ter estrutura NATIVA FARM_*, conectada ao que já
   temos (Safra/Ciclo/Cultura/Variedade/Talhão/Equipamento/Meteorologia).

   REUSO (NÃO recriar — já existem):
     FARM_SEASON, FARM_SEASON_CYCLE, FARM_CULTURE, FARM_VARIETY(+TRAIT/VALUE),
     FARM_FARMS, FARM_PLOTS, FARM_FIELDS(+GEOMETRY), FARM_FIELD_PLANTING,
     FARM_FIELD_ROTATION, PROD_ESTIMATE_FORMULA, MACHINE_OPERATION_EQUIPMENT,
     WEATHER_ e FIELD_WEATHER_, FERT_, OPS_, MANAGEMENT_.

   TRANSIÇÃO: cada tabela tem `source` ('farmbox' | 'app') e `farmbox_*_id`
   (id de origem) para backfill idempotente enquanto o Farmbox coexiste; ao
   descontinuar, novos registros entram com source='app'.
   Convenção: id BIGINT IDENTITY, soft-delete (deleted_at), created/updated_at.
   ========================================================================= */

/* ── TEARDOWN (idempotente) — filhos antes dos pais ──────────────────────── */
DROP TABLE IF EXISTS dbo.FARM_HARVEST_YIELD;
DROP TABLE IF EXISTS dbo.FARM_ESTIMATE;
DROP TABLE IF EXISTS dbo.FARM_COUNT_PARAM;
DROP TABLE IF EXISTS dbo.FARM_COUNT;
DROP TABLE IF EXISTS dbo.FARM_PEST_THRESHOLD;
DROP TABLE IF EXISTS dbo.FARM_MONITORING_DAY_MONITOR;
DROP TABLE IF EXISTS dbo.FARM_MONITORING_FINDING;
DROP TABLE IF EXISTS dbo.FARM_MONITORING_POINT;
DROP TABLE IF EXISTS dbo.FARM_MONITORING;
DROP TABLE IF EXISTS dbo.FARM_APPLICATION_TARGET;
DROP TABLE IF EXISTS dbo.FARM_APPLICATION_INPUT;
DROP TABLE IF EXISTS dbo.FARM_APPLICATION;
DROP TABLE IF EXISTS dbo.FARM_ART;
DROP TABLE IF EXISTS dbo.FARM_PRODUCT_TRIAL;
DROP TABLE IF EXISTS dbo.FARM_PRODUCT_LABEL;
DROP TABLE IF EXISTS dbo.FARM_PRODUCT_REF;
DROP TABLE IF EXISTS dbo.FARM_PRODUCT_INGREDIENT;
DROP TABLE IF EXISTS dbo.FARM_ACTIVE_INGREDIENT;
DROP TABLE IF EXISTS dbo.FARM_PRODUCT;
DROP TABLE IF EXISTS dbo.FARM_PRODUCT_TEST;
DROP TABLE IF EXISTS dbo.FARM_PRODUCT_CATEGORY;
DROP TABLE IF EXISTS dbo.FARM_PEST;
GO

/* ───────────────────── 0) CATÁLOGOS BASE ────────────────────────────────── */
CREATE TABLE dbo.FARM_PEST (                      -- alvos (pragas/doenças/daninhas) — usado por bulário e monitoramento
    id             BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_PEST PRIMARY KEY,
    code           VARCHAR(40)  NULL,
    name           NVARCHAR(200) NOT NULL,
    scientific_name NVARCHAR(200) NULL,
    kind           VARCHAR(20)  NULL,              -- praga | doenca | daninha | inimigo_natural
    active         BIT NOT NULL CONSTRAINT DF_FPEST_active DEFAULT 1,
    created_at     DATETIME2(3) NOT NULL CONSTRAINT DF_FPEST_created DEFAULT SYSUTCDATETIME(),
    deleted_at     DATETIME2(3) NULL
);

/* ───────────────────────── 1) PRODUTOS (catálogo) ───────────────────────── */
CREATE TABLE dbo.FARM_PRODUCT_CATEGORY (
    id          BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_PRODUCT_CATEGORY PRIMARY KEY,
    code        VARCHAR(40)  NOT NULL,               -- HERBICIDA, FUNGICIDA, FERTILIZANTE...
    name        NVARCHAR(120) NOT NULL,
    kind        VARCHAR(20)  NULL,                   -- defensivo | fertilizante | biologico | outro
    color_hex   CHAR(7)      NULL,
    active      BIT NOT NULL CONSTRAINT DF_FPC_active DEFAULT 1,
    created_at  DATETIME2(3) NOT NULL CONSTRAINT DF_FPC_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3) NULL,
    deleted_at  DATETIME2(3) NULL
);

/* PRODUTO DE TESTE / experimental — separado do comercial. Seus ensaios
   (FARM_PRODUCT_TRIAL) guardam a performance; quando "gradua", um produto
   COMERCIAL aponta p/ ele (FARM_PRODUCT.test_product_id) e herda o histórico. */
CREATE TABLE dbo.FARM_PRODUCT_TEST (
    id           BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_PRODUCT_TEST PRIMARY KEY,
    code         VARCHAR(40)  NULL,               -- codinome do ensaio
    name         NVARCHAR(200) NOT NULL,
    category_id  BIGINT NULL CONSTRAINT FK_FPTEST_cat REFERENCES dbo.FARM_PRODUCT_CATEGORY(id),
    supplier     NVARCHAR(200) NULL,
    objective    NVARCHAR(1000) NULL,             -- hipótese/objetivo do teste
    status       VARCHAR(20)  NOT NULL CONSTRAINT DF_FPTEST_status DEFAULT 'open', -- open|approved|discarded
    notes        NVARCHAR(1000) NULL,
    active       BIT NOT NULL CONSTRAINT DF_FPTEST_active DEFAULT 1,
    created_at   DATETIME2(3) NOT NULL CONSTRAINT DF_FPTEST_created DEFAULT SYSUTCDATETIME(),
    updated_at   DATETIME2(3) NULL,
    deleted_at   DATETIME2(3) NULL
);

CREATE TABLE dbo.FARM_PRODUCT (
    id            BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_PRODUCT PRIMARY KEY,
    code          VARCHAR(40)  NULL,
    name          NVARCHAR(200) NOT NULL,
    category_id   BIGINT NOT NULL CONSTRAINT FK_FPROD_cat REFERENCES dbo.FARM_PRODUCT_CATEGORY(id),
    dose_unit     VARCHAR(20)  NULL,                 -- l_ha, kg_ha, ml_ha, g_ha...
    formulation   VARCHAR(40)  NULL,                 -- liquid | solid | SC | WG...
    manufacturer  NVARCHAR(200) NULL,
    register_mapa VARCHAR(40)  NULL,                 -- nº registro MAPA (do Farmbox)
    toxicological NVARCHAR(120) NULL,
    environmental NVARCHAR(120) NULL,
    -- NOSSO diferencial: princípio ativo (o Farmbox NÃO fornece)
    active_ingredient NVARCHAR(300) NULL,            -- texto livre (rollup dos ingredientes)
    test_product_id BIGINT NULL CONSTRAINT FK_FPROD_test REFERENCES dbo.FARM_PRODUCT_TEST(id), -- lineage: origem em teste (herda performance)
    source        VARCHAR(12)  NOT NULL CONSTRAINT DF_FPROD_src DEFAULT 'app',
    farmbox_input_id INT       NULL,                 -- ponte p/ backfill (FARMBOX_INPUT.farmbox_id)
    active        BIT NOT NULL CONSTRAINT DF_FPROD_active DEFAULT 1,
    notes         NVARCHAR(1000) NULL,
    created_at    DATETIME2(3) NOT NULL CONSTRAINT DF_FPROD_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3) NULL,
    deleted_at    DATETIME2(3) NULL
);
CREATE INDEX IX_FARM_PRODUCT_cat ON dbo.FARM_PRODUCT(category_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARM_PRODUCT_fb  ON dbo.FARM_PRODUCT(farmbox_input_id) WHERE deleted_at IS NULL;

CREATE TABLE dbo.FARM_ACTIVE_INGREDIENT (        -- catálogo próprio de princípios ativos
    id         BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_ACTIVE_INGREDIENT PRIMARY KEY,
    name       NVARCHAR(200) NOT NULL,
    active     BIT NOT NULL CONSTRAINT DF_FAING_active DEFAULT 1,
    created_at DATETIME2(3) NOT NULL CONSTRAINT DF_FAING_created DEFAULT SYSUTCDATETIME(),
    deleted_at DATETIME2(3) NULL
);
CREATE TABLE dbo.FARM_PRODUCT_INGREDIENT (       -- N:N produto ↔ princípio ativo (+ concentração)
    id            BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_PRODUCT_INGREDIENT PRIMARY KEY,
    product_id    BIGINT NOT NULL CONSTRAINT FK_FPI_prod REFERENCES dbo.FARM_PRODUCT(id),
    ingredient_id BIGINT NOT NULL CONSTRAINT FK_FPI_ing  REFERENCES dbo.FARM_ACTIVE_INGREDIENT(id),
    concentration DECIMAL(10,3) NULL,              -- g/L ou g/kg
    unit          VARCHAR(20)  NULL,
    created_at    DATETIME2(3) NOT NULL CONSTRAINT DF_FPI_created DEFAULT SYSUTCDATETIME(),
    deleted_at    DATETIME2(3) NULL
);

/* Referência a cadastros EXTERNOS de produto (DBA da fazenda / ERP / outros) —
   preparado p/ casar nosso produto com o ID externo no futuro. Genérico (N sistemas). */
CREATE TABLE dbo.FARM_PRODUCT_REF (
    id           BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_PRODUCT_REF PRIMARY KEY,
    product_id   BIGINT NOT NULL CONSTRAINT FK_FPREF_prod REFERENCES dbo.FARM_PRODUCT(id),
    system       VARCHAR(30) NOT NULL,             -- 'dba_fazenda' | 'erp' | 'farmbox' | ...
    external_id  VARCHAR(60) NULL,                 -- ID no sistema externo (uso futuro)
    external_code VARCHAR(60) NULL,
    external_name NVARCHAR(200) NULL,
    created_at   DATETIME2(3) NOT NULL CONSTRAINT DF_FPREF_created DEFAULT SYSUTCDATETIME(),
    deleted_at   DATETIME2(3) NULL
);
CREATE INDEX IX_FARM_PRODUCT_REF_prod ON dbo.FARM_PRODUCT_REF(product_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARM_PRODUCT_REF_ext  ON dbo.FARM_PRODUCT_REF(system, external_id) WHERE deleted_at IS NULL;

/* BULÁRIO (bula): dose min/max + condições por produto × cultura × praga.
   Base para RECOMENDAÇÃO automática (cruza com monitoramento + limiar de praga). */
CREATE TABLE dbo.FARM_PRODUCT_LABEL (
    id              BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_PRODUCT_LABEL PRIMARY KEY,
    product_id      BIGINT NOT NULL CONSTRAINT FK_FPL_prod REFERENCES dbo.FARM_PRODUCT(id),
    culture_id      BIGINT NULL CONSTRAINT FK_FPL_cult REFERENCES dbo.FARM_CULTURE(id), -- NULL = geral
    pest_id         BIGINT NULL CONSTRAINT FK_FPL_pest REFERENCES dbo.FARM_PEST(id),    -- alvo (NULL = qualquer)
    equipment_mode  VARCHAR(10)  NULL,             -- land | air | ferti (NULL = qualquer) — dose varia por equipamento!
    dose_min        DECIMAL(14,4) NULL,
    dose_max        DECIMAL(14,4) NULL,
    dose_unit       VARCHAR(20)  NULL,             -- l/ha, kg/ha...
    spray_volume_min DECIMAL(10,2) NULL,           -- calda l/ha
    spray_volume_max DECIMAL(10,2) NULL,
    droplet_type    VARCHAR(40)  NULL,             -- fina | média | grossa | muito grossa
    application_conditions NVARCHAR(1000) NULL,    -- janela, temperatura, UR, vento...
    carencia_days   INT NULL,                      -- intervalo de segurança (pré-colheita)
    reentry_days    INT NULL,                      -- reentrada
    max_applications INT NULL,
    notes           NVARCHAR(1000) NULL,
    active          BIT NOT NULL CONSTRAINT DF_FPL_active DEFAULT 1,
    created_at      DATETIME2(3) NOT NULL CONSTRAINT DF_FPL_created DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3) NULL,
    deleted_at      DATETIME2(3) NULL
);
CREATE INDEX IX_FARM_PRODUCT_LABEL_key ON dbo.FARM_PRODUCT_LABEL(product_id, culture_id, pest_id, equipment_mode) WHERE deleted_at IS NULL;

/* ENSAIOS do PRODUTO DE TESTE — avaliação de dose, método e tipo de gota.
   É a performance que o produto comercial herda via FARM_PRODUCT.test_product_id. */
CREATE TABLE dbo.FARM_PRODUCT_TRIAL (
    id             BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_PRODUCT_TRIAL PRIMARY KEY,
    test_product_id BIGINT NOT NULL CONSTRAINT FK_FPT2_test REFERENCES dbo.FARM_PRODUCT_TEST(id),
    culture_id     BIGINT NULL CONSTRAINT FK_FPT2_cult REFERENCES dbo.FARM_CULTURE(id),
    field_id       BIGINT NULL CONSTRAINT FK_FPT2_field REFERENCES dbo.FARM_FIELDS(id),
    planting_id    BIGINT NULL CONSTRAINT FK_FPT2_plant REFERENCES dbo.FARM_FIELD_PLANTING(id),
    trial_date     DATE NULL,
    dose_tested    DECIMAL(14,4) NULL,
    dose_unit      VARCHAR(20)  NULL,
    application_method VARCHAR(60) NULL,           -- terrestre | aéreo | fertirrigação | costal...
    droplet_type   VARCHAR(40)  NULL,
    spray_volume   DECIMAL(10,2) NULL,
    result_rating  VARCHAR(30)  NULL,             -- eficácia observada
    status         VARCHAR(20)  NOT NULL CONSTRAINT DF_FPT2_status DEFAULT 'open', -- open|done|discarded
    notes          NVARCHAR(2000) NULL,
    created_at     DATETIME2(3) NOT NULL CONSTRAINT DF_FPT2_created DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3) NULL,
    deleted_at     DATETIME2(3) NULL
);
CREATE INDEX IX_FARM_PRODUCT_TRIAL_test ON dbo.FARM_PRODUCT_TRIAL(test_product_id) WHERE deleted_at IS NULL;

/* ───────────────────────── 2) APLICAÇÕES ────────────────────────────────── */
/* ART — Anotação de Responsabilidade Técnica (registro formal do agrônomo). */
CREATE TABLE dbo.FARM_ART (
    id            BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_ART PRIMARY KEY,
    art_number    VARCHAR(60)  NOT NULL,
    agronomist_person_id BIGINT NULL,              -- → MANAGEMENT_PEOPLES (quando houver)
    agronomist_name NVARCHAR(200) NULL,
    crea          VARCHAR(40)  NULL,               -- registro no conselho
    issue_date    DATE NULL,
    valid_from    DATE NULL,
    valid_to      DATE NULL,
    farm_id       BIGINT NULL CONSTRAINT FK_FART_farm REFERENCES dbo.FARM_FARMS(id),
    scope         NVARCHAR(1000) NULL,
    document_url  NVARCHAR(500) NULL,              -- PDF/anexo
    status        VARCHAR(20)  NOT NULL CONSTRAINT DF_FART_status DEFAULT 'active', -- active|expired|canceled
    active        BIT NOT NULL CONSTRAINT DF_FART_active DEFAULT 1,
    created_at    DATETIME2(3) NOT NULL CONSTRAINT DF_FART_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3) NULL,
    deleted_at    DATETIME2(3) NULL
);
CREATE INDEX IX_FARM_ART_number ON dbo.FARM_ART(art_number) WHERE deleted_at IS NULL;

CREATE TABLE dbo.FARM_APPLICATION (
    id             BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_APPLICATION PRIMARY KEY,
    code           VARCHAR(30)  NULL,
    farm_id        BIGINT NULL CONSTRAINT FK_FAPP_farm REFERENCES dbo.FARM_FARMS(id), -- resolvido via alvo→talhão→gleba→fazenda (nullable: ~7 apps sem talhão)
    season_cycle_id BIGINT NULL CONSTRAINT FK_FAPP_cycle REFERENCES dbo.FARM_SEASON_CYCLE(id),
    status         VARCHAR(20)  NOT NULL CONSTRAINT DF_FAPP_status DEFAULT 'finalized', -- planned|in_progress|finalized|canceled
    operation_type VARCHAR(40)  NULL,              -- pulverization | soil_management...
    activity       NVARCHAR(80) NULL,              -- finalidade (Fungicida, Cobertura, Adubação...)
    app_date       DATE NULL,
    end_date       DATE NULL,
    start_time     TIME NULL,
    end_time       TIME NULL,
    total_area_ha  DECIMAL(12,2) NULL,
    equipment_id   BIGINT NULL CONSTRAINT FK_FAPP_equip REFERENCES dbo.MACHINE_OPERATION_EQUIPMENT(id),
    equipment_mode VARCHAR(10)  NULL,              -- land | air | ferti
    responsible_person_id BIGINT NULL,             -- → MANAGEMENT_PEOPLES (quando houver)
    responsible_name NVARCHAR(200) NULL,           -- fallback texto
    art_id         BIGINT NULL CONSTRAINT FK_FAPP_art REFERENCES dbo.FARM_ART(id), -- registro formal (ART)
    observations   NVARCHAR(2000) NULL,
    source         VARCHAR(12)  NOT NULL CONSTRAINT DF_FAPP_src DEFAULT 'app',
    farmbox_application_id BIGINT NULL,
    active         BIT NOT NULL CONSTRAINT DF_FAPP_active DEFAULT 1,
    created_at     DATETIME2(3) NOT NULL CONSTRAINT DF_FAPP_created DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3) NULL,
    deleted_at     DATETIME2(3) NULL
);
CREATE INDEX IX_FARM_APP_farm_date ON dbo.FARM_APPLICATION(farm_id, app_date DESC) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARM_APP_status    ON dbo.FARM_APPLICATION(status) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARM_APP_fb        ON dbo.FARM_APPLICATION(farmbox_application_id) WHERE deleted_at IS NULL;

CREATE TABLE dbo.FARM_APPLICATION_INPUT (        -- produto + dose por aplicação
    id            BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_APPLICATION_INPUT PRIMARY KEY,
    application_id BIGINT NOT NULL CONSTRAINT FK_FAI_app  REFERENCES dbo.FARM_APPLICATION(id),
    product_id    BIGINT NOT NULL CONSTRAINT FK_FAI_prod REFERENCES dbo.FARM_PRODUCT(id),
    dosage        DECIMAL(14,4) NULL,             -- dose por ha
    dosage_unit   VARCHAR(20)  NULL,
    quantity      DECIMAL(14,4) NULL,             -- quantidade total aplicada
    quantity_unit VARCHAR(20)  NULL,
    created_at    DATETIME2(3) NOT NULL CONSTRAINT DF_FAI_created DEFAULT SYSUTCDATETIME(),
    deleted_at    DATETIME2(3) NULL
);
CREATE INDEX IX_FARM_APP_INPUT_app  ON dbo.FARM_APPLICATION_INPUT(application_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARM_APP_INPUT_prod ON dbo.FARM_APPLICATION_INPUT(product_id) WHERE deleted_at IS NULL;

CREATE TABLE dbo.FARM_APPLICATION_TARGET (       -- onde foi aplicada (talhão/plantio + área)
    id            BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_APPLICATION_TARGET PRIMARY KEY,
    application_id BIGINT NOT NULL CONSTRAINT FK_FAT_app REFERENCES dbo.FARM_APPLICATION(id),
    field_id      BIGINT NOT NULL CONSTRAINT FK_FAT_field REFERENCES dbo.FARM_FIELDS(id),
    planting_id   BIGINT NULL CONSTRAINT FK_FAT_plant REFERENCES dbo.FARM_FIELD_PLANTING(id),
    -- contexto do alvo (desnormalizado do plantio p/ os filtros do mapa não dependerem de FARM_FIELD_PLANTING)
    culture_id    BIGINT NULL CONSTRAINT FK_FAT_cult REFERENCES dbo.FARM_CULTURE(id),
    variety_id    BIGINT NULL CONSTRAINT FK_FAT_var REFERENCES dbo.FARM_VARIETY(id),
    harvest_id    INT NULL,                          -- id da safra no Farmbox (casa FARM_SEASON.farmbox_harvest_id)
    harvest_name  VARCHAR(100) NULL,
    sought_area   DECIMAL(12,2) NULL,
    applied_area  DECIMAL(12,2) NULL,
    created_at    DATETIME2(3) NOT NULL CONSTRAINT DF_FAT_created DEFAULT SYSUTCDATETIME(),
    deleted_at    DATETIME2(3) NULL
);
CREATE INDEX IX_FARM_APP_TARGET_app   ON dbo.FARM_APPLICATION_TARGET(application_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARM_APP_TARGET_field ON dbo.FARM_APPLICATION_TARGET(field_id) WHERE deleted_at IS NULL;

/* ─────────────────── 3) MONITORAMENTOS + PRAGAS/ÍNDICES ──────────────────── */
CREATE TABLE dbo.FARM_MONITORING (
    id             BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_MONITORING PRIMARY KEY,
    field_id       BIGINT NOT NULL CONSTRAINT FK_FMON_field REFERENCES dbo.FARM_FIELDS(id),
    planting_id    BIGINT NULL CONSTRAINT FK_FMON_plant REFERENCES dbo.FARM_FIELD_PLANTING(id),
    monitoring_date DATE NULL,
    methodology    VARCHAR(40)  NULL,
    samples        INT NULL,
    phenological_stage NVARCHAR(60) NULL,
    mon_state      VARCHAR(20)  NULL,
    recommendation NVARCHAR(2000) NULL,
    monitor_person_id BIGINT NULL,                 -- amostrador → MANAGEMENT_PEOPLES
    monitor_name   NVARCHAR(200) NULL,
    source         VARCHAR(12)  NOT NULL CONSTRAINT DF_FMON_src DEFAULT 'app',
    farmbox_monitoring_id BIGINT NULL,
    created_at     DATETIME2(3) NOT NULL CONSTRAINT DF_FMON_created DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3) NULL,
    deleted_at     DATETIME2(3) NULL
);
CREATE INDEX IX_FARM_MON_field_date ON dbo.FARM_MONITORING(field_id, monitoring_date DESC) WHERE deleted_at IS NULL;

CREATE TABLE dbo.FARM_MONITORING_POINT (         -- paradas/pontos com coordenada
    id            BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_MONITORING_POINT PRIMARY KEY,
    monitoring_id BIGINT NOT NULL CONSTRAINT FK_FMP_mon REFERENCES dbo.FARM_MONITORING(id),
    seq           INT NULL,
    latitude      DECIMAL(10,7) NULL,
    longitude     DECIMAL(10,7) NULL,
    created_at    DATETIME2(3) NOT NULL CONSTRAINT DF_FMP_created DEFAULT SYSUTCDATETIME(),
    deleted_at    DATETIME2(3) NULL
);
CREATE INDEX IX_FARM_MON_POINT_mon ON dbo.FARM_MONITORING_POINT(monitoring_id) WHERE deleted_at IS NULL;

CREATE TABLE dbo.FARM_MONITORING_FINDING (       -- o ÍNDICE medido (infestação por alvo)
    id            BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_MONITORING_FINDING PRIMARY KEY,
    monitoring_id BIGINT NOT NULL CONSTRAINT FK_FMF_mon REFERENCES dbo.FARM_MONITORING(id),
    point_id      BIGINT NULL CONSTRAINT FK_FMF_point REFERENCES dbo.FARM_MONITORING_POINT(id), -- NULL por design: achado agregado por (monitoramento, praga), não por ponto

    pest_id       BIGINT NOT NULL CONSTRAINT FK_FMF_pest REFERENCES dbo.FARM_PEST(id),
    infestation   DECIMAL(12,3) NULL,             -- valor do índice (ex.: nº/planta, %)
    infestation_level VARCHAR(20) NULL,           -- baixo/médio/alto (ou escala Farmbox)
    quantity      DECIMAL(12,3) NULL,
    created_at    DATETIME2(3) NOT NULL CONSTRAINT DF_FMF_created DEFAULT SYSUTCDATETIME(),
    deleted_at    DATETIME2(3) NULL
);
CREATE INDEX IX_FARM_MON_FIND_mon  ON dbo.FARM_MONITORING_FINDING(monitoring_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARM_MON_FIND_pest ON dbo.FARM_MONITORING_FINDING(pest_id) WHERE deleted_at IS NULL;

CREATE TABLE dbo.FARM_MONITORING_DAY_MONITOR (   -- amostrador (quem monitorou) por plantation+dia
    id            BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_MDM PRIMARY KEY,
    plantation_id BIGINT NOT NULL,               -- ponte: farmbox plantation id (elo com a contagem)
    result_date   DATE NULL,
    monitor_id    BIGINT NULL,
    monitor_name  NVARCHAR(200) NULL,
    source        VARCHAR(12) NOT NULL CONSTRAINT DF_FMDM_src DEFAULT 'farmbox',
    created_at    DATETIME2(3) NOT NULL CONSTRAINT DF_FMDM_created DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_FARM_MDM_plant ON dbo.FARM_MONITORING_DAY_MONITOR(plantation_id, result_date);

CREATE TABLE dbo.FARM_PEST_THRESHOLD (           -- nível de ação (índice de controle) por cultura×praga
    id          BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_PEST_THRESHOLD PRIMARY KEY,
    culture_id  BIGINT NOT NULL CONSTRAINT FK_FPT_cult REFERENCES dbo.FARM_CULTURE(id),
    pest_id     BIGINT NOT NULL CONSTRAINT FK_FPT_pest REFERENCES dbo.FARM_PEST(id),
    level_name  VARCHAR(30)  NULL,                -- atenção | controle
    threshold_value DECIMAL(12,3) NULL,
    unit        VARCHAR(20)  NULL,
    action      NVARCHAR(400) NULL,
    active      BIT NOT NULL CONSTRAINT DF_FPT_active DEFAULT 1,
    created_at  DATETIME2(3) NOT NULL CONSTRAINT DF_FPT_created DEFAULT SYSUTCDATETIME(),
    deleted_at  DATETIME2(3) NULL
);

/* ─────────────────── 4) CONTAGEM + ESTIMATIVA ────────────────────────────── */
/* (fórmula por cultura já existe em PROD_ESTIMATE_FORMULA — reuso) */
CREATE TABLE dbo.FARM_COUNT (                     -- contagem em campo (base da estimativa)
    id            BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_COUNT PRIMARY KEY,
    field_id      BIGINT NOT NULL CONSTRAINT FK_FCNT_field REFERENCES dbo.FARM_FIELDS(id),
    planting_id   BIGINT NULL CONSTRAINT FK_FCNT_plant REFERENCES dbo.FARM_FIELD_PLANTING(id),
    count_date    DATE NULL,
    count_group   VARCHAR(150) NULL,             -- grupo de contagem (ex.: Estande, Componentes)
    latitude      DECIMAL(10,7) NULL,
    longitude     DECIMAL(10,7) NULL,
    parameters    NVARCHAR(MAX) NULL,            -- payload cru dos pIDs medidos (consumido pelo motor de estimativa)
    sampler_person_id BIGINT NULL,
    source        VARCHAR(12)  NOT NULL CONSTRAINT DF_FCNT_src DEFAULT 'app',
    farmbox_count_id BIGINT NULL,
    created_at    DATETIME2(3) NOT NULL CONSTRAINT DF_FCNT_created DEFAULT SYSUTCDATETIME(),
    deleted_at    DATETIME2(3) NULL
);
CREATE INDEX IX_FARM_COUNT_field_date ON dbo.FARM_COUNT(field_id, count_date DESC) WHERE deleted_at IS NULL;

CREATE TABLE dbo.FARM_COUNT_PARAM (              -- parâmetros medidos na contagem (pID)
    id         BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_COUNT_PARAM PRIMARY KEY,
    count_id   BIGINT NOT NULL CONSTRAINT FK_FCP_count REFERENCES dbo.FARM_COUNT(id),
    param_code VARCHAR(60)  NOT NULL,            -- ex.: pID / stand / vagens
    param_name NVARCHAR(120) NULL,
    value      DECIMAL(16,4) NULL,
    created_at DATETIME2(3) NOT NULL CONSTRAINT DF_FCP_created DEFAULT SYSUTCDATETIME(),
    deleted_at DATETIME2(3) NULL
);
CREATE INDEX IX_FARM_COUNT_PARAM_count ON dbo.FARM_COUNT_PARAM(count_id) WHERE deleted_at IS NULL;

CREATE TABLE dbo.FARM_ESTIMATE (                 -- estimativa calculada (snapshot por contagem)
    id           BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_ESTIMATE PRIMARY KEY,
    planting_id  BIGINT NOT NULL CONSTRAINT FK_FEST_plant REFERENCES dbo.FARM_FIELD_PLANTING(id),
    count_id     BIGINT NULL CONSTRAINT FK_FEST_count REFERENCES dbo.FARM_COUNT(id),
    formula_id   INT NULL CONSTRAINT FK_FEST_formula REFERENCES dbo.PROD_ESTIMATE_FORMULA(id),
    estimate_date DATE NULL,
    est_value    DECIMAL(12,2) NULL,             -- rendimento estimado
    unit         VARCHAR(20)  NULL,              -- sc/ha, @/ha...
    created_at   DATETIME2(3) NOT NULL CONSTRAINT DF_FEST_created DEFAULT SYSUTCDATETIME(),
    deleted_at   DATETIME2(3) NULL
);
CREATE INDEX IX_FARM_ESTIMATE_plant ON dbo.FARM_ESTIMATE(planting_id, estimate_date DESC) WHERE deleted_at IS NULL;

/* ─────────────────── 5) PRODUTIVIDADE (colheita) ─────────────────────────── */
/* rollup fica em FARM_FIELD_PLANTING.productivity; aqui o registro detalhado */
CREATE TABLE dbo.FARM_HARVEST_YIELD (
    id           BIGINT IDENTITY(1,1) CONSTRAINT PK_FARM_HARVEST_YIELD PRIMARY KEY,
    planting_id  BIGINT NOT NULL CONSTRAINT FK_FHY_plant REFERENCES dbo.FARM_FIELD_PLANTING(id),
    harvest_date DATE NULL,
    area_ha      DECIMAL(12,2) NULL,
    quantity     DECIMAL(14,3) NULL,             -- total colhido
    unit         VARCHAR(20)  NULL,              -- sc, kg, @, t
    productivity DECIMAL(12,3) NULL,             -- por ha
    moisture_pct DECIMAL(6,2) NULL,
    source       VARCHAR(12)  NOT NULL CONSTRAINT DF_FHY_src DEFAULT 'app',
    created_at   DATETIME2(3) NOT NULL CONSTRAINT DF_FHY_created DEFAULT SYSUTCDATETIME(),
    deleted_at   DATETIME2(3) NULL
);
CREATE INDEX IX_FARM_HARVEST_YIELD_plant ON dbo.FARM_HARVEST_YIELD(planting_id) WHERE deleted_at IS NULL;
