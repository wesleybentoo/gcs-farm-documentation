/* #####################################################################
   GCS CONNECTION FARM  |  SETUP COMPLETO DOS BANCOS  |  SQL Server
   Versão: 2026-07-03  (154 tabelas / 23 views / 1 proc — validado 0 drift em banco novo)

   Cria, na ordem correta:
     1) CONNECTOR_GCS_FARM (raw)
        1.1 Solinftec (SOLINFTEC_*)
        1.2 IrriControl (IRRICONTROL_*)
        1.3 Farmbox (FARMBOX_*)
     2) GCS_FARM (master)
        2.1 CONFIG, criptografia, MANAGEMENT
        2.2 FARM (+ FARM_FIELD_GEOMETRY)
        2.3 MACHINE_OPERATION, WEATHER (+ grid de clima por talhão:
            FIELD_WEATHER_HOURLY / FIELD_WEATHER_COVERAGE)
        2.4 Farmbox master (FARMBOX_*)

   Mudanças 2026-06-28 (clima): sensor vira ponto "solteiro" (lat/long); o ETL
   NÃO deriva mais field_id/farm_id da estação por interseção espacial (isso
   estourava o timeout). A chuva/temperatura/etc. POR TALHÃO passa a vir de um
   grid IDW (interpolação entre os sensores), gravado por talhão×hora em
   FIELD_WEATHER_HOURLY — fonte da verdade p/ KPIs, mapa de calor e cruzamento
   com a telemetria. Ver weatherGrid.service.ts (backend).

   Re-executável. Para reset limpo rode RESET_FULL.sql antes.
   ATENCAO: troque a senha do DMK na secao 2.3 (criptografia).
   ##################################################################### */
GO

/* =====================================================================
   SECAO 1 — CONNECTOR_GCS_FARM (camada raw)
   ===================================================================== */
IF DB_ID('CONNECTOR_GCS_FARM') IS NULL CREATE DATABASE CONNECTOR_GCS_FARM;
GO
USE CONNECTOR_GCS_FARM;
GO

/* ─── 1.1 SOLINFTEC raw ─────────────────────────────────────────────── */
/* =====================================================================
   CONNECTOR_GCS_FARM  |  Camada RAW (dados brutos)  |  SQL Server (T-SQL)
   Conector: Solinftec (tabelas dbo.SOLINFTEC_*)
   Gerado em: 2026-06-17

   Papel: guardar o retorno da API Solinftec EXATAMENTE como recebido
          (JSON em NVARCHAR(MAX) + ISJSON), mais o controle de ingestao.
          O tratamento/parsing acontece no ETL que alimenta o banco
          processado (GCS_FARM).

   Convencao:
     - Identificadores em INGLES; documentacao (comentarios) em PORTUGUES.
     - JSON validado por CHECK (ISJSON(...) = 1).
     - Datas/horas em DATETIME2(3), default SYSUTCDATETIME() (UTC).
     - record_id (CD_ID) e unico globalmente -> UNIQUE(record_id).
     - Padrao de auditoria em TODAS as tabelas: created_at, updated_at, deleted_at
       (deleted_at = soft delete; NULL = ativo). created_at substitui os antigos
       loaded_at/occurred_at/started_at (mesma semantica de criacao da linha).
   ===================================================================== */

-- CREATE DATABASE CONNECTOR_GCS_FARM;
-- GO
-- USE CONNECTOR_GCS_FARM;
-- GO

/* =====================================================================
   1) SOLINFTEC_INGESTION_LOG  -- controle por execucao (dia + fonte)
      "Dia bem-sucedido" = status 'SUCCESS'. created_at = abertura da execucao.
   ===================================================================== */
IF OBJECT_ID('dbo.SOLINFTEC_INGESTION_LOG') IS NOT NULL DROP TABLE dbo.SOLINFTEC_INGESTION_LOG;
GO
CREATE TABLE dbo.SOLINFTEC_INGESTION_LOG (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_SOLINFTEC_INGESTION_LOG PRIMARY KEY,
    source          VARCHAR(10)   NOT NULL,            -- OPERATION | WEATHER
    api_identifier  VARCHAR(4)    NOT NULL,            -- 22 | 21
    reference_date  DATE          NOT NULL,            -- dia coletado (D-1)
    status          VARCHAR(15)   NOT NULL
                    CONSTRAINT DF_SOLINFTEC_ING_status DEFAULT 'IN_PROGRESS',
    total_pages     INT           NULL,
    pages_loaded    INT           NOT NULL CONSTRAINT DF_SOLINFTEC_ING_pages DEFAULT 0,
    total_rows      INT           NULL,
    rows_loaded     INT           NOT NULL CONSTRAINT DF_SOLINFTEC_ING_rows DEFAULT 0,
    attempt         INT           NOT NULL CONSTRAINT DF_SOLINFTEC_ING_attempt DEFAULT 1,
    finished_at     DATETIME2(3)  NULL,                -- encerramento da execucao
    notes           NVARCHAR(MAX) NULL,
    created_at      DATETIME2(3)  NOT NULL CONSTRAINT DF_SOLINFTEC_ING_created DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)  NULL,
    deleted_at      DATETIME2(3)  NULL,
    CONSTRAINT CK_SOLINFTEC_ING_source CHECK (source IN ('OPERATION','WEATHER')),
    CONSTRAINT CK_SOLINFTEC_ING_api    CHECK (api_identifier IN ('22','21')),
    CONSTRAINT CK_SOLINFTEC_ING_status CHECK (status IN ('IN_PROGRESS','SUCCESS','PARTIAL','ERROR')),
    CONSTRAINT UQ_SOLINFTEC_ING_api_date UNIQUE (api_identifier, reference_date)
);
GO
CREATE INDEX IX_SOLINFTEC_ING_status ON dbo.SOLINFTEC_INGESTION_LOG (status, reference_date) INCLUDE (source);
GO

/* =====================================================================
   2) SOLINFTEC_INTEGRATION_ERROR  -- erros (aceita orfao: ingestion_id NULL)
      created_at = momento do erro.
   ===================================================================== */
IF OBJECT_ID('dbo.SOLINFTEC_INTEGRATION_ERROR') IS NOT NULL DROP TABLE dbo.SOLINFTEC_INTEGRATION_ERROR;
GO
CREATE TABLE dbo.SOLINFTEC_INTEGRATION_ERROR (
    id               BIGINT        IDENTITY(1,1) CONSTRAINT PK_SOLINFTEC_INTEGRATION_ERROR PRIMARY KEY,
    ingestion_id     BIGINT        NULL,              -- NULL = falha antes de abrir a execucao
    source           VARCHAR(10)   NULL,
    reference_date   DATE          NULL,
    page             INT           NULL,
    stage            VARCHAR(20)   NULL,              -- AUTH | PULL | PARSE | PERSIST
    http_status      INT           NULL,
    error_class      VARCHAR(150)  NULL,
    message          NVARCHAR(MAX) NULL,
    request_payload  NVARCHAR(MAX) NULL,              -- SEM credenciais
    response_payload NVARCHAR(MAX) NULL,
    created_at       DATETIME2(3)  NOT NULL CONSTRAINT DF_SOLINFTEC_ERR_created DEFAULT SYSUTCDATETIME(),
    updated_at       DATETIME2(3)  NULL,
    deleted_at       DATETIME2(3)  NULL,
    CONSTRAINT FK_SOLINFTEC_ERR_ingestion FOREIGN KEY (ingestion_id) REFERENCES dbo.SOLINFTEC_INGESTION_LOG(id),
    CONSTRAINT CK_SOLINFTEC_ERR_source   CHECK (source IS NULL OR source IN ('OPERATION','WEATHER')),
    CONSTRAINT CK_SOLINFTEC_ERR_req_json CHECK (request_payload  IS NULL OR ISJSON(request_payload)  = 1),
    CONSTRAINT CK_SOLINFTEC_ERR_res_json CHECK (response_payload IS NULL OR ISJSON(response_payload) = 1)
);
GO
CREATE INDEX IX_SOLINFTEC_ERR_created   ON dbo.SOLINFTEC_INTEGRATION_ERROR (created_at);
CREATE INDEX IX_SOLINFTEC_ERR_ingestion ON dbo.SOLINFTEC_INTEGRATION_ERROR (ingestion_id);
GO

/* =====================================================================
   3) SOLINFTEC_RESPONSE  -- pagina crua completa do /pull (auditoria)
      created_at = momento da gravacao.
   ===================================================================== */
IF OBJECT_ID('dbo.SOLINFTEC_RESPONSE') IS NOT NULL DROP TABLE dbo.SOLINFTEC_RESPONSE;
GO
CREATE TABLE dbo.SOLINFTEC_RESPONSE (
    id            BIGINT        IDENTITY(1,1) CONSTRAINT PK_SOLINFTEC_RESPONSE PRIMARY KEY,
    ingestion_id  BIGINT        NOT NULL,
    page          INT           NOT NULL,
    page_size     INT           NULL,
    total_rows    INT           NULL,
    total_pages   INT           NULL,
    body          NVARCHAR(MAX) NOT NULL,             -- resposta /pull completa da pagina
    created_at    DATETIME2(3)  NOT NULL CONSTRAINT DF_SOLINFTEC_RESP_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3)  NULL,
    deleted_at    DATETIME2(3)  NULL,
    CONSTRAINT FK_SOLINFTEC_RESP_ingestion FOREIGN KEY (ingestion_id) REFERENCES dbo.SOLINFTEC_INGESTION_LOG(id),
    CONSTRAINT CK_SOLINFTEC_RESP_json CHECK (ISJSON(body) = 1),
    CONSTRAINT UQ_SOLINFTEC_RESP_page UNIQUE (ingestion_id, page)
);
GO

/* =====================================================================
   4) SOLINFTEC_OPERATION  -- API 22, 1 linha por apontamento (record_id = CD_ID)
   ===================================================================== */
IF OBJECT_ID('dbo.SOLINFTEC_OPERATION') IS NOT NULL DROP TABLE dbo.SOLINFTEC_OPERATION;
GO
CREATE TABLE dbo.SOLINFTEC_OPERATION (
    id            BIGINT        IDENTITY(1,1) CONSTRAINT PK_SOLINFTEC_OPERATION PRIMARY KEY,
    ingestion_id  BIGINT        NOT NULL,
    page          INT           NULL,
    record_id     BIGINT        NOT NULL,             -- CD_ID (unico global)
    record        NVARCHAR(MAX) NOT NULL,             -- objeto cru do apontamento
    processed     BIT           NOT NULL CONSTRAINT DF_SOLINFTEC_OP_processed DEFAULT 0,
    processed_at  DATETIME2(3)  NULL,                 -- quando o ETL tratou
    created_at    DATETIME2(3)  NOT NULL CONSTRAINT DF_SOLINFTEC_OP_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3)  NULL,
    deleted_at    DATETIME2(3)  NULL,
    CONSTRAINT FK_SOLINFTEC_OP_ingestion FOREIGN KEY (ingestion_id) REFERENCES dbo.SOLINFTEC_INGESTION_LOG(id),
    CONSTRAINT CK_SOLINFTEC_OP_json CHECK (ISJSON(record) = 1),
    CONSTRAINT UQ_SOLINFTEC_OP_record UNIQUE (record_id)
);
GO
-- indice filtrado: fila do ETL (so o que ainda nao foi processado e nao deletado)
CREATE INDEX IX_SOLINFTEC_OP_pending ON dbo.SOLINFTEC_OPERATION (id) WHERE processed = 0 AND deleted_at IS NULL;
GO

/* =====================================================================
   5) SOLINFTEC_WEATHER  -- API 21, 1 linha por equipamento + hora
   ===================================================================== */
IF OBJECT_ID('dbo.SOLINFTEC_WEATHER') IS NOT NULL DROP TABLE dbo.SOLINFTEC_WEATHER;
GO
CREATE TABLE dbo.SOLINFTEC_WEATHER (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_SOLINFTEC_WEATHER PRIMARY KEY,
    ingestion_id    BIGINT        NOT NULL,
    page            INT           NULL,
    source_id       BIGINT        NULL,              -- CDID
    equipment_code  VARCHAR(20)   NOT NULL,          -- CDEQUIPAMENTO
    local_datetime  DATETIME2(3)  NOT NULL,          -- DTHRLOCAL (a hora ja carrega o dia)
    record          NVARCHAR(MAX) NOT NULL,          -- objeto cru completo
    processed       BIT           NOT NULL CONSTRAINT DF_SOLINFTEC_WEA_processed DEFAULT 0,
    processed_at    DATETIME2(3)  NULL,
    created_at      DATETIME2(3)  NOT NULL CONSTRAINT DF_SOLINFTEC_WEA_created DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)  NULL,
    deleted_at      DATETIME2(3)  NULL,
    CONSTRAINT FK_SOLINFTEC_WEA_ingestion FOREIGN KEY (ingestion_id) REFERENCES dbo.SOLINFTEC_INGESTION_LOG(id),
    CONSTRAINT CK_SOLINFTEC_WEA_json CHECK (ISJSON(record) = 1),
    CONSTRAINT UQ_SOLINFTEC_WEA_point UNIQUE (equipment_code, local_datetime)
);
GO
CREATE INDEX IX_SOLINFTEC_WEA_pending ON dbo.SOLINFTEC_WEATHER (id) WHERE processed = 0 AND deleted_at IS NULL;
GO

/* =====================================================================
   VIEW: dias pendentes (sem SUCCESS) nos ultimos 30 dias, por fonte.
   ===================================================================== */
IF OBJECT_ID('dbo.SOLINFTEC_PENDING_DAYS') IS NOT NULL DROP VIEW dbo.SOLINFTEC_PENDING_DAYS;
GO
CREATE VIEW dbo.SOLINFTEC_PENDING_DAYS AS
SELECT s.source, s.api_identifier, d.reference_date
FROM (VALUES ('OPERATION','22'), ('WEATHER','21')) AS s(source, api_identifier)
CROSS JOIN (
    SELECT TOP (30)
           CAST(DATEADD(DAY, - ROW_NUMBER() OVER (ORDER BY (SELECT 1)),
                        CAST(SYSUTCDATETIME() AS DATE)) AS DATE) AS reference_date
    FROM sys.all_objects
) AS d
LEFT JOIN dbo.SOLINFTEC_INGESTION_LOG i
       ON i.api_identifier = s.api_identifier
      AND i.reference_date = d.reference_date
      AND i.status = 'SUCCESS'
      AND i.deleted_at IS NULL
WHERE i.id IS NULL;
GO

/* =====================================================================
   NOTAS
   - Auditoria padrao: created_at, updated_at, deleted_at em todas as tabelas.
     deleted_at IS NULL = registro ativo (soft delete).
   - SEGURANCA: cliente/senha/token NUNCA gravados aqui (cofre/variavel de ambiente);
     request_payload deve omitir credenciais.
   ===================================================================== */

/* ---- 1.2 CADASTROS SOLINFTEC (de/para de codigos) ---- */
/* =====================================================================
   CONNECTOR_GCS_FARM  |  Cadastros de apoio do Solinftec  |  SQL Server
   Gerado em: 2026-06-25  |  Revisado: 2026-06-25 (v2 - correcoes da revisao)

   Objetivo: guardar os "cadastros" exportados do Solinftec (planilhas) que
   traduzem os codigos do JSON cru em descricoes (de/para). O ETL raw->master
   usa estes cadastros para enriquecer os dados (ex.: CD_EQUIPAMENTO -> nome).

   Estrategia (v2) - GENERICA, um unico modelo para TODAS as planilhas:
     - SOLINFTEC_CAD_CATALOG      : dicionario dos cadastros (chave, titulo,
       mapeamento de colunas, modo de importacao e se entra na LOOKUP).
     - SOLINFTEC_CAD_IMPORT       : 1 registro por importacao (auditoria do upload).
     - SOLINFTEC_CAD_IMPORT_ERROR : linhas/colunas rejeitadas na importacao.
     - SOLINFTEC_CAD_ENTRY        : 1 linha por item (code + description + payload).

   Correcoes desta versao (vindas da revisao):
     1. import_mode (UPSERT|REPLACE) por cadastro:
        - UPSERT  : cadastros com chave estavel (code/descricao unica) -> MERGE
          por (cad_key, natural_key), preserva id. Reconciliacao por last_import.
        - REPLACE : snapshots sem chave confiavel (EQUIPMENT_MODEL, RAIN_STATION)
          -> apaga o cad_key e regrava. Resolve de
          uma vez a colisao de chave e as linhas orfas.
     2. natural_key agora NVARCHAR(400) e ANULAVEL (REPLACE usa source_row).
        Unicidade so para quem tem chave (indice unico FILTRADO).
     3. is_lookup: RAIN_STATION sai da LOOKUP (e mapeamento de estacao -> alimenta
        WEATHER_STATION no master, nao um de/para code->descricao).
     4. SOLINFTEC_CAD_IMPORT_ERROR + rejected_rows + header_snapshot (detecta drift
        de colunas e captura erro por linha).

   Padrao das planilhas Solinftec:
     - Linha 1: titulo | Linha 2: data de exportacao | Linha 3: cabecalho | Linha 4+: dados.

   Flags de estado (semantica):
     - catalog.active   : cadastro habilitado para importacao.
     - entry.is_current : item presente no ultimo import (UPSERT) / sempre 1 (REPLACE).
     - entry.deleted_at : soft delete (item retirado/invalidado).
   ===================================================================== */

-- USE CONNECTOR_GCS_FARM;
-- GO

/* =====================================================================
   1) SOLINFTEC_CAD_CATALOG  -- dicionario dos cadastros disponiveis
   ===================================================================== */
IF OBJECT_ID('dbo.SOLINFTEC_CAD_CATALOG') IS NOT NULL DROP TABLE dbo.SOLINFTEC_CAD_CATALOG;
GO
CREATE TABLE dbo.SOLINFTEC_CAD_CATALOG (
    id                   BIGINT        IDENTITY(1,1) CONSTRAINT PK_SOLINFTEC_CAD_CATALOG PRIMARY KEY,
    cad_key              VARCHAR(40)   NOT NULL,           -- chave logica do cadastro (ingles)
    name                 NVARCHAR(120) NULL,               -- nome exibido (PT)
    source_title         NVARCHAR(120) NULL,               -- titulo na planilha (conferencia; NAO confiar p/ deteccao)
    header_row           INT           NULL CONSTRAINT DF_SOLINFTEC_CAD_CATALOG_hrow DEFAULT 3, -- cabecalho (1=titulo, 2=data, 3=cabecalho, 4+=dados)
    code_column          NVARCHAR(80)  NULL,               -- coluna que vira "code" (pode ser NULL)
    description_column   NVARCHAR(80)  NULL,               -- coluna que vira "description"
    natural_key_columns  NVARCHAR(200) NULL,               -- colunas que formam a chave natural (CSV); NULL em REPLACE
    import_mode          VARCHAR(10)   NOT NULL CONSTRAINT DF_SOLINFTEC_CAD_CATALOG_mode DEFAULT 'UPSERT',
    is_lookup            BIT           NULL CONSTRAINT DF_SOLINFTEC_CAD_CATALOG_lookup DEFAULT 1, -- entra na view LOOKUP?
    target_table         VARCHAR(80)   NULL,               -- dimensao de destino no master (ETL futuro)
    active               BIT           NULL CONSTRAINT DF_SOLINFTEC_CAD_CATALOG_active DEFAULT 1,
    created_at           DATETIME2(3)  NULL CONSTRAINT DF_SOLINFTEC_CAD_CATALOG_created DEFAULT SYSUTCDATETIME(),
    updated_at           DATETIME2(3)  NULL,
    deleted_at           DATETIME2(3)  NULL,
    CONSTRAINT UQ_SOLINFTEC_CAD_CATALOG_key   UNIQUE (cad_key),  -- unique constraint p/ permitir FK
    CONSTRAINT CK_SOLINFTEC_CAD_CATALOG_mode  CHECK (import_mode IN ('UPSERT','REPLACE'))
);
GO
-- Conferencia de titulo (apenas como auxilio; importacao usa cad_key explicito)
CREATE UNIQUE INDEX UX_SOLINFTEC_CAD_CATALOG_title ON dbo.SOLINFTEC_CAD_CATALOG (source_title) WHERE source_title IS NOT NULL;
GO
-- Seed dos cadastros enviados (planilhas Solinftec)
INSERT INTO dbo.SOLINFTEC_CAD_CATALOG
   (cad_key, name, source_title, code_column, description_column, natural_key_columns, import_mode, is_lookup, target_table) VALUES
 ('EQUIPMENT',               N'Equipamentos',                   N'Equipamentos',                   N'Código',        N'Descrição',           N'Código',  'UPSERT',  1, 'MACHINE_OPERATION_EQUIPMENT'),
 ('EQUIPMENT_TYPE',          N'Tipo de Equipamento',            N'Tipo de Equipamento',            N'Código',        N'Tipo de Equipamento', N'Código',  'UPSERT',  1, NULL),
 ('EQUIPMENT_GROUP',         N'Grupo de Equipamento',           N'Grupo de Equipamento',           N'Código',        N'Descrição',           N'Código',  'UPSERT',  1, NULL),
 ('EQUIPMENT_MODEL',         N'Modelo de Equipamento',          N'Modelo de Equipamento',          NULL,             N'Modelo',              NULL,       'REPLACE', 1, NULL),
 ('STATE',                   N'Estado',                         N'Estado',                         NULL,             N'Descrição',           N'Descrição','UPSERT', 1, NULL),
 ('STATE_BY_EQUIPMENT_TYPE', N'Estado por Tipo de Equipamento', N'Estado por Tipo de Equipamento', N'Código',        N'Estado',              N'Código',  'UPSERT',  1, NULL),
 ('IMPLEMENT_MEASURE',       N'Medidas do Implemento',          N'Medidas do Implemento',          N'Código',        N'Descrição',           N'Código',  'UPSERT',  1, NULL),
 ('STOP_GROUP',              N'Grupo Parada',                   N'Grupo Parada',                   N'Código',        N'Descrição',           N'Código',  'UPSERT',  1, 'MACHINE_OPERATION_STOP_REASON'),
 ('ACTIVITY_GROUP',          N'Grupo de Atividade',             N'Grupo de Atividade',             N'Código',        N'Descrição',           N'Código',  'UPSERT',  1, NULL),
 ('OPERATION_GROUP',         N'Grupo de Operação',              N'Grupo de Operação',              NULL,             N'Descrição',           N'Descrição','UPSERT', 1, NULL),
 ('OPERATION',               N'Operação',                       N'Operação',                       N'Código',        N'Descrição',           N'Código',  'UPSERT',  1, 'MACHINE_OPERATION_OPERATION'),
 ('ROLE',                    N'Cargo',                          N'Cargo',                          N'Código',        N'Descrição',           N'Código',  'UPSERT',  1, NULL),
 ('EMPLOYEE',                N'Funcionários',                   N'Funcionários',                   N'Código',        N'Nome',                N'Código',  'UPSERT',  1, 'MACHINE_OPERATION_OPERATOR'),
 ('FIELD_METADATA',          N'Metadado Campo',                 N'Metadado Campo',                 N'Código',        N'Nome Campo',          N'Código',  'UPSERT',  1, NULL),
 ('ALARM_JUSTIFICATION',     N'Justificativa de Alarme',        N'Justificativa de Alarme',        N'Código',        N'Descrição',           N'Código',  'UPSERT',  1, NULL),
 ('RAIN_STATION',            N'Estação Pluviômetro / Fazenda',  N'Estação Pluviômetro / Fazenda',  N'Equipamento',   N'Tipo de Equipamento', NULL,                  'REPLACE', 0, 'WEATHER_STATION'),
 -- geolocalizacao dos pluviometros/estacoes (planilha "Pluviômetros"): cabecalho na 1a linha; code vem "5001 - PLUVIOMETRO".
 -- natural_key_columns (Latitude,Longitude) so torna a auto-deteccao distintiva; REPLACE nao usa como chave.
 ('WEATHER_STATION_GEO',     N'Pluviômetros / Geolocalização',  N'Pluviômetros',                   N'Código Equipamento', N'Tipo',           N'Latitude,Longitude', 'REPLACE', 0, 'WEATHER_STATION');
GO

/* =====================================================================
   2) SOLINFTEC_CAD_IMPORT  -- 1 registro por importacao de planilha
   ===================================================================== */
IF OBJECT_ID('dbo.SOLINFTEC_CAD_IMPORT') IS NOT NULL DROP TABLE dbo.SOLINFTEC_CAD_IMPORT;
GO
CREATE TABLE dbo.SOLINFTEC_CAD_IMPORT (
    id                 BIGINT        IDENTITY(1,1) CONSTRAINT PK_SOLINFTEC_CAD_IMPORT PRIMARY KEY,
    cad_key            VARCHAR(40)   NOT NULL,             -- qual cadastro (FK -> CATALOG)
    import_mode        VARCHAR(10)   NULL,                 -- modo usado (copia do catalogo no momento)
    source_filename    NVARCHAR(255) NULL,                 -- nome do arquivo enviado
    source_exported_at DATETIME2(3)  NULL,                 -- data/hora dentro da planilha (linha 1)
    header_snapshot    NVARCHAR(MAX) NULL,                 -- colunas lidas (JSON) p/ detectar drift
    total_rows         INT           NULL,                 -- linhas de dados na planilha
    imported_rows      INT           NULL,                 -- linhas gravadas
    rejected_rows      INT           NULL,                 -- linhas rejeitadas (ver IMPORT_ERROR)
    status             VARCHAR(15)   NULL,                 -- IN_PROGRESS | SUCCESS | PARTIAL | ERROR
    imported_by        VARCHAR(60)   NULL,                 -- usuario do GCS_FARM (referencia logica)
    notes              NVARCHAR(MAX) NULL,
    created_at         DATETIME2(3)  NULL CONSTRAINT DF_SOLINFTEC_CAD_IMPORT_created DEFAULT SYSUTCDATETIME(),
    updated_at         DATETIME2(3)  NULL,
    deleted_at         DATETIME2(3)  NULL,
    CONSTRAINT FK_SOLINFTEC_CAD_IMPORT_catalog FOREIGN KEY (cad_key) REFERENCES dbo.SOLINFTEC_CAD_CATALOG(cad_key),
    CONSTRAINT CK_SOLINFTEC_CAD_IMPORT_status  CHECK (status IS NULL OR status IN ('IN_PROGRESS','SUCCESS','PARTIAL','ERROR')),
    CONSTRAINT CK_SOLINFTEC_CAD_IMPORT_jsonhdr CHECK (header_snapshot IS NULL OR ISJSON(header_snapshot) = 1)
);
GO
CREATE INDEX IX_SOLINFTEC_CAD_IMPORT_key ON dbo.SOLINFTEC_CAD_IMPORT (cad_key, created_at);
GO

/* =====================================================================
   3) SOLINFTEC_CAD_IMPORT_ERROR  -- erros por linha/coluna na importacao
   ===================================================================== */
IF OBJECT_ID('dbo.SOLINFTEC_CAD_IMPORT_ERROR') IS NOT NULL DROP TABLE dbo.SOLINFTEC_CAD_IMPORT_ERROR;
GO
CREATE TABLE dbo.SOLINFTEC_CAD_IMPORT_ERROR (
    id          BIGINT        IDENTITY(1,1) CONSTRAINT PK_SOLINFTEC_CAD_IMPORT_ERROR PRIMARY KEY,
    import_id   BIGINT        NOT NULL,                    -- FK -> IMPORT
    source_row  INT           NULL,                        -- linha na planilha
    column_name NVARCHAR(80)  NULL,                        -- coluna problematica
    error_type  VARCHAR(30)   NULL,                        -- MISSING_COLUMN | INVALID_VALUE | DUPLICATE_KEY | OTHER
    message     NVARCHAR(MAX) NULL,
    raw_value   NVARCHAR(MAX) NULL,
    created_at  DATETIME2(3)  NULL CONSTRAINT DF_SOLINFTEC_CAD_IMPORT_ERROR_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3)  NULL,
    deleted_at  DATETIME2(3)  NULL,
    CONSTRAINT FK_SOLINFTEC_CAD_IMPORT_ERROR_import FOREIGN KEY (import_id) REFERENCES dbo.SOLINFTEC_CAD_IMPORT(id),
    CONSTRAINT CK_SOLINFTEC_CAD_IMPORT_ERROR_type CHECK (error_type IS NULL OR error_type IN ('MISSING_COLUMN','INVALID_VALUE','DUPLICATE_KEY','OTHER'))
);
GO
CREATE INDEX IX_SOLINFTEC_CAD_IMPORT_ERROR_import ON dbo.SOLINFTEC_CAD_IMPORT_ERROR (import_id);
GO

/* =====================================================================
   4) SOLINFTEC_CAD_ENTRY  -- itens dos cadastros (de/para code -> descricao)
      - UPSERT : natural_key preenchida (chave) -> indice unico filtrado garante 1/cad_key.
      - REPLACE: natural_key NULL; source_row identifica a linha; sem unicidade.
   ===================================================================== */
IF OBJECT_ID('dbo.SOLINFTEC_CAD_ENTRY') IS NOT NULL DROP TABLE dbo.SOLINFTEC_CAD_ENTRY;
GO
CREATE TABLE dbo.SOLINFTEC_CAD_ENTRY (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_SOLINFTEC_CAD_ENTRY PRIMARY KEY,
    cad_key         VARCHAR(40)   NOT NULL,                -- FK -> CATALOG
    natural_key     NVARCHAR(400) NULL,                    -- chave do item (UPSERT); NULL em REPLACE
    source_row      INT           NULL,                    -- linha no export (REPLACE)
    code            VARCHAR(60)   NULL,                    -- codigo do cadastro (quando houver)
    description     NVARCHAR(300) NULL,                    -- descricao/nome
    payload         NVARCHAR(MAX) NULL,                    -- linha completa (JSON)
    import_id       BIGINT        NULL,                    -- FK -> importacao que gravou/atualizou
    is_current      BIT           NULL CONSTRAINT DF_SOLINFTEC_CAD_ENTRY_current DEFAULT 1,
    created_at      DATETIME2(3)  NULL CONSTRAINT DF_SOLINFTEC_CAD_ENTRY_created DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)  NULL,
    deleted_at      DATETIME2(3)  NULL,
    CONSTRAINT FK_SOLINFTEC_CAD_ENTRY_catalog FOREIGN KEY (cad_key)   REFERENCES dbo.SOLINFTEC_CAD_CATALOG(cad_key),
    CONSTRAINT FK_SOLINFTEC_CAD_ENTRY_import  FOREIGN KEY (import_id) REFERENCES dbo.SOLINFTEC_CAD_IMPORT(id),
    CONSTRAINT CK_SOLINFTEC_CAD_ENTRY_json    CHECK (payload IS NULL OR ISJSON(payload) = 1)
);
GO
-- Unicidade SO para cadastros com chave (UPSERT). REPLACE deixa natural_key NULL.
CREATE UNIQUE INDEX UX_SOLINFTEC_CAD_ENTRY_nk
    ON dbo.SOLINFTEC_CAD_ENTRY (cad_key, natural_key)
    WHERE natural_key IS NOT NULL AND deleted_at IS NULL;
GO
-- Lookup rapido por codigo (enriquecimento no ETL)
CREATE INDEX IX_SOLINFTEC_CAD_ENTRY_code ON dbo.SOLINFTEC_CAD_ENTRY (cad_key, code) WHERE code IS NOT NULL;
GO

/* =====================================================================
   5) VIEW de enriquecimento (de/para code -> description; so cadastros is_lookup=1)
   ===================================================================== */
IF OBJECT_ID('dbo.SOLINFTEC_CAD_LOOKUP') IS NOT NULL DROP VIEW dbo.SOLINFTEC_CAD_LOOKUP;
GO
CREATE VIEW dbo.SOLINFTEC_CAD_LOOKUP AS
SELECT e.cad_key, e.code, e.description, e.payload
FROM dbo.SOLINFTEC_CAD_ENTRY e
JOIN dbo.SOLINFTEC_CAD_CATALOG c ON c.cad_key = e.cad_key
WHERE c.is_lookup = 1 AND c.deleted_at IS NULL
  AND e.is_current = 1 AND e.deleted_at IS NULL;
GO

/* =====================================================================
   NOTAS DE USO (o backend/front faz isto; aqui so referencia)
   -------------------------------------------------------------------
   IMPORTACAO (fluxo do front, sem SQL puro):
     1. Front envia SO o .xlsx (sem dizer o tipo). O backend IDENTIFICA o cadastro:
        - le o titulo (linha 1) e o cabecalho (linha 3) e compara com o CATALOG
          (source_title + conjunto de colunas code/description/natural_key).
        - match unico -> usa esse cad_key; ambiguo/nenhum -> erro p/ o usuario
          escolher manualmente (cad_key override e opcional).
     2. Valida as colunas esperadas; divergencia -> CAD_IMPORT_ERROR (MISSING_COLUMN)
        e grava header_snapshot no IMPORT.
     3. Conforme catalog.import_mode:
        - UPSERT : para cada linha calcula natural_key (natural_key_columns),
          code, description, payload(JSON) e faz MERGE por (cad_key, natural_key).
          Apos o lote, marca is_current=0 nos itens cujo natural_key nao veio
          neste import (reconciliacao de orfaos).
        - REPLACE: DELETE FROM CAD_ENTRY WHERE cad_key=@k; depois INSERT de todas
          as linhas (natural_key NULL, source_row = numero da linha). Resolve
          chaves duplicadas e orfaos sem depender de unicidade.
     4. Grava CAD_IMPORT (status, total/imported/rejected_rows, usuario).

   ENRIQUECIMENTO (ETL raw -> master), exemplo equipamento (cast p/ tipo do JSON):
     SELECT l.description
     FROM dbo.SOLINFTEC_CAD_LOOKUP l
     WHERE l.cad_key = 'EQUIPMENT' AND l.code = CAST(@cd_equipamento AS varchar(60));

   - REPLACE (sem chave confiavel): EQUIPMENT_MODEL, RAIN_STATION.
     Os demais sao UPSERT (chave unica confirmada nos dados).
   - RAIN_STATION (is_lookup=0): mapeamento estacao->fazenda/zona/talhao + flags
     de sensores; alimenta dbo.WEATHER_STATION no master, nao a LOOKUP.
   - ALARM_TYPE / GENERAL_TYPES: NAO carregados (dados indisponiveis) — fora do catalogo.
   - OPERATION (Operação): dimensao de operacoes, code unico -> alimenta MACHINE_OPERATION_OPERATION.
   ===================================================================== */

/* ─── 1.2 IRRICONTROL raw ──────────────────────────────────────────── */
/* #####################################################################
   GCS CONNECTION FARM  |  CONNECTOR_GCS_FARM (camada raw)
   Modulo: IRRICONTROL  |  SQL Server (T-SQL)
   Gerado em: 2026-06-25  |  Versao: v2

   Correcoes aplicadas sobre a v1 (resultado da simulacao de ingestion):

   FIX-1 [CRITICO] UX_ING_pivot_src_date inclui AND status = 'SUCCESS'
         Impede que uma execucao com ERROR bloqueie o retry do mesmo dia.

   FIX-2 [WARN] pivot_irri_id adicionado em PIVOT_OPERATION, PIVOT_SNAPSHOT
         e PIVOT_HISTORY. Guarda o id numerico do pivo (pivot_information.id)
         para manter vinculo mesmo que pivot_name seja renomeado na plataforma.

   FIX-3 [WARN] event_type CHECK removido — tipo desconhecido grava como NULL.
         Um novo tipo de evento nao quebra mais o PERSIST. O tipo original
         continua disponivel no campo record (JSON cru).
         Substituido por: coluna event_type_raw VARCHAR(30) guarda o valor
         original da API sem filtro; event_type so e preenchido se reconhecido.

   FIX-4 [WARN] total_rows DEFAULT 1 quando source = 'SNAPSHOT'.
         Para SNAPSHOT a API retorna sempre 1 objeto; o campo fica coerente
         sem precisar de logica no ETL. Aplicado via DEFAULT + constraint.

   FIX-5 [WARN] Colunas de suporte ao resume automatico no INGESTION_LOG.
         Adicionado: resume_at DATETIME2(3) (quando o scheduler vai retomar),
         max_attempts INT DEFAULT 3 (limite de tentativas), e indice
         IX_ING_stale para o scheduler encontrar execucoes travadas.

   FIX-6 [INFO] current_direction CHECK substituido por coluna _raw.
         Mesmo padrao do event_type: direction_raw guarda o valor original;
         current_direction so e preenchido se CLOCKWISE|COUNTER_CLOCKWISE|STOPPED.

   FIX-7 [INFO] Coluna partition_month AS (CONVERT(CHAR(7),reference_date,23))
         adicionada ao PIVOT_SNAPSHOT para facilitar future particao por mes
         e politica de retencao (TTL via deleted_at em lote por mes).
   ##################################################################### */

/* =====================================================================
   1) IRRICONTROL_INGESTION_LOG  (v2)

   Alteracoes vs v1:
   - [FIX-1] UX_ING_pivot_src_date agora filtra AND status = 'SUCCESS':
             uma execucao com ERROR libera nova tentativa no mesmo dia.
   - [FIX-5] Adicionado: resume_at, max_attempts, IX_ING_stale (encontrar
             execucoes IN_PROGRESS travadas para resume automatico).
   ===================================================================== */
IF OBJECT_ID('dbo.IRRICONTROL_INGESTION_LOG') IS NOT NULL DROP TABLE dbo.IRRICONTROL_INGESTION_LOG;
GO
CREATE TABLE dbo.IRRICONTROL_INGESTION_LOG (
    id             BIGINT        IDENTITY(1,1) CONSTRAINT PK_IRRICONTROL_INGESTION_LOG PRIMARY KEY,
    pivot_name     VARCHAR(120)  NOT NULL,
    source         VARCHAR(10)   NOT NULL,
    reference_date DATE          NULL,
    status         VARCHAR(15)   NOT NULL
                   CONSTRAINT DF_IRRICONTROL_ING_status  DEFAULT 'IN_PROGRESS',

    -- controle de execucao
    total_rows     INT           NULL,
    rows_loaded    INT           NOT NULL CONSTRAINT DF_IRRICONTROL_ING_rows    DEFAULT 0,
    offset_loaded  INT           NOT NULL CONSTRAINT DF_IRRICONTROL_ING_offset  DEFAULT 0,
    attempt        INT           NOT NULL CONSTRAINT DF_IRRICONTROL_ING_attempt DEFAULT 1,
    max_attempts   INT           NOT NULL CONSTRAINT DF_IRRICONTROL_ING_maxatt  DEFAULT 3,  -- [FIX-5]
    resume_at      DATETIME2(3)  NULL,    -- [FIX-5] quando o scheduler deve retomar (NULL = nao agendar)
    finished_at    DATETIME2(3)  NULL,
    notes          NVARCHAR(MAX) NULL,

    created_at     DATETIME2(3)  NOT NULL CONSTRAINT DF_IRRICONTROL_ING_created DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)  NULL,
    deleted_at     DATETIME2(3)  NULL,

    CONSTRAINT CK_IRRICONTROL_ING_source CHECK (source IN ('OPERATION','HISTORY','SNAPSHOT')),
    CONSTRAINT CK_IRRICONTROL_ING_status CHECK (status IN ('IN_PROGRESS','SUCCESS','PARTIAL','ERROR'))
);
GO

/* [FIX-1] Unicidade filtrada: so OPERATION/HISTORY COM status=SUCCESS ocupam a vaga.
   Uma execucao ERROR ou PARTIAL NAO bloqueia o retry do mesmo dia/pivo. */
CREATE UNIQUE INDEX UX_IRRICONTROL_ING_pivot_src_date
    ON dbo.IRRICONTROL_INGESTION_LOG (pivot_name, source, reference_date)
    WHERE source IN ('OPERATION','HISTORY')
      AND reference_date IS NOT NULL
      AND status = 'SUCCESS'         -- [FIX-1] correcao critica
      AND deleted_at IS NULL;
GO

/* [FIX-5] Indice para o scheduler encontrar execucoes travadas (stale IN_PROGRESS).
   Query: WHERE status='IN_PROGRESS' AND created_at < DATEADD(MINUTE,-15,SYSUTCDATETIME()) */
CREATE INDEX IX_IRRICONTROL_ING_stale
    ON dbo.IRRICONTROL_INGESTION_LOG (status, created_at)
    INCLUDE (pivot_name, source, offset_loaded, attempt, max_attempts)
    WHERE status = 'IN_PROGRESS' AND deleted_at IS NULL;
GO

/* Consulta geral por pivo/fonte/status (monitoramento e dashboard). */
CREATE INDEX IX_IRRICONTROL_ING_pivot_source
    ON dbo.IRRICONTROL_INGESTION_LOG (pivot_name, source, status, reference_date)
    INCLUDE (rows_loaded, finished_at, attempt);
GO

/* =====================================================================
   2) IRRICONTROL_INTEGRATION_ERROR  (sem alteracoes vs v1)
   ===================================================================== */
IF OBJECT_ID('dbo.IRRICONTROL_INTEGRATION_ERROR') IS NOT NULL DROP TABLE dbo.IRRICONTROL_INTEGRATION_ERROR;
GO
CREATE TABLE dbo.IRRICONTROL_INTEGRATION_ERROR (
    id               BIGINT        IDENTITY(1,1) CONSTRAINT PK_IRRICONTROL_INTEGRATION_ERROR PRIMARY KEY,
    ingestion_id     BIGINT        NULL,
    pivot_name       VARCHAR(120)  NULL,
    source           VARCHAR(10)   NULL,
    reference_date   DATE          NULL,
    stage            VARCHAR(10)   NULL,
    http_status      INT           NULL,
    error_class      VARCHAR(150)  NULL,
    message          NVARCHAR(MAX) NULL,
    request_payload  NVARCHAR(MAX) NULL,
    response_payload NVARCHAR(MAX) NULL,
    created_at       DATETIME2(3)  NOT NULL CONSTRAINT DF_IRRICONTROL_ERR_created DEFAULT SYSUTCDATETIME(),
    updated_at       DATETIME2(3)  NULL,
    deleted_at       DATETIME2(3)  NULL,
    CONSTRAINT FK_IRRICONTROL_ERR_ingestion  FOREIGN KEY (ingestion_id) REFERENCES dbo.IRRICONTROL_INGESTION_LOG(id),
    CONSTRAINT CK_IRRICONTROL_ERR_source     CHECK (source IS NULL OR source IN ('OPERATION','HISTORY','SNAPSHOT')),
    CONSTRAINT CK_IRRICONTROL_ERR_stage      CHECK (stage  IS NULL OR stage  IN ('AUTH','PULL','PARSE','PERSIST')),
    CONSTRAINT CK_IRRICONTROL_ERR_req_json   CHECK (request_payload  IS NULL OR ISJSON(request_payload)  = 1),
    CONSTRAINT CK_IRRICONTROL_ERR_res_json   CHECK (response_payload IS NULL OR ISJSON(response_payload) = 1)
);
GO
CREATE INDEX IX_IRRICONTROL_ERR_ingestion ON dbo.IRRICONTROL_INTEGRATION_ERROR (ingestion_id);
CREATE INDEX IX_IRRICONTROL_ERR_created   ON dbo.IRRICONTROL_INTEGRATION_ERROR (created_at);
GO

/* =====================================================================
   3) IRRICONTROL_PIVOT_OPERATION  (v2)

   Alteracoes vs v1:
   - [FIX-2] pivot_irri_id BIGINT NULL: id numerico do pivo na API
             (pivot_information.id). Vinculo estavel mesmo se pivot_name mudar.
   ===================================================================== */
IF OBJECT_ID('dbo.IRRICONTROL_PIVOT_OPERATION') IS NOT NULL DROP TABLE dbo.IRRICONTROL_PIVOT_OPERATION;
GO
CREATE TABLE dbo.IRRICONTROL_PIVOT_OPERATION (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_IRRICONTROL_PIVOT_OPERATION PRIMARY KEY,
    ingestion_id    BIGINT        NOT NULL,
    record_id       BIGINT        NOT NULL,
    pivot_name      VARCHAR(120)  NOT NULL,
    pivot_irri_id   BIGINT        NULL,    -- [FIX-2] pivot_information.id (vinculo estavel)
    start_date      DATETIME2(3)  NULL,
    end_date        DATETIME2(3)  NULL,
    irrigation_mode VARCHAR(30)   NULL,
    record          NVARCHAR(MAX) NOT NULL,
    processed       BIT           NOT NULL CONSTRAINT DF_IRRICONTROL_OP_processed DEFAULT 0,
    processed_at    DATETIME2(3)  NULL,
    created_at      DATETIME2(3)  NOT NULL CONSTRAINT DF_IRRICONTROL_OP_created DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)  NULL,
    deleted_at      DATETIME2(3)  NULL,
    CONSTRAINT FK_IRRICONTROL_OP_ingestion FOREIGN KEY (ingestion_id) REFERENCES dbo.IRRICONTROL_INGESTION_LOG(id),
    CONSTRAINT CK_IRRICONTROL_OP_json      CHECK (ISJSON(record) = 1),
    CONSTRAINT UQ_IRRICONTROL_OP_record    UNIQUE (record_id)
);
GO
CREATE INDEX IX_IRRICONTROL_OP_pending
    ON dbo.IRRICONTROL_PIVOT_OPERATION (id)
    WHERE processed = 0 AND deleted_at IS NULL;
GO
CREATE INDEX IX_IRRICONTROL_OP_pivot_start
    ON dbo.IRRICONTROL_PIVOT_OPERATION (pivot_name, start_date)
    INCLUDE (end_date, irrigation_mode, processed);
GO
-- [FIX-2] Busca por id numerico do pivo (resolucao no ETL)
CREATE INDEX IX_IRRICONTROL_OP_irri_id
    ON dbo.IRRICONTROL_PIVOT_OPERATION (pivot_irri_id)
    WHERE pivot_irri_id IS NOT NULL;
GO

/* =====================================================================
   4) IRRICONTROL_PIVOT_SNAPSHOT  (v2)

   Alteracoes vs v1:
   - [FIX-2] pivot_irri_id: id numerico do pivo na API.
   - [FIX-4] total_rows DEFAULT 1 para SNAPSHOT (a API sempre retorna 1 objeto).
             Aplicado pelo ETL ao fechar o log; o campo fica coerente sem logica extra.
   - [FIX-7] partition_month coluna computada VARCHAR(7) = 'YYYY-MM', gerada
             a partir de snapshot_at. Facilita TTL em lote e futuro particionamento.
   ===================================================================== */
IF OBJECT_ID('dbo.IRRICONTROL_PIVOT_SNAPSHOT') IS NOT NULL DROP TABLE dbo.IRRICONTROL_PIVOT_SNAPSHOT;
GO
CREATE TABLE dbo.IRRICONTROL_PIVOT_SNAPSHOT (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_IRRICONTROL_PIVOT_SNAPSHOT PRIMARY KEY,
    ingestion_id    BIGINT        NOT NULL,
    pivot_name      VARCHAR(120)  NOT NULL,
    pivot_irri_id   BIGINT        NULL,    -- [FIX-2]
    snapshot_at     DATETIME2(3)  NOT NULL,

    -- [FIX-7] Coluna computada para TTL / particionamento por mes
    -- estilo 126 (ISO) e deterministico p/ datetime->char (23 nao e) -> permite PERSISTED
    partition_month AS (CONVERT(CHAR(7), snapshot_at, 126)) PERSISTED,

    -- campos extraidos para ETL rapido
    pivot_status    VARCHAR(30)   NULL,
    current_angle   DECIMAL(8,4)  NULL,
    gps_lat         DECIMAL(9,6)  NULL,
    gps_lng         DECIMAL(9,6)  NULL,
    is_raining      BIT           NULL,

    record          NVARCHAR(MAX) NOT NULL,
    processed       BIT           NOT NULL CONSTRAINT DF_IRRICONTROL_SNAP_processed DEFAULT 0,
    processed_at    DATETIME2(3)  NULL,
    created_at      DATETIME2(3)  NOT NULL CONSTRAINT DF_IRRICONTROL_SNAP_created DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)  NULL,
    deleted_at      DATETIME2(3)  NULL,

    CONSTRAINT FK_IRRICONTROL_SNAP_ingestion FOREIGN KEY (ingestion_id) REFERENCES dbo.IRRICONTROL_INGESTION_LOG(id),
    CONSTRAINT CK_IRRICONTROL_SNAP_json      CHECK (ISJSON(record) = 1),
    CONSTRAINT UQ_IRRICONTROL_SNAP_point     UNIQUE (pivot_name, snapshot_at)
);
GO
CREATE INDEX IX_IRRICONTROL_SNAP_pending
    ON dbo.IRRICONTROL_PIVOT_SNAPSHOT (id)
    WHERE processed = 0 AND deleted_at IS NULL;
GO
-- Serie temporal + consulta por mes (TTL / dashboard)
CREATE INDEX IX_IRRICONTROL_SNAP_pivot_time
    ON dbo.IRRICONTROL_PIVOT_SNAPSHOT (pivot_name, snapshot_at DESC)
    INCLUDE (pivot_status, current_angle, is_raining, processed, partition_month);
GO
-- [FIX-7] Indice de suporte para TTL em lote (DELETE WHERE partition_month < 'YYYY-MM')
CREATE INDEX IX_IRRICONTROL_SNAP_partition
    ON dbo.IRRICONTROL_PIVOT_SNAPSHOT (partition_month, pivot_name)
    INCLUDE (deleted_at)
    WHERE deleted_at IS NULL;
GO

/* =====================================================================
   5) IRRICONTROL_PIVOT_HISTORY  (v2)

   Alteracoes vs v1:
   - [FIX-2] pivot_irri_id: id numerico do pivo na API.
   - [FIX-3] CHECK(event_type) REMOVIDO. Substituido por:
       event_type_raw VARCHAR(30): valor exato retornado pela API (sem filtro).
       event_type     VARCHAR(30): preenchido pelo ETL somente se reconhecido;
                                   NULL se tipo desconhecido (nao quebra o PERSIST).
   - [FIX-6] current_direction: mesmo padrao. Coluna direction_raw guarda
             o valor original; current_direction so recebe o valor se valido.
   ===================================================================== */
IF OBJECT_ID('dbo.IRRICONTROL_PIVOT_HISTORY') IS NOT NULL DROP TABLE dbo.IRRICONTROL_PIVOT_HISTORY;
GO
CREATE TABLE dbo.IRRICONTROL_PIVOT_HISTORY (
    id                BIGINT        IDENTITY(1,1) CONSTRAINT PK_IRRICONTROL_PIVOT_HISTORY PRIMARY KEY,
    ingestion_id      BIGINT        NOT NULL,
    record_id         BIGINT        NOT NULL,
    pivot_name        VARCHAR(120)  NOT NULL,
    pivot_irri_id     BIGINT        NULL,    -- [FIX-2]

    -- [FIX-3] event_type: raw preservado + campo normalizado (sem CHECK que quebra)
    event_type_raw    VARCHAR(30)   NULL,    -- valor exato da API (sem restricao)
    event_type        VARCHAR(30)   NULL,    -- normalizado; NULL se desconhecido

    event_at          DATETIME2(3)  NULL,

    -- [FIX-6] direction: raw preservado + campo normalizado
    direction_raw     VARCHAR(30)   NULL,    -- valor exato da API
    current_direction VARCHAR(30)   NULL,    -- CLOCKWISE|COUNTER_CLOCKWISE|STOPPED ou NULL

    record            NVARCHAR(MAX) NOT NULL,
    processed         BIT           NOT NULL CONSTRAINT DF_IRRICONTROL_HIST_processed DEFAULT 0,
    processed_at      DATETIME2(3)  NULL,
    created_at        DATETIME2(3)  NOT NULL CONSTRAINT DF_IRRICONTROL_HIST_created DEFAULT SYSUTCDATETIME(),
    updated_at        DATETIME2(3)  NULL,
    deleted_at        DATETIME2(3)  NULL,

    CONSTRAINT FK_IRRICONTROL_HIST_ingestion  FOREIGN KEY (ingestion_id) REFERENCES dbo.IRRICONTROL_INGESTION_LOG(id),
    CONSTRAINT CK_IRRICONTROL_HIST_json       CHECK (ISJSON(record) = 1),
    -- [FIX-3/6] CHECKs nas colunas NORMALIZADAS (nao nas _raw). NULL e permitido.
    CONSTRAINT CK_IRRICONTROL_HIST_etype      CHECK (event_type IS NULL
                                                     OR event_type IN ('action','config','gps','panel','periodic','maintenance','central')),
    CONSTRAINT CK_IRRICONTROL_HIST_direction  CHECK (current_direction IS NULL
                                                     OR current_direction IN ('CLOCKWISE','COUNTER_CLOCKWISE','STOPPED')),
    CONSTRAINT UQ_IRRICONTROL_HIST_record     UNIQUE (record_id)
);
GO
CREATE INDEX IX_IRRICONTROL_HIST_pending
    ON dbo.IRRICONTROL_PIVOT_HISTORY (id)
    WHERE processed = 0 AND deleted_at IS NULL;
GO
CREATE INDEX IX_IRRICONTROL_HIST_pivot_type_time
    ON dbo.IRRICONTROL_PIVOT_HISTORY (pivot_name, event_type, event_at DESC)
    INCLUDE (current_direction, processed);
GO
-- [FIX-3] Indice para monitorar tipos desconhecidos (alertar equipe)
CREATE INDEX IX_IRRICONTROL_HIST_unknown_type
    ON dbo.IRRICONTROL_PIVOT_HISTORY (event_type_raw)
    WHERE event_type IS NULL AND event_type_raw IS NOT NULL AND deleted_at IS NULL;
GO

/* =====================================================================
   VIEW: fila do ETL (sem alteracoes de logica vs v1)
   ===================================================================== */
IF OBJECT_ID('dbo.IRRICONTROL_PENDING_QUEUE') IS NOT NULL DROP VIEW dbo.IRRICONTROL_PENDING_QUEUE;
GO
CREATE VIEW dbo.IRRICONTROL_PENDING_QUEUE AS
SELECT pivot_name, 'OPERATION' AS source, COUNT(*) AS pending_rows, MIN(id) AS oldest_id
FROM dbo.IRRICONTROL_PIVOT_OPERATION
WHERE processed = 0 AND deleted_at IS NULL GROUP BY pivot_name
UNION ALL
SELECT pivot_name, 'SNAPSHOT', COUNT(*), MIN(id)
FROM dbo.IRRICONTROL_PIVOT_SNAPSHOT
WHERE processed = 0 AND deleted_at IS NULL GROUP BY pivot_name
UNION ALL
SELECT pivot_name, 'HISTORY', COUNT(*), MIN(id)
FROM dbo.IRRICONTROL_PIVOT_HISTORY
WHERE processed = 0 AND deleted_at IS NULL GROUP BY pivot_name;
GO

/* =====================================================================
   VIEW: execucoes travadas (suporte ao resume automatico [FIX-5])
   Retorna logs IN_PROGRESS abertos ha mais de 15 minutos e que ainda
   tem tentativas restantes. O scheduler faz:
     SELECT * FROM IRRICONTROL_STALE_INGESTIONS
     -> para cada linha: retomar pelo offset_loaded, incrementar attempt.
   ===================================================================== */
IF OBJECT_ID('dbo.IRRICONTROL_STALE_INGESTIONS') IS NOT NULL DROP VIEW dbo.IRRICONTROL_STALE_INGESTIONS;
GO
CREATE VIEW dbo.IRRICONTROL_STALE_INGESTIONS AS
SELECT
    id, pivot_name, source, reference_date,
    rows_loaded, offset_loaded,
    attempt, max_attempts,
    DATEDIFF(MINUTE, created_at, SYSUTCDATETIME()) AS minutes_open,
    created_at
FROM dbo.IRRICONTROL_INGESTION_LOG
WHERE status    = 'IN_PROGRESS'
  AND deleted_at IS NULL
  AND attempt   < max_attempts                                          -- ainda tem tentativas
  AND created_at < DATEADD(MINUTE, -15, SYSUTCDATETIME());             -- aberto ha mais de 15 min
GO

/* =====================================================================
   NOTAS GERAIS  (v2)
   -------------------------------------------------------------------
   RETRY AUTOMATICO (FIX-1 + FIX-5):
     1. UX agora filtra status='SUCCESS': ERROR/PARTIAL nao bloqueiam retry.
     2. O scheduler consulta IRRICONTROL_STALE_INGESTIONS a cada ciclo.
     3. Para retomar: UPDATE INGESTION_LOG SET attempt=attempt+1,
        status='IN_PROGRESS', resume_at=NULL WHERE id=@id; e prosseguir
        a partir do offset_loaded gravado.
     4. Se attempt >= max_attempts: fechar como ERROR definitivo.

   PIVOT_IRRI_ID (FIX-2):
     Extrair de pivot_information.id no JSON de current-state e propagar
     para as tres tabelas de dados. Se a API nao retornar o id em
     /operations ou /history, preencher via lookup no PIVOT_SNAPSHOT
     mais recente do mesmo pivot_name.

   EVENT_TYPE / DIRECTION (FIX-3, FIX-6):
     ETL grava event_type_raw e direction_raw sempre.
     event_type e current_direction so recebem valor se reconhecido:
       SET event_type = CASE WHEN event_type_raw IN ('action',...) THEN event_type_raw END
     Tipos novos ficam como NULL e aparecem em IX_IRRICONTROL_HIST_unknown_type.
     Alerta para a equipe quando event_type IS NULL AND event_type_raw IS NOT NULL.

   TTL / RETENCAO DO SNAPSHOT (FIX-7):
     Sugestao de politica: manter os ultimos 90 dias em producao.
     Job mensal: UPDATE ... SET deleted_at = SYSUTCDATETIME()
                 WHERE partition_month < FORMAT(DATEADD(MONTH,-3,GETDATE()),'yyyy-MM')
                   AND deleted_at IS NULL;
     partition_month PERSISTED habilita futuro particionamento sem recriar a tabela.

   LOCK DE SCHEDULER (SNAPSHOT race condition):
     Usar sp_getapplock (SQL Server) ou chave de lock externa (Redis/DB lock)
     por pivot_name antes de abrir o log de SNAPSHOT para evitar dois
     pollings simultâneos com timestamps proximos.
   ===================================================================== */

/* #####################################################################
   FIM DO SETUP v2 — IRRICONTROL camada raw (CONNECTOR_GCS_FARM)
   ##################################################################### */
GO


/* ─── 1.3 FARMBOX raw ───────────────────────────────────────────────── */
/* =========================================================================
   FARMBOX_connector_raw_mssql_v1.sql
   Camada RAW — conector Farmbox no banco CONNECTOR_GCS_FARM
   Versão  : 3.0
   Data    : 2026-06-26
   Alterações v3:
     - FARMBOX_MONITORING_NOTE: tabela para notas c/ imagens do monitoring_day_results
     - CONFIG_CONNECTORS pattern: documentado padrão plot_id → field_id (seção 10)
     - FARMBOX_PENDING_PROCESSING: adicionado FARMBOX_MONITORING_NOTE ao UNION ALL
   Alterações v2:
     - FARMBOX_PLANTATION: adicionado harvest_name VARCHAR(100) + índice
     - FARMBOX_PLUVIOMETER_MONITORING: lat/lng DECIMAL(9,6) → DECIMAL(12,9)
     - FARMBOX_COUNT_MONITORING: comentário lat/lng vêm como STRING na API
     - FARMBOX_TRAP_MONITORING: comentário fallback cursor modified_at → date
     - Cabeçalho: documentadas as 3 variantes de formato de data da API
     - Enums observados documentados (infestation_level, location_type, status)
   =========================================================================

   ARQUITETURA
   ───────────
   API Farmbox (30 endpoints) ──ETL──▶ CONNECTOR_GCS_FARM (FARMBOX_*)
                                              ──ETL──▶ GCS_FARM (master)

   AUTENTICAÇÃO
   ────────────
   Header  : Authorization: <token>   (token cru, sem prefixo Bearer/Token)
   Base URL: https://farmbox.cc/api/v1
   Segurança: token armazenado em dbo.CONFIG_API (AES-256, SK_CONFIG_API).
              Nunca em texto plano neste banco.

   CONVENÇÕES
   ──────────
   • farmbox_id    : id numérico do registro na API Farmbox (BIGINT/INT)
   • record        : JSON bruto completo do registro (NVARCHAR MAX, ISJSON=1)
   • ingestion_id  : FK → FARMBOX_INGESTION_LOG (rastreabilidade por lote)
   • processed     : fila ETL → GCS_FARM (0=pendente, 1=processado)
   • deleted_at    : soft-delete (NULL=ativo)
   • updated_at    : updated_at vindo da API (usado como cursor incremental)

   PAGINAÇÃO DA API
   ────────────────
   Envelope: {"<recurso>": [...], "pagination": {"total_entries": N,
              "total_pages": P, "per_page": 30, "current_page": C}}
   Filtro incremental: ?updated_since=<ISO8601>
   Referências (culturas, variedades etc.) → carga FULL semanal (sem updated_since)
   Dados transacionais → carga INCREMENTAL diária via updated_since

   FORMATOS DE DATA/HORA DA API (3 variantes — ETL deve normalizar)
   ──────────────────────────────────────────────────────────────────
   Variante A: "2019-09-19T10:54:53.000-03:00"  → ISO com offset de timezone
               Afeta: APPLICATION, INPUT, PLANTATION, PLOT, PLUVIOMETER_MONITORING
               ETL: converter para UTC com datetime.fromisoformat(val).astimezone(utc)
   Variante B: "2026-06-26 12:04:00"             → sem T, sem timezone
               Afeta: MONITORING (close_date, updated_at), MONITORING_DAY_RESULT
               ETL: substituir espaço por T (tratar como UTC-3 ou UTC — decisão negócio)
   Variante C: "2019-09-11"                       → apenas data, sem hora
               Afeta: HARVEST (start_date, end_date), MOVIMENTATION (date)
               DDL: colunas tipadas como DATE (não DATETIME2)

   OBJETOS CRIADOS (32)
   ────────────────────
   Controle  (2) : FARMBOX_INGESTION_LOG, FARMBOX_INTEGRATION_ERROR
   Referência(8) : FARMBOX_REF_CULTURE, _VARIETY, _PHENOLOGICAL_STAGE,
                   _USER, _EQUIPMENT, _ACTIVITY_TYPE, _BEAK, _INPUT_TYPE
   Estrutura (5) : FARMBOX_FARM, _PLOT, _HARVEST, _STORAGE, _PLUVIOMETER
   Plantation(1) : FARMBOX_PLANTATION
   Insumos   (4) : FARMBOX_INPUT, _INPUT_VALUE, _BATCH, _MOVIMENTATION
   Aplicações(2) : FARMBOX_APPLICATION, _APPLICATION_PROGRESS
   Monit.    (3) : FARMBOX_MONITORING, _MONITORING_DAY_RESULT,
                   _MONITORING_TOLERANCE
   Campo     (7) : FARMBOX_PLUVIOMETER_MONITORING, _PHENOLOGICAL_STAGE_SAMPLE,
                   _TRAP_MONITORING, _COUNT_DAY, _COUNT_MONITORING,
                   _NOTE, _RESOURCE_SUBSCRIPTION
   Views     (2) : FARMBOX_STALE_INGESTIONS, FARMBOX_PENDING_PROCESSING
   ========================================================================= */

/* =========================================================================
   SEÇÃO 1 — CONTROLE DE INGESTION
   ========================================================================= */

/* ─── 1.1 FARMBOX_INGESTION_LOG ─────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_INGESTION_LOG') IS NOT NULL
    DROP TABLE dbo.FARMBOX_INGESTION_LOG;
GO

CREATE TABLE dbo.FARMBOX_INGESTION_LOG (
    id               BIGINT        IDENTITY(1,1)
                                   CONSTRAINT PK_FARMBOX_INGESTION_LOG PRIMARY KEY,

    /* Identificação do job */
    endpoint         VARCHAR(60)   NOT NULL,   -- ex: 'monitorings', 'plantations'
    ingestion_type   VARCHAR(12)   NOT NULL,   -- 'FULL' | 'INCREMENTAL'
    updated_since    DATETIME2(3)  NULL,       -- cursor para INCREMENTAL (NULL = FULL)

    /* Progresso de paginação */
    page_loaded      INT           NOT NULL DEFAULT 0,   -- última página concluída
    total_pages      INT           NULL,                  -- descoberto após 1ª pág
    per_page         TINYINT       NOT NULL DEFAULT 30,   -- fixo na API

    /* Estado */
    status           VARCHAR(15)   NOT NULL DEFAULT 'IN_PROGRESS',
                     -- IN_PROGRESS | SUCCESS | ERROR | PARTIAL

    rows_loaded      INT           NOT NULL DEFAULT 0,
    attempt          TINYINT       NOT NULL DEFAULT 1,
    max_attempts     TINYINT       NOT NULL DEFAULT 3,
    error_message    NVARCHAR(2000) NULL,
    resume_at        DATETIME2(3)  NULL,       -- retry após falha transitória

    /* Temporização */
    started_at       DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    finished_at      DATETIME2(3)  NULL,

    /* Auditoria */
    created_at       DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at       DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at       DATETIME2(3)  NULL,

    CONSTRAINT CK_FARMBOX_ING_type   CHECK (ingestion_type IN ('FULL','INCREMENTAL')),
    CONSTRAINT CK_FARMBOX_ING_status CHECK (status IN
        ('IN_PROGRESS','SUCCESS','ERROR','PARTIAL'))
);
GO

/* Monitorar jobs travados (IN_PROGRESS > 30 min) */
CREATE INDEX IX_FARMBOX_ING_stale
    ON dbo.FARMBOX_INGESTION_LOG (status, started_at)
    INCLUDE (endpoint, page_loaded, total_pages, attempt)
    WHERE status = 'IN_PROGRESS' AND deleted_at IS NULL;
GO

/* Histórico por endpoint para cursor incremental */
CREATE INDEX IX_FARMBOX_ING_endpoint
    ON dbo.FARMBOX_INGESTION_LOG (endpoint, status, finished_at DESC)
    INCLUDE (updated_since, rows_loaded)
    WHERE deleted_at IS NULL;
GO


/* ─── 1.2 FARMBOX_INTEGRATION_ERROR ────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_INTEGRATION_ERROR') IS NOT NULL
    DROP TABLE dbo.FARMBOX_INTEGRATION_ERROR;
GO

CREATE TABLE dbo.FARMBOX_INTEGRATION_ERROR (
    id               BIGINT        IDENTITY(1,1)
                                   CONSTRAINT PK_FARMBOX_INTEGRATION_ERROR PRIMARY KEY,
    ingestion_id     BIGINT        NULL,
    endpoint         VARCHAR(60)   NULL,
    farmbox_id       BIGINT        NULL,        -- id do registro com problema (se conhecido)
    page             INT           NULL,
    error_type       VARCHAR(50)   NULL,        -- ex: 'PARSE_ERROR', 'DUPLICATE_KEY'
    error_message    NVARCHAR(2000) NULL,
    raw_payload      NVARCHAR(MAX) NULL,        -- payload que causou o erro
    created_at       DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),

    CONSTRAINT FK_FARMBOX_ERR_ing FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO

CREATE INDEX IX_FARMBOX_ERR_ing
    ON dbo.FARMBOX_INTEGRATION_ERROR (ingestion_id);
GO


/* =========================================================================
   SEÇÃO 2 — TABELAS DE REFERÊNCIA (carga FULL semanal)
   Dados de cadastro estáveis: culturas, variedades, estágios fenológicos,
   usuários, equipamentos, tipos de atividade, bicos, tipos de insumo.
   Padrão: farmbox_id + name + record + audit. Sem processed/queue.
   ========================================================================= */

/* ─── 2.1 FARMBOX_REF_CULTURE ──────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_REF_CULTURE') IS NOT NULL DROP TABLE dbo.FARMBOX_REF_CULTURE;
GO
CREATE TABLE dbo.FARMBOX_REF_CULTURE (
    id           BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_REF_CULTURE PRIMARY KEY,
    farmbox_id   INT           NOT NULL,           -- cultures.id
    ingestion_id BIGINT        NOT NULL,
    name         NVARCHAR(200) NOT NULL,
    record       NVARCHAR(MAX) NOT NULL,
    created_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at   DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_REF_CULTURE_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_REF_CULTURE_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_REF_CULTURE_id
    ON dbo.FARMBOX_REF_CULTURE (farmbox_id) WHERE deleted_at IS NULL;
GO


/* ─── 2.2 FARMBOX_REF_VARIETY ──────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_REF_VARIETY') IS NOT NULL DROP TABLE dbo.FARMBOX_REF_VARIETY;
GO
CREATE TABLE dbo.FARMBOX_REF_VARIETY (
    id           BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_REF_VARIETY PRIMARY KEY,
    farmbox_id   INT           NOT NULL,           -- varieties.id
    ingestion_id BIGINT        NOT NULL,
    name         NVARCHAR(200) NOT NULL,
    culture_id   INT           NULL,               -- FK lógico → FARMBOX_REF_CULTURE
    record       NVARCHAR(MAX) NOT NULL,
    created_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at   DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_REF_VARIETY_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_REF_VARIETY_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_REF_VARIETY_id
    ON dbo.FARMBOX_REF_VARIETY (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_REF_VARIETY_culture
    ON dbo.FARMBOX_REF_VARIETY (culture_id) WHERE deleted_at IS NULL;
GO


/* ─── 2.3 FARMBOX_REF_PHENOLOGICAL_STAGE ───────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_REF_PHENOLOGICAL_STAGE') IS NOT NULL
    DROP TABLE dbo.FARMBOX_REF_PHENOLOGICAL_STAGE;
GO
CREATE TABLE dbo.FARMBOX_REF_PHENOLOGICAL_STAGE (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_REF_PHENO PRIMARY KEY,
    farmbox_id      INT           NOT NULL,
    ingestion_id    BIGINT        NOT NULL,
    name            NVARCHAR(100) NOT NULL,        -- ex: 'VC', 'R1', 'C6'
    culture_id      INT           NULL,
    classification  INT           NULL,            -- 1=Vegetativo 2=Reprodutivo
    position        INT           NULL,
    record          NVARCHAR(MAX) NOT NULL,
    created_at      DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_REF_PHENO_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_REF_PHENO_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_REF_PHENO_id
    ON dbo.FARMBOX_REF_PHENOLOGICAL_STAGE (farmbox_id) WHERE deleted_at IS NULL;
GO


/* ─── 2.4 FARMBOX_REF_USER ─────────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_REF_USER') IS NOT NULL DROP TABLE dbo.FARMBOX_REF_USER;
GO
CREATE TABLE dbo.FARMBOX_REF_USER (
    id           BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_REF_USER PRIMARY KEY,
    farmbox_id   INT           NOT NULL,
    ingestion_id BIGINT        NOT NULL,
    name         NVARCHAR(200) NOT NULL,
    username     VARCHAR(100)  NULL,
    email        VARCHAR(200)  NULL,
    uuid         VARCHAR(40)   NULL,
    role_label   NVARCHAR(100) NULL,
    record       NVARCHAR(MAX) NOT NULL,
    created_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at   DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_REF_USER_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_REF_USER_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_REF_USER_id
    ON dbo.FARMBOX_REF_USER (farmbox_id) WHERE deleted_at IS NULL;
GO


/* ─── 2.5 FARMBOX_REF_EQUIPMENT ────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_REF_EQUIPMENT') IS NOT NULL DROP TABLE dbo.FARMBOX_REF_EQUIPMENT;
GO
CREATE TABLE dbo.FARMBOX_REF_EQUIPMENT (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_REF_EQUIPMENT PRIMARY KEY,
    farmbox_id      INT           NOT NULL,
    ingestion_id    BIGINT        NOT NULL,
    name            NVARCHAR(200) NOT NULL,
    equipment_type  VARCHAR(50)   NULL,            -- ex: 'land', 'aerial'
    operation_type  VARCHAR(50)   NULL,
    tank_volume     DECIMAL(10,2) NULL,
    record          NVARCHAR(MAX) NOT NULL,
    created_at      DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_REF_EQUIP_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_REF_EQUIP_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_REF_EQUIP_id
    ON dbo.FARMBOX_REF_EQUIPMENT (farmbox_id) WHERE deleted_at IS NULL;
GO


/* ─── 2.6 FARMBOX_REF_ACTIVITY_TYPE ────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_REF_ACTIVITY_TYPE') IS NOT NULL
    DROP TABLE dbo.FARMBOX_REF_ACTIVITY_TYPE;
GO
CREATE TABLE dbo.FARMBOX_REF_ACTIVITY_TYPE (
    id           BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_REF_ACTTYPE PRIMARY KEY,
    farmbox_id   INT           NOT NULL,
    ingestion_id BIGINT        NOT NULL,
    name         NVARCHAR(200) NOT NULL,
    no_culture   BIT           NULL,
    all_cultures BIT           NULL,
    inactive     BIT           NULL,
    record       NVARCHAR(MAX) NOT NULL,
    created_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at   DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_REF_ACTTYPE_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_REF_ACTTYPE_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_REF_ACTTYPE_id
    ON dbo.FARMBOX_REF_ACTIVITY_TYPE (farmbox_id) WHERE deleted_at IS NULL;
GO


/* ─── 2.7 FARMBOX_REF_BEAK ─────────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_REF_BEAK') IS NOT NULL DROP TABLE dbo.FARMBOX_REF_BEAK;
GO
CREATE TABLE dbo.FARMBOX_REF_BEAK (
    id           BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_REF_BEAK PRIMARY KEY,
    farmbox_id   INT           NOT NULL,
    ingestion_id BIGINT        NOT NULL,
    name         NVARCHAR(200) NOT NULL,           -- ex: 'TXA 8003 CONE'
    record       NVARCHAR(MAX) NOT NULL,
    created_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at   DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_REF_BEAK_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_REF_BEAK_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_REF_BEAK_id
    ON dbo.FARMBOX_REF_BEAK (farmbox_id) WHERE deleted_at IS NULL;
GO


/* ─── 2.8 FARMBOX_REF_INPUT_TYPE ───────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_REF_INPUT_TYPE') IS NOT NULL DROP TABLE dbo.FARMBOX_REF_INPUT_TYPE;
GO
CREATE TABLE dbo.FARMBOX_REF_INPUT_TYPE (
    id            BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_REF_INTYPE PRIMARY KEY,
    farmbox_id    INT           NOT NULL,
    ingestion_id  BIGINT        NOT NULL,
    name          NVARCHAR(200) NOT NULL,           -- ex: 'Inseticida', 'Fungicida'
    grace_period  INT           NULL,               -- período de carência (dias)
    record        NVARCHAR(MAX) NOT NULL,
    created_at    DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at    DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_REF_INTYPE_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_REF_INTYPE_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_REF_INTYPE_id
    ON dbo.FARMBOX_REF_INPUT_TYPE (farmbox_id) WHERE deleted_at IS NULL;
GO


/* =========================================================================
   SEÇÃO 3 — ESTRUTURA DA FAZENDA (carga INCREMENTAL por updated_at)
   ========================================================================= */

/* ─── 3.1 FARMBOX_FARM ──────────────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_FARM') IS NOT NULL DROP TABLE dbo.FARMBOX_FARM;
GO
CREATE TABLE dbo.FARMBOX_FARM (
    id           BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_FARM PRIMARY KEY,
    farmbox_id   BIGINT        NOT NULL,           -- farms.id
    ingestion_id BIGINT        NOT NULL,
    name         NVARCHAR(200) NOT NULL,
    storage_id   BIGINT        NULL,               -- FK lógico → FARMBOX_STORAGE
    city         NVARCHAR(200) NULL,
    record       NVARCHAR(MAX) NOT NULL,
    processed    BIT           NOT NULL DEFAULT 0,
    processed_at DATETIME2(3)  NULL,
    created_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at   DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_FARM_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_FARM_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_FARM_id
    ON dbo.FARMBOX_FARM (farmbox_id) WHERE deleted_at IS NULL;
GO


/* ─── 3.2 FARMBOX_PLOT ──────────────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_PLOT') IS NOT NULL DROP TABLE dbo.FARMBOX_PLOT;
GO
CREATE TABLE dbo.FARMBOX_PLOT (
    id           BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_PLOT PRIMARY KEY,
    farmbox_id   BIGINT        NOT NULL,           -- plots.id
    ingestion_id BIGINT        NOT NULL,
    name         NVARCHAR(200) NOT NULL,
    farm_id      BIGINT        NULL,               -- plots.farm_id
    area         DECIMAL(12,4) NULL,               -- hectares
    api_updated_at DATETIME2(3) NULL,              -- updated_at da API
    disabled_at  DATETIME2(3)  NULL,               -- talhão desativado
    record       NVARCHAR(MAX) NOT NULL,            -- inclui geo_points[]
    processed    BIT           NOT NULL DEFAULT 0,
    processed_at DATETIME2(3)  NULL,
    created_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at   DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_PLOT_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_PLOT_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_PLOT_id
    ON dbo.FARMBOX_PLOT (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_PLOT_farm
    ON dbo.FARMBOX_PLOT (farm_id) WHERE deleted_at IS NULL;
GO


/* ─── 3.3 FARMBOX_HARVEST ──────────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_HARVEST') IS NOT NULL DROP TABLE dbo.FARMBOX_HARVEST;
GO
CREATE TABLE dbo.FARMBOX_HARVEST (
    id             BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_HARVEST PRIMARY KEY,
    farmbox_id     BIGINT        NOT NULL,
    ingestion_id   BIGINT        NOT NULL,
    name           NVARCHAR(100) NOT NULL,          -- ex: '2025/2026'
    start_date     DATE          NULL,
    end_date       DATE          NULL,
    rain_start_date DATE         NULL,
    rain_end_date  DATE          NULL,
    record         NVARCHAR(MAX) NOT NULL,
    processed      BIT           NOT NULL DEFAULT 0,
    processed_at   DATETIME2(3)  NULL,
    created_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at     DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_HARVEST_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_HARVEST_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_HARVEST_id
    ON dbo.FARMBOX_HARVEST (farmbox_id) WHERE deleted_at IS NULL;
GO


/* ─── 3.4 FARMBOX_STORAGE ──────────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_STORAGE') IS NOT NULL DROP TABLE dbo.FARMBOX_STORAGE;
GO
CREATE TABLE dbo.FARMBOX_STORAGE (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_STORAGE PRIMARY KEY,
    farmbox_id      BIGINT        NOT NULL,
    ingestion_id    BIGINT        NOT NULL,
    name            NVARCHAR(200) NOT NULL,
    storage_type    VARCHAR(50)   NULL,
    farm_id         BIGINT        NULL,
    default_storage BIT           NULL,
    api_updated_at  DATETIME2(3)  NULL,
    api_disabled_at DATETIME2(3)  NULL,
    record          NVARCHAR(MAX) NOT NULL,
    processed       BIT           NOT NULL DEFAULT 0,
    processed_at    DATETIME2(3)  NULL,
    created_at      DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_STORAGE_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_STORAGE_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_STORAGE_id
    ON dbo.FARMBOX_STORAGE (farmbox_id) WHERE deleted_at IS NULL;
GO


/* ─── 3.5 FARMBOX_PLUVIOMETER ──────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_PLUVIOMETER') IS NOT NULL DROP TABLE dbo.FARMBOX_PLUVIOMETER;
GO
CREATE TABLE dbo.FARMBOX_PLUVIOMETER (
    id             BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_PLUVIOMETER PRIMARY KEY,
    farmbox_id     BIGINT        NOT NULL,
    ingestion_id   BIGINT        NOT NULL,
    name           NVARCHAR(200) NOT NULL,
    farm_id        BIGINT        NULL,
    latitude       DECIMAL(9,6)  NULL,
    longitude      DECIMAL(9,6)  NULL,
    start_date     DATE          NULL,
    api_updated_at DATETIME2(3)  NULL,
    record         NVARCHAR(MAX) NOT NULL,
    processed      BIT           NOT NULL DEFAULT 0,
    processed_at   DATETIME2(3)  NULL,
    created_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at     DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_PLUVIO_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_PLUVIO_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_PLUVIOMETER_id
    ON dbo.FARMBOX_PLUVIOMETER (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_PLUVIOMETER_farm
    ON dbo.FARMBOX_PLUVIOMETER (farm_id) WHERE deleted_at IS NULL;
GO


/* =========================================================================
   SEÇÃO 4 — PLANTATION (core do negócio)
   Objeto mais rico da API: carrega farm + plot (com geo_points) + harvest
   embutidos no JSON. Campos extraídos para filtros e joins no ETL.
   ========================================================================= */

IF OBJECT_ID('dbo.FARMBOX_PLANTATION') IS NOT NULL DROP TABLE dbo.FARMBOX_PLANTATION;
GO
CREATE TABLE dbo.FARMBOX_PLANTATION (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_PLANTATION PRIMARY KEY,
    farmbox_id      BIGINT        NOT NULL,           -- plantations.id
    ingestion_id    BIGINT        NOT NULL,

    /* Chaves para joins no ETL */
    farm_id         BIGINT        NULL,               -- plantation.farm.id
    plot_id         BIGINT        NULL,               -- plantation.plot.id
    harvest_id      BIGINT        NULL,               -- plantation.harvest.id (via harvest_name → join em GCS_FARM)
    harvest_name    VARCHAR(100)  NULL,               -- plantation.harvest_name (ex: "2019/20-1") — API não retorna harvest_id diretamente
    culture_id      INT           NULL,               -- plantation.culture_id
    variety_id      INT           NULL,               -- plantation.variety_id

    /* Campos operacionais extraídos */
    state           VARCHAR(20)   NULL,               -- 'active' | 'closed'
    plantation_date DATE          NULL,               -- plantation.date (semeadura)
    emergence_date  DATE          NULL,
    activation_date DATE          NULL,
    harvest_prediction_date DATE  NULL,
    closed_date     DATE          NULL,
    area            DECIMAL(12,4) NULL,               -- ha
    irrigated       BIT           NULL,
    productivity    DECIMAL(12,4) NULL,               -- rendimento final
    cycle           TINYINT       NULL,               -- 1=1ª safra, 2=2ª safra
    api_updated_at  DATETIME2(3)  NULL,               -- cursor incremental

    /* Fila ETL → GCS_FARM */
    processed       BIT           NOT NULL DEFAULT 0,
    processed_at    DATETIME2(3)  NULL,

    /* JSON completo (inclui farm, plot, harvest, geo_points) */
    record          NVARCHAR(MAX) NOT NULL,

    /* Auditoria */
    created_at      DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3)  NULL,

    CONSTRAINT CK_FARMBOX_PLANT_json  CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_PLANT_ing   FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO

CREATE UNIQUE INDEX UX_FARMBOX_PLANTATION_id
    ON dbo.FARMBOX_PLANTATION (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_PLANT_farm
    ON dbo.FARMBOX_PLANTATION (farm_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_PLANT_harvest
    ON dbo.FARMBOX_PLANTATION (harvest_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_PLANT_state
    ON dbo.FARMBOX_PLANTATION (state, api_updated_at DESC)
    INCLUDE (farmbox_id, farm_id, culture_id)
    WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_PLANT_pending
    ON dbo.FARMBOX_PLANTATION (processed, api_updated_at)
    WHERE processed = 0 AND deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_PLANT_harvest_name
    ON dbo.FARMBOX_PLANTATION (harvest_name)
    WHERE deleted_at IS NULL;
GO


/* =========================================================================
   SEÇÃO 5 — INSUMOS E ESTOQUE
   ========================================================================= */

/* ─── 5.1 FARMBOX_INPUT ─────────────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_INPUT') IS NOT NULL DROP TABLE dbo.FARMBOX_INPUT;
GO
CREATE TABLE dbo.FARMBOX_INPUT (
    id                   BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_INPUT PRIMARY KEY,
    farmbox_id           BIGINT        NOT NULL,
    ingestion_id         BIGINT        NOT NULL,
    name                 NVARCHAR(200) NOT NULL,
    input_type_id        INT           NULL,
    formulation          VARCHAR(50)   NULL,          -- 'liquid' | 'solid' | ...
    dosage_unit          VARCHAR(30)   NULL,          -- ex: 'l_ha', 'kg_ha'
    api_updated_at       DATETIME2(3)  NULL,
    record               NVARCHAR(MAX) NOT NULL,       -- inclui input_classification{}
    processed            BIT           NOT NULL DEFAULT 0,
    processed_at         DATETIME2(3)  NULL,
    created_at           DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at           DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at           DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_INPUT_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_INPUT_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_INPUT_id
    ON dbo.FARMBOX_INPUT (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_INPUT_type
    ON dbo.FARMBOX_INPUT (input_type_id) WHERE deleted_at IS NULL;
GO


/* ─── 5.2 FARMBOX_INPUT_VALUE ──────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_INPUT_VALUE') IS NOT NULL DROP TABLE dbo.FARMBOX_INPUT_VALUE;
GO
CREATE TABLE dbo.FARMBOX_INPUT_VALUE (
    id             BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_INPUT_VALUE PRIMARY KEY,
    farmbox_id     BIGINT        NOT NULL,
    ingestion_id   BIGINT        NOT NULL,
    input_id       BIGINT        NULL,
    farm_id        BIGINT        NULL,
    harvest_id     BIGINT        NULL,
    value          DECIMAL(14,4) NULL,               -- custo unitário
    api_updated_at DATETIME2(3)  NULL,
    record         NVARCHAR(MAX) NOT NULL,
    processed      BIT           NOT NULL DEFAULT 0,
    processed_at   DATETIME2(3)  NULL,
    created_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at     DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_INVAL_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_INVAL_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_INVAL_id
    ON dbo.FARMBOX_INPUT_VALUE (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_INVAL_inp_farm_harv
    ON dbo.FARMBOX_INPUT_VALUE (input_id, farm_id, harvest_id) WHERE deleted_at IS NULL;
GO


/* ─── 5.3 FARMBOX_BATCH ─────────────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_BATCH') IS NOT NULL DROP TABLE dbo.FARMBOX_BATCH;
GO
CREATE TABLE dbo.FARMBOX_BATCH (
    id             BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_BATCH PRIMARY KEY,
    farmbox_id     BIGINT        NOT NULL,
    ingestion_id   BIGINT        NOT NULL,
    input_id       BIGINT        NULL,
    batch_number   NVARCHAR(100) NULL,
    validity       DATE          NULL,
    record         NVARCHAR(MAX) NOT NULL,
    processed      BIT           NOT NULL DEFAULT 0,
    processed_at   DATETIME2(3)  NULL,
    created_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at     DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_BATCH_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_BATCH_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_BATCH_id
    ON dbo.FARMBOX_BATCH (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_BATCH_input
    ON dbo.FARMBOX_BATCH (input_id) WHERE deleted_at IS NULL;
GO


/* ─── 5.4 FARMBOX_MOVIMENTATION ─────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_MOVIMENTATION') IS NOT NULL DROP TABLE dbo.FARMBOX_MOVIMENTATION;
GO
CREATE TABLE dbo.FARMBOX_MOVIMENTATION (
    id                  BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_MOVIMENTATION PRIMARY KEY,
    farmbox_id          BIGINT        NOT NULL,
    ingestion_id        BIGINT        NOT NULL,
    input_id            BIGINT        NULL,
    storage_id          BIGINT        NULL,
    user_id             BIGINT        NULL,
    movimentation_date  DATE          NULL,
    movimentation_type  VARCHAR(10)   NULL,           -- 'in' | 'out'
    quantity            DECIMAL(14,4) NULL,
    unit                VARCHAR(20)   NULL,
    /* batch_info e application_info ficam no record */
    record              NVARCHAR(MAX) NOT NULL,
    processed           BIT           NOT NULL DEFAULT 0,
    processed_at        DATETIME2(3)  NULL,
    created_at          DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at          DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at          DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_MOVIM_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_MOVIM_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_MOVIM_id
    ON dbo.FARMBOX_MOVIMENTATION (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MOVIM_input_date
    ON dbo.FARMBOX_MOVIMENTATION (input_id, movimentation_date DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MOVIM_storage
    ON dbo.FARMBOX_MOVIMENTATION (storage_id, movimentation_type)
    WHERE deleted_at IS NULL;
GO


/* =========================================================================
   SEÇÃO 6 — OPERAÇÕES DE CAMPO (14 k+ registros — INCREMENTAL diário)
   ========================================================================= */

/* ─── 6.1 FARMBOX_APPLICATION ───────────────────────────────────────────── */
/*
   Objeto mais complexo da API. O record inclui:
     equipments[]   → equipment{}, beak{}, pressure, area
     plantations[]  → plantation{}, sought_area, applied_area
     inputs[]       → input{}, dosage, quantity
     progresses[]   → array de application_progresses
     input_movimentations[]
   O ETL extrai essas sub-listas para popular tabelas master em GCS_FARM.

   Enums observados em dados reais:
     app_status:     'finalized' (confirmar lista completa antes de adicionar CHECK)
     operation_type: 'pulverization' (confirmar lista completa antes de adicionar CHECK)
   ATENÇÃO: created_at e updated_at chegam no formato Variante A com offset de timezone.
            ETL deve normalizar para UTC antes do INSERT em api_created_at / api_updated_at.
*/
IF OBJECT_ID('dbo.FARMBOX_APPLICATION') IS NOT NULL DROP TABLE dbo.FARMBOX_APPLICATION;
GO
CREATE TABLE dbo.FARMBOX_APPLICATION (
    id               BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_APPLICATION PRIMARY KEY,
    farmbox_id       BIGINT        NOT NULL,           -- applications.id
    ingestion_id     BIGINT        NOT NULL,
    code             VARCHAR(20)   NULL,               -- ex: 'AP18'
    application_date DATE          NULL,
    end_date         DATE          NULL,
    app_status       VARCHAR(30)   NULL,               -- 'finalized' | 'open' | ...
    operation_type   VARCHAR(50)   NULL,               -- 'pulverization' | ...
    api_created_at   DATETIME2(3)  NULL,
    api_updated_at   DATETIME2(3)  NULL,               -- cursor incremental
    record           NVARCHAR(MAX) NOT NULL,
    processed        BIT           NOT NULL DEFAULT 0,
    processed_at     DATETIME2(3)  NULL,
    created_at       DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at       DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at       DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_APP_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_APP_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_APP_id
    ON dbo.FARMBOX_APPLICATION (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_APP_date
    ON dbo.FARMBOX_APPLICATION (application_date DESC, app_status)
    INCLUDE (farmbox_id, operation_type)
    WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_APP_updated
    ON dbo.FARMBOX_APPLICATION (api_updated_at DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_APP_pending
    ON dbo.FARMBOX_APPLICATION (processed, api_updated_at)
    WHERE processed = 0 AND deleted_at IS NULL;
GO


/* ─── 6.2 FARMBOX_APPLICATION_PROGRESS ─────────────────────────────────── */
/*
   Populado pelo ETL ao processar FARMBOX_APPLICATION (extraído do array
   progresses[] dentro do record da aplicação). Também disponível via
   GET /applications/:id/application_progresses.
   Campos agronômicos: condições climáticas no momento da operação.
*/
IF OBJECT_ID('dbo.FARMBOX_APPLICATION_PROGRESS') IS NOT NULL
    DROP TABLE dbo.FARMBOX_APPLICATION_PROGRESS;
GO
CREATE TABLE dbo.FARMBOX_APPLICATION_PROGRESS (
    id               BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_APP_PROG PRIMARY KEY,
    farmbox_id       BIGINT        NOT NULL,           -- application_progress.id
    ingestion_id     BIGINT        NOT NULL,
    application_id   BIGINT        NOT NULL,           -- FK lógico → FARMBOX_APPLICATION.farmbox_id
    progress_date    DATETIME2(3)  NULL,
    area             DECIMAL(12,4) NULL,               -- ha executados neste progresso
    wind_speed       DECIMAL(8,2)  NULL,
    humidity         DECIMAL(5,2)  NULL,
    temperature      DECIMAL(5,2)  NULL,
    wind_direction   VARCHAR(20)   NULL,
    pressure         DECIMAL(8,3)  NULL,
    solution         DECIMAL(8,3)  NULL,
    velocity         DECIMAL(8,3)  NULL,
    api_updated_at   DATETIME2(3)  NULL,
    record           NVARCHAR(MAX) NOT NULL,
    processed        BIT           NOT NULL DEFAULT 0,
    processed_at     DATETIME2(3)  NULL,
    created_at       DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at       DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at       DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_APP_PROG_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_APP_PROG_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_APP_PROG_id
    ON dbo.FARMBOX_APPLICATION_PROGRESS (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_APP_PROG_app
    ON dbo.FARMBOX_APPLICATION_PROGRESS (application_id, progress_date DESC)
    WHERE deleted_at IS NULL;
GO


/* =========================================================================
   SEÇÃO 7 — MONITORAMENTO FITOSSANITÁRIO (14 k+ registros)
   ========================================================================= */

/* ─── 7.1 FARMBOX_MONITORING ────────────────────────────────────────────── */
/*
   Objeto mais profundo da API. O record inclui:
     plantation{}   → objeto plantation completo (farm, plot, geo_points)
     monitors[]     → usuários que fizeram o monitoramento
     monitoring_stops[]  → pontos de amostragem, cada um com:
         monitoring_stop_results[] → por alvo: quantity, infestation,
                                     infestation_level, target_parameter
     monitoring_results[]  → consolidado por alvo (média dos stops)

   ATENÇÃO: campos close_date e updated_at ainda emitem formato sem T/Z
   em todos os registros ("2026-06-26 12:04:00" — Variante B). O ETL normaliza
   para ISO 8601 antes de persistir em api_updated_at e close_date.

   Enums observados em dados reais:
     mon_state: 'open' | 'closed'
     infestation_level (em monitoring_stop_results[]): 'infested' | 'damaged' | 'clear'
*/
IF OBJECT_ID('dbo.FARMBOX_MONITORING') IS NOT NULL DROP TABLE dbo.FARMBOX_MONITORING;
GO
CREATE TABLE dbo.FARMBOX_MONITORING (
    id               BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_MONITORING PRIMARY KEY,
    farmbox_id       BIGINT        NOT NULL,           -- monitorings.id
    ingestion_id     BIGINT        NOT NULL,
    plantation_id    BIGINT        NULL,               -- monitorings.plantation.id
    farm_id          BIGINT        NULL,               -- monitorings.plantation.farm.id
    monitoring_date  DATE          NULL,               -- monitorings.date
    close_date       DATETIME2(3)  NULL,               -- normalizado pelo ETL
    mon_state        VARCHAR(20)   NULL,               -- 'open' | 'closed'
    methodology      VARCHAR(30)   NULL,               -- 'route' | ...
    samples          INT           NULL,               -- nº pontos de amostragem
    api_updated_at   DATETIME2(3)  NULL,               -- normalizado pelo ETL (cursor)
    record           NVARCHAR(MAX) NOT NULL,
    processed        BIT           NOT NULL DEFAULT 0,
    processed_at     DATETIME2(3)  NULL,
    created_at       DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at       DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at       DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_MON_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_MON_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_MONITORING_id
    ON dbo.FARMBOX_MONITORING (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MON_plantation
    ON dbo.FARMBOX_MONITORING (plantation_id, monitoring_date DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MON_farm_date
    ON dbo.FARMBOX_MONITORING (farm_id, monitoring_date DESC)
    INCLUDE (mon_state, methodology)
    WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MON_updated
    ON dbo.FARMBOX_MONITORING (api_updated_at DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MON_pending
    ON dbo.FARMBOX_MONITORING (processed, api_updated_at)
    WHERE processed = 0 AND deleted_at IS NULL;
GO


/* ─── 7.2 FARMBOX_MONITORING_DAY_RESULT ────────────────────────────────── */
/*
   ATENÇÃO: o id da API é uma STRING COMPOSTA "timestamp-plantation_id"
   ex: "1782442800-358334". Não é BIGINT.
   record_id é a chave natural (VARCHAR 60).
   O record inclui: count_targets, targets[], monitoring_stops[], notes[]
*/
IF OBJECT_ID('dbo.FARMBOX_MONITORING_DAY_RESULT') IS NOT NULL
    DROP TABLE dbo.FARMBOX_MONITORING_DAY_RESULT;
GO
CREATE TABLE dbo.FARMBOX_MONITORING_DAY_RESULT (
    id             BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_MDR PRIMARY KEY,
    record_id      VARCHAR(60)   NOT NULL,             -- "timestamp-plantation_id"
    ingestion_id   BIGINT        NOT NULL,
    plantation_id  BIGINT        NULL,                 -- extraído do record_id
    result_date    DATE          NULL,                 -- monitoring_day_results.date
    api_updated_at DATETIME2(3)  NULL,                 -- normalizado pelo ETL
    record         NVARCHAR(MAX) NOT NULL,
    processed      BIT           NOT NULL DEFAULT 0,
    processed_at   DATETIME2(3)  NULL,
    created_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at     DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_MDR_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_MDR_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_MDR_record_id
    ON dbo.FARMBOX_MONITORING_DAY_RESULT (record_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MDR_plantation
    ON dbo.FARMBOX_MONITORING_DAY_RESULT (plantation_id, result_date DESC)
    WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MDR_updated
    ON dbo.FARMBOX_MONITORING_DAY_RESULT (api_updated_at DESC)
    WHERE deleted_at IS NULL;
GO


/* ─── 7.3 FARMBOX_MONITORING_TOLERANCE ─────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_MONITORING_TOLERANCE') IS NOT NULL
    DROP TABLE dbo.FARMBOX_MONITORING_TOLERANCE;
GO
CREATE TABLE dbo.FARMBOX_MONITORING_TOLERANCE (
    id             BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_MON_TOL PRIMARY KEY,
    farmbox_id     BIGINT        NOT NULL,
    ingestion_id   BIGINT        NOT NULL,
    farm_id        BIGINT        NULL,
    culture_id     INT           NULL,
    variety_id     INT           NULL,
    days           INT           NULL,                 -- período de tolerância (dias)
    api_created_at DATETIME2(3)  NULL,
    api_updated_at DATETIME2(3)  NULL,
    record         NVARCHAR(MAX) NOT NULL,
    processed      BIT           NOT NULL DEFAULT 0,
    processed_at   DATETIME2(3)  NULL,
    created_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at     DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_MON_TOL_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_MON_TOL_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_MON_TOL_id
    ON dbo.FARMBOX_MONITORING_TOLERANCE (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MON_TOL_farm
    ON dbo.FARMBOX_MONITORING_TOLERANCE (farm_id, culture_id, variety_id)
    WHERE deleted_at IS NULL;
GO


/* =========================================================================
   SEÇÃO 8 — DADOS DE CAMPO
   ========================================================================= */

/* ─── 8.1 FARMBOX_PLUVIOMETER_MONITORING ───────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_PLUVIOMETER_MONITORING') IS NOT NULL
    DROP TABLE dbo.FARMBOX_PLUVIOMETER_MONITORING;
GO
CREATE TABLE dbo.FARMBOX_PLUVIOMETER_MONITORING (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_PLUVIO_MON PRIMARY KEY,
    farmbox_id      BIGINT        NOT NULL,
    ingestion_id    BIGINT        NOT NULL,
    pluviometer_id  BIGINT        NULL,               -- pluviometer.id no record
    farm_id         BIGINT        NULL,               -- pluviometer.farm_id
    reading_date    DATETIME2(3)  NULL,               -- Variante A: ISO com offset → normalizar para UTC
    quantity_mm     DECIMAL(8,2)  NULL,               -- precipitação em mm
    latitude        DECIMAL(12,9) NULL,               -- API retorna STRING e precisão > 9 casas (ex: -14.361991116825624)
    longitude       DECIMAL(12,9) NULL,               -- ETL: float(record["latitude"]) antes do INSERT
    api_updated_at  DATETIME2(3)  NULL,
    record          NVARCHAR(MAX) NOT NULL,
    processed       BIT           NOT NULL DEFAULT 0,
    processed_at    DATETIME2(3)  NULL,
    created_at      DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_PLUVIO_MON_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_PLUVIO_MON_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_PLUVIO_MON_id
    ON dbo.FARMBOX_PLUVIOMETER_MONITORING (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_PLUVIO_MON_date
    ON dbo.FARMBOX_PLUVIOMETER_MONITORING (pluviometer_id, reading_date DESC)
    WHERE deleted_at IS NULL;
GO


/* ─── 8.2 FARMBOX_PHENOLOGICAL_STAGE_SAMPLE ────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_PHENOLOGICAL_STAGE_SAMPLE') IS NOT NULL
    DROP TABLE dbo.FARMBOX_PHENOLOGICAL_STAGE_SAMPLE;
GO
CREATE TABLE dbo.FARMBOX_PHENOLOGICAL_STAGE_SAMPLE (
    id               BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_PHENO_SAMP PRIMARY KEY,
    farmbox_id       BIGINT        NOT NULL,
    ingestion_id     BIGINT        NOT NULL,
    plantation_id    BIGINT        NULL,
    sample_date      DATETIME2(3)  NULL,
    latitude         DECIMAL(9,6)  NULL,
    longitude        DECIMAL(9,6)  NULL,
    api_updated_at   DATETIME2(3)  NULL,
    record           NVARCHAR(MAX) NOT NULL,  -- inclui phenological_stage + plantation completo
    processed        BIT           NOT NULL DEFAULT 0,
    processed_at     DATETIME2(3)  NULL,
    created_at       DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at       DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at       DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_PHENO_SAMP_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_PHENO_SAMP_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_PHENO_SAMP_id
    ON dbo.FARMBOX_PHENOLOGICAL_STAGE_SAMPLE (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_PHENO_SAMP_plant
    ON dbo.FARMBOX_PHENOLOGICAL_STAGE_SAMPLE (plantation_id, sample_date DESC)
    WHERE deleted_at IS NULL;
GO


/* ─── 8.3 FARMBOX_TRAP_MONITORING ──────────────────────────────────────── */
/*
   record inclui: trap{plantation completo, lat/lng, qrcode}, monitored_targets[]
*/
IF OBJECT_ID('dbo.FARMBOX_TRAP_MONITORING') IS NOT NULL DROP TABLE dbo.FARMBOX_TRAP_MONITORING;
GO
CREATE TABLE dbo.FARMBOX_TRAP_MONITORING (
    id             BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_TRAP_MON PRIMARY KEY,
    farmbox_id     BIGINT        NOT NULL,
    ingestion_id   BIGINT        NOT NULL,
    plantation_id  BIGINT        NULL,                -- trap.plantation.id
    farm_id        BIGINT        NULL,                -- trap.plantation.farm.id
    trap_date      DATETIME2(3)  NULL,
    api_updated_at DATETIME2(3)  NULL,               -- modified_at normalizado (ATENÇÃO: pode ser NULL em todos os registros)
                                                     -- ETL fallback: api_updated_at = modified_at ?? date
    record         NVARCHAR(MAX) NOT NULL,
    processed      BIT           NOT NULL DEFAULT 0,
    processed_at   DATETIME2(3)  NULL,
    created_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at     DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_TRAP_MON_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_TRAP_MON_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_TRAP_MON_id
    ON dbo.FARMBOX_TRAP_MONITORING (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_TRAP_MON_plant
    ON dbo.FARMBOX_TRAP_MONITORING (plantation_id, trap_date DESC)
    WHERE deleted_at IS NULL;
GO


/* ─── 8.4 FARMBOX_COUNT_DAY ─────────────────────────────────────────────── */
/*
   Contagens diárias agregadas por talhão (ex: germinação, stand).
   record inclui count_groups[] → count_parameters[] com total/samples/value.
*/
IF OBJECT_ID('dbo.FARMBOX_COUNT_DAY') IS NOT NULL DROP TABLE dbo.FARMBOX_COUNT_DAY;
GO
CREATE TABLE dbo.FARMBOX_COUNT_DAY (
    id             BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_COUNT_DAY PRIMARY KEY,
    farmbox_id     BIGINT        NOT NULL,
    ingestion_id   BIGINT        NOT NULL,
    plantation_id  BIGINT        NULL,
    count_date     DATE          NULL,
    api_updated_at DATETIME2(3)  NULL,
    record         NVARCHAR(MAX) NOT NULL,
    processed      BIT           NOT NULL DEFAULT 0,
    processed_at   DATETIME2(3)  NULL,
    created_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at     DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_COUNT_DAY_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_COUNT_DAY_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_COUNT_DAY_id
    ON dbo.FARMBOX_COUNT_DAY (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_COUNT_DAY_plant
    ON dbo.FARMBOX_COUNT_DAY (plantation_id, count_date DESC)
    WHERE deleted_at IS NULL;
GO


/* ─── 8.5 FARMBOX_COUNT_MONITORING ─────────────────────────────────────── */
/*
   Contagem pontual georreferenciada (por ponto de amostragem).
   record inclui count_group + count_monitoring_parameters[].
*/
IF OBJECT_ID('dbo.FARMBOX_COUNT_MONITORING') IS NOT NULL
    DROP TABLE dbo.FARMBOX_COUNT_MONITORING;
GO
CREATE TABLE dbo.FARMBOX_COUNT_MONITORING (
    id             BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_COUNT_MON PRIMARY KEY,
    farmbox_id     BIGINT        NOT NULL,
    ingestion_id   BIGINT        NOT NULL,
    plantation_id  BIGINT        NULL,
    count_date     DATETIME2(3)  NULL,
    latitude       DECIMAL(9,6)  NULL,               -- API retorna STRING (ex: "-14.3803867") — ETL: float(val)
    longitude      DECIMAL(9,6)  NULL,               -- ETL: float(val) antes do INSERT
    api_updated_at DATETIME2(3)  NULL,
    record         NVARCHAR(MAX) NOT NULL,
    processed      BIT           NOT NULL DEFAULT 0,
    processed_at   DATETIME2(3)  NULL,
    created_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at     DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_COUNT_MON_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_COUNT_MON_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_COUNT_MON_id
    ON dbo.FARMBOX_COUNT_MONITORING (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_COUNT_MON_plant
    ON dbo.FARMBOX_COUNT_MONITORING (plantation_id, count_date DESC)
    WHERE deleted_at IS NULL;
GO


/* ─── 8.6 FARMBOX_NOTE ──────────────────────────────────────────────────── */
/*
   Observações de campo com imagens e localização polimórfica
   Enums observados em dados reais:
     location_type: 'Fields::Plantation' | 'Farms::Farm'
*/
IF OBJECT_ID('dbo.FARMBOX_NOTE') IS NOT NULL DROP TABLE dbo.FARMBOX_NOTE;
GO
CREATE TABLE dbo.FARMBOX_NOTE (
    id             BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_NOTE PRIMARY KEY,
    farmbox_id     BIGINT        NOT NULL,
    ingestion_id   BIGINT        NOT NULL,
    location_id    BIGINT        NULL,                -- plantation_id quando location_type=Fields::Plantation
    location_type  VARCHAR(50)   NULL,
    note_date      DATETIME2(3)  NULL,
    latitude       DECIMAL(9,6)  NULL,
    longitude      DECIMAL(9,6)  NULL,
    record         NVARCHAR(MAX) NOT NULL,             -- inclui image_addresses[], attachments[]
    processed      BIT           NOT NULL DEFAULT 0,
    processed_at   DATETIME2(3)  NULL,
    created_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at     DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_NOTE_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_NOTE_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_NOTE_id
    ON dbo.FARMBOX_NOTE (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_NOTE_location
    ON dbo.FARMBOX_NOTE (location_type, location_id, note_date DESC)
    WHERE deleted_at IS NULL;
GO


/* ─── 8.7 FARMBOX_RESOURCE_SUBSCRIPTION ────────────────────────────────── */
/*
   Vínculo insumo ↔ plantio (planejamento de uso de insumos por safra).
   0 registros no teste inicial — tabela criada para carga futura.
*/
IF OBJECT_ID('dbo.FARMBOX_RESOURCE_SUBSCRIPTION') IS NOT NULL
    DROP TABLE dbo.FARMBOX_RESOURCE_SUBSCRIPTION;
GO
CREATE TABLE dbo.FARMBOX_RESOURCE_SUBSCRIPTION (
    id             BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_RES_SUB PRIMARY KEY,
    farmbox_id     BIGINT        NOT NULL,
    ingestion_id   BIGINT        NOT NULL,
    plantation_id  BIGINT        NULL,
    input_id       BIGINT        NULL,
    api_updated_at DATETIME2(3)  NULL,
    record         NVARCHAR(MAX) NOT NULL,
    processed      BIT           NOT NULL DEFAULT 0,
    processed_at   DATETIME2(3)  NULL,
    created_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at     DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_RES_SUB_json CHECK (ISJSON(record) = 1),
    CONSTRAINT FK_FARMBOX_RES_SUB_ing  FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_RES_SUB_id
    ON dbo.FARMBOX_RESOURCE_SUBSCRIPTION (farmbox_id) WHERE deleted_at IS NULL;
GO


/* =========================================================================
   SEÇÃO 9 — FARMBOX_MONITORING_NOTE (notas com imagens nos monitoramentos)
   =========================================================================
   Origem: monitoring_day_results[].notes[]
   Cada nota pode ter múltiplas imagens em image_addresses[] (S3 direto).
   Também é retornada pelo endpoint /notes (location_type = Fields::Plantation).
   image_addresses é um JSON array de URLs — renderizável diretamente no front.
   ========================================================================= */

IF OBJECT_ID('dbo.FARMBOX_MONITORING_NOTE') IS NOT NULL DROP TABLE dbo.FARMBOX_MONITORING_NOTE;
GO
CREATE TABLE dbo.FARMBOX_MONITORING_NOTE (
    id                  BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_MON_NOTE PRIMARY KEY,
    farmbox_id          BIGINT        NOT NULL,       -- note.id
    ingestion_id        BIGINT        NOT NULL,

    -- Vínculo: pode vir de monitoring_day_results (via record_id) ou /notes
    monitoring_day_result_id VARCHAR(60) NULL,        -- "timestamp-plantation_id"
    plantation_id       BIGINT        NULL,           -- location_id quando Fields::Plantation
    location_type       VARCHAR(50)   NULL,           -- 'Fields::Plantation' | 'Farms::Farm'

    description         NVARCHAR(MAX) NULL,           -- texto da nota
    user_name           VARCHAR(200)  NULL,           -- nome do autor (desnormalizado)
    note_date           DATETIME2(3)  NULL,           -- Variante A com offset → normalizado UTC
    latitude            DECIMAL(12,9) NULL,           -- localização exata da nota no campo
    longitude           DECIMAL(12,9) NULL,
    image_addresses     NVARCHAR(MAX) NULL,           -- JSON array de URLs S3 (renderizável no front)
                                                      -- ex: ["https://s3.amazonaws.com/.../foto.jpg?ts"]
                                                      -- URLs diretas, sem proxy necessário

    api_updated_at      DATETIME2(3)  NULL,
    record              NVARCHAR(MAX) NOT NULL,
    processed           BIT           NOT NULL DEFAULT 0,
    processed_at        DATETIME2(3)  NULL,
    created_at          DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at          DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at          DATETIME2(3)  NULL,

    CONSTRAINT CK_FARMBOX_MON_NOTE_json  CHECK (ISJSON(record) = 1),
    CONSTRAINT CK_FARMBOX_MON_NOTE_imgs  CHECK (image_addresses IS NULL OR ISJSON(image_addresses) = 1),
    CONSTRAINT FK_FARMBOX_MON_NOTE_ing FOREIGN KEY (ingestion_id)
        REFERENCES dbo.FARMBOX_INGESTION_LOG(id)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_MON_NOTE_id
    ON dbo.FARMBOX_MONITORING_NOTE (farmbox_id) WHERE deleted_at IS NULL;
GO
CREATE INDEX IX_FARMBOX_MON_NOTE_proc
    ON dbo.FARMBOX_MONITORING_NOTE (processed)
    WHERE processed = 0 AND deleted_at IS NULL;
GO
CREATE INDEX IX_FARMBOX_MON_NOTE_mdr
    ON dbo.FARMBOX_MONITORING_NOTE (monitoring_day_result_id)
    WHERE monitoring_day_result_id IS NOT NULL AND deleted_at IS NULL;
GO

/* =========================================================================
   SEÇÃO 11 — VIEWS DE SUPORTE
   ========================================================================= */

/* ─── 11.1 FARMBOX_STALE_INGESTIONS ─────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_STALE_INGESTIONS') IS NOT NULL
    DROP VIEW dbo.FARMBOX_STALE_INGESTIONS;
GO
CREATE VIEW dbo.FARMBOX_STALE_INGESTIONS AS
SELECT id, endpoint, ingestion_type, status, started_at,
       DATEDIFF(MINUTE, started_at, SYSUTCDATETIME()) AS minutes_running,
       attempt, error_message
FROM   dbo.FARMBOX_INGESTION_LOG
WHERE  status = 'IN_PROGRESS'
  AND  DATEDIFF(MINUTE, started_at, SYSUTCDATETIME()) > 30
  AND  deleted_at IS NULL;
GO

/* ─── 11.2 FARMBOX_PENDING_PROCESSING ───────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_PENDING_PROCESSING') IS NOT NULL
    DROP VIEW dbo.FARMBOX_PENDING_PROCESSING;
GO
CREATE VIEW dbo.FARMBOX_PENDING_PROCESSING AS
SELECT 'FARMBOX_FARM'                    AS tabela, COUNT(*) AS pendentes FROM dbo.FARMBOX_FARM                    WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_HARVEST'                 ,          COUNT(*) FROM dbo.FARMBOX_HARVEST                 WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_PLOT'                    ,          COUNT(*) FROM dbo.FARMBOX_PLOT                    WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_PLUVIOMETER'             ,          COUNT(*) FROM dbo.FARMBOX_PLUVIOMETER             WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_STORAGE'                 ,          COUNT(*) FROM dbo.FARMBOX_STORAGE                 WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_PLANTATION'              ,          COUNT(*) FROM dbo.FARMBOX_PLANTATION              WHERE processed = 0 AND deleted_at IS NULL UNION ALL
-- tabelas REF (cultures/varieties/users/equipments/input_types/activity_types/beaks/phenological_stages)
-- nao tem coluna processed (carga FULL, sem fila ETL) -> ficam fora desta view.
SELECT 'FARMBOX_INPUT'                   ,          COUNT(*) FROM dbo.FARMBOX_INPUT                   WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_INPUT_VALUE'             ,          COUNT(*) FROM dbo.FARMBOX_INPUT_VALUE             WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_BATCH'                   ,          COUNT(*) FROM dbo.FARMBOX_BATCH                   WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_MOVIMENTATION'           ,          COUNT(*) FROM dbo.FARMBOX_MOVIMENTATION           WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_APPLICATION'             ,          COUNT(*) FROM dbo.FARMBOX_APPLICATION             WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_APPLICATION_PROGRESS'    ,          COUNT(*) FROM dbo.FARMBOX_APPLICATION_PROGRESS    WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_MONITORING'              ,          COUNT(*) FROM dbo.FARMBOX_MONITORING              WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_MONITORING_DAY_RESULT'   ,          COUNT(*) FROM dbo.FARMBOX_MONITORING_DAY_RESULT   WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_MONITORING_NOTE'         ,          COUNT(*) FROM dbo.FARMBOX_MONITORING_NOTE         WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_MONITORING_TOLERANCE'    ,          COUNT(*) FROM dbo.FARMBOX_MONITORING_TOLERANCE    WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_PLUVIOMETER_MONITORING'  ,          COUNT(*) FROM dbo.FARMBOX_PLUVIOMETER_MONITORING  WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_PHENOLOGICAL_STAGE_SAMPLE', COUNT(*) FROM dbo.FARMBOX_PHENOLOGICAL_STAGE_SAMPLE WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_TRAP_MONITORING'         ,          COUNT(*) FROM dbo.FARMBOX_TRAP_MONITORING         WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_COUNT_DAY'               ,          COUNT(*) FROM dbo.FARMBOX_COUNT_DAY               WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_COUNT_MONITORING'        ,          COUNT(*) FROM dbo.FARMBOX_COUNT_MONITORING        WHERE processed = 0 AND deleted_at IS NULL UNION ALL
SELECT 'FARMBOX_NOTE'                    ,          COUNT(*) FROM dbo.FARMBOX_NOTE                    WHERE processed = 0 AND deleted_at IS NULL;
GO


/* =====================================================================
   SECAO 2 — GCS_FARM (master)
   ===================================================================== */
/* =====================================================================
   SECAO 2 — GCS_FARM (master / dados tratados)
   ===================================================================== */
IF DB_ID('GCS_FARM') IS NULL CREATE DATABASE GCS_FARM;
GO
USE GCS_FARM;
GO

/* ---- 2.1 CONFIG_CONNECTORS ---- */
/* =====================================================================
   GCS_FARM  |  Banco MASTER (dados tratados)  |  SQL Server (T-SQL)
   Modulo: CONFIG  |  Tabela: dbo.CONFIG_CONNECTORS
   Gerado em: 2026-06-17

   Papel: de/para CENTRAL de codigos externos. Liga um codigo de um conector
          (Solinftec, Farmbox, IrriControl, ...) a uma entidade interna do
          GCS_FARM (fazenda, gleba, talhao, operacao, equipamento, ...).

   Decisoes:
     - SEM FOREIGN KEYS por design: as colunas *_id sao referencias LOGICAS
       (resolvidas na aplicacao). Evita o "embaralhamento" de FKs cruzando
       todos os modulos na visualizacao completa.
     - Tabela pensada para CRESCER: novas colunas *_id sao adicionadas conforme
       novos modulos/entidades passam a ser mapeados por conectores.
     - Auditoria padrao: created_at, updated_at, deleted_at (soft delete).
   ===================================================================== */

-- USE GCS_FARM;
-- GO

IF OBJECT_ID('dbo.CONFIG_CONNECTORS') IS NOT NULL DROP TABLE dbo.CONFIG_CONNECTORS;
GO
CREATE TABLE dbo.CONFIG_CONNECTORS (
    id            BIGINT        IDENTITY(1,1) CONSTRAINT PK_CONFIG_CONNECTORS PRIMARY KEY,
    type          VARCHAR(30)   NOT NULL,            -- solinftec | farmbox | irricontrol | pelican | ...
    code          VARCHAR(60)   NOT NULL,            -- codigo no conector de origem

    -- referencias logicas (sem FK). Preenche-se o(s) id(s) da entidade que o codigo resolve.
    farm_id       BIGINT        NULL,                -- -> dbo.FARM_FARMS.id
    plot_id       BIGINT        NULL,                -- -> dbo.FARM_PLOTS.id
    field_id      BIGINT        NULL,                -- -> dbo.FARM_FIELDS.id
    operation_id  BIGINT        NULL,                -- -> dbo.<operacoes>.id (futuro)
    equipment_id  BIGINT        NULL,                -- -> dbo.<frota/equip>.id (futuro)
    -- (cresce: weather_station_id, person_id, product_id, ... conforme os modulos)

    created_at    DATETIME2(3)  NULL CONSTRAINT DF_CONFIG_CONNECTORS_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3)  NULL,
    deleted_at    DATETIME2(3)  NULL
);
GO

-- Busca principal do ETL: por conector + codigo.
CREATE INDEX IX_CONFIG_CONNECTORS_type_code ON dbo.CONFIG_CONNECTORS (type, code);
-- Buscas reversas mais comuns (resolver entidade -> codigo). Filtradas para ignorar NULLs.
CREATE INDEX IX_CONFIG_CONNECTORS_field ON dbo.CONFIG_CONNECTORS (field_id) WHERE field_id IS NOT NULL;
CREATE INDEX IX_CONFIG_CONNECTORS_farm  ON dbo.CONFIG_CONNECTORS (farm_id)  WHERE farm_id  IS NOT NULL;
GO

/* ---- CONFIG_SCHEDULER ---- agendador central das integrações (jobs + histórico) */
IF OBJECT_ID('dbo.CONFIG_SCHEDULER_LOG') IS NOT NULL DROP TABLE dbo.CONFIG_SCHEDULER_LOG;
GO
IF OBJECT_ID('dbo.CONFIG_SCHEDULER') IS NOT NULL DROP TABLE dbo.CONFIG_SCHEDULER;
GO
CREATE TABLE dbo.CONFIG_SCHEDULER (
    id               BIGINT        IDENTITY(1,1) CONSTRAINT PK_CONFIG_SCHEDULER PRIMARY KEY,
    connector        VARCHAR(30)   NOT NULL,
    job_key          VARCHAR(60)   NOT NULL,
    label            VARCHAR(120)  NOT NULL,
    kind             VARCHAR(20)   NULL,
    cadence_type     VARCHAR(12)   NOT NULL,
    cadence_value    VARCHAR(60)   NULL,
    enabled          BIT           NOT NULL CONSTRAINT DF_CONFIG_SCHED_enabled DEFAULT 1,
    last_run_at      DATETIME2(3)  NULL,
    last_status      VARCHAR(15)   NULL,
    last_rows        INT           NULL,
    last_duration_ms INT           NULL,
    last_message     NVARCHAR(2000) NULL,
    next_run_at      DATETIME2(3)  NULL,
    sort_order       INT           NULL,
    created_at       DATETIME2(3)  NOT NULL CONSTRAINT DF_CONFIG_SCHED_created DEFAULT SYSUTCDATETIME(),
    updated_at       DATETIME2(3)  NULL,
    deleted_at       DATETIME2(3)  NULL,
    CONSTRAINT CK_CONFIG_SCHED_cadence CHECK (cadence_type IN ('interval','daily','weekly','cron','realtime','manual'))
);
GO
CREATE UNIQUE INDEX UX_CONFIG_SCHEDULER_job ON dbo.CONFIG_SCHEDULER (connector, job_key) WHERE deleted_at IS NULL;
GO
CREATE TABLE dbo.CONFIG_SCHEDULER_LOG (
    id           BIGINT        IDENTITY(1,1) CONSTRAINT PK_CONFIG_SCHEDULER_LOG PRIMARY KEY,
    job_id       BIGINT        NOT NULL,
    started_at   DATETIME2(3)  NOT NULL CONSTRAINT DF_CONFIG_SCHED_LOG_started DEFAULT SYSUTCDATETIME(),
    finished_at  DATETIME2(3)  NULL,
    status       VARCHAR(15)   NULL,
    rows_loaded  INT           NULL,
    duration_ms  INT           NULL,
    trigger_by   VARCHAR(12)   NULL,
    message      NVARCHAR(2000) NULL,
    CONSTRAINT FK_CONFIG_SCHED_LOG_job FOREIGN KEY (job_id) REFERENCES dbo.CONFIG_SCHEDULER(id)
);
GO
CREATE INDEX IX_CONFIG_SCHEDULER_LOG_job ON dbo.CONFIG_SCHEDULER_LOG (job_id, started_at DESC);
GO

/* =====================================================================
   NOTAS
   - Exemplos de uso:
       Solinftec CD_TALHAO  -> linha (type='solinftec', code='<CD_TALHAO>',  field_id=<id>)
       Solinftec CD_FAZENDA -> linha (type='solinftec', code='<CD_FAZENDA>', farm_id=<id>)
       Solinftec CDEQUIPAMENTO -> (type='solinftec', code='<cod>', equipment_id=<id>)
   - Uma linha resolve um codigo para a(s) entidade(s) correspondente(s).
   - Unicidade (type, code) NAO e imposta por padrao (codigos podem repetir
     entre tipos de entidade). Se confirmarem que o par e unico por conector,
     trocar IX_CONFIG_CONNECTORS_type_code por UNIQUE.
   - Integridade das colunas *_id e responsabilidade da aplicacao (sem FK).
   ===================================================================== */

/* ---- 2.2 CONFIG_API ---- */
/* =====================================================================
   GCS_FARM  |  Banco MASTER (dados tratados)  |  SQL Server (T-SQL)
   Modulo: CONFIG  |  Tabela: dbo.CONFIG_API
   Gerado em: 2026-06-17

   Papel: registrar as APIs externas (URL e credenciais) usadas pela
          plataforma. Os endpoints buscam a conexao por NAME e fazem as
          requisicoes a partir daqui -> nada de URL/segredo fixo no codigo.

   Convencao:
     - Identificadores em INGLES; documentacao em PORTUGUES.
     - Schema dbo; prefixo CONFIG_.
     - Auditoria padrao: created_at, updated_at, deleted_at.
     - Apenas PK NOT NULL; demais colunas NULL.

   SEGURANCA:
     - Os segredos (password, token, api_key, client_secret) sao VARBINARY(MAX)
       e ficam CIFRADOS com a chave simetrica SK_CONFIG_API (AES-256).
       Ver script: GCS_FARM_config_api_encryption_mssql.sql
       (gravar com ENCRYPTBYKEY; ler com DECRYPTBYKEY).
     - Restringir o acesso da tabela e da chave ao login do servico.
   ===================================================================== */

-- USE GCS_FARM;
-- GO

IF OBJECT_ID('dbo.CONFIG_API') IS NOT NULL DROP TABLE dbo.CONFIG_API;
GO
CREATE TABLE dbo.CONFIG_API (
    id               BIGINT         IDENTITY(1,1) CONSTRAINT PK_CONFIG_API PRIMARY KEY,
    name             VARCHAR(80)    NULL,           -- identificador (ex.: SOLINFTEC, FARMBOX)
    url              VARCHAR(500)   NULL,           -- base URL / endpoint de conexao
    auth_type        VARCHAR(15)    NULL,           -- NONE | BASIC | TOKEN | APIKEY | OAUTH2

    -- credenciais de acesso (preenche-se apenas o que a API usa)
    username         VARCHAR(120)   NULL,           -- login / cliente (ex.: Solinftec 'cliente')
    password         VARBINARY(MAX) NULL,           -- CIFRADO (SK_CONFIG_API)
    token            VARBINARY(MAX) NULL,           -- CIFRADO (volatil; cache de runtime)
    token_expires_at DATETIME2(3)   NULL,           -- validade do token
    api_key          VARBINARY(MAX) NULL,           -- CIFRADO
    client_id        VARCHAR(120)   NULL,           -- OAuth2 client id (nao secreto)
    client_secret    VARBINARY(MAX) NULL,           -- CIFRADO

    active           BIT            NULL CONSTRAINT DF_CONFIG_API_active DEFAULT 1,
    created_at       DATETIME2(3)   NULL CONSTRAINT DF_CONFIG_API_created DEFAULT SYSUTCDATETIME(),
    updated_at       DATETIME2(3)   NULL,
    deleted_at       DATETIME2(3)   NULL,
    CONSTRAINT CK_CONFIG_API_auth CHECK (auth_type IS NULL OR auth_type IN ('NONE','BASIC','TOKEN','APIKEY','OAUTH2'))
);
GO
CREATE UNIQUE INDEX UX_CONFIG_API_name ON dbo.CONFIG_API (name) WHERE name IS NOT NULL;
GO

/* =====================================================================
   NOTAS
   - Gravar/ler segredos sempre com a chave simetrica aberta:
       OPEN SYMMETRIC KEY SK_CONFIG_API DECRYPTION BY CERTIFICATE CERT_CONFIG_API;
       ... ENCRYPTBYKEY(KEY_GUID('SK_CONFIG_API'), @valor) / DECRYPTBYKEY(coluna) ...
       CLOSE SYMMETRIC KEY SK_CONFIG_API;
   - Campos NAO secretos (name, url, auth_type, username, client_id) ficam em claro.
   - Exemplos de preenchimento:
       Solinftec : auth_type='TOKEN', username='<cliente>', password=<cifrado>, token=<cifrado runtime>
       Farmbox   : auth_type='TOKEN', token=<cifrado>  (sem username/senha)
       Generica  : auth_type='APIKEY', api_key=<cifrado>
   ===================================================================== */

/* ---- 2.3 CRIPTOGRAFIA DA CONFIG_API (TROCAR A SENHA DO DMK) ---- */
/* =====================================================================
   GCS_FARM  |  Criptografia dos segredos da CONFIG_API  |  SQL Server (T-SQL)
   Gerado em: 2026-06-17

   Objetivo: criar a "chave secreta de criptografia" e proteger em repouso os
   campos sensiveis da dbo.CONFIG_API (password, token, api_key, client_secret),
   usando criptografia de celula (cell-level) com chave simetrica AES-256.

   Hierarquia de protecao (padrao SQL Server):
     Database Master Key (DMK)  ->  Certificado  ->  Chave simetrica AES-256
   Os segredos sao gravados como VARBINARY (texto cifrado) e lidos com
   OPEN SYMMETRIC KEY + DECRYPTBYKEY.

   ATENCAO (trocar / guardar com seguranca):
     - A senha do DMK e o backup do certificado sao CRITICOS: sem eles os
       dados cifrados nao sao recuperaveis. Guardar em cofre.
     - Restringir permissao da chave/certificado ao login do servico.
   ===================================================================== */

-- USE GCS_FARM;
-- GO

/* ----- 1) Database Master Key (protege os certificados do banco) ----- */
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'TROCAR_POR_SENHA_FORTE_DMK_#2026';
GO

/* ----- 2) Certificado que protege a chave simetrica ----- */
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = 'CERT_CONFIG_API')
    CREATE CERTIFICATE CERT_CONFIG_API
        WITH SUBJECT = 'Protecao dos segredos da CONFIG_API',
             EXPIRY_DATE = '20311231';
GO

/* ----- 3) Chave simetrica AES-256 (a "chave secreta de criptografia") ----- */
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = 'SK_CONFIG_API')
    CREATE SYMMETRIC KEY SK_CONFIG_API
        WITH ALGORITHM = AES_256
        ENCRYPTION BY CERTIFICATE CERT_CONFIG_API;
GO

/* ----- 4) Backup do certificado (guardar os arquivos em cofre) ----- */
-- BACKUP CERTIFICATE CERT_CONFIG_API
--   TO FILE = 'C:\seguro\CERT_CONFIG_API.cer'
--   WITH PRIVATE KEY (
--        FILE = 'C:\seguro\CERT_CONFIG_API.pvk',
--        ENCRYPTION BY PASSWORD = 'TROCAR_SENHA_BACKUP_CERT');
-- GO

/* ----- 5) Colunas de segredo como VARBINARY (texto cifrado) -----
   Em ambiente novo (sem dados). As colunas password/token/api_key/client_secret
   da CONFIG_API devem ser VARBINARY(MAX). Caso ja existam como texto, recriar:
*/
-- IF COL_LENGTH('dbo.CONFIG_API','password') IS NOT NULL AND
--    (SELECT system_type_id FROM sys.columns WHERE object_id=OBJECT_ID('dbo.CONFIG_API') AND name='password') <> 165 -- 165 = varbinary
-- BEGIN
--   ALTER TABLE dbo.CONFIG_API DROP COLUMN password;
--   ALTER TABLE dbo.CONFIG_API DROP COLUMN token;
--   ALTER TABLE dbo.CONFIG_API DROP COLUMN api_key;
--   ALTER TABLE dbo.CONFIG_API DROP COLUMN client_secret;
--   ALTER TABLE dbo.CONFIG_API ADD password      VARBINARY(MAX) NULL;
--   ALTER TABLE dbo.CONFIG_API ADD token         VARBINARY(MAX) NULL;
--   ALTER TABLE dbo.CONFIG_API ADD api_key       VARBINARY(MAX) NULL;
--   ALTER TABLE dbo.CONFIG_API ADD client_secret VARBINARY(MAX) NULL;
-- END
-- GO
-- (No DDL principal da CONFIG_API essas colunas ja estao definidas como VARBINARY(MAX).)

/* =====================================================================
   EXEMPLOS DE USO
   ===================================================================== */

/* ----- Gravar/atualizar segredos (cifrando) ----- */
-- DECLARE @senha NVARCHAR(255) = N'<SENHA_SOLINFTEC>';  -- nunca versionar a senha real
-- OPEN SYMMETRIC KEY SK_CONFIG_API DECRYPTION BY CERTIFICATE CERT_CONFIG_API;
--   UPDATE dbo.CONFIG_API
--      SET password   = ENCRYPTBYKEY(KEY_GUID('SK_CONFIG_API'), @senha),
--          updated_at = SYSUTCDATETIME()
--    WHERE name = 'SOLINFTEC';
-- CLOSE SYMMETRIC KEY SK_CONFIG_API;
-- GO

/* ----- Ler segredos (decifrando) — o endpoint usa este SELECT ----- */
-- OPEN SYMMETRIC KEY SK_CONFIG_API DECRYPTION BY CERTIFICATE CERT_CONFIG_API;
--   SELECT name, url, auth_type, username,
--          CONVERT(NVARCHAR(255), DECRYPTBYKEY(password))      AS password,
--          CONVERT(NVARCHAR(MAX), DECRYPTBYKEY(token))         AS token,
--          CONVERT(NVARCHAR(255), DECRYPTBYKEY(api_key))       AS api_key,
--          CONVERT(NVARCHAR(255), DECRYPTBYKEY(client_secret)) AS client_secret
--     FROM dbo.CONFIG_API
--    WHERE name = 'SOLINFTEC' AND active = 1 AND deleted_at IS NULL;
-- CLOSE SYMMETRIC KEY SK_CONFIG_API;
-- GO

/* =====================================================================
   PERMISSOES (exemplo) — conceder so ao login do servico de integracao
   -------------------------------------------------------------------
   GRANT VIEW DEFINITION ON SYMMETRIC KEY::SK_CONFIG_API TO [svc_integracao];
   GRANT CONTROL ON CERTIFICATE::CERT_CONFIG_API          TO [svc_integracao];

   ALTERNATIVA MAIS FORTE
   - Always Encrypted (com Azure Key Vault): a chave nunca fica em claro no
     servidor; a cifra/decifra ocorre no driver do cliente. Recomendado se o
     requisito de seguranca for alto. Mais complexo de operar.
   ===================================================================== */

/* ---- 2.3.1 SEED da conexao SOLINFTEC (metadados; SEM a senha) ----
   Cria a linha da CONFIG_API usada pela integracao Solinftec. A senha NAO
   vai aqui — aplique-a depois com o snippet "Gravar/atualizar segredos"
   acima (ENCRYPTBYKEY), para nunca versionar o segredo. Idempotente. */
IF NOT EXISTS (SELECT 1 FROM dbo.CONFIG_API WHERE name = 'SOLINFTEC')
    INSERT INTO dbo.CONFIG_API (name, url, auth_type, username, active, created_at)
    VALUES ('SOLINFTEC', 'https://scdi.saas-solinftec.com', 'TOKEN', 'grupo_celeiro', 1, SYSUTCDATETIME());
GO

/* ---- 2.4 MODULO MANAGEMENT ---- */
/* =====================================================================
   GCS_FARM  |  Banco MASTER (dados tratados)  |  SQL Server (T-SQL)
   Modulo: MANAGEMENT (gestao de usuarios e acessos)
   Gerado em: 2026-06-17  |  Revisado: 2026-06-24 (RBAC + setores + catalogos)

   Convencao:
     - Identificadores em INGLES; documentacao (comentarios) em PORTUGUES.
     - Schema dbo; prefixo MANAGEMENT_ no modulo de gestao.
     - Datas/horas em DATETIME2(3), default SYSUTCDATETIME() (UTC).
     - Auditoria padrao em TODAS as tabelas: created_at, updated_at, deleted_at.
     - Apenas PK e FK NOT NULL; demais colunas NULL. Uniques anulaveis usam
       indice unico filtrado (WHERE col IS NOT NULL).
     - Textos de seed em ASCII (sem acentos) para evitar problemas de code page.

   Modelo de ACESSO (RBAC):
     - Permissao concedida ao PERFIL (MANAGEMENT_TYPE_USERS) por PAGINA.
     - Paginas/rotas/funcionalidades em MANAGEMENT_PAGES (hierarquia via
       parent_page_id), pertencentes a um MODULO (MANAGEMENT_MODULES).
     - Excecao por usuario em MANAGEMENT_USER_ACCESS_OVERRIDE (tri-state).
     - Cada usuario pertence a um SETOR (MANAGEMENT_SECTORS).
   ===================================================================== */

-- CREATE DATABASE GCS_FARM;
-- GO
-- USE GCS_FARM;
-- GO

/* =====================================================================
   1) MANAGEMENT_PEOPLES  -- cadastro unico de pessoas (PF/PJ)
   ===================================================================== */
IF OBJECT_ID('dbo.MANAGEMENT_PEOPLES') IS NOT NULL DROP TABLE dbo.MANAGEMENT_PEOPLES;
GO
CREATE TABLE dbo.MANAGEMENT_PEOPLES (
    id            BIGINT        IDENTITY(1,1) CONSTRAINT PK_MANAGEMENT_PEOPLES PRIMARY KEY,
    person_type   CHAR(2)       NULL,                -- PF | PJ
    name          NVARCHAR(150) NULL,                -- nome / razao social
    document      VARCHAR(18)   NULL,                -- CPF ou CNPJ
    email         VARCHAR(150)  NULL,
    phone         VARCHAR(20)   NULL,
    birth_date    DATE          NULL,
    active        BIT           NULL CONSTRAINT DF_MANAGEMENT_PEOPLES_active DEFAULT 1,
    created_at    DATETIME2(3)  NULL CONSTRAINT DF_MANAGEMENT_PEOPLES_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3)  NULL,
    deleted_at    DATETIME2(3)  NULL,
    CONSTRAINT CK_MANAGEMENT_PEOPLES_type CHECK (person_type IS NULL OR person_type IN ('PF','PJ'))
);
GO
CREATE UNIQUE INDEX UX_MANAGEMENT_PEOPLES_document ON dbo.MANAGEMENT_PEOPLES (document) WHERE document IS NOT NULL;
GO

/* =====================================================================
   2) MANAGEMENT_TYPE_USERS  -- perfis (donos das permissoes)
   ===================================================================== */
IF OBJECT_ID('dbo.MANAGEMENT_TYPE_USERS') IS NOT NULL DROP TABLE dbo.MANAGEMENT_TYPE_USERS;
GO
CREATE TABLE dbo.MANAGEMENT_TYPE_USERS (
    id           BIGINT        IDENTITY(1,1) CONSTRAINT PK_MANAGEMENT_TYPE_USERS PRIMARY KEY,
    code         VARCHAR(40)   NULL,                 -- chave estavel (ingles)
    name         VARCHAR(60)   NULL,                 -- nome exibido
    description  VARCHAR(200)  NULL,
    active       BIT           NULL CONSTRAINT DF_MANAGEMENT_TYPE_USERS_active DEFAULT 1,
    created_at   DATETIME2(3)  NULL CONSTRAINT DF_MANAGEMENT_TYPE_USERS_created DEFAULT SYSUTCDATETIME(),
    updated_at   DATETIME2(3)  NULL,
    deleted_at   DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_MANAGEMENT_TYPE_USERS_code ON dbo.MANAGEMENT_TYPE_USERS (code) WHERE code IS NOT NULL;
CREATE UNIQUE INDEX UX_MANAGEMENT_TYPE_USERS_name ON dbo.MANAGEMENT_TYPE_USERS (name) WHERE name IS NOT NULL;
GO
INSERT INTO dbo.MANAGEMENT_TYPE_USERS (code, name, description) VALUES
 ('ADMIN',       'Administrador', 'Acesso total ao sistema'),
 ('INTEGRATION', 'Integração',    'Conta de integração (n8n / consumo de APIs externas)'),
 ('DIRECTOR',    'Diretor',       'Direção'),
 ('MANAGER',     'Gerente',       'Gerência'),
 ('COORDINATOR', 'Coordenador',   'Coordenação'),
 ('ANALYST',     'Analista',      'Análise'),
 ('ASSISTANT',   'Auxiliar',      'Auxiliar'),
 ('TECHNICIAN',  'Técnico',       'Técnico'),
 ('STANDARD',    'Padrão',        'Acesso padrão');
GO

/* =====================================================================
   3) MANAGEMENT_SECTORS  -- setores onde os usuarios trabalham
   ===================================================================== */
IF OBJECT_ID('dbo.MANAGEMENT_SECTORS') IS NOT NULL DROP TABLE dbo.MANAGEMENT_SECTORS;
GO
CREATE TABLE dbo.MANAGEMENT_SECTORS (
    id           BIGINT        IDENTITY(1,1) CONSTRAINT PK_MANAGEMENT_SECTORS PRIMARY KEY,
    code         VARCHAR(40)   NULL,                 -- chave estavel (ingles)
    name         VARCHAR(80)   NULL,                 -- nome exibido
    description  VARCHAR(200)  NULL,
    sort_order   INT           NULL,
    active       BIT           NULL CONSTRAINT DF_MANAGEMENT_SECTORS_active DEFAULT 1,
    created_at   DATETIME2(3)  NULL CONSTRAINT DF_MANAGEMENT_SECTORS_created DEFAULT SYSUTCDATETIME(),
    updated_at   DATETIME2(3)  NULL,
    deleted_at   DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_MANAGEMENT_SECTORS_code ON dbo.MANAGEMENT_SECTORS (code) WHERE code IS NOT NULL;
GO
INSERT INTO dbo.MANAGEMENT_SECTORS (code, name, sort_order) VALUES
 ('ADMINISTRATIVE',                   'Administrativo',                  1),
 ('COTTON_GIN',                       'Algodoeira',                      2),
 ('PROCESSING',                       'Beneficiamento',                  3),
 ('WORKSHOP',                         'Oficina',                         4),
 ('WAREHOUSE',                        'Almoxarifado',                    5),
 ('DEFENSIVES',                       'Defensivos',                      6),
 ('FERTILIZER_MIXER',                 'Misturadora Adubo',               7),
 ('SOIL_PREPARATION',                 'Preparo de Solo',                 8),
 ('IRRIGATION',                       'Irrigação',                       9),
 ('GENERAL_SERVICES',                 'Serviços Gerais',                10),
 ('PESTICIDE_APPLICATION',            'Aplicação de Defensivos',        11),
 ('CIVIL_WORKS',                      'Obras Civis',                    12),
 ('ELECTRICAL',                       'Elétrica',                       13),
 ('HYDRAULIC',                        'Hidráulica',                     14),
 ('AGRONOMIC',                        'Agronômico',                     15),
 ('AGRICULTURAL_INTELLIGENCE_CENTER', 'Centro de Inteligência Agrícola',16);
GO

/* =====================================================================
   4) MANAGEMENT_MODULES  -- catalogo dos modulos do GCS_FARM
   ===================================================================== */
IF OBJECT_ID('dbo.MANAGEMENT_MODULES') IS NOT NULL DROP TABLE dbo.MANAGEMENT_MODULES;
GO
CREATE TABLE dbo.MANAGEMENT_MODULES (
    id           BIGINT        IDENTITY(1,1) CONSTRAINT PK_MANAGEMENT_MODULES PRIMARY KEY,
    code         VARCHAR(40)   NULL,
    name         VARCHAR(80)   NULL,
    description  VARCHAR(200)  NULL,
    sort_order   INT           NULL,
    active       BIT           NULL CONSTRAINT DF_MANAGEMENT_MODULES_active DEFAULT 1,
    created_at   DATETIME2(3)  NULL CONSTRAINT DF_MANAGEMENT_MODULES_created DEFAULT SYSUTCDATETIME(),
    updated_at   DATETIME2(3)  NULL,
    deleted_at   DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_MANAGEMENT_MODULES_code ON dbo.MANAGEMENT_MODULES (code) WHERE code IS NOT NULL;
GO
INSERT INTO dbo.MANAGEMENT_MODULES (code, name, sort_order) VALUES
 ('CONFIG',               'Configurações',          1),
 ('MANAGEMENT',           'Gestão',                 2),
 ('HUMAN_RESOURCES',      'Recursos Humanos',       3),
 ('FARMS',                'Fazendas',               4),
 ('AGRICULTURE',          'Agricultura',            5),
 ('WEATHER',              'Meteorologia',           6),
 ('DEFENSIVES_STOCK',     'Estoque Defensivos',     7),
 ('FERTILIZER_STOCK',     'Estoque Adubos',         8),
 ('PARTS_STOCK',          'Estoque Peças',          9),
 ('IRRIGATION',           'Irrigação',             10),
 ('MACHINE_OPERATIONS',   'Operações Máquinas',    11),
 ('WORKSHOP',             'Oficina',               12),
 ('FLEET',                'Frota',                 13),
 ('COTTON',               'Algodão',               14),
 ('PROCESSING',           'Beneficiamento',        15),
 ('KANBAN',               'Kanban',                16),
 ('AGRICULTURAL_PLANNING','Planejamento Agrícola', 17);
GO

/* =====================================================================
   5) MANAGEMENT_PAGES  -- paginas / rotas / funcionalidades por modulo
      - module_id   : modulo dono (FK)
      - parent_page_id: hierarquia de menu (auto-FK; NULL = raiz)
      - kind        : PAGE (tela) | ROUTE (endpoint) | FEATURE (funcao/botao)
   ===================================================================== */
IF OBJECT_ID('dbo.MANAGEMENT_PAGES') IS NOT NULL DROP TABLE dbo.MANAGEMENT_PAGES;
GO
CREATE TABLE dbo.MANAGEMENT_PAGES (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_MANAGEMENT_PAGES PRIMARY KEY,
    module_id       BIGINT        NOT NULL,            -- FK -> MANAGEMENT_MODULES
    parent_page_id  BIGINT        NULL,                -- FK -> MANAGEMENT_PAGES (auto); NULL = raiz
    code            VARCHAR(80)   NULL,                -- chave estavel (unica)
    name            NVARCHAR(150) NULL,
    path            VARCHAR(200)  NULL,                -- rota (front ou API)
    kind            VARCHAR(15)   NULL,                -- PAGE | ROUTE | FEATURE
    sort_order      INT           NULL,
    active          BIT           NULL CONSTRAINT DF_MANAGEMENT_PAGES_active DEFAULT 1,
    created_at      DATETIME2(3)  NULL CONSTRAINT DF_MANAGEMENT_PAGES_created DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)  NULL,
    deleted_at      DATETIME2(3)  NULL,
    CONSTRAINT FK_MANAGEMENT_PAGES_module FOREIGN KEY (module_id)      REFERENCES dbo.MANAGEMENT_MODULES(id),
    CONSTRAINT FK_MANAGEMENT_PAGES_parent FOREIGN KEY (parent_page_id) REFERENCES dbo.MANAGEMENT_PAGES(id),
    CONSTRAINT CK_MANAGEMENT_PAGES_kind   CHECK (kind IS NULL OR kind IN ('PAGE','ROUTE','FEATURE'))
);
GO
CREATE UNIQUE INDEX UX_MANAGEMENT_PAGES_code   ON dbo.MANAGEMENT_PAGES (code) WHERE code IS NOT NULL;
CREATE INDEX        IX_MANAGEMENT_PAGES_module ON dbo.MANAGEMENT_PAGES (module_id);
CREATE INDEX        IX_MANAGEMENT_PAGES_parent ON dbo.MANAGEMENT_PAGES (parent_page_id) WHERE parent_page_id IS NOT NULL;
GO

-- Seed: 1 pagina raiz (home) por modulo
INSERT INTO dbo.MANAGEMENT_PAGES (module_id, parent_page_id, code, name, path, kind, sort_order)
SELECT m.id, NULL, m.code + '.HOME', m.name, '/' + LOWER(m.code), 'PAGE', 1
FROM dbo.MANAGEMENT_MODULES m;
GO
-- Seed: exemplos de subpaginas do modulo MANAGEMENT (demonstra hierarquia e kinds)
DECLARE @mgmt_home BIGINT = (SELECT id FROM dbo.MANAGEMENT_PAGES WHERE code = 'MANAGEMENT.HOME');
INSERT INTO dbo.MANAGEMENT_PAGES (module_id, parent_page_id, code, name, path, kind, sort_order)
SELECT m.id, @mgmt_home, v.code, v.name, v.path, v.kind, v.sort_order
FROM (VALUES
   ('MANAGEMENT.USERS',         'Usuários',           '/management/users',    'PAGE',    1),
   ('MANAGEMENT.USERS.CREATE',  'Criar usuário',      '/management/users',    'FEATURE', 2),
   ('MANAGEMENT.PROFILES',      'Perfis',             '/management/profiles', 'PAGE',    3),
   ('MANAGEMENT.SECTORS',       'Setores',            '/management/sectors',  'PAGE',    4),
   ('MANAGEMENT.PAGES',         'Páginas e acessos',  '/management/pages',    'PAGE',    5)
) AS v(code, name, path, kind, sort_order)
CROSS JOIN dbo.MANAGEMENT_MODULES m
WHERE m.code = 'MANAGEMENT';
GO

/* =====================================================================
   6) MANAGEMENT_USERS  -- usuarios do sistema (1 pessoa = 1 usuario)
      Cada usuario pertence a um SETOR (sector_id).
   ===================================================================== */
IF OBJECT_ID('dbo.MANAGEMENT_USERS') IS NOT NULL DROP TABLE dbo.MANAGEMENT_USERS;
GO
CREATE TABLE dbo.MANAGEMENT_USERS (
    id            BIGINT        IDENTITY(1,1) CONSTRAINT PK_MANAGEMENT_USERS PRIMARY KEY,
    person_id     BIGINT        NOT NULL,            -- FK
    type_user_id  BIGINT        NOT NULL,            -- FK (perfil que define as permissoes)
    sector_id     BIGINT        NOT NULL,            -- FK (setor onde o usuario trabalha)
    username      VARCHAR(60)   NULL,
    email         VARCHAR(150)  NULL,
    password_hash VARCHAR(255)  NULL,                -- somente hash+salt; NUNCA senha em texto
    active        BIT           NULL CONSTRAINT DF_MANAGEMENT_USERS_active DEFAULT 1,
    last_login_at DATETIME2(3)  NULL,
    created_at    DATETIME2(3)  NULL CONSTRAINT DF_MANAGEMENT_USERS_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3)  NULL,
    deleted_at    DATETIME2(3)  NULL,
    CONSTRAINT FK_MANAGEMENT_USERS_person FOREIGN KEY (person_id)    REFERENCES dbo.MANAGEMENT_PEOPLES(id),
    CONSTRAINT FK_MANAGEMENT_USERS_type   FOREIGN KEY (type_user_id) REFERENCES dbo.MANAGEMENT_TYPE_USERS(id),
    CONSTRAINT FK_MANAGEMENT_USERS_sector FOREIGN KEY (sector_id)    REFERENCES dbo.MANAGEMENT_SECTORS(id)
);
GO
CREATE UNIQUE INDEX UX_MANAGEMENT_USERS_person   ON dbo.MANAGEMENT_USERS (person_id);
CREATE UNIQUE INDEX UX_MANAGEMENT_USERS_username ON dbo.MANAGEMENT_USERS (username) WHERE username IS NOT NULL;
CREATE INDEX        IX_MANAGEMENT_USERS_sector   ON dbo.MANAGEMENT_USERS (sector_id);
CREATE INDEX        IX_MANAGEMENT_USERS_type     ON dbo.MANAGEMENT_USERS (type_user_id);
GO

/* =====================================================================
   7) MANAGEMENT_ACCESS  -- permissao do PERFIL x PAGINA (base do RBAC)
   ===================================================================== */
IF OBJECT_ID('dbo.MANAGEMENT_ACCESS') IS NOT NULL DROP TABLE dbo.MANAGEMENT_ACCESS;
GO
CREATE TABLE dbo.MANAGEMENT_ACCESS (
    id           BIGINT       IDENTITY(1,1) CONSTRAINT PK_MANAGEMENT_ACCESS PRIMARY KEY,
    type_user_id BIGINT       NOT NULL,               -- FK -> MANAGEMENT_TYPE_USERS (perfil)
    page_id      BIGINT       NOT NULL,               -- FK -> MANAGEMENT_PAGES
    can_read     BIT          NULL CONSTRAINT DF_MANAGEMENT_ACCESS_read   DEFAULT 0,
    can_write    BIT          NULL CONSTRAINT DF_MANAGEMENT_ACCESS_write  DEFAULT 0,
    can_delete   BIT          NULL CONSTRAINT DF_MANAGEMENT_ACCESS_delete DEFAULT 0,
    can_admin    BIT          NULL CONSTRAINT DF_MANAGEMENT_ACCESS_admin  DEFAULT 0,
    created_at   DATETIME2(3) NULL CONSTRAINT DF_MANAGEMENT_ACCESS_created DEFAULT SYSUTCDATETIME(),
    updated_at   DATETIME2(3) NULL,
    deleted_at   DATETIME2(3) NULL,
    CONSTRAINT FK_MANAGEMENT_ACCESS_type FOREIGN KEY (type_user_id) REFERENCES dbo.MANAGEMENT_TYPE_USERS(id),
    CONSTRAINT FK_MANAGEMENT_ACCESS_page FOREIGN KEY (page_id)      REFERENCES dbo.MANAGEMENT_PAGES(id),
    CONSTRAINT UQ_MANAGEMENT_ACCESS_type_page UNIQUE (type_user_id, page_id)
);
GO
CREATE INDEX IX_MANAGEMENT_ACCESS_page ON dbo.MANAGEMENT_ACCESS (page_id);
GO
-- Seed: perfil ADMIN com acesso total a todas as paginas
DECLARE @admin_type BIGINT = (SELECT id FROM dbo.MANAGEMENT_TYPE_USERS WHERE code = 'ADMIN');
INSERT INTO dbo.MANAGEMENT_ACCESS (type_user_id, page_id, can_read, can_write, can_delete, can_admin)
SELECT @admin_type, p.id, 1, 1, 1, 1
FROM dbo.MANAGEMENT_PAGES p;
GO

/* =====================================================================
   8) MANAGEMENT_USER_ACCESS_OVERRIDE  -- excecao por usuario (sobrepoe o perfil)
      can_* tri-state: NULL = herda do perfil; 1 = permite; 0 = nega.
   ===================================================================== */
IF OBJECT_ID('dbo.MANAGEMENT_USER_ACCESS_OVERRIDE') IS NOT NULL DROP TABLE dbo.MANAGEMENT_USER_ACCESS_OVERRIDE;
GO
CREATE TABLE dbo.MANAGEMENT_USER_ACCESS_OVERRIDE (
    id          BIGINT       IDENTITY(1,1) CONSTRAINT PK_MANAGEMENT_USER_ACCESS_OVERRIDE PRIMARY KEY,
    user_id     BIGINT       NOT NULL,               -- FK -> MANAGEMENT_USERS
    page_id     BIGINT       NOT NULL,               -- FK -> MANAGEMENT_PAGES
    can_read    BIT          NULL,                   -- NULL = herda; 1 = permite; 0 = nega
    can_write   BIT          NULL,
    can_delete  BIT          NULL,
    can_admin   BIT          NULL,
    reason      VARCHAR(200) NULL,                   -- motivo da excecao (auditavel)
    created_at  DATETIME2(3) NULL CONSTRAINT DF_MANAGEMENT_USER_ACCESS_OVERRIDE_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3) NULL,
    deleted_at  DATETIME2(3) NULL,
    CONSTRAINT FK_MANAGEMENT_USER_ACCESS_OVERRIDE_user FOREIGN KEY (user_id) REFERENCES dbo.MANAGEMENT_USERS(id),
    CONSTRAINT FK_MANAGEMENT_USER_ACCESS_OVERRIDE_page FOREIGN KEY (page_id) REFERENCES dbo.MANAGEMENT_PAGES(id),
    CONSTRAINT UQ_MANAGEMENT_USER_ACCESS_OVERRIDE UNIQUE (user_id, page_id)
);
GO
CREATE INDEX IX_MANAGEMENT_USER_ACCESS_OVERRIDE_page ON dbo.MANAGEMENT_USER_ACCESS_OVERRIDE (page_id);
GO

/* =====================================================================
   9) MANAGEMENT_USER_FARM  -- escopo de fazendas POR USUARIO
   ===================================================================== */
IF OBJECT_ID('dbo.MANAGEMENT_USER_FARM') IS NOT NULL DROP TABLE dbo.MANAGEMENT_USER_FARM;
GO
CREATE TABLE dbo.MANAGEMENT_USER_FARM (
    id          BIGINT       IDENTITY(1,1) CONSTRAINT PK_MANAGEMENT_USER_FARM PRIMARY KEY,
    user_id     BIGINT       NOT NULL,               -- FK
    farm_id     BIGINT       NOT NULL,               -- FK futura -> modulo Fazendas
    active      BIT          NULL CONSTRAINT DF_MANAGEMENT_USER_FARM_active DEFAULT 1,
    created_at  DATETIME2(3) NULL CONSTRAINT DF_MANAGEMENT_USER_FARM_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3) NULL,
    deleted_at  DATETIME2(3) NULL,
    CONSTRAINT FK_MANAGEMENT_USER_FARM_user FOREIGN KEY (user_id) REFERENCES dbo.MANAGEMENT_USERS(id),
    CONSTRAINT UQ_MANAGEMENT_USER_FARM UNIQUE (user_id, farm_id)
);
GO

/* =====================================================================
   9.1) MANAGEMENT_USER_PREFERENCE  -- preferencias de UI por usuario
        (tema, fazenda selecionada, etc.) em JSON livre. 1 linha por usuario.
   ===================================================================== */
IF OBJECT_ID('dbo.MANAGEMENT_USER_PREFERENCE') IS NOT NULL DROP TABLE dbo.MANAGEMENT_USER_PREFERENCE;
GO
CREATE TABLE dbo.MANAGEMENT_USER_PREFERENCE (
    user_id     BIGINT        NOT NULL CONSTRAINT PK_MANAGEMENT_USER_PREFERENCE PRIMARY KEY,
    preferences NVARCHAR(MAX) NULL,                    -- JSON: { theme, farm, ... }
    created_at  DATETIME2(3)  NOT NULL CONSTRAINT DF_MANAGEMENT_USER_PREFERENCE_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3)  NULL,
    CONSTRAINT FK_MANAGEMENT_USER_PREFERENCE_user FOREIGN KEY (user_id) REFERENCES dbo.MANAGEMENT_USERS(id),
    CONSTRAINT CK_MANAGEMENT_USER_PREFERENCE_json CHECK (preferences IS NULL OR ISJSON(preferences) = 1)
);
GO

/* =====================================================================
   10) MANAGEMENT_ACCESS_LOG  -- log de login / acesso
       user_id NULL = excecao consciente (tentativa com usuario desconhecido).
   ===================================================================== */
IF OBJECT_ID('dbo.MANAGEMENT_ACCESS_LOG') IS NOT NULL DROP TABLE dbo.MANAGEMENT_ACCESS_LOG;
GO
CREATE TABLE dbo.MANAGEMENT_ACCESS_LOG (
    id             BIGINT       IDENTITY(1,1) CONSTRAINT PK_MANAGEMENT_ACCESS_LOG PRIMARY KEY,
    user_id        BIGINT       NULL,                -- FK (anulavel: login falho sem usuario)
    event_type     VARCHAR(15)  NULL,                -- LOGIN | LOGOUT | LOGIN_FAILED
    username_tried VARCHAR(60)  NULL,
    ip_address     VARCHAR(45)  NULL,
    user_agent     VARCHAR(255) NULL,
    created_at     DATETIME2(3) NULL CONSTRAINT DF_MANAGEMENT_ACCESS_LOG_created DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3) NULL,
    deleted_at     DATETIME2(3) NULL,
    CONSTRAINT FK_MANAGEMENT_ACCESS_LOG_user FOREIGN KEY (user_id) REFERENCES dbo.MANAGEMENT_USERS(id),
    CONSTRAINT CK_MANAGEMENT_ACCESS_LOG_event CHECK (event_type IS NULL OR event_type IN ('LOGIN','LOGOUT','LOGIN_FAILED'))
);
GO
CREATE INDEX IX_MANAGEMENT_ACCESS_LOG_user ON dbo.MANAGEMENT_ACCESS_LOG (user_id, created_at);
GO

/* =====================================================================
   RESOLUCAO DA PERMISSAO EFETIVA (perfil + override)
   View: dbo.MANAGEMENT_EFFECTIVE_ACCESS
   Efetivo por usuario x pagina = COALESCE(override, perfil, 0).
   ===================================================================== */
IF OBJECT_ID('dbo.MANAGEMENT_EFFECTIVE_ACCESS') IS NOT NULL DROP VIEW dbo.MANAGEMENT_EFFECTIVE_ACCESS;
GO
CREATE VIEW dbo.MANAGEMENT_EFFECTIVE_ACCESS AS
SELECT
    u.id        AS user_id,
    p.id        AS page_id,
    p.code      AS page_code,
    p.module_id AS module_id,
    CAST(COALESCE(o.can_read,   a.can_read,   0) AS BIT) AS can_read,
    CAST(COALESCE(o.can_write,  a.can_write,  0) AS BIT) AS can_write,
    CAST(COALESCE(o.can_delete, a.can_delete, 0) AS BIT) AS can_delete,
    CAST(COALESCE(o.can_admin,  a.can_admin,  0) AS BIT) AS can_admin
FROM dbo.MANAGEMENT_USERS u
CROSS JOIN dbo.MANAGEMENT_PAGES p
LEFT JOIN dbo.MANAGEMENT_ACCESS a
       ON a.type_user_id = u.type_user_id AND a.page_id = p.id AND a.deleted_at IS NULL
LEFT JOIN dbo.MANAGEMENT_USER_ACCESS_OVERRIDE o
       ON o.user_id = u.id AND o.page_id = p.id AND o.deleted_at IS NULL
WHERE u.deleted_at IS NULL AND p.deleted_at IS NULL;
GO
/* ---- 2.5 MODULO FARM ---- */
/* =====================================================================
   GCS_FARM  |  Banco MASTER (dados tratados)  |  SQL Server (T-SQL)
   Modulo: FARM (cadastro de fazendas, glebas e talhoes)
   Gerado em: 2026-06-17

   Hierarquia: FARM_FARMS (fazenda) -> FARM_PLOTS (gleba/zona) -> FARM_FIELDS (talhao)

   Convencao:
     - Identificadores em INGLES; documentacao (comentarios) em PORTUGUES.
     - Schema dbo; prefixo FARM_.
     - Auditoria padrao em todas as tabelas: created_at, updated_at, deleted_at.
     - Apenas PK e FK NOT NULL; demais colunas NULL. Uniques anulaveis = indice
       unico filtrado (WHERE coluna IS NOT NULL).
     - Codigos externos (Solinftec, etc.) NAO ficam mais aqui: centralizados em
       dbo.CONFIG_CONNECTORS (de/para por conector). O ETL resolve a entidade
       via CONFIG_CONNECTORS (ex.: type='solinftec', code=CD_TALHAO -> field_id).
   ===================================================================== */

-- USE GCS_FARM;
-- GO

/* =====================================================================
   1) FARM_FARMS  -- fazendas
   ===================================================================== */
IF OBJECT_ID('dbo.FARM_FARMS') IS NOT NULL DROP TABLE dbo.FARM_FARMS;
GO
CREATE TABLE dbo.FARM_FARMS (
    id                   BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARM_FARMS PRIMARY KEY,
    code                 VARCHAR(40)   NULL,            -- codigo interno
    name                 NVARCHAR(150) NULL,
    city                 VARCHAR(120)  NULL,
    state                CHAR(2)       NULL,            -- UF
    total_area_hectares  DECIMAL(14,4) NULL,
    active               BIT           NULL CONSTRAINT DF_FARM_FARMS_active DEFAULT 1,
    created_at           DATETIME2(3)  NULL CONSTRAINT DF_FARM_FARMS_created DEFAULT SYSUTCDATETIME(),
    updated_at           DATETIME2(3)  NULL,
    deleted_at           DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_FARM_FARMS_code ON dbo.FARM_FARMS (code) WHERE code IS NOT NULL;
GO

/* =====================================================================
   2) FARM_PLOTS  -- glebas / zonas (recebe farm_id)
   ===================================================================== */
-- FARM_PLOT_ROTATION (módulo Planejamento/Rotação) tem FK p/ FARM_PLOTS —
-- dropar ele, o filho e as views ANTES de FARM_PLOTS p/ liberar a FK no re-run.
IF OBJECT_ID('dbo.VW_FARM_ROTATION_DEVIATION') IS NOT NULL DROP VIEW  dbo.VW_FARM_ROTATION_DEVIATION;
IF OBJECT_ID('dbo.VW_FARM_PLOT_ROTATION')      IS NOT NULL DROP VIEW  dbo.VW_FARM_PLOT_ROTATION;
GO
IF OBJECT_ID('dbo.FARM_PLOT_ROTATION_CROP')    IS NOT NULL DROP TABLE dbo.FARM_PLOT_ROTATION_CROP;
IF OBJECT_ID('dbo.FARM_PLOT_ROTATION')         IS NOT NULL DROP TABLE dbo.FARM_PLOT_ROTATION;
GO
IF OBJECT_ID('dbo.FARM_PLOTS') IS NOT NULL DROP TABLE dbo.FARM_PLOTS;
GO
CREATE TABLE dbo.FARM_PLOTS (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARM_PLOTS PRIMARY KEY,
    farm_id         BIGINT        NOT NULL,             -- FK
    code            VARCHAR(40)   NULL,
    name            NVARCHAR(150) NULL,
    area_hectares   DECIMAL(14,4) NULL,
    active          BIT           NULL CONSTRAINT DF_FARM_PLOTS_active DEFAULT 1,
    created_at      DATETIME2(3)  NULL CONSTRAINT DF_FARM_PLOTS_created DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)  NULL,
    deleted_at      DATETIME2(3)  NULL,
    CONSTRAINT FK_FARM_PLOTS_farm FOREIGN KEY (farm_id) REFERENCES dbo.FARM_FARMS(id)
);
GO
CREATE UNIQUE INDEX UX_FARM_PLOTS_farm_code ON dbo.FARM_PLOTS (farm_id, code) WHERE code IS NOT NULL;
CREATE INDEX        IX_FARM_PLOTS_farm      ON dbo.FARM_PLOTS (farm_id);
GO

/* =====================================================================
   3) FARM_FIELDS  -- talhoes (recebe plot_id)
   ===================================================================== */
-- FARM_FIELD_PLANTING (módulo Planejamento, criado depois) tem FK p/ FARM_FIELDS —
-- dropar ele e suas views ANTES de FARM_FIELDS para o re-run liberar a FK.
IF OBJECT_ID('dbo.VW_FARMBOX_HARVEST_UNMAPPED') IS NOT NULL DROP VIEW  dbo.VW_FARMBOX_HARVEST_UNMAPPED;
IF OBJECT_ID('dbo.VW_FARM_FIELD_PLANTING')      IS NOT NULL DROP VIEW  dbo.VW_FARM_FIELD_PLANTING;
GO
IF OBJECT_ID('dbo.FARM_PLANTING_REVIEW')        IS NOT NULL DROP TABLE dbo.FARM_PLANTING_REVIEW;  -- FK p/ FARM_FIELD_PLANTING
IF OBJECT_ID('dbo.FARM_FIELD_PLANTING')         IS NOT NULL DROP TABLE dbo.FARM_FIELD_PLANTING;
IF OBJECT_ID('dbo.FARM_FIELD_ROTATION')         IS NOT NULL DROP TABLE dbo.FARM_FIELD_ROTATION;  -- FK p/ FARM_FIELDS
IF OBJECT_ID('dbo.FERT_AMENDMENT_APPLICATION')  IS NOT NULL DROP TABLE dbo.FERT_AMENDMENT_APPLICATION;  -- FK p/ FARM_FIELDS + FARM_SEASON
GO
IF OBJECT_ID('dbo.FARM_FIELDS') IS NOT NULL DROP TABLE dbo.FARM_FIELDS;
GO
CREATE TABLE dbo.FARM_FIELDS (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARM_FIELDS PRIMARY KEY,
    plot_id         BIGINT        NOT NULL,             -- FK
    code            VARCHAR(40)   NULL,
    name            NVARCHAR(150) NULL,                 -- DESC_TALHAO
    area_hectares   DECIMAL(14,4) NULL,
    active          BIT           NULL CONSTRAINT DF_FARM_FIELDS_active DEFAULT 1,
    created_at      DATETIME2(3)  NULL CONSTRAINT DF_FARM_FIELDS_created DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)  NULL,
    deleted_at      DATETIME2(3)  NULL,
    CONSTRAINT FK_FARM_FIELDS_plot FOREIGN KEY (plot_id) REFERENCES dbo.FARM_PLOTS(id)
);
GO
CREATE UNIQUE INDEX UX_FARM_FIELDS_plot_code ON dbo.FARM_FIELDS (plot_id, code) WHERE code IS NOT NULL;
CREATE INDEX        IX_FARM_FIELDS_plot      ON dbo.FARM_FIELDS (plot_id);
GO

/* =====================================================================
   FK pendente do modulo MANAGEMENT: agora que FARM_FARMS existe,
   ligar MANAGEMENT_USER_FARM.farm_id -> FARM_FARMS.id.
   ===================================================================== */
IF OBJECT_ID('dbo.MANAGEMENT_USER_FARM') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_MANAGEMENT_USER_FARM_farm')
   EXEC('ALTER TABLE dbo.MANAGEMENT_USER_FARM
         ADD CONSTRAINT FK_MANAGEMENT_USER_FARM_farm
         FOREIGN KEY (farm_id) REFERENCES dbo.FARM_FARMS(id);');
GO

/* =====================================================================
   NOTAS
   - Vinculo com conectores (Solinftec, etc.) fica em dbo.CONFIG_CONNECTORS.
     Ex.: resolver talhao do Solinftec ->
       SELECT field_id FROM dbo.CONFIG_CONNECTORS
       WHERE type = 'solinftec' AND code = @CD_TALHAO AND deleted_at IS NULL;
   - Geometria/contorno (shapefile) e coordenadas entram depois, junto da
     telemetria GPS propria.
   ===================================================================== */

/* ---- 2.6 FARM_FIELD_GEOMETRY (geoespacial) ---- */
/* =====================================================================
   GCS_FARM (ou PIMS_TST)  |  Extensao geoespacial do modulo FARM
   Tabela: dbo.FARM_FIELD_GEOMETRY  |  SQL Server (T-SQL)
   Gerado em: 2026-06-17

   Objetivo: guardar o poligono (contorno) dos talhoes para exibir no
   frontend (MapLibre GL JS). Upload de shapefile/KML feito no backend,
   que reprojeta para WGS84 e grava aqui.

   Decisoes:
     - Geometria nativa GEOGRAPHY (SRID 4326) -> area real, indice espacial.
     - Tabela SEPARADA do FARM_FIELDS, 1:N, com HISTORICO (varias versoes do
       contorno por talhao; a vigente tem is_current = 1).
     - GeoJSON nao e armazenado: a API converte geography -> GeoJSON na leitura
       (SQL Server nao tem saida nativa de GeoJSON).

   Rodar DEPOIS de dbo.FARM_FIELDS existir.
   ===================================================================== */

-- USE PIMS_TST;  (ou GCS_FARM)
-- GO

IF OBJECT_ID('dbo.FARM_FIELD_GEOMETRY') IS NOT NULL DROP TABLE dbo.FARM_FIELD_GEOMETRY;
GO
CREATE TABLE dbo.FARM_FIELD_GEOMETRY (
    id               BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARM_FIELD_GEOMETRY PRIMARY KEY,
    field_id         BIGINT        NOT NULL,            -- FK -> FARM_FIELDS
    geom             GEOGRAPHY     NOT NULL,            -- poligono / multipoligono (SRID 4326)
    area_hectares    DECIMAL(18,4) NULL,                -- geom.STArea()/10000 (calculado na carga)
    source_format    VARCHAR(15)   NULL,                -- SHAPEFILE | KML | GEOJSON
    source_srid      INT           NULL,                -- SRID original do arquivo (se conhecido)
    source_filename  NVARCHAR(255) NULL,
    version          INT           NULL,                -- numero da versao do contorno
    is_current       BIT           NULL CONSTRAINT DF_FFG_current DEFAULT 1,  -- contorno vigente
    created_at       DATETIME2(3)  NULL CONSTRAINT DF_FFG_created DEFAULT SYSUTCDATETIME(),
    updated_at       DATETIME2(3)  NULL,
    deleted_at       DATETIME2(3)  NULL,
    CONSTRAINT FK_FARM_FIELD_GEOMETRY_field FOREIGN KEY (field_id) REFERENCES dbo.FARM_FIELDS(id),
    CONSTRAINT CK_FFG_format CHECK (source_format IS NULL OR source_format IN ('SHAPEFILE','KML','GEOJSON'))
);
GO

-- Um unico contorno VIGENTE por talhao
CREATE UNIQUE INDEX UX_FFG_field_current
    ON dbo.FARM_FIELD_GEOMETRY (field_id)
    WHERE is_current = 1 AND deleted_at IS NULL;
GO

-- Busca por talhao
CREATE INDEX IX_FFG_field ON dbo.FARM_FIELD_GEOMETRY (field_id);
GO

-- Indice ESPACIAL (consultas de area / contem / intersecta no mapa)
CREATE SPATIAL INDEX SIX_FARM_FIELD_GEOMETRY
    ON dbo.FARM_FIELD_GEOMETRY (geom)
    USING GEOGRAPHY_AUTO_GRID;
GO

/* =====================================================================
   NOTAS DE USO (o backend faz isto; aqui so para referencia)
   -------------------------------------------------------------------
   -- Inserir contorno (WKT vindo do parse, ja em 4326). Corrige orientacao
   -- de anel invertido (geography rejeita poligono "maior que a Terra"):
   --   DECLARE @g geography = geography::STGeomFromText(@wkt, 4326);
   --   IF @g.STArea() > 1e12 SET @g = @g.ReorientObject();
   --   SET @g = @g.MakeValid();
   --   INSERT ... VALUES (@field, @g, @g.STArea()/10000.0, ...);

   -- Ler como WKT (a API converte para GeoJSON):
   --   SELECT geom.STAsText() AS wkt, area_hectares
   --   FROM dbo.FARM_FIELD_GEOMETRY WHERE field_id=@f AND is_current=1;

   -- Coordenadas em WKT do geography: ordem (longitude latitude) = [x,y],
   -- compativel com GeoJSON. Nao precisa inverter.
   ===================================================================== */

/* ---- 2.7 MODULO MACHINE_OPERATION ---- */
/* =====================================================================
   GCS_FARM  |  Banco MASTER (dados tratados)  |  SQL Server (T-SQL)
   Modulo: MACHINE_OPERATION (operacoes de maquinas - dado computado)
   Origem: CONNECTOR_GCS_FARM.dbo.SOLINFTEC_OPERATION (API 22) via ETL
   Gerado em: 2026-06-17

   Convencao:
     - Identificadores em INGLES; documentacao em PORTUGUES.
     - Schema dbo; prefixo MACHINE_OPERATION_.
     - Auditoria padrao: created_at, updated_at, deleted_at.
     - Apenas PK e FK NOT NULL; demais NULL. FKs anulaveis sao excecoes
       conscientes (operador/talhao/operacao/parada podem faltar).
     - raw_record_id (CD_ID) e a chave de negocio para idempotencia do ETL.

   Dimensoes minimas: equipment, operator, operation, stop_reason.
   Motivo de parada: a API 22 traz apenas o codigo (CD_OPERACAO_PARADA);
   a descricao vem do cadastro "Apontamento de paradas" (export Solinftec),
   carregado em MACHINE_OPERATION_STOP_REASON.
   ===================================================================== */

-- USE GCS_FARM;
-- GO

/* ----- DIMENSOES MINIMAS ----- */

IF OBJECT_ID('dbo.MACHINE_OPERATION_EQUIPMENT') IS NOT NULL DROP TABLE dbo.MACHINE_OPERATION_EQUIPMENT;
GO
CREATE TABLE dbo.MACHINE_OPERATION_EQUIPMENT (
    id          BIGINT        IDENTITY(1,1) CONSTRAINT PK_MACHINE_OPERATION_EQUIPMENT PRIMARY KEY,
    code        VARCHAR(20)   NULL,            -- CD_EQUIPAMENTO
    name        NVARCHAR(150) NULL,            -- DESC_EQUIPAMENTO
    group_code  VARCHAR(20)   NULL,            -- CD_GRUPO_EQUIPAMENTO
    group_name  NVARCHAR(150) NULL,            -- DESC_GRUPO_EQUIPAMENTO
    active      BIT           NULL CONSTRAINT DF_MO_EQUIP_active DEFAULT 1,
    created_at  DATETIME2(3)  NULL CONSTRAINT DF_MO_EQUIP_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3)  NULL,
    deleted_at  DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_MO_EQUIP_code ON dbo.MACHINE_OPERATION_EQUIPMENT (code) WHERE code IS NOT NULL;
GO

IF OBJECT_ID('dbo.MACHINE_OPERATION_OPERATOR') IS NOT NULL DROP TABLE dbo.MACHINE_OPERATION_OPERATOR;
GO
CREATE TABLE dbo.MACHINE_OPERATION_OPERATOR (
    id          BIGINT        IDENTITY(1,1) CONSTRAINT PK_MACHINE_OPERATION_OPERATOR PRIMARY KEY,
    code        VARCHAR(20)   NULL,            -- CD_OPERADOR
    name        NVARCHAR(150) NULL,
    person_id   BIGINT        NULL,            -- id logico -> MANAGEMENT_PEOPLES (futuro RH)
    active      BIT           NULL CONSTRAINT DF_MO_OPER_active DEFAULT 1,
    created_at  DATETIME2(3)  NULL CONSTRAINT DF_MO_OPER_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3)  NULL,
    deleted_at  DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_MO_OPER_code ON dbo.MACHINE_OPERATION_OPERATOR (code) WHERE code IS NOT NULL;
GO

IF OBJECT_ID('dbo.MACHINE_OPERATION_OPERATION') IS NOT NULL DROP TABLE dbo.MACHINE_OPERATION_OPERATION;
GO
CREATE TABLE dbo.MACHINE_OPERATION_OPERATION (
    id             BIGINT        IDENTITY(1,1) CONSTRAINT PK_MACHINE_OPERATION_OPERATION PRIMARY KEY,
    code           VARCHAR(20)   NULL,         -- CD_OPERACAO
    cb_code        VARCHAR(20)   NULL,         -- CD_OPERACAO_CB
    description    NVARCHAR(150) NULL,
    operation_type CHAR(1)       NULL,         -- FG_TIPO_OPERACAO: P|A|I|S
    active         BIT           NULL CONSTRAINT DF_MO_OP_active DEFAULT 1,
    created_at     DATETIME2(3)  NULL CONSTRAINT DF_MO_OP_created DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)  NULL,
    deleted_at     DATETIME2(3)  NULL,
    CONSTRAINT CK_MO_OP_type CHECK (operation_type IS NULL OR operation_type IN ('P','A','I','S'))
);
GO
CREATE UNIQUE INDEX UX_MO_OP_code ON dbo.MACHINE_OPERATION_OPERATION (code) WHERE code IS NOT NULL;
GO

-- NOVO: dimensao de motivo de parada (cadastro "Apontamento de paradas")
IF OBJECT_ID('dbo.MACHINE_OPERATION_STOP_REASON') IS NOT NULL DROP TABLE dbo.MACHINE_OPERATION_STOP_REASON;
GO
CREATE TABLE dbo.MACHINE_OPERATION_STOP_REASON (
    id           BIGINT        IDENTITY(1,1) CONSTRAINT PK_MACHINE_OPERATION_STOP_REASON PRIMARY KEY,
    code         VARCHAR(20)   NULL,          -- CD_OPERACAO_PARADA
    description  NVARCHAR(150) NULL,          -- descricao do cadastro de paradas
    category     VARCHAR(30)   NULL,          -- MECHANICAL | OPERATIONAL | CLIMATE | OTHER (enriquecido)
    active       BIT           NULL CONSTRAINT DF_MO_STOP_active DEFAULT 1,
    created_at   DATETIME2(3)  NULL CONSTRAINT DF_MO_STOP_created DEFAULT SYSUTCDATETIME(),
    updated_at   DATETIME2(3)  NULL,
    deleted_at   DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_MO_STOP_code ON dbo.MACHINE_OPERATION_STOP_REASON (code) WHERE code IS NOT NULL;
GO

/* ----- FATO DETALHADO (1 linha por apontamento) ----- */
IF OBJECT_ID('dbo.MACHINE_OPERATION_FACT') IS NOT NULL DROP TABLE dbo.MACHINE_OPERATION_FACT;
GO
CREATE TABLE dbo.MACHINE_OPERATION_FACT (
    id                  BIGINT        IDENTITY(1,1) CONSTRAINT PK_MACHINE_OPERATION_FACT PRIMARY KEY,
    raw_record_id       BIGINT        NOT NULL,        -- CD_ID (chave de negocio / idempotencia)
    movement_date       DATE          NULL,            -- DT_MOVIMENTACAO

    -- vinculos (FK). field_id/operator_id/operation_id/stop_reason_id anulaveis.
    field_id            BIGINT        NULL,            -- -> FARM_FIELDS (resolvido via CONFIG_CONNECTORS)
    equipment_id        BIGINT        NOT NULL,        -- -> MACHINE_OPERATION_EQUIPMENT
    operator_id         BIGINT        NULL,            -- -> MACHINE_OPERATION_OPERATOR
    operation_id        BIGINT        NULL,            -- -> MACHINE_OPERATION_OPERATION
    operation_type      CHAR(1)       NULL,            -- FG_TIPO_OPERACAO (copia p/ consulta)
    stop_reason_id      BIGINT        NULL,            -- -> MACHINE_OPERATION_STOP_REASON (so paradas)

    -- contexto operacional (codigos do Solinftec, mantidos para rastreio)
    order_service_code  VARCHAR(30)   NULL,            -- CD_ORDEM_SERVICO
    journey_code        VARCHAR(30)   NULL,            -- CD_JORNADA
    unit_code           VARCHAR(20)   NULL,            -- CD_UNIDADE
    corporate_code      VARCHAR(20)   NULL,            -- CD_CORPORATIVO
    team_code           VARCHAR(20)   NULL,            -- CD_EQUIPE
    implement_code      VARCHAR(20)   NULL,            -- CD_IMPLEMENTO
    journey_start       DATETIME2(3)  NULL,            -- DT_HR_INI_JORNADA
    journey_end         DATETIME2(3)  NULL,            -- DT_HR_FIM_JORNADA
    record_start        DATETIME2(3)  NULL,            -- DT_HR_INI_REGNAJORNADA

    -- metricas
    time_seconds        DECIMAL(12,2) NULL,            -- VL_TEMPO_SEGUNDOS (tempo do segmento / parada)
    engine_on_seconds   DECIMAL(12,2) NULL,            -- VL_TEMPO_MOTOR_LIGADO
    engine_idle_seconds DECIMAL(12,2) NULL,            -- VL_TEMPO_MOTOR_OCIOSO
    hourmeter_start     DECIMAL(12,2) NULL,            -- VL_HORIMETRO_INICIAL
    hourmeter_end       DECIMAL(12,2) NULL,            -- VL_HORIMETRO_FINAL
    area_hectares       DECIMAL(14,6) NULL,            -- VL_AREA_HECTARES_EQUIPAMENTO
    fuel_liters         DECIMAL(12,3) NULL,            -- VL_CONSUMO (-1 -> NULL no ETL)
    avg_speed           DECIMAL(8,2)  NULL,            -- VL_VELOCIDADE_MEDIA
    avg_rpm             DECIMAL(8,2)  NULL,            -- VL_RPM_MEDIO

    created_at          DATETIME2(3)  NULL CONSTRAINT DF_MO_FACT_created DEFAULT SYSUTCDATETIME(),
    updated_at          DATETIME2(3)  NULL,
    deleted_at          DATETIME2(3)  NULL,

    CONSTRAINT UQ_MO_FACT_raw  UNIQUE (raw_record_id),
    CONSTRAINT FK_MO_FACT_field     FOREIGN KEY (field_id)       REFERENCES dbo.FARM_FIELDS(id),
    CONSTRAINT FK_MO_FACT_equipment FOREIGN KEY (equipment_id)   REFERENCES dbo.MACHINE_OPERATION_EQUIPMENT(id),
    CONSTRAINT FK_MO_FACT_operator  FOREIGN KEY (operator_id)    REFERENCES dbo.MACHINE_OPERATION_OPERATOR(id),
    CONSTRAINT FK_MO_FACT_operation FOREIGN KEY (operation_id)   REFERENCES dbo.MACHINE_OPERATION_OPERATION(id),
    CONSTRAINT FK_MO_FACT_stop      FOREIGN KEY (stop_reason_id) REFERENCES dbo.MACHINE_OPERATION_STOP_REASON(id)
);
GO
CREATE INDEX IX_MO_FACT_date       ON dbo.MACHINE_OPERATION_FACT (movement_date);
CREATE INDEX IX_MO_FACT_equip_date ON dbo.MACHINE_OPERATION_FACT (equipment_id, movement_date) INCLUDE (area_hectares);
CREATE INDEX IX_MO_FACT_field      ON dbo.MACHINE_OPERATION_FACT (field_id) WHERE field_id IS NOT NULL;
-- consultas das 6 perguntas (SUM de ha)
CREATE INDEX IX_MO_FACT_operation_date ON dbo.MACHINE_OPERATION_FACT (operation_id, movement_date)
    INCLUDE (area_hectares, field_id, operator_id, equipment_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_MO_FACT_operator_date  ON dbo.MACHINE_OPERATION_FACT (operator_id, movement_date)
    INCLUDE (area_hectares, field_id, operation_id, equipment_id) WHERE deleted_at IS NULL;
-- Pareto de paradas (tempo por motivo)
CREATE INDEX IX_MO_FACT_stop_date ON dbo.MACHINE_OPERATION_FACT (stop_reason_id, movement_date)
    INCLUDE (time_seconds) WHERE stop_reason_id IS NOT NULL AND deleted_at IS NULL;
GO

/* ----- VIEW DE RESUMO: por maquina e dia ----- */
IF OBJECT_ID('dbo.MACHINE_OPERATION_SUMMARY') IS NOT NULL DROP VIEW dbo.MACHINE_OPERATION_SUMMARY;
GO
CREATE VIEW dbo.MACHINE_OPERATION_SUMMARY AS
SELECT
    f.equipment_id,
    e.code                         AS equipment_code,
    e.name                         AS equipment_name,
    f.movement_date,
    SUM(f.time_seconds)            AS total_time_seconds,
    SUM(f.engine_on_seconds)       AS total_engine_on_seconds,
    SUM(f.engine_idle_seconds)     AS total_engine_idle_seconds,
    SUM(CASE WHEN f.stop_reason_id IS NOT NULL THEN f.time_seconds END) AS total_stop_seconds,
    SUM(f.area_hectares)           AS total_area_hectares,
    SUM(f.fuel_liters)             AS total_fuel_liters,
    CASE WHEN SUM(f.time_seconds) > 0
         THEN SUM(f.avg_speed * f.time_seconds) / SUM(f.time_seconds) END AS avg_speed_weighted,
    MIN(f.hourmeter_start)         AS hourmeter_start,
    MAX(f.hourmeter_end)           AS hourmeter_end
FROM dbo.MACHINE_OPERATION_FACT f
LEFT JOIN dbo.MACHINE_OPERATION_EQUIPMENT e ON e.id = f.equipment_id
WHERE f.deleted_at IS NULL
GROUP BY f.equipment_id, e.code, e.name, f.movement_date;
GO

/* =====================================================================
   EXEMPLO — PARETO DE PARADAS (tempo perdido por motivo no periodo)
   -------------------------------------------------------------------
   SELECT sr.code, sr.description, sr.category,
          SUM(f.time_seconds) / 3600.0 AS horas_paradas,
          COUNT(*)                     AS ocorrencias
   FROM dbo.MACHINE_OPERATION_FACT f
   JOIN dbo.MACHINE_OPERATION_STOP_REASON sr ON sr.id = f.stop_reason_id
   WHERE f.stop_reason_id IS NOT NULL
     AND f.movement_date >= @date_start AND f.movement_date <= @date_end
     AND f.deleted_at IS NULL
   GROUP BY sr.code, sr.description, sr.category
   ORDER BY horas_paradas DESC;

   -- Por maquina, basta adicionar f.equipment_id ao WHERE/GROUP BY.

   NOTAS
   - Parada = linha com stop_reason_id IS NOT NULL (FG_TIPO_OPERACAO = 'I').
   - O tempo da parada e o proprio time_seconds da linha.
   - fuel_liters: ETL converte VL_CONSUMO = -1 (sem leitura) em NULL.
   - field_id NULL = talhao nao mapeado; operator_id NULL = parada sem operador.
   ===================================================================== */

/* ---- 2.8 MODULO WEATHER ---- */
/* =====================================================================
   GCS_FARM  |  Banco MASTER (dados tratados)  |  SQL Server (T-SQL)
   Modulo: WEATHER (meteorologia - dado computado)
   Origem: CONNECTOR_GCS_FARM.dbo.SOLINFTEC_WEATHER (API 21) via ETL
   Gerado em: 2026-06-17

   Convencao:
     - Identificadores em INGLES; documentacao em PORTUGUES.
     - Schema dbo; prefixo WEATHER_.
     - Auditoria padrao: created_at, updated_at, deleted_at.
     - Apenas PK e FK NOT NULL; demais NULL.
     - Estacoes completas e pluviometros na MESMA tabela de leitura
       (campos nao medidos ficam NULL — ex.: pluviometro so tem chuva/folha).
   ===================================================================== */

-- USE GCS_FARM;
-- GO

/* ----- DIMENSAO: estacao / pluviometro ----- */
IF OBJECT_ID('dbo.WEATHER_STATION') IS NOT NULL DROP TABLE dbo.WEATHER_STATION;
GO
-- Sensor "solteiro": apenas um PONTO (lat/long). NÃO há vínculo estação→talhão/fazenda
-- (o clima por talhão vem do grid IDW FIELD_WEATHER_HOURLY). Por isso não existem mais
-- as colunas field_id/farm_id aqui (removidas em 2026-06-28 p/ encerrar o legado).
CREATE TABLE dbo.WEATHER_STATION (
    id            BIGINT        IDENTITY(1,1) CONSTRAINT PK_WEATHER_STATION PRIMARY KEY,
    code          VARCHAR(20)   NULL,          -- CDEQUIPAMENTO
    name          NVARCHAR(150) NULL,
    station_type  VARCHAR(15)   NULL,          -- STATION (completa) | PLUVIOMETER (so chuva/folha)
    active        BIT           NULL CONSTRAINT DF_WEATHER_STATION_active DEFAULT 1,
    created_at    DATETIME2(3)  NULL CONSTRAINT DF_WEATHER_STATION_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3)  NULL,
    deleted_at    DATETIME2(3)  NULL,
    -- Geolocalizacao da estacao (promovida do cadastro pelo ETL).
    latitude      DECIMAL(9,6)  NULL,          -- grau decimal (WGS84)
    longitude     DECIMAL(9,6)  NULL,          -- grau decimal (WGS84)
    geom          GEOGRAPHY     NULL,          -- ponto (SRID 4326) p/ o mapa
    CONSTRAINT CK_WEATHER_STATION_type CHECK (station_type IS NULL OR station_type IN ('STATION','PLUVIOMETER'))
);
GO
CREATE UNIQUE INDEX UX_WEATHER_STATION_code ON dbo.WEATHER_STATION (code) WHERE code IS NOT NULL;
GO
-- Indice espacial p/ consultas geograficas (heatmaps de meteorologia, estacao->talhao).
CREATE SPATIAL INDEX SIX_WEATHER_STATION_geom ON dbo.WEATHER_STATION (geom)
    USING GEOGRAPHY_AUTO_GRID;
GO

/* ----- LEITURA HORARIA (1 linha por estacao + hora) ----- */
IF OBJECT_ID('dbo.WEATHER_READING') IS NOT NULL DROP TABLE dbo.WEATHER_READING;
GO
CREATE TABLE dbo.WEATHER_READING (
    id                  BIGINT        IDENTITY(1,1) CONSTRAINT PK_WEATHER_READING PRIMARY KEY,
    raw_record_id       BIGINT        NOT NULL,      -- CDID (idempotencia do ETL)
    station_id          BIGINT        NOT NULL,      -- -> WEATHER_STATION
    local_datetime      DATETIME2(3)  NULL,          -- DTHRLOCAL
    reference_date      DATE          NULL,          -- dia (derivado, p/ filtro)

    -- medias horarias
    wind_direction      DECIMAL(6,2)  NULL,          -- VLDIRECAOVENTO
    wind_speed          DECIMAL(8,2)  NULL,          -- VLVELOCIDADEVENTO
    wind_speed_max      DECIMAL(8,2)  NULL,          -- VLMAXVELOCIDADEVENTO
    temperature         DECIMAL(6,2)  NULL,          -- VLTEMPERATURA
    humidity            DECIMAL(6,2)  NULL,          -- VLUMIDADE
    solar_radiation     DECIMAL(10,2) NULL,          -- VLRADIACAOSOLAR
    dew_point           DECIMAL(6,2)  NULL,          -- VLPONTOORVALHO
    atm_pressure        DECIMAL(8,2)  NULL,          -- VLPRESSAOATMOSFERICA
    rainfall            DECIMAL(8,2)  NULL,          -- VLCHUVA
    leaf_wetness_pct    DECIMAL(6,2)  NULL,          -- PCFOLHAMOLHADA

    -- minimas da hora
    min_wind_direction  DECIMAL(6,2)  NULL,
    min_wind_speed      DECIMAL(8,2)  NULL,
    min_temperature     DECIMAL(6,2)  NULL,
    min_humidity        DECIMAL(6,2)  NULL,
    min_solar_radiation DECIMAL(10,2) NULL,
    min_dew_point       DECIMAL(6,2)  NULL,
    min_atm_pressure    DECIMAL(8,2)  NULL,

    -- maximas da hora
    max_wind_direction  DECIMAL(6,2)  NULL,
    max_wind_speed      DECIMAL(8,2)  NULL,
    max_temperature     DECIMAL(6,2)  NULL,
    max_humidity        DECIMAL(6,2)  NULL,
    max_solar_radiation DECIMAL(10,2) NULL,
    max_dew_point       DECIMAL(6,2)  NULL,
    max_atm_pressure    DECIMAL(8,2)  NULL,

    created_at          DATETIME2(3)  NULL CONSTRAINT DF_WEATHER_READING_created DEFAULT SYSUTCDATETIME(),
    updated_at          DATETIME2(3)  NULL,
    deleted_at          DATETIME2(3)  NULL,

    CONSTRAINT UQ_WEATHER_READING_raw   UNIQUE (raw_record_id),
    CONSTRAINT UQ_WEATHER_READING_point UNIQUE (station_id, local_datetime),
    CONSTRAINT FK_WEATHER_READING_station FOREIGN KEY (station_id) REFERENCES dbo.WEATHER_STATION(id)
);
GO
CREATE INDEX IX_WEATHER_READING_date         ON dbo.WEATHER_READING (reference_date);
CREATE INDEX IX_WEATHER_READING_station_date ON dbo.WEATHER_READING (station_id, reference_date);
GO

/* ─── FIELD_WEATHER_HOURLY — clima interpolado (IDW) por talhão × hora ─────
   Dado bruto "quanto de cada grandeza teve cada talhão em cada dia e hora":
   derivado dos pontos dos sensores (WEATHER_STATION) por IDW (peso 1/d^2.4)
   amostrado no CENTROIDE do talhão — idêntico ao que o front desenha. Fonte da
   verdade p/ KPIs/relatórios, mapa de calor e cruzamento com a telemetria das
   máquinas (datada). O diário sai por agregação (chuva soma; vento máx por MAX;
   demais média). Recalculado pelo ETL (weatherGrid.service →
   recomputeFieldWeatherHourly), idempotente por (field_id, obs_date, obs_hour). */
IF OBJECT_ID('dbo.FIELD_WEATHER_HOURLY') IS NOT NULL DROP TABLE dbo.FIELD_WEATHER_HOURLY;
GO
CREATE TABLE dbo.FIELD_WEATHER_HOURLY (
    field_id         BIGINT        NOT NULL,              -- -> FARM_FIELDS
    obs_date         DATE          NOT NULL,              -- dia
    obs_hour         TINYINT       NOT NULL,              -- hora 0..23
    rain_mm          DECIMAL(9,4)  NULL,                  -- chuva (mm) — todos os sensores
    temp_c           DECIMAL(9,4)  NULL,                  -- temperatura (°C) — só estações
    humidity_pct     DECIMAL(9,4)  NULL,                  -- umidade (%)
    wind_kmh         DECIMAL(9,4)  NULL,                  -- vento médio (km/h)
    wind_max_kmh     DECIMAL(9,4)  NULL,                  -- vento máx (km/h)
    solar_radiation  DECIMAL(9,4)  NULL,                  -- radiação (W/m²)
    dew_point_c      DECIMAL(9,4)  NULL,                  -- ponto de orvalho (°C)
    atm_pressure     DECIMAL(9,4)  NULL,                  -- pressão (hPa)
    leaf_wetness_pct DECIMAL(9,4)  NULL,                  -- folha molhada (%)
    computed_at      DATETIME2(3)  NOT NULL CONSTRAINT DF_FWH_computed DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_FIELD_WEATHER_HOURLY PRIMARY KEY (field_id, obs_date, obs_hour),
    CONSTRAINT FK_FWH_field FOREIGN KEY (field_id) REFERENCES dbo.FARM_FIELDS(id)
);
CREATE INDEX IX_FWH_date ON dbo.FIELD_WEATHER_HOURLY (obs_date);
GO

/* ─── FIELD_WEATHER_COVERAGE — confiança por talhão × métrica ──────────────
   Distância ao sensor mais próximo que MEDE cada métrica (+ nº de sensores).
   Constante no tempo (sensores fixos); recalculada junto do grid. Chuva = grid
   denso (~todos os sensores); temp/umidade/etc. = grid ralo (só as estações). */
IF OBJECT_ID('dbo.FIELD_WEATHER_COVERAGE') IS NOT NULL DROP TABLE dbo.FIELD_WEATHER_COVERAGE;
GO
CREATE TABLE dbo.FIELD_WEATHER_COVERAGE (
    field_id      BIGINT        NOT NULL,                 -- -> FARM_FIELDS
    metric        VARCHAR(24)   NOT NULL,                 -- rain_mm, temp_c, ...
    confidence_km DECIMAL(8,2)  NULL,                     -- distância ao sensor mais próximo
    station_count INT           NULL,                     -- nº de sensores que medem a métrica
    computed_at   DATETIME2(3)  NOT NULL CONSTRAINT DF_FWC_computed DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_FIELD_WEATHER_COVERAGE PRIMARY KEY (field_id, metric),
    CONSTRAINT FK_FWC_field FOREIGN KEY (field_id) REFERENCES dbo.FARM_FIELDS(id)
);
GO

/* =====================================================================
   NOTAS
   - station_type distingue estacao completa (4000) de pluviometro (5000).
     Pluviometro preenche tipicamente so rainfall e leaf_wetness_pct.
   - Sensor e tratado como ponto solteiro (lat/long); NAO ha mais vinculo fixo
     estacao -> talhao. O clima por talhao vem do grid IDW (FIELD_WEATHER_HOURLY).
   - field_id/farm_id em WEATHER_STATION sao legados (nao mais populados pelo ETL).
   ===================================================================== */

/* ─── 2.4 FARMBOX master ────────────────────────────────────────────── */
/* #####################################################################
   ⚠️ DEPRECADO (Fase B — 05/07/2026): o ESPELHO tipado FARMBOX_* foi
   REMOVIDO do banco GCS_FARM (29 tabelas + 4 views VW_FARMBOX_* dropadas).
   O ETL passou a ler o JSON cru DIRETO do CONNECTOR_GCS_FARM
   (JSON_VALUE/OPENJSON sobre `record`) e gravar no domínio nativo FARM_*
   — ver farmMaterialize.service.ts / MATERIALIZE_FARM.sql. Resolução de ids
   por CONFIG_CONNECTORS(code=record.plot.id) + pontes farmbox_*_id.
   → NÃO execute esta seção 2.4 num setup novo. Se for criada por engano,
     rode DROP_FARMBOX_MIRROR.sql. O domínio agronômico vivo é o
     MODULE_AGRO_V1.sql (21 tabelas FARM_*). A seção 1.3 (CONNECTOR, raw)
     PERMANECE como landing. Bloco abaixo mantido só como referência histórica.
   ##################################################################### */
USE GCS_FARM;
GO
/* =========================================================================
   FARMBOX_master_gcsfarm_mssql_v2.sql   [DEPRECADO — ver banner acima]
   Camada MASTER — Farmbox no banco GCS_FARM
   Versão  : 2.0
   Data    : 2026-06-26
   Alterações v2:
     - FARMBOX_PLANTATION: + field_id → FARM_FIELDS (via CONFIG_CONNECTORS pattern)
     - FARMBOX_MONITORING:  + field_id, recommendation, delivered, phenological_stage_name
     - FARMBOX_APPLICATION: + code, app_date, end_date, observations, responsible_name/email
     - FARMBOX_NOTE:        + latitude, longitude (geoloc da nota no campo)
     - FARMBOX_MONITORING_NOTE: tabela nova — notas com imagens de monitoring_day_results
     - TABELAS: 18 → 19

   ARQUITETURA
   ───────────
   CONNECTOR_GCS_FARM (FARMBOX_* raw) ──ETL──▶ GCS_FARM (FARMBOX_* master)

   Esta camada contém dados normalizados, tipados corretamente e deduplicados.
   Cada tabela tem uma CHAVE NATURAL (farmbox_id) + PK surrogate interna.
   O ETL usa MERGE (upsert) via farmbox_id para idempotência.

   CONVENÇÕES
   ──────────
   • farmbox_id     : id original da API (chave natural, imutável)
   • source_farm_id : farm_id Farmbox (para multi-farm queries)
   • connector_id   : FK → CONFIG_CONNECTORS (rastreabilidade)
   • etl_loaded_at  : quando este registro chegou ao master
   • etl_updated_at : última vez que o ETL atualizou este registro
   • deleted_at     : soft-delete sincronizado com a API

   SEGURANÇA
   ─────────
   Credenciais NUNCA persistidas neste banco.
   Token Farmbox decriptado da SK_CONFIG_API em memória pelo ETL.

   TABELAS (18)
   ────────────
   Referência (3) : FARMBOX_CULTURE, FARMBOX_VARIETY, FARMBOX_USER
   Estrutura  (4) : FARMBOX_FARM, FARMBOX_PLOT, FARMBOX_HARVEST, FARMBOX_PLANTATION
   Insumos    (3) : FARMBOX_INPUT, FARMBOX_MOVIMENTATION, FARMBOX_APPLICATION
   Aplicação  (2) : FARMBOX_APPLICATION_INPUT, FARMBOX_APPLICATION_PLANTATION
   Monitoring (4) : FARMBOX_MONITORING, FARMBOX_MONITORING_STOP,
                    FARMBOX_MONITORING_STOP_RESULT, FARMBOX_MONITORING_DAY_RESULT
   Campo      (2) : FARMBOX_PLUVIOMETER_MONITORING, FARMBOX_NOTE
   ========================================================================= */

/* =========================================================================
   SEÇÃO 1 — REFERÊNCIAS
   ========================================================================= */

/* ─── 1.1 FARMBOX_CULTURE ───────────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_CULTURE') IS NOT NULL DROP TABLE dbo.FARMBOX_CULTURE;
GO
CREATE TABLE dbo.FARMBOX_CULTURE (
    id              INT           IDENTITY(1,1) CONSTRAINT PK_FARMBOX_CULTURE PRIMARY KEY,
    farmbox_id      INT           NOT NULL,           -- cultures.id (INT na API)
    connector_id    INT           NOT NULL,
    name            VARCHAR(200)  NOT NULL,
    etl_loaded_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_CULTURE ON dbo.FARMBOX_CULTURE (farmbox_id) WHERE deleted_at IS NULL;
GO

/* ─── 1.2 FARMBOX_VARIETY ───────────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_VARIETY') IS NOT NULL DROP TABLE dbo.FARMBOX_VARIETY;
GO
CREATE TABLE dbo.FARMBOX_VARIETY (
    id              INT           IDENTITY(1,1) CONSTRAINT PK_FARMBOX_VARIETY PRIMARY KEY,
    farmbox_id      INT           NOT NULL,
    connector_id    INT           NOT NULL,
    culture_id      INT           NULL,               -- FK lógico → FARMBOX_CULTURE.farmbox_id
    name            VARCHAR(200)  NOT NULL,
    etl_loaded_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_VARIETY ON dbo.FARMBOX_VARIETY (farmbox_id) WHERE deleted_at IS NULL;
GO

/* ─── 1.3 FARMBOX_USER ──────────────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_USER') IS NOT NULL DROP TABLE dbo.FARMBOX_USER;
GO
CREATE TABLE dbo.FARMBOX_USER (
    id              INT           IDENTITY(1,1) CONSTRAINT PK_FARMBOX_USER PRIMARY KEY,
    farmbox_id      INT           NOT NULL,
    connector_id    INT           NOT NULL,
    uuid            VARCHAR(40)   NULL,
    name            VARCHAR(200)  NULL,
    email           VARCHAR(200)  NULL,
    role            VARCHAR(50)   NULL,
    etl_loaded_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_USER ON dbo.FARMBOX_USER (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_USER_email ON dbo.FARMBOX_USER (email) WHERE deleted_at IS NULL;
GO

/* =========================================================================
   SEÇÃO 2 — ESTRUTURA TERRITORIAL
   ========================================================================= */

/* ─── 2.1 FARMBOX_FARM ──────────────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_FARM') IS NOT NULL DROP TABLE dbo.FARMBOX_FARM;
GO
CREATE TABLE dbo.FARMBOX_FARM (
    id              INT           IDENTITY(1,1) CONSTRAINT PK_FARMBOX_FARM PRIMARY KEY,
    farmbox_id      INT           NOT NULL,           -- farms.id
    connector_id    INT           NOT NULL,
    name            VARCHAR(200)  NOT NULL,
    cnpj_cpf        VARCHAR(20)   NULL,
    city            VARCHAR(100)  NULL,
    state_uf        CHAR(2)       NULL,
    storage_id      INT           NULL,               -- farms.storage_id
    etl_loaded_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_FARM ON dbo.FARMBOX_FARM (farmbox_id) WHERE deleted_at IS NULL;
GO

/* ─── 2.2 FARMBOX_PLOT ──────────────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_PLOT') IS NOT NULL DROP TABLE dbo.FARMBOX_PLOT;
GO
CREATE TABLE dbo.FARMBOX_PLOT (
    id              INT           IDENTITY(1,1) CONSTRAINT PK_FARMBOX_PLOT PRIMARY KEY,
    farmbox_id      INT           NOT NULL,
    connector_id    INT           NOT NULL,
    farm_id         INT           NULL,               -- FK lógico → FARMBOX_FARM.farmbox_id
    name            VARCHAR(200)  NULL,
    area_ha         DECIMAL(12,4) NULL,
    geo_points      NVARCHAR(MAX) NULL,               -- JSON array de {latitude, longitude}
    api_updated_at  DATETIME2(3)  NULL,
    etl_loaded_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_PLOT_geo CHECK (geo_points IS NULL OR ISJSON(geo_points) = 1)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_PLOT ON dbo.FARMBOX_PLOT (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_PLOT_farm ON dbo.FARMBOX_PLOT (farm_id) WHERE deleted_at IS NULL;
GO

/* ─── 2.3 FARMBOX_HARVEST ───────────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_HARVEST') IS NOT NULL DROP TABLE dbo.FARMBOX_HARVEST;
GO
CREATE TABLE dbo.FARMBOX_HARVEST (
    id              INT           IDENTITY(1,1) CONSTRAINT PK_FARMBOX_HARVEST PRIMARY KEY,
    farmbox_id      INT           NOT NULL,
    connector_id    INT           NOT NULL,
    name            VARCHAR(100)  NOT NULL,           -- ex: "2025/26-1" (único por farm)
    start_date      DATE          NULL,
    end_date        DATE          NULL,
    etl_loaded_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_HARVEST ON dbo.FARMBOX_HARVEST (farmbox_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX UX_FARMBOX_HARVEST_name
    ON dbo.FARMBOX_HARVEST (connector_id, name) WHERE deleted_at IS NULL;
GO

/* ─── 2.4 FARMBOX_PLANTATION ────────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_PLANTATION') IS NOT NULL DROP TABLE dbo.FARMBOX_PLANTATION;
GO
CREATE TABLE dbo.FARMBOX_PLANTATION (
    id                    INT           IDENTITY(1,1) CONSTRAINT PK_FARMBOX_PLANTATION PRIMARY KEY,
    farmbox_id            INT           NOT NULL,
    connector_id          INT           NOT NULL,

    /* Chaves de estrutura */
    field_id              BIGINT        NULL,         -- FK → GCS_FARM.FARM_FIELDS.id (via CONFIG_CONNECTORS type='farmbox', code=plot_id)
    farm_id               INT           NULL,         -- FK lógico → FARMBOX_FARM.farmbox_id
    plot_id               INT           NULL,         -- FK lógico → FARMBOX_PLOT.farmbox_id
    harvest_id            INT           NULL,         -- FK lógico → FARMBOX_HARVEST.farmbox_id (resolvido via harvest_name)
    harvest_name          VARCHAR(100)  NULL,         -- nome original da safra (para auditoria)
    culture_id            INT           NULL,         -- FK lógico → FARMBOX_CULTURE.farmbox_id
    variety_id            INT           NULL,         -- FK lógico → FARMBOX_VARIETY.farmbox_id

    /* Dados agronômicos */
    state                 VARCHAR(20)   NULL,         -- 'active' | 'closed'
    area_ha               DECIMAL(12,4) NULL,
    cycle                 TINYINT       NULL,         -- 1=1ª safra 2=2ª safra
    irrigated             BIT           NULL,
    plantation_date       DATE          NULL,
    emergence_date        DATE          NULL,
    harvest_prediction_date DATE        NULL,
    closed_date           DATE          NULL,
    planned_date          DATETIME2(3)  NULL,         -- normalizado para UTC (Variante A)
    productivity          DECIMAL(12,4) NULL,         -- sc/ha ou similar

    api_updated_at        DATETIME2(3)  NULL,
    etl_loaded_at         DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at        DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at            DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_PLANTATION ON dbo.FARMBOX_PLANTATION (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_PLANTATION_field
    ON dbo.FARMBOX_PLANTATION (field_id) WHERE field_id IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_PLANTATION_farm
    ON dbo.FARMBOX_PLANTATION (farm_id, state) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_PLANTATION_harvest
    ON dbo.FARMBOX_PLANTATION (harvest_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_PLANTATION_plot
    ON dbo.FARMBOX_PLANTATION (plot_id) WHERE deleted_at IS NULL;
GO

/* =========================================================================
   SEÇÃO 3 — INSUMOS E ESTOQUE
   ========================================================================= */

/* ─── 3.1 FARMBOX_INPUT ─────────────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_INPUT') IS NOT NULL DROP TABLE dbo.FARMBOX_INPUT;
GO
CREATE TABLE dbo.FARMBOX_INPUT (
    id              INT           IDENTITY(1,1) CONSTRAINT PK_FARMBOX_INPUT PRIMARY KEY,
    farmbox_id      INT           NOT NULL,
    connector_id    INT           NOT NULL,
    name            VARCHAR(200)  NOT NULL,
    input_type      VARCHAR(100)  NULL,
    classification  VARCHAR(100)  NULL,               -- input_classification.name
    unit            VARCHAR(20)   NULL,
    api_updated_at  DATETIME2(3)  NULL,
    etl_loaded_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_INPUT ON dbo.FARMBOX_INPUT (farmbox_id) WHERE deleted_at IS NULL;
GO

/* ─── 3.2 FARMBOX_MOVIMENTATION ─────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_MOVIMENTATION') IS NOT NULL DROP TABLE dbo.FARMBOX_MOVIMENTATION;
GO
CREATE TABLE dbo.FARMBOX_MOVIMENTATION (
    id                  BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_MOVIMENTATION PRIMARY KEY,
    farmbox_id          BIGINT        NOT NULL,
    connector_id        INT           NOT NULL,
    input_id            INT           NULL,           -- FK → FARMBOX_INPUT.farmbox_id
    farm_id             INT           NULL,
    movimentation_type  VARCHAR(10)   NOT NULL,       -- 'in' | 'out'
    quantity            DECIMAL(14,4) NULL,
    unit                VARCHAR(20)   NULL,
    movimentation_date  DATE          NULL,
    note                NVARCHAR(500) NULL,
    etl_loaded_at       DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at      DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at          DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_MOV_type CHECK (movimentation_type IN ('in','out'))
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_MOVIMENTATION ON dbo.FARMBOX_MOVIMENTATION (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MOV_input
    ON dbo.FARMBOX_MOVIMENTATION (input_id, movimentation_date DESC) WHERE deleted_at IS NULL;
GO

/* =========================================================================
   SEÇÃO 4 — APLICAÇÕES
   ========================================================================= */

/* ─── 4.1 FARMBOX_APPLICATION ───────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_APPLICATION') IS NOT NULL DROP TABLE dbo.FARMBOX_APPLICATION;
GO
CREATE TABLE dbo.FARMBOX_APPLICATION (
    id                  BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_APPLICATION PRIMARY KEY,
    farmbox_id          BIGINT        NOT NULL,
    connector_id        INT           NOT NULL,
    farm_id             INT           NULL,
    code                VARCHAR(20)   NULL,           -- "AP18" — código humano da aplicação
    app_status          VARCHAR(30)   NULL,           -- 'finalized' | outros (confirmar lista completa)
    operation_type      VARCHAR(50)   NULL,           -- 'pulverization' | outros
    app_date            DATE          NULL,           -- application.date (data real da aplicação)
    end_date            DATE          NULL,           -- application.end_date
    start_time          TIME(0)       NULL,
    end_time            TIME(0)       NULL,
    total_area_ha       DECIMAL(12,4) NULL,
    observations        NVARCHAR(MAX) NULL,           -- texto livre do aplicador
    responsible_name    VARCHAR(200)  NULL,           -- application.responsible.name
    responsible_email   VARCHAR(200)  NULL,           -- application.responsible.email
    equipment_type      VARCHAR(20)   NULL,           -- 'land' (terrestre) | 'air' (aéreo) — de equipments[0].equipment.type
    equipment_name      VARCHAR(120)  NULL,           -- nome do equipamento (ex.: FERTIRRIGAÇÃO) — de equipments[0].equipment.name
    retroactive         BIT           NULL,           -- aplicação retroativa
    api_created_at      DATETIME2(3)  NULL,           -- normalizado UTC (Variante A)
    api_updated_at      DATETIME2(3)  NULL,           -- normalizado UTC (Variante A)
    etl_loaded_at       DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at      DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at          DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_APPLICATION ON dbo.FARMBOX_APPLICATION (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_APP_date
    ON dbo.FARMBOX_APPLICATION (farm_id, app_date DESC) WHERE deleted_at IS NULL;
-- filtro app_status='finalized' das análises; inclui colunas quentes (equip/data) p/ cobertura
CREATE INDEX IX_FARMBOX_APP_status
    ON dbo.FARMBOX_APPLICATION (app_status) INCLUDE (farmbox_id, equipment_type, equipment_name, app_date) WHERE deleted_at IS NULL;
GO

/* ─── 4.2 FARMBOX_APPLICATION_INPUT ─────────────────────────────────────── */
/*
   Insumos utilizados por aplicação — extraídos do array inputs[] dentro do
   record de APPLICATION. Relação N:N entre APPLICATION e INPUT.
*/
IF OBJECT_ID('dbo.FARMBOX_APPLICATION_INPUT') IS NOT NULL DROP TABLE dbo.FARMBOX_APPLICATION_INPUT;
GO
CREATE TABLE dbo.FARMBOX_APPLICATION_INPUT (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_APP_INPUT PRIMARY KEY,
    connector_id    INT           NOT NULL,
    application_id  BIGINT        NOT NULL,           -- FK → FARMBOX_APPLICATION.farmbox_id
    input_id        INT           NULL,               -- FK → FARMBOX_INPUT.farmbox_id
    dosage          DECIMAL(18,6) NULL,               -- dosagem por ha
    quantity        DECIMAL(18,6) NULL,               -- quantidade total aplicada
    unit            VARCHAR(20)   NULL,
    etl_loaded_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3)  NULL
);
GO
-- (application_id, input_id) NÃO é único: uma aplicação pode listar o mesmo insumo
-- mais de uma vez (posições/dosagens diferentes). A idempotência do ETL é por
-- replace-do-pai (apaga filhos da aplicação e reinsere).
CREATE INDEX IX_FARMBOX_APP_INPUT_app
    ON dbo.FARMBOX_APPLICATION_INPUT (application_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_APP_INPUT_input
    ON dbo.FARMBOX_APPLICATION_INPUT (input_id) WHERE deleted_at IS NULL;
GO

/* ─── 4.3 FARMBOX_APPLICATION_PLANTATION ────────────────────────────────── */
/*
   Plantações atendidas por aplicação — extraídas de plantations[] no record.
   Preserva sought_area (planejado) vs applied_area (realizado).
*/
IF OBJECT_ID('dbo.FARMBOX_APPLICATION_PLANTATION') IS NOT NULL DROP TABLE dbo.FARMBOX_APPLICATION_PLANTATION;
GO
CREATE TABLE dbo.FARMBOX_APPLICATION_PLANTATION (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_APP_PLANT PRIMARY KEY,
    connector_id    INT           NOT NULL,
    application_id  BIGINT        NOT NULL,           -- FK → FARMBOX_APPLICATION.farmbox_id
    plantation_id   INT           NULL,               -- FK → FARMBOX_PLANTATION.farmbox_id
    sought_area     DECIMAL(12,4) NULL,               -- área planejada (ha)
    applied_area    DECIMAL(12,4) NULL,               -- área realizada (ha)
    etl_loaded_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3)  NULL
);
GO
-- não-único pelo mesmo motivo do APPLICATION_INPUT (idempotência via replace-do-pai)
CREATE INDEX IX_FARMBOX_APP_PLANT_app
    ON dbo.FARMBOX_APPLICATION_PLANTATION (application_id) WHERE deleted_at IS NULL;
-- join pl.farmbox_id = ap.plantation_id (dedup pf nas análises de aplicação)
CREATE INDEX IX_FARMBOX_APP_PLANT_plant
    ON dbo.FARMBOX_APPLICATION_PLANTATION (plantation_id) WHERE deleted_at IS NULL;
GO

/* =========================================================================
   SEÇÃO 5 — MONITORAMENTO
   ========================================================================= */

/* ─── 5.1 FARMBOX_MONITORING ────────────────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_MONITORING') IS NOT NULL DROP TABLE dbo.FARMBOX_MONITORING;
GO
CREATE TABLE dbo.FARMBOX_MONITORING (
    id                      BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_MONITORING PRIMARY KEY,
    farmbox_id              BIGINT        NOT NULL,
    connector_id            INT           NOT NULL,
    plantation_id           INT           NULL,       -- FK → FARMBOX_PLANTATION.farmbox_id
    farm_id                 INT           NULL,
    field_id                BIGINT        NULL,       -- FK → FARM_FIELDS.id (herdado da plantation)
    monitoring_date         DATE          NULL,
    close_date              DATETIME2(3)  NULL,       -- normalizado UTC (Variante B)
    mon_state               VARCHAR(20)   NULL,       -- 'open' | 'closed'
    methodology             VARCHAR(30)   NULL,
    samples                 INT           NULL,       -- nº pontos de amostragem
    phenological_stage_name VARCHAR(50)   NULL,       -- ex: "C12" — estágio fenológico no momento
    phenology               BIT           NULL,       -- coletou dados fenológicos?
    recommendation          NVARCHAR(MAX) NULL,       -- recomendação agronômica do técnico
    delivered               BIT           NULL,       -- entregue ao produtor?
    api_updated_at          DATETIME2(3)  NULL,       -- normalizado UTC (cursor)
    etl_loaded_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_MONITORING ON dbo.FARMBOX_MONITORING (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MON_plantation
    ON dbo.FARMBOX_MONITORING (plantation_id, monitoring_date DESC) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MON_farm_date
    ON dbo.FARMBOX_MONITORING (farm_id, monitoring_date DESC)
    INCLUDE (mon_state, methodology) WHERE deleted_at IS NULL;
GO

/* ─── 5.2 FARMBOX_MONITORING_STOP ───────────────────────────────────────── */
/*
   Pontos de amostragem dentro de um monitoring.
   Extraídos do array monitoring_stops[] no record de MONITORING.
*/
IF OBJECT_ID('dbo.FARMBOX_MONITORING_STOP') IS NOT NULL DROP TABLE dbo.FARMBOX_MONITORING_STOP;
GO
CREATE TABLE dbo.FARMBOX_MONITORING_STOP (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_MON_STOP PRIMARY KEY,
    farmbox_id      BIGINT        NOT NULL,           -- monitoring_stop.id
    connector_id    INT           NOT NULL,
    monitoring_id   BIGINT        NOT NULL,           -- FK → FARMBOX_MONITORING.farmbox_id
    stop_number     INT           NULL,               -- posição dentro do monitoring
    latitude        DECIMAL(12,9) NULL,
    longitude       DECIMAL(12,9) NULL,
    etl_loaded_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_MON_STOP ON dbo.FARMBOX_MONITORING_STOP (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MON_STOP_mon
    ON dbo.FARMBOX_MONITORING_STOP (monitoring_id) WHERE deleted_at IS NULL;
GO

/* ─── 5.3 FARMBOX_MONITORING_STOP_RESULT ────────────────────────────────── */
/*
   Resultado por alvo em cada ponto de amostragem.
   Extraídos de monitoring_stops[].monitoring_stop_results[].
   infestation_level: 'infested' | 'damaged' | 'clear'
*/
IF OBJECT_ID('dbo.FARMBOX_MONITORING_STOP_RESULT') IS NOT NULL DROP TABLE dbo.FARMBOX_MONITORING_STOP_RESULT;
GO
CREATE TABLE dbo.FARMBOX_MONITORING_STOP_RESULT (
    id                  BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_MON_STOP_RES PRIMARY KEY,
    farmbox_id          BIGINT        NOT NULL,       -- monitoring_stop_result.id
    connector_id        INT           NOT NULL,
    stop_id             BIGINT        NOT NULL,       -- FK → FARMBOX_MONITORING_STOP.farmbox_id
    monitoring_id       BIGINT        NOT NULL,       -- desnormalizado para joins diretos
    target_name         VARCHAR(200)  NULL,           -- alvo (praga/doença/erva daninha)
    infestation         DECIMAL(18,6) NULL,           -- valor numérico (contagem/%) — largo p/ não estourar
    infestation_level   VARCHAR(20)   NULL,           -- 'infested' | 'damaged' | 'clear'
    quantity            DECIMAL(18,6) NULL,
    etl_loaded_at       DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at      DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at          DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_MON_RES_level
        CHECK (infestation_level IN ('infested','damaged','clear') OR infestation_level IS NULL)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_MON_STOP_RES
    ON dbo.FARMBOX_MONITORING_STOP_RESULT (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MON_STOP_RES_stop
    ON dbo.FARMBOX_MONITORING_STOP_RESULT (stop_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MON_STOP_RES_mon
    ON dbo.FARMBOX_MONITORING_STOP_RESULT (monitoring_id, target_name) WHERE deleted_at IS NULL;
GO

/* ─── 5.4 FARMBOX_MONITORING_DAY_RESULT ─────────────────────────────────── */
/*
   Resumo diário por plantation — id composto "timestamp-plantation_id".
   Cursor incremental: updated_at (Variante B, normalizado).
*/
IF OBJECT_ID('dbo.FARMBOX_MONITORING_DAY_RESULT') IS NOT NULL DROP TABLE dbo.FARMBOX_MONITORING_DAY_RESULT;
GO
CREATE TABLE dbo.FARMBOX_MONITORING_DAY_RESULT (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_MON_DAY_RES PRIMARY KEY,
    record_id       VARCHAR(60)   NOT NULL,           -- "timestamp-plantation_id" (chave natural)
    connector_id    INT           NOT NULL,
    plantation_id   INT           NULL,               -- extraído do record_id (segunda parte)
    result_date     DATE          NULL,               -- extraído do timestamp (primeira parte)
    api_updated_at  DATETIME2(3)  NULL,               -- normalizado UTC (Variante B)
    etl_loaded_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_MON_DAY_RES
    ON dbo.FARMBOX_MONITORING_DAY_RESULT (record_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MON_DAY_RES_plant
    ON dbo.FARMBOX_MONITORING_DAY_RESULT (plantation_id, result_date DESC) WHERE deleted_at IS NULL;
GO

/* ─── FARMBOX_MONITORING_DAY_MONITOR ─────────────────────────────────────────
   Amostradores (monitors[]) de cada resultado do dia. ÚNICO vínculo entre a
   contagem de estimativa (FARMBOX_COUNT_MONITORING, sem usuário) e o técnico,
   via (plantation_id + result_date). Nome/email denormalizados do JSON. */
IF OBJECT_ID('dbo.FARMBOX_MONITORING_DAY_MONITOR') IS NOT NULL DROP TABLE dbo.FARMBOX_MONITORING_DAY_MONITOR;
GO
CREATE TABLE dbo.FARMBOX_MONITORING_DAY_MONITOR (
    id                        BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_MDR_MON PRIMARY KEY,
    connector_id              INT           NOT NULL,
    monitoring_day_result_id  VARCHAR(60)   NOT NULL,    -- FK natural → FARMBOX_MONITORING_DAY_RESULT.record_id
    plantation_id             INT           NULL,
    result_date               DATE          NULL,
    monitor_id                INT           NULL,         -- → FARMBOX_USER.farmbox_id (REF_USER)
    monitor_name              VARCHAR(200)  NULL,
    monitor_email             VARCHAR(200)  NULL,
    etl_loaded_at             DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at            DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at                DATETIME2(3)  NULL
);
GO
CREATE INDEX IX_FARMBOX_MDR_MON_parent  ON dbo.FARMBOX_MONITORING_DAY_MONITOR (monitoring_day_result_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MDR_MON_plant   ON dbo.FARMBOX_MONITORING_DAY_MONITOR (plantation_id, result_date) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MDR_MON_monitor ON dbo.FARMBOX_MONITORING_DAY_MONITOR (monitor_id) WHERE deleted_at IS NULL;
GO

/* =========================================================================
   SEÇÃO 6 — CAMPO E ANOTAÇÕES
   ========================================================================= */

/* ─── 6.1 FARMBOX_PLUVIOMETER_MONITORING ────────────────────────────────── */
IF OBJECT_ID('dbo.FARMBOX_PLUVIOMETER_MONITORING') IS NOT NULL DROP TABLE dbo.FARMBOX_PLUVIOMETER_MONITORING;
GO
CREATE TABLE dbo.FARMBOX_PLUVIOMETER_MONITORING (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_PLUVIO_MON PRIMARY KEY,
    farmbox_id      BIGINT        NOT NULL,
    connector_id    INT           NOT NULL,
    pluviometer_id  INT           NULL,
    farm_id         INT           NULL,
    reading_date    DATE          NULL,               -- Variante A normalizada → só data (hora = 00:00)
    quantity_mm     DECIMAL(8,2)  NULL,
    latitude        DECIMAL(12,9) NULL,               -- STRING na API → float()
    longitude       DECIMAL(12,9) NULL,
    etl_loaded_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_PLUVIO_MON ON dbo.FARMBOX_PLUVIOMETER_MONITORING (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_PLUVIO_MON_date
    ON dbo.FARMBOX_PLUVIOMETER_MONITORING (farm_id, reading_date DESC) WHERE deleted_at IS NULL;
GO

/* ─── 6.2 FARMBOX_NOTE ──────────────────────────────────────────────────── */
/*
   Anotações polimórficas. location_type: 'Fields::Plantation' | 'Farms::Farm'
*/
IF OBJECT_ID('dbo.FARMBOX_NOTE') IS NOT NULL DROP TABLE dbo.FARMBOX_NOTE;
GO
CREATE TABLE dbo.FARMBOX_NOTE (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_NOTE PRIMARY KEY,
    farmbox_id      BIGINT        NOT NULL,
    connector_id    INT           NOT NULL,
    location_id     INT           NULL,               -- plantation_id ou farm_id
    location_type   VARCHAR(50)   NULL,               -- 'Fields::Plantation' | 'Farms::Farm'
    description     NVARCHAR(MAX) NULL,               -- campo 'description' da API (texto principal)
    title           NVARCHAR(300) NULL,               -- campo 'title' quando presente
    note_date       DATETIME2(3)  NULL,               -- normalizado UTC (Variante A)
    latitude        DECIMAL(12,9) NULL,               -- geolocalização da nota no campo
    longitude       DECIMAL(12,9) NULL,
    image_addresses NVARCHAR(MAX) NULL,               -- JSON array de URLs S3 (renderizável no front)
    user_name       VARCHAR(200)  NULL,               -- nome do autor (desnormalizado)
    author_id       INT           NULL,               -- FK → FARMBOX_USER.farmbox_id
    etl_loaded_at   DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at  DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at      DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_NOTE ON dbo.FARMBOX_NOTE (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_NOTE_location
    ON dbo.FARMBOX_NOTE (location_type, location_id, note_date DESC) WHERE deleted_at IS NULL;
GO

/* =========================================================================
   SEÇÃO 7 — FARMBOX_MONITORING_NOTE (notas de campo com imagens)
   =========================================================================
   Extraída de monitoring_day_results[].notes[] e do endpoint /notes.
   image_addresses[] = array de URLs S3 públicas — frontend renderiza direto.
   ========================================================================= */
IF OBJECT_ID('dbo.FARMBOX_MONITORING_NOTE') IS NOT NULL DROP TABLE dbo.FARMBOX_MONITORING_NOTE;
GO
CREATE TABLE dbo.FARMBOX_MONITORING_NOTE (
    id                       BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARMBOX_MON_NOTE PRIMARY KEY,
    farmbox_id               BIGINT        NOT NULL,
    connector_id             INT           NOT NULL,
    monitoring_day_result_id VARCHAR(60)   NULL,       -- "timestamp-plantation_id"
    plantation_id            INT           NULL,
    field_id                 BIGINT        NULL,       -- FK → FARM_FIELDS.id
    location_type            VARCHAR(50)   NULL,
    description              NVARCHAR(MAX) NULL,
    user_name                VARCHAR(200)  NULL,
    note_date                DATETIME2(3)  NULL,
    latitude                 DECIMAL(12,9) NULL,
    longitude                DECIMAL(12,9) NULL,
    image_addresses          NVARCHAR(MAX) NULL,
    etl_loaded_at            DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_updated_at           DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at               DATETIME2(3)  NULL,
    CONSTRAINT CK_FARMBOX_MON_NOTE_imgs
        CHECK (image_addresses IS NULL OR ISJSON(image_addresses) = 1)
);
GO
CREATE UNIQUE INDEX UX_FARMBOX_MON_NOTE
    ON dbo.FARMBOX_MONITORING_NOTE (farmbox_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MON_NOTE_plant
    ON dbo.FARMBOX_MONITORING_NOTE (plantation_id, note_date DESC) WHERE deleted_at IS NULL;
CREATE INDEX IX_FARMBOX_MON_NOTE_field
    ON dbo.FARMBOX_MONITORING_NOTE (field_id, note_date DESC)
    WHERE field_id IS NOT NULL AND deleted_at IS NULL;
GO

/* =========================================================================
   SEÇÃO 7B — MASTER COMPLEMENTAR (contagens, armadilhas, fenologia, preços,
   tolerâncias, pluviômetros, lotes, almoxarifados). ETL 1-1 do raw.
   ========================================================================= */

IF OBJECT_ID('dbo.FARMBOX_COUNT_MONITORING') IS NOT NULL DROP TABLE dbo.FARMBOX_COUNT_MONITORING;
GO
CREATE TABLE dbo.FARMBOX_COUNT_MONITORING (
    id BIGINT IDENTITY(1,1) CONSTRAINT PK_FARMBOX_COUNT_MONITORING PRIMARY KEY,
    farmbox_id BIGINT NOT NULL, connector_id INT NOT NULL, plantation_id INT NULL,
    count_date DATE NULL, latitude DECIMAL(12,9) NULL, longitude DECIMAL(12,9) NULL,
    count_group VARCHAR(150) NULL, parameters NVARCHAR(MAX) NULL, api_updated_at DATETIME2(3) NULL,
    etl_loaded_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(), etl_updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(), deleted_at DATETIME2(3) NULL);
GO
CREATE UNIQUE INDEX UX_FARMBOX_COUNT_MONITORING ON dbo.FARMBOX_COUNT_MONITORING (farmbox_id) WHERE deleted_at IS NULL;
GO

IF OBJECT_ID('dbo.FARMBOX_COUNT_DAY') IS NOT NULL DROP TABLE dbo.FARMBOX_COUNT_DAY;
GO
CREATE TABLE dbo.FARMBOX_COUNT_DAY (
    id BIGINT IDENTITY(1,1) CONSTRAINT PK_FARMBOX_COUNT_DAY PRIMARY KEY,
    farmbox_id BIGINT NOT NULL, connector_id INT NOT NULL, plantation_id INT NULL,
    count_date DATE NULL, count_groups NVARCHAR(MAX) NULL, api_updated_at DATETIME2(3) NULL,
    etl_loaded_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(), etl_updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(), deleted_at DATETIME2(3) NULL);
GO
CREATE UNIQUE INDEX UX_FARMBOX_COUNT_DAY ON dbo.FARMBOX_COUNT_DAY (farmbox_id) WHERE deleted_at IS NULL;
GO

IF OBJECT_ID('dbo.FARMBOX_TRAP_MONITORING') IS NOT NULL DROP TABLE dbo.FARMBOX_TRAP_MONITORING;
GO
CREATE TABLE dbo.FARMBOX_TRAP_MONITORING (
    id BIGINT IDENTITY(1,1) CONSTRAINT PK_FARMBOX_TRAP_MONITORING PRIMARY KEY,
    farmbox_id BIGINT NOT NULL, connector_id INT NOT NULL, trap_id INT NULL, trap_name VARCHAR(200) NULL,
    plantation_id INT NULL, trap_date DATE NULL, change_pheromone BIT NULL, user_name VARCHAR(200) NULL,
    targets NVARCHAR(MAX) NULL, api_updated_at DATETIME2(3) NULL,
    etl_loaded_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(), etl_updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(), deleted_at DATETIME2(3) NULL);
GO
CREATE UNIQUE INDEX UX_FARMBOX_TRAP_MONITORING ON dbo.FARMBOX_TRAP_MONITORING (farmbox_id) WHERE deleted_at IS NULL;
GO

IF OBJECT_ID('dbo.FARMBOX_PHENOLOGICAL_STAGE_SAMPLE') IS NOT NULL DROP TABLE dbo.FARMBOX_PHENOLOGICAL_STAGE_SAMPLE;
GO
CREATE TABLE dbo.FARMBOX_PHENOLOGICAL_STAGE_SAMPLE (
    id BIGINT IDENTITY(1,1) CONSTRAINT PK_FARMBOX_PHENO_SAMPLE PRIMARY KEY,
    farmbox_id BIGINT NOT NULL, connector_id INT NOT NULL, plantation_id INT NULL,
    sample_date DATE NULL, latitude DECIMAL(12,9) NULL, longitude DECIMAL(12,9) NULL,
    stage_name VARCHAR(50) NULL, api_updated_at DATETIME2(3) NULL,
    etl_loaded_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(), etl_updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(), deleted_at DATETIME2(3) NULL);
GO
CREATE UNIQUE INDEX UX_FARMBOX_PHENO_SAMPLE ON dbo.FARMBOX_PHENOLOGICAL_STAGE_SAMPLE (farmbox_id) WHERE deleted_at IS NULL;
GO

IF OBJECT_ID('dbo.FARMBOX_INPUT_VALUE') IS NOT NULL DROP TABLE dbo.FARMBOX_INPUT_VALUE;
GO
CREATE TABLE dbo.FARMBOX_INPUT_VALUE (
    id BIGINT IDENTITY(1,1) CONSTRAINT PK_FARMBOX_INPUT_VALUE PRIMARY KEY,
    farmbox_id BIGINT NOT NULL, connector_id INT NOT NULL, input_id INT NULL, farm_id INT NULL,
    harvest_id INT NULL, value DECIMAL(16,4) NULL, api_updated_at DATETIME2(3) NULL,
    etl_loaded_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(), etl_updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(), deleted_at DATETIME2(3) NULL);
GO
CREATE UNIQUE INDEX UX_FARMBOX_INPUT_VALUE ON dbo.FARMBOX_INPUT_VALUE (farmbox_id) WHERE deleted_at IS NULL;
GO

IF OBJECT_ID('dbo.FARMBOX_MONITORING_TOLERANCE') IS NOT NULL DROP TABLE dbo.FARMBOX_MONITORING_TOLERANCE;
GO
CREATE TABLE dbo.FARMBOX_MONITORING_TOLERANCE (
    id BIGINT IDENTITY(1,1) CONSTRAINT PK_FARMBOX_MON_TOLERANCE PRIMARY KEY,
    farmbox_id BIGINT NOT NULL, connector_id INT NOT NULL, farm_id INT NULL, culture_id INT NULL,
    variety_id INT NULL, days INT NULL, api_updated_at DATETIME2(3) NULL,
    etl_loaded_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(), etl_updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(), deleted_at DATETIME2(3) NULL);
GO
CREATE UNIQUE INDEX UX_FARMBOX_MON_TOLERANCE ON dbo.FARMBOX_MONITORING_TOLERANCE (farmbox_id) WHERE deleted_at IS NULL;
GO

IF OBJECT_ID('dbo.FARMBOX_PLUVIOMETER') IS NOT NULL DROP TABLE dbo.FARMBOX_PLUVIOMETER;
GO
CREATE TABLE dbo.FARMBOX_PLUVIOMETER (
    id BIGINT IDENTITY(1,1) CONSTRAINT PK_FARMBOX_PLUVIOMETER PRIMARY KEY,
    farmbox_id BIGINT NOT NULL, connector_id INT NOT NULL, farm_id INT NULL, name VARCHAR(200) NULL,
    latitude DECIMAL(12,9) NULL, longitude DECIMAL(12,9) NULL, start_date DATE NULL, api_updated_at DATETIME2(3) NULL,
    etl_loaded_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(), etl_updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(), deleted_at DATETIME2(3) NULL);
GO
CREATE UNIQUE INDEX UX_FARMBOX_PLUVIOMETER ON dbo.FARMBOX_PLUVIOMETER (farmbox_id) WHERE deleted_at IS NULL;
GO

IF OBJECT_ID('dbo.FARMBOX_BATCH') IS NOT NULL DROP TABLE dbo.FARMBOX_BATCH;
GO
CREATE TABLE dbo.FARMBOX_BATCH (
    id BIGINT IDENTITY(1,1) CONSTRAINT PK_FARMBOX_BATCH PRIMARY KEY,
    farmbox_id BIGINT NOT NULL, connector_id INT NOT NULL, input_id INT NULL, batch_number VARCHAR(100) NULL,
    validity DATE NULL, api_updated_at DATETIME2(3) NULL,
    etl_loaded_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(), etl_updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(), deleted_at DATETIME2(3) NULL);
GO
CREATE UNIQUE INDEX UX_FARMBOX_BATCH ON dbo.FARMBOX_BATCH (farmbox_id) WHERE deleted_at IS NULL;
GO

IF OBJECT_ID('dbo.FARMBOX_STORAGE') IS NOT NULL DROP TABLE dbo.FARMBOX_STORAGE;
GO
CREATE TABLE dbo.FARMBOX_STORAGE (
    id BIGINT IDENTITY(1,1) CONSTRAINT PK_FARMBOX_STORAGE PRIMARY KEY,
    farmbox_id BIGINT NOT NULL, connector_id INT NOT NULL, farm_id INT NULL, name VARCHAR(200) NULL,
    storage_type INT NULL, default_storage BIT NULL, api_disabled_at DATETIME2(3) NULL, api_updated_at DATETIME2(3) NULL,
    etl_loaded_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(), etl_updated_at DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(), deleted_at DATETIME2(3) NULL);
GO
CREATE UNIQUE INDEX UX_FARMBOX_STORAGE ON dbo.FARMBOX_STORAGE (farmbox_id) WHERE deleted_at IS NULL;
GO

/* =========================================================================
   SEÇÃO 8 — VIEWS ANALÍTICAS
   ========================================================================= */

/* ─── 8.1 VW_FARMBOX_PLANTATION_SUMMARY ─────────────────────────────────── */
CREATE OR ALTER VIEW dbo.VW_FARMBOX_PLANTATION_SUMMARY AS
SELECT
    p.farmbox_id            AS plantation_id,
    p.connector_id,
    p.field_id,
    ff.name                 AS field_name,
    f.name                  AS farm_name,
    h.name                  AS harvest_name,
    c.name                  AS culture_name,
    v.name                  AS variety_name,
    pl.name                 AS plot_name,
    p.state,
    p.area_ha,
    p.cycle,
    p.irrigated,
    p.plantation_date,
    p.harvest_prediction_date,
    p.closed_date,
    p.productivity
FROM       dbo.FARMBOX_PLANTATION  p
LEFT JOIN  dbo.FARM_FIELDS         ff ON ff.id       = p.field_id
LEFT JOIN  dbo.FARMBOX_FARM        f  ON f.farmbox_id = p.farm_id        AND f.deleted_at IS NULL
LEFT JOIN  dbo.FARMBOX_HARVEST     h  ON h.farmbox_id = p.harvest_id     AND h.deleted_at IS NULL
LEFT JOIN  dbo.FARMBOX_CULTURE     c  ON c.farmbox_id = p.culture_id     AND c.deleted_at IS NULL
LEFT JOIN  dbo.FARMBOX_VARIETY     v  ON v.farmbox_id = p.variety_id     AND v.deleted_at IS NULL
LEFT JOIN  dbo.FARMBOX_PLOT        pl ON pl.farmbox_id = p.plot_id       AND pl.deleted_at IS NULL
WHERE p.deleted_at IS NULL;
GO

/* ─── 8.2 VW_FARMBOX_MONITORING_INFEST ──────────────────────────────────── */
CREATE OR ALTER VIEW dbo.VW_FARMBOX_MONITORING_INFEST AS
SELECT
    m.farmbox_id            AS monitoring_id,
    m.farm_id,
    m.plantation_id,
    m.field_id,
    m.monitoring_date,
    r.target_name,
    r.infestation_level,
    AVG(r.infestation)      AS avg_infestation,
    COUNT(r.id)             AS sample_count,
    SUM(CASE WHEN r.infestation_level = 'infested' THEN 1 ELSE 0 END) AS infested_stops,
    SUM(CASE WHEN r.infestation_level = 'damaged'  THEN 1 ELSE 0 END) AS damaged_stops,
    SUM(CASE WHEN r.infestation_level = 'clear'    THEN 1 ELSE 0 END) AS clear_stops
FROM       dbo.FARMBOX_MONITORING             m
INNER JOIN dbo.FARMBOX_MONITORING_STOP        s  ON s.monitoring_id = m.farmbox_id AND s.deleted_at IS NULL
INNER JOIN dbo.FARMBOX_MONITORING_STOP_RESULT r  ON r.stop_id = s.farmbox_id       AND r.deleted_at IS NULL
WHERE m.deleted_at IS NULL
GROUP BY m.farmbox_id, m.farm_id, m.plantation_id, m.field_id, m.monitoring_date,
         r.target_name, r.infestation_level;
GO

/* ─── 8.3 VW_FARMBOX_FIELD_NOTES_WITH_IMAGES ───────────────────────────── */
/*
  View para o frontend renderizar notas com imagens por talhão/dia.
  Inclui todas as notas com pelo menos 1 imagem.
*/
CREATE OR ALTER VIEW dbo.VW_FARMBOX_FIELD_NOTES_WITH_IMAGES AS
SELECT
    n.farmbox_id            AS note_id,
    n.field_id,
    ff.name                 AS field_name,
    n.plantation_id,
    n.monitoring_day_result_id,
    n.description,
    n.user_name,
    n.note_date,
    n.latitude,
    n.longitude,
    n.image_addresses       -- JSON array de URLs S3, renderizável no front
FROM      dbo.FARMBOX_MONITORING_NOTE  n
LEFT JOIN dbo.FARM_FIELDS              ff ON ff.id = n.field_id
WHERE n.deleted_at IS NULL
  AND n.image_addresses IS NOT NULL
  AND n.image_addresses <> '[]';
GO


/* #####################################################################
   MÓDULOS AGRONÔMICOS — Calendário Agrícola + Fertilidade + VRA
   Integrados em 2026-06-27. Contexto GCS_FARM (USE GCS_FARM acima),
   após FARM_FARMS / FARM_FIELDS / FARM_FIELD_GEOMETRY.
   Ordem: FARM_SEASON -> FERTILIDADE -> VRA.
   ##################################################################### */
GO

/* =====================================================================
   GCS_FARM  |  CALENDÁRIO AGRÍCOLA (cultura / safra / ciclo)  |  T-SQL
   Versão: v1  |  Gerado em: 2026-06-27

   Modela o ano agrícola real de uma fazenda:
     SAFRA (26/27)  -- guarda-chuva (período)
       └─ CICLOS produtivos (1º, 2º, 3º, 4º), cada um com uma CULTURA
            Ex.: 26/27 -> 1º Soja ; 2º Milho ; 2º Algodão

   Por que dimensões GENÉRICAS (família FARM_*)?
     Safra/ciclo/cultura são transversais: usados por Fertilidade, VRA
     (calagem/adubação/semeadura), NDVI, etc. Ficam como masters únicos e
     padronizados (evita "2025/26" texto livre espalhado pelos módulos).

   Regra de uso nos mapas (VRA):
     - CALAGEM / GESSAGEM  -> basta season_id (correção de solo da safra).
     - ADUBAÇÃO / SEMEADURA / APLICAÇÃO -> exigem season_cycle_id (a CULTURA).
     (enforçado via VRA_MAP_TYPE.requires_cycle; FK garante a integridade.)

   Estrutura (3 tabelas + 1 view).
   Rodar em GCS_FARM ANTES dos módulos FERTILIDADE e VRA.
   ===================================================================== */
-- USE GCS_FARM;
-- GO

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

/* =====================================================================
   0) DROP em ordem reversa de dependência
   ===================================================================== */
IF OBJECT_ID('dbo.VW_FARM_SEASON_CYCLE') IS NOT NULL DROP VIEW dbo.VW_FARM_SEASON_CYCLE;
IF OBJECT_ID('dbo.VW_FERT_CROP_EXPORT')  IS NOT NULL DROP VIEW dbo.VW_FERT_CROP_EXPORT;
GO
-- FERT_CROP_EXPORT tem FK p/ FARM_CULTURE — dropar antes de FARM_CULTURE (módulo Fertilidade
-- é criado depois, mas no re-run a tabela antiga precisa sair primeiro p/ liberar a FK).
IF OBJECT_ID('dbo.FERT_CROP_EXPORT')  IS NOT NULL DROP TABLE dbo.FERT_CROP_EXPORT;
-- FARM_VARIETY (módulo Planejamento) tem FK p/ FARM_CULTURE — dropar antes.
IF OBJECT_ID('dbo.FARM_VARIETY')      IS NOT NULL DROP TABLE dbo.FARM_VARIETY;
IF OBJECT_ID('dbo.FARM_SEASON_CYCLE') IS NOT NULL DROP TABLE dbo.FARM_SEASON_CYCLE;
IF OBJECT_ID('dbo.FARM_SEASON')       IS NOT NULL DROP TABLE dbo.FARM_SEASON;
IF OBJECT_ID('dbo.FARM_CULTURE')      IS NOT NULL DROP TABLE dbo.FARM_CULTURE;
GO

/* =====================================================================
   1) FARM_CULTURE  -- catálogo de culturas (genérico)
   ===================================================================== */
CREATE TABLE dbo.FARM_CULTURE (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARM_CULTURE PRIMARY KEY,
    code            VARCHAR(40)   NOT NULL,                -- SOJA, MILHO, ALGODAO...
    name            NVARCHAR(120) NOT NULL,
    scientific_name NVARCHAR(150) NULL,
    color_hex       CHAR(7)       NULL,
    -- unidade da PRODUTIVIDADE (Farmbox vem como rendimento/ha sem unidade explícita).
    -- Usada p/ converter produtividade -> tonelada no cálculo de exportação de nutrientes
    -- (coef em kg/t e g/t). sc = saca 60 kg · @ = arroba 15 kg · t = t/ha (1000 kg).
    productivity_unit        VARCHAR(8)    NULL,
    productivity_kg_per_unit DECIMAL(10,3) NULL,
    farmbox_culture_id INT     NULL,                     -- id da cultura no Farmbox (FARMBOX_PLANTATION.culture_id usa este id, NÃO o local)
    active          BIT           NULL CONSTRAINT DF_FARM_CULTURE_active DEFAULT 1,
    created_at      DATETIME2(3)  NULL CONSTRAINT DF_FARM_CULTURE_created DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)  NULL,
    deleted_at      DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_FARM_CULTURE_code ON dbo.FARM_CULTURE (code) WHERE deleted_at IS NULL;
GO

/* =====================================================================
   2) FARM_SEASON  -- safra (ano agrícola, ex.: 26/27)
   ===================================================================== */
CREATE TABLE dbo.FARM_SEASON (
    id          BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARM_SEASON PRIMARY KEY,
    code        VARCHAR(20)   NOT NULL,                    -- '26/27'
    name        NVARCHAR(120) NULL,                        -- 'Safra 2026/2027'
    year_start  SMALLINT      NULL,                        -- 2026
    year_end    SMALLINT      NULL,                        -- 2027
    start_date  DATE          NULL,                        -- início do ano agrícola
    end_date    DATE          NULL,
    is_current  BIT           NULL CONSTRAINT DF_FARM_SEASON_cur DEFAULT 0,
    active      BIT           NULL CONSTRAINT DF_FARM_SEASON_active DEFAULT 1,
    notes       NVARCHAR(MAX) NULL,
    farmbox_harvest_id INT     NULL,                       -- de/para -> FARMBOX_HARVEST.farmbox_id (safra)
    created_at  DATETIME2(3)  NULL CONSTRAINT DF_FARM_SEASON_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3)  NULL,
    deleted_at  DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_FARM_SEASON_code      ON dbo.FARM_SEASON (code) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX UX_FARM_SEASON_current   ON dbo.FARM_SEASON (is_current) WHERE is_current = 1 AND deleted_at IS NULL;
CREATE UNIQUE INDEX UX_FARM_SEASON_fbharvest ON dbo.FARM_SEASON (farmbox_harvest_id) WHERE farmbox_harvest_id IS NOT NULL AND deleted_at IS NULL;
GO

/* =====================================================================
   3) FARM_SEASON_CYCLE  -- ciclo produtivo da safra (com cultura)
      Uma safra tem 1..N ciclos; um mesmo nº de ciclo pode ter culturas
      diferentes (ex.: 2º ciclo: Milho E Algodão em talhões distintos).
   ===================================================================== */
CREATE TABLE dbo.FARM_SEASON_CYCLE (
    id             BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARM_SEASON_CYCLE PRIMARY KEY,
    season_id      BIGINT        NOT NULL,                 -- FK -> FARM_SEASON
    cycle_no       TINYINT       NOT NULL,                 -- 1,2,3,4
    name           NVARCHAR(60)  NULL,                     -- "1º Ciclo", "2ª Safra"...
    culture_id     BIGINT        NOT NULL,                 -- FK -> FARM_CULTURE
    planting_start DATE          NULL,                     -- janela de plantio
    planting_end   DATE          NULL,
    harvest_start  DATE          NULL,                     -- janela de colheita
    harvest_end    DATE          NULL,
    active         BIT           NULL CONSTRAINT DF_FARM_CYCLE_active DEFAULT 1,
    notes          NVARCHAR(MAX) NULL,
    created_at     DATETIME2(3)  NULL CONSTRAINT DF_FARM_CYCLE_created DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)  NULL,
    deleted_at     DATETIME2(3)  NULL,
    CONSTRAINT FK_FARM_CYCLE_season  FOREIGN KEY (season_id)  REFERENCES dbo.FARM_SEASON(id),
    CONSTRAINT FK_FARM_CYCLE_culture FOREIGN KEY (culture_id) REFERENCES dbo.FARM_CULTURE(id)
);
GO
CREATE UNIQUE INDEX UX_FARM_CYCLE ON dbo.FARM_SEASON_CYCLE (season_id, cycle_no, culture_id) WHERE deleted_at IS NULL;
CREATE INDEX        IX_FARM_CYCLE_season ON dbo.FARM_SEASON_CYCLE (season_id);
GO

/* =====================================================================
   4) SEEDS
   ===================================================================== */
INSERT INTO dbo.FARM_CULTURE (code, name, color_hex, productivity_unit, productivity_kg_per_unit) VALUES
 ('SOJA',    N'Soja',      '#2E7D33', 'sc', 60),
 ('MILHO',   N'Milho',     '#D4A017', 'sc', 60),   -- amarelo escuro
 ('ALGODAO', N'Algodão',   '#FFFFFF', '@',  15),   -- branco (algodão em caroço, arroba 15 kg)
 ('SORGO',   N'Sorgo',     '#D9701A', 'sc', 60),   -- laranja (escuro)
 ('FEIJAO',  N'Feijão',    '#E8431C', 'sc', 60),
 ('TRIGO',   N'Trigo',     '#C9A227', 'sc', 60),
 ('CAFE',          N'Café',           '#7D4B32', 'sc', 60),
 ('CANA',          N'Cana-de-açúcar', '#6FA82F', 't',  1000),
 ('MILHO_SILAGEM', N'Milho silagem',  '#9AA84A', 't',  1000),
 ('POUSIO',  N'Pousio',    '#8893A0', NULL, NULL);
GO

INSERT INTO dbo.FARM_SEASON (code, name, year_start, year_end, is_current) VALUES
 ('25/26', N'Safra 2025/2026', 2025, 2026, 0),
 ('26/27', N'Safra 2026/2027', 2026, 2027, 1);
GO

/* Ciclos da safra 26/27: 1º Soja ; 2º Milho ; 2º Algodão */
INSERT INTO dbo.FARM_SEASON_CYCLE (season_id, cycle_no, name, culture_id)
SELECT s.id, c.cycle_no, c.name, cu.id
FROM (VALUES (1,N'1º Ciclo','SOJA'),(2,N'2º Ciclo','MILHO'),(2,N'2º Ciclo','ALGODAO')) c(cycle_no,name,culcode)
JOIN dbo.FARM_SEASON  s  ON s.code = '26/27'
JOIN dbo.FARM_CULTURE cu ON cu.code = c.culcode;
GO

/* =====================================================================
   5) VIEW  VW_FARM_SEASON_CYCLE  -- safra + ciclo + cultura achatado
   ===================================================================== */
CREATE VIEW dbo.VW_FARM_SEASON_CYCLE AS
SELECT
    cy.id AS season_cycle_id, s.id AS season_id, s.code AS season_code, s.name AS season_name,
    s.is_current, cy.cycle_no, cy.name AS cycle_name,
    cu.id AS culture_id, cu.code AS culture_code, cu.name AS culture_name, cu.color_hex,
    cy.planting_start, cy.planting_end, cy.harvest_start, cy.harvest_end
FROM dbo.FARM_SEASON_CYCLE cy
JOIN dbo.FARM_SEASON  s  ON s.id  = cy.season_id  AND s.deleted_at IS NULL
JOIN dbo.FARM_CULTURE cu ON cu.id = cy.culture_id AND cu.deleted_at IS NULL
WHERE cy.deleted_at IS NULL;
GO

/* =====================================================================
   6) FARM_VARIETY  -- catálogo de VARIEDADE / HÍBRIDO, por cultura
      (folha do planejamento: SAFRA→CICLO→CULTURA→TALHÃO→VARIEDADE)
   ===================================================================== */
CREATE TABLE dbo.FARM_VARIETY (
    id                 BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARM_VARIETY PRIMARY KEY,
    culture_id         BIGINT        NOT NULL,                 -- FK -> FARM_CULTURE
    code               VARCHAR(60)   NULL,
    name               NVARCHAR(200) NOT NULL,                 -- 'NS7901RR', 'TMG 81WS', ...
    kind               VARCHAR(20)   NULL,                     -- cultivar | hibrido | linhagem (afeta a label)
    tech               NVARCHAR(120) NULL,                     -- biotecnologia/traits (legado; ver FARM_VARIETY_TRAIT)
    primary_tech       NVARCHAR(120) NULL,                     -- tecnologia PRINCIPAL (desempata multi-tecnologia p/ coef. de exportação)
    maturity_group     VARCHAR(20)   NULL,
    company            NVARCHAR(120) NULL,
    farmbox_variety_id INT           NULL,                     -- de/para -> FARMBOX_VARIETY.farmbox_id
    active             BIT           NULL CONSTRAINT DF_FARM_VARIETY_active  DEFAULT 1,
    notes              NVARCHAR(MAX) NULL,
    created_at         DATETIME2(3)  NULL CONSTRAINT DF_FARM_VARIETY_created DEFAULT SYSUTCDATETIME(),
    updated_at         DATETIME2(3)  NULL,
    deleted_at         DATETIME2(3)  NULL,
    CONSTRAINT FK_FARM_VARIETY_culture FOREIGN KEY (culture_id) REFERENCES dbo.FARM_CULTURE(id),
    CONSTRAINT CK_FARM_VARIETY_kind CHECK (kind IS NULL OR kind IN ('cultivar','hibrido','linhagem'))
);
GO
CREATE UNIQUE INDEX UX_FARM_VARIETY_culture_name ON dbo.FARM_VARIETY (culture_id, name) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX UX_FARM_VARIETY_fb           ON dbo.FARM_VARIETY (farmbox_variety_id) WHERE farmbox_variety_id IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX        IX_FARM_VARIETY_culture      ON dbo.FARM_VARIETY (culture_id);
GO

/* =====================================================================
   FARM_VARIETY_TRAIT — catálogo CONFIGURÁVEL de características da variedade
   (PMS, peso de capulho, tecnologia…), opcionalmente por cultura.
   FARM_VARIETY_TRAIT_VALUE — valor de cada característica por variedade.
   ===================================================================== */
CREATE TABLE dbo.FARM_VARIETY_TRAIT (
    id          INT           IDENTITY(1,1) CONSTRAINT PK_FARM_VARIETY_TRAIT PRIMARY KEY,
    culture_id  BIGINT        NULL,               -- NULL = todas as culturas; senão FK FARM_CULTURE
    code        VARCHAR(60)   NULL,
    name        NVARCHAR(120) NOT NULL,           -- ex.: Peso de mil sementes, Peso de capulho, Tecnologia
    unit        VARCHAR(30)   NULL,               -- ex.: g, %, dias
    data_type   VARCHAR(12)   NOT NULL CONSTRAINT DF_FVT_dtype DEFAULT 'number', -- number | text | list
    options     NVARCHAR(1000) NULL,              -- p/ list: JSON array de opções (ex.: ["RR","Bollgard II"])
    multi       BIT           NOT NULL CONSTRAINT DF_FVT_multi DEFAULT 0,        -- list aceita vários
    sort_order  INT           NOT NULL CONSTRAINT DF_FVT_sort DEFAULT 0,
    override_pid INT          NULL,               -- pID (count_parameter) medido que esta caracteristica substitui na formula (fallback = medido)
    active      BIT           NOT NULL CONSTRAINT DF_FVT_active DEFAULT 1,
    created_at  DATETIME2(3)  NOT NULL CONSTRAINT DF_FVT_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3)  NOT NULL CONSTRAINT DF_FVT_updated DEFAULT SYSUTCDATETIME(),
    deleted_at  DATETIME2(3)  NULL,
    CONSTRAINT CK_FVT_dtype CHECK (data_type IN ('number','text','list')),
    CONSTRAINT FK_FVT_culture FOREIGN KEY (culture_id) REFERENCES dbo.FARM_CULTURE(id)
);
GO
CREATE UNIQUE INDEX UX_FVT_culture_name ON dbo.FARM_VARIETY_TRAIT (culture_id, name) WHERE deleted_at IS NULL;
GO
CREATE TABLE dbo.FARM_VARIETY_TRAIT_VALUE (
    id          BIGINT        IDENTITY(1,1) CONSTRAINT PK_FVT_VALUE PRIMARY KEY,
    variety_id  BIGINT        NOT NULL,
    trait_id    INT           NOT NULL,
    value       NVARCHAR(1000) NULL,              -- número (texto), texto livre, ou JSON/CSV p/ list-multi
    created_at  DATETIME2(3)  NOT NULL CONSTRAINT DF_FVTV_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3)  NOT NULL CONSTRAINT DF_FVTV_updated DEFAULT SYSUTCDATETIME(),
    deleted_at  DATETIME2(3)  NULL,
    CONSTRAINT FK_FVTV_variety FOREIGN KEY (variety_id) REFERENCES dbo.FARM_VARIETY(id),
    CONSTRAINT FK_FVTV_trait   FOREIGN KEY (trait_id)   REFERENCES dbo.FARM_VARIETY_TRAIT(id)
);
GO
CREATE UNIQUE INDEX UX_FVTV_variety_trait ON dbo.FARM_VARIETY_TRAIT_VALUE (variety_id, trait_id) WHERE deleted_at IS NULL;
GO
/* seed inicial de características (editáveis na tela) */
INSERT INTO dbo.FARM_VARIETY_TRAIT (culture_id, name, unit, data_type, options, multi, sort_order)
SELECT NULL, 'Tecnologia', NULL, 'list', N'["RR","RR2 PRO","Bollgard II","Bollgard 3","WideStrike","GLTP","STP","Enlist","Intacta RR2 PRO","Intacta 2 Xtend","VTPRO3","Viptera"]', 1, 1
WHERE NOT EXISTS (SELECT 1 FROM dbo.FARM_VARIETY_TRAIT WHERE name='Tecnologia' AND culture_id IS NULL AND deleted_at IS NULL);
INSERT INTO dbo.FARM_VARIETY_TRAIT (culture_id, name, unit, data_type, multi, sort_order)
SELECT NULL, 'Peso de mil sementes (PMS)', 'g', 'number', 0, 2
WHERE NOT EXISTS (SELECT 1 FROM dbo.FARM_VARIETY_TRAIT WHERE name='Peso de mil sementes (PMS)' AND culture_id IS NULL AND deleted_at IS NULL);
INSERT INTO dbo.FARM_VARIETY_TRAIT (culture_id, name, unit, data_type, multi, sort_order)
SELECT cu.id, 'Peso de capulho', 'g', 'number', 0, 3 FROM dbo.FARM_CULTURE cu
WHERE cu.name LIKE 'Algod%' AND cu.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.FARM_VARIETY_TRAIT WHERE name='Peso de capulho' AND culture_id=cu.id AND deleted_at IS NULL);
GO
/* override_pid: a caracteristica da variedade substitui o parametro medido na formula (fallback = medido) */
UPDATE dbo.FARM_VARIETY_TRAIT SET override_pid=2657  WHERE name='Peso de capulho' AND deleted_at IS NULL AND override_pid IS NULL;
UPDATE dbo.FARM_VARIETY_TRAIT SET override_pid=17790 WHERE name='Peso de mil sementes (PMS)' AND deleted_at IS NULL AND override_pid IS NULL;
GO

/* =====================================================================
   7) FARM_FIELD_PLANTING  -- FOLHA: talhão plantado num (safra+ciclo+cultura)
      com uma variedade. season_cycle_id = FARM_SEASON_CYCLE (safra+ciclo+cultura).
   ===================================================================== */
CREATE TABLE dbo.FARM_FIELD_PLANTING (
    id                      BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARM_FIELD_PLANTING PRIMARY KEY,
    season_cycle_id         BIGINT        NOT NULL,            -- FK -> FARM_SEASON_CYCLE
    field_id                BIGINT        NOT NULL,            -- FK -> FARM_FIELDS (talhão)
    variety_id              BIGINT        NULL,                -- FK -> FARM_VARIETY
    area_ha                 DECIMAL(14,4) NULL,
    irrigated               BIT           NULL,
    planting_date           DATE          NULL,
    emergence_date          DATE          NULL,
    harvest_prediction_date DATE          NULL,
    closed_date             DATE          NULL,
    productivity            DECIMAL(18,6) NULL,
    status                  VARCHAR(12)   NOT NULL CONSTRAINT DF_FFP_status DEFAULT 'PLANNED', -- PLANNED|ACTIVE|CLOSED
    source                  VARCHAR(12)   NOT NULL CONSTRAINT DF_FFP_source DEFAULT 'PLAN',    -- PLAN|FARMBOX
    farmbox_plantation_id   INT           NULL,                -- de/para -> FARMBOX_PLANTATION.farmbox_id
    notes                   NVARCHAR(MAX) NULL,
    active                  BIT           NULL CONSTRAINT DF_FFP_active  DEFAULT 1,
    created_at              DATETIME2(3)  NULL CONSTRAINT DF_FFP_created DEFAULT SYSUTCDATETIME(),
    updated_at              DATETIME2(3)  NULL,
    deleted_at              DATETIME2(3)  NULL,
    CONSTRAINT FK_FFP_cycle   FOREIGN KEY (season_cycle_id) REFERENCES dbo.FARM_SEASON_CYCLE(id),
    CONSTRAINT FK_FFP_field   FOREIGN KEY (field_id)        REFERENCES dbo.FARM_FIELDS(id),
    CONSTRAINT FK_FFP_variety FOREIGN KEY (variety_id)      REFERENCES dbo.FARM_VARIETY(id),
    CONSTRAINT CK_FFP_status  CHECK (status IN ('PLANNED','ACTIVE','CLOSED')),
    CONSTRAINT CK_FFP_source  CHECK (source IN ('PLAN','FARMBOX'))
);
GO
CREATE UNIQUE INDEX UX_FFP_cycle_field ON dbo.FARM_FIELD_PLANTING (season_cycle_id, field_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX UX_FFP_fb          ON dbo.FARM_FIELD_PLANTING (farmbox_plantation_id) WHERE farmbox_plantation_id IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX        IX_FFP_field       ON dbo.FARM_FIELD_PLANTING (field_id)        WHERE deleted_at IS NULL;
CREATE INDEX        IX_FFP_cycle       ON dbo.FARM_FIELD_PLANTING (season_cycle_id) WHERE deleted_at IS NULL;
CREATE INDEX        IX_FFP_variety     ON dbo.FARM_FIELD_PLANTING (variety_id)      WHERE deleted_at IS NULL;
GO

/* =====================================================================
   7c) FARM_PLANTING_REVIEW -- revisão de produtividade fora da curva detectada na
       importação de safras (corrigir valor / trocar cultura / aceitar). 1 por plantio.
       FK p/ FARM_FIELD_PLANTING — drop antes dela (módulo, linha ~2901).
   ===================================================================== */
CREATE TABLE dbo.FARM_PLANTING_REVIEW (
    id               BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARM_PLANTING_REVIEW PRIMARY KEY,
    planting_id      BIGINT        NOT NULL,              -- FK -> FARM_FIELD_PLANTING
    action           VARCHAR(12)   NOT NULL,              -- VALUE | CULTURE | ACCEPTED
    old_productivity DECIMAL(12,4) NULL,
    new_productivity DECIMAL(12,4) NULL,
    old_culture_id   BIGINT        NULL,
    new_culture_id   BIGINT        NULL,
    note             NVARCHAR(500) NULL,
    reviewed_at      DATETIME2(3)  NULL CONSTRAINT DF_FPREV_reviewed DEFAULT SYSUTCDATETIME(),
    created_at       DATETIME2(3)  NULL CONSTRAINT DF_FPREV_created DEFAULT SYSUTCDATETIME(),
    deleted_at       DATETIME2(3)  NULL,
    CONSTRAINT FK_FPREV_planting FOREIGN KEY (planting_id) REFERENCES dbo.FARM_FIELD_PLANTING(id),
    CONSTRAINT CK_FPREV_action   CHECK (action IN ('VALUE','CULTURE','ACCEPTED'))
);
GO
CREATE UNIQUE INDEX UX_FPREV_planting ON dbo.FARM_PLANTING_REVIEW (planting_id) WHERE deleted_at IS NULL;
GO

/* =====================================================================
   PROD_ESTIMATE_FORMULA — config da fórmula de estimativa de produtividade
   por (cultura, grupo de contagem Farmbox). A fórmula usa tokens pID (id do
   count_parameter no Farmbox); o backend avalia por PONTO a partir dos
   componentes crus de FARMBOX_COUNT_MONITORING e agrega por talhão.
   ===================================================================== */
IF OBJECT_ID('dbo.PROD_ESTIMATE_FORMULA','U') IS NULL
BEGIN
  CREATE TABLE dbo.PROD_ESTIMATE_FORMULA (
      id                 INT           IDENTITY(1,1) CONSTRAINT PK_PROD_EST_FORMULA PRIMARY KEY,
      culture_id         BIGINT        NOT NULL,               -- FK -> FARM_CULTURE.id
      count_group        VARCHAR(150)  NOT NULL,               -- grupo de contagem Farmbox
      label              VARCHAR(200)  NULL,                   -- nome amigavel exibido na config
      formula            NVARCHAR(1000) NOT NULL,              -- expressao pID (ex '(((p2660+p2663)/6)*p2657)*0.823045')
      output_unit        VARCHAR(20)   NULL,                   -- '@/ha' | 'sc/ha' | 't/ha'
      correction_factor  DECIMAL(9,4)  NOT NULL DEFAULT 1,     -- fator de calibracao vs colheita real
      min_valid          DECIMAL(12,4) NULL,                   -- descarta ponto abaixo (dado ruim)
      max_valid          DECIMAL(12,4) NULL,                   -- descarta ponto acima
      require_all_params BIT           NOT NULL DEFAULT 1,     -- exigir todos os pID presentes no ponto
      notes              NVARCHAR(1000) NULL,
      active             BIT           NOT NULL DEFAULT 1,
      created_at         DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
      updated_at         DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
      deleted_at         DATETIME2(3)  NULL
  );
  CREATE UNIQUE INDEX UX_PROD_EST_FORMULA ON dbo.PROD_ESTIMATE_FORMULA (culture_id, count_group) WHERE deleted_at IS NULL;
END
GO
/* seed ALGODAO (formula oficial Farmbox, validada MAPE 10.8% vs colheita real) */
INSERT INTO dbo.PROD_ESTIMATE_FORMULA (culture_id, count_group, label, formula, output_unit, correction_factor, min_valid, max_valid, require_all_params, notes, active)
SELECT cu.id, 'Estimativa de produtividade', 'Produtividade do Algodao (@/ha)',
       '((p2660+p2663)*p2657)*0.823045', '@/ha', 1, 50, 900, 0,
       'p2660=Macas, p2663=Capulho (engine normaliza POR METRO pelo nome), p2657=Peso Capulho(g). require_all_params=0: em amostragem precoce o capulho ainda nao abriu (=0) e a estimativa sai das macas. 0.823045 embute espac ~0.81m + arroba 15kg.', 1
FROM dbo.FARM_CULTURE cu
WHERE cu.name LIKE 'Algod%' AND cu.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.PROD_ESTIMATE_FORMULA f WHERE f.culture_id=cu.id AND f.count_group='Estimativa de produtividade' AND f.deleted_at IS NULL);
/* seed SOJA (cross-group: populacao vem do Stand inicial OU final, resolvida por plantation) */
INSERT INTO dbo.PROD_ESTIMATE_FORMULA (culture_id, count_group, label, formula, output_unit, correction_factor, min_valid, max_valid, require_all_params, notes, active)
SELECT cu.id, 'Estimativa de produtividade', 'Produtividade da Soja (sc/ha)',
       '(p2038*(1000000/p2407)*p17788*p17789*p17790)/1000/1000/60', 'sc/ha', 0.708, 20, 250, 1,
       'pop=(p2038/5)*(1000000/p2407) do Stand inicial ou final; p17788=vagens/planta, p17789=grao/vagem, p17790=PMS. Fator 0.708 calibrado vs colheita real (16 pontos, amostra pequena).', 1
FROM dbo.FARM_CULTURE cu
WHERE cu.name = 'Soja' AND cu.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.PROD_ESTIMATE_FORMULA f WHERE f.culture_id=cu.id AND f.count_group='Estimativa de produtividade' AND f.deleted_at IS NULL);
GO

/* =====================================================================
   8) VIEWS do planejamento
      VW_FARM_FIELD_PLANTING       -- folha achatada (safra→...→variedade)
      VW_FARMBOX_HARVEST_UNMAPPED  -- SAFRAS do Farmbox ainda SEM FARM_SEASON
   ===================================================================== */
CREATE VIEW dbo.VW_FARM_FIELD_PLANTING AS
SELECT  fp.id,
        s.id   AS season_id,   s.code AS season_code,   s.name AS season_name, s.is_current,
        cy.id  AS season_cycle_id, cy.cycle_no, cy.name AS cycle_name,
        cu.id  AS culture_id,  cu.code AS culture_code, cu.name AS culture_name, cu.color_hex,
        ff.id  AS field_id,    ff.code AS field_code,   ff.name AS field_name,
        pl.id  AS plot_id,     pl.name AS plot_name,
        fa.id  AS farm_id,     fa.name AS farm_name,
        v.id   AS variety_id,  v.name AS variety_name,  v.kind AS variety_kind, v.tech AS variety_tech,
        fp.area_ha, fp.irrigated, fp.planting_date, fp.emergence_date, fp.harvest_prediction_date,
        fp.closed_date, fp.productivity, fp.status, fp.source, fp.farmbox_plantation_id, fp.updated_at
FROM        dbo.FARM_FIELD_PLANTING fp
JOIN        dbo.FARM_SEASON_CYCLE   cy ON cy.id = fp.season_cycle_id AND cy.deleted_at IS NULL
JOIN        dbo.FARM_SEASON         s  ON s.id  = cy.season_id        AND s.deleted_at  IS NULL
JOIN        dbo.FARM_CULTURE        cu ON cu.id = cy.culture_id       AND cu.deleted_at IS NULL
JOIN        dbo.FARM_FIELDS         ff ON ff.id = fp.field_id         AND ff.deleted_at IS NULL
JOIN        dbo.FARM_PLOTS          pl ON pl.id = ff.plot_id          AND pl.deleted_at IS NULL
JOIN        dbo.FARM_FARMS          fa ON fa.id = pl.farm_id          AND fa.deleted_at IS NULL
LEFT JOIN   dbo.FARM_VARIETY        v  ON v.id  = fp.variety_id       AND v.deleted_at  IS NULL
WHERE       fp.deleted_at IS NULL;
GO

CREATE VIEW dbo.VW_FARMBOX_HARVEST_UNMAPPED AS
SELECT  h.farmbox_id            AS farmbox_harvest_id,
        h.name                  AS harvest_name,
        h.start_date, h.end_date,
        COUNT(p.id)             AS plantings,
        MIN(p.plantation_date)  AS first_planting,
        MAX(p.plantation_date)  AS last_planting
FROM        dbo.FARMBOX_HARVEST    h
LEFT JOIN   dbo.FARMBOX_PLANTATION p ON p.harvest_id = h.farmbox_id AND p.deleted_at IS NULL
WHERE       h.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.FARM_SEASON s
                   WHERE s.deleted_at IS NULL AND s.farmbox_harvest_id = h.farmbox_id)
GROUP BY    h.farmbox_id, h.name, h.start_date, h.end_date;
GO

/* =====================================================================
   9) ROTAÇÃO DE CULTURA — plano por GLEBA × SAFRA × CICLO (+ desvio no talhão)
      FARM_PLOT_ROTATION (slot do plano) + FARM_PLOT_ROTATION_CROP (cultura(s),
      consórcio = 2+) + views: matriz achatada e plano(gleba) × realizado(talhão).
   ===================================================================== */
CREATE TABLE dbo.FARM_PLOT_ROTATION (
    id          BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARM_PLOT_ROTATION PRIMARY KEY,
    plot_id     BIGINT        NOT NULL,            -- FK -> FARM_PLOTS (gleba)
    season_id   BIGINT        NOT NULL,            -- FK -> FARM_SEASON (safra)
    cycle_no    TINYINT       NOT NULL,            -- 1,2,3 (posição na rotação da safra)
    status      VARCHAR(16)   NOT NULL CONSTRAINT DF_FPR_status DEFAULT 'PLANNED', -- PLANNED|OPENING|FALLOW|NONE
    area_ha     DECIMAL(14,4) NULL,                -- quando a célula traz área (ex.: 'Café (130 há)')
    raw_label   NVARCHAR(120) NULL,                -- token original da célula (rastreio)
    source      VARCHAR(12)   NOT NULL CONSTRAINT DF_FPR_source DEFAULT 'PLAN',    -- PLAN|IMPORT
    notes       NVARCHAR(MAX) NULL,
    active      BIT           NULL CONSTRAINT DF_FPR_active  DEFAULT 1,
    created_at  DATETIME2(3)  NULL CONSTRAINT DF_FPR_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3)  NULL,
    deleted_at  DATETIME2(3)  NULL,
    CONSTRAINT FK_FPR_plot   FOREIGN KEY (plot_id)   REFERENCES dbo.FARM_PLOTS(id),
    CONSTRAINT FK_FPR_season FOREIGN KEY (season_id) REFERENCES dbo.FARM_SEASON(id),
    CONSTRAINT CK_FPR_status CHECK (status IN ('PLANNED','OPENING','FALLOW','NONE')),
    CONSTRAINT CK_FPR_source CHECK (source IN ('PLAN','IMPORT'))
);
GO
CREATE UNIQUE INDEX UX_FPR_plot_season_cycle ON dbo.FARM_PLOT_ROTATION (plot_id, season_id, cycle_no) WHERE deleted_at IS NULL;
CREATE INDEX        IX_FPR_plot   ON dbo.FARM_PLOT_ROTATION (plot_id)   WHERE deleted_at IS NULL;
CREATE INDEX        IX_FPR_season ON dbo.FARM_PLOT_ROTATION (season_id) WHERE deleted_at IS NULL;
GO

CREATE TABLE dbo.FARM_PLOT_ROTATION_CROP (
    id          BIGINT       IDENTITY(1,1) CONSTRAINT PK_FARM_PLOT_ROTATION_CROP PRIMARY KEY,
    rotation_id BIGINT       NOT NULL,             -- FK -> FARM_PLOT_ROTATION
    culture_id  BIGINT       NOT NULL,             -- FK -> FARM_CULTURE
    position    TINYINT      NOT NULL CONSTRAINT DF_FPRC_pos DEFAULT 1,  -- 1 principal, 2 consorciada...
    active      BIT          NULL CONSTRAINT DF_FPRC_active  DEFAULT 1,
    created_at  DATETIME2(3) NULL CONSTRAINT DF_FPRC_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3) NULL,
    deleted_at  DATETIME2(3) NULL,
    CONSTRAINT FK_FPRC_rotation FOREIGN KEY (rotation_id) REFERENCES dbo.FARM_PLOT_ROTATION(id),
    CONSTRAINT FK_FPRC_culture  FOREIGN KEY (culture_id)  REFERENCES dbo.FARM_CULTURE(id)
);
GO
CREATE UNIQUE INDEX UX_FPRC_rotation_culture ON dbo.FARM_PLOT_ROTATION_CROP (rotation_id, culture_id) WHERE deleted_at IS NULL;
CREATE INDEX        IX_FPRC_rotation         ON dbo.FARM_PLOT_ROTATION_CROP (rotation_id) WHERE deleted_at IS NULL;
GO

CREATE VIEW dbo.VW_FARM_PLOT_ROTATION AS
SELECT  r.id,
        fa.id AS farm_id, fa.name AS farm_name,
        pl.id AS plot_id, pl.code AS plot_code, pl.name AS plot_name,
        s.id  AS season_id, s.code AS season_code, s.name AS season_name,
        r.cycle_no, r.status, r.area_ha, r.raw_label,
        (SELECT STRING_AGG(CONVERT(nvarchar(max), c.name), N' + ') WITHIN GROUP (ORDER BY rc.position)
           FROM dbo.FARM_PLOT_ROTATION_CROP rc
           JOIN dbo.FARM_CULTURE c ON c.id = rc.culture_id AND c.deleted_at IS NULL
          WHERE rc.rotation_id = r.id AND rc.deleted_at IS NULL) AS cultures,
        r.source, r.notes, r.updated_at
FROM        dbo.FARM_PLOT_ROTATION r
JOIN        dbo.FARM_PLOTS  pl ON pl.id = r.plot_id   AND pl.deleted_at IS NULL
JOIN        dbo.FARM_FARMS  fa ON fa.id = pl.farm_id  AND fa.deleted_at IS NULL
JOIN        dbo.FARM_SEASON s  ON s.id  = r.season_id AND s.deleted_at  IS NULL
WHERE       r.deleted_at IS NULL;
GO

CREATE VIEW dbo.VW_FARM_ROTATION_DEVIATION AS
SELECT  fp.id AS planting_id,
        fa.name AS farm_name, pl.id AS plot_id, pl.code AS plot_code,
        ff.id AS field_id, ff.code AS field_code, ff.name AS field_name,
        s.code AS season_code, cy.cycle_no,
        cu.name AS culture_planted,
        (SELECT STRING_AGG(CONVERT(nvarchar(max), pc.name), N' + ') WITHIN GROUP (ORDER BY rc.position)
           FROM dbo.FARM_PLOT_ROTATION r2
           JOIN dbo.FARM_PLOT_ROTATION_CROP rc ON rc.rotation_id = r2.id AND rc.deleted_at IS NULL
           JOIN dbo.FARM_CULTURE pc ON pc.id = rc.culture_id AND pc.deleted_at IS NULL
          WHERE r2.deleted_at IS NULL AND r2.plot_id = ff.plot_id AND r2.season_id = cy.season_id AND r2.cycle_no = cy.cycle_no) AS cultures_planned,
        CASE WHEN EXISTS (
              SELECT 1 FROM dbo.FARM_PLOT_ROTATION r3
              JOIN dbo.FARM_PLOT_ROTATION_CROP rc3 ON rc3.rotation_id = r3.id AND rc3.deleted_at IS NULL
              WHERE r3.deleted_at IS NULL AND r3.plot_id = ff.plot_id AND r3.season_id = cy.season_id
                AND r3.cycle_no = cy.cycle_no AND rc3.culture_id = cy.culture_id
            ) THEN 0 ELSE 1 END AS deviated
FROM        dbo.FARM_FIELD_PLANTING fp
JOIN        dbo.FARM_SEASON_CYCLE   cy ON cy.id = fp.season_cycle_id AND cy.deleted_at IS NULL
JOIN        dbo.FARM_SEASON         s  ON s.id  = cy.season_id        AND s.deleted_at  IS NULL
JOIN        dbo.FARM_CULTURE        cu ON cu.id = cy.culture_id       AND cu.deleted_at IS NULL
JOIN        dbo.FARM_FIELDS         ff ON ff.id = fp.field_id         AND ff.deleted_at IS NULL
JOIN        dbo.FARM_PLOTS          pl ON pl.id = ff.plot_id          AND pl.deleted_at IS NULL
JOIN        dbo.FARM_FARMS          fa ON fa.id = pl.farm_id          AND fa.deleted_at IS NULL
WHERE       fp.deleted_at IS NULL
  AND EXISTS (SELECT 1 FROM dbo.FARM_PLOT_ROTATION r
               WHERE r.deleted_at IS NULL AND r.plot_id = ff.plot_id AND r.season_id = cy.season_id);
GO

/* =====================================================================
   10) FARM_FIELD_ROTATION — override por TALHÃO do plano da gleba (ajuste fino
       do "pivô que escapa"). Efetivo = override (se houver) ?? plano da gleba.
   ===================================================================== */
CREATE TABLE dbo.FARM_FIELD_ROTATION (
    id          BIGINT        IDENTITY(1,1) CONSTRAINT PK_FARM_FIELD_ROTATION PRIMARY KEY,
    field_id    BIGINT        NOT NULL,            -- FK -> FARM_FIELDS (pivô/talhão)
    season_id   BIGINT        NOT NULL,            -- FK -> FARM_SEASON
    cycle_no    TINYINT       NOT NULL,
    culture_id  BIGINT        NOT NULL,            -- FK -> FARM_CULTURE
    source      VARCHAR(12)   NOT NULL CONSTRAINT DF_FFR_source DEFAULT 'PLAN', -- PLAN (manual/mapa) | FARMBOX (importado)
    notes       NVARCHAR(MAX) NULL,
    active      BIT           NULL CONSTRAINT DF_FFR_active  DEFAULT 1,
    created_at  DATETIME2(3)  NULL CONSTRAINT DF_FFR_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3)  NULL,
    deleted_at  DATETIME2(3)  NULL,
    CONSTRAINT FK_FFR_field   FOREIGN KEY (field_id)   REFERENCES dbo.FARM_FIELDS(id),
    CONSTRAINT FK_FFR_season  FOREIGN KEY (season_id)  REFERENCES dbo.FARM_SEASON(id),
    CONSTRAINT FK_FFR_culture FOREIGN KEY (culture_id) REFERENCES dbo.FARM_CULTURE(id),
    CONSTRAINT CK_FFR_source  CHECK (source IN ('PLAN','FARMBOX'))
);
GO
CREATE UNIQUE INDEX UX_FFR_field_season_cycle ON dbo.FARM_FIELD_ROTATION (field_id, season_id, cycle_no) WHERE deleted_at IS NULL;
CREATE INDEX        IX_FFR_field   ON dbo.FARM_FIELD_ROTATION (field_id)  WHERE deleted_at IS NULL;
CREATE INDEX        IX_FFR_season  ON dbo.FARM_FIELD_ROTATION (season_id) WHERE deleted_at IS NULL;
GO

PRINT 'Modulo CALENDARIO AGRICOLA (FARM_SEASON) v1 criado com sucesso.';
GO


/* =====================================================================
   GCS_FARM  |  MÓDULO DE FERTILIDADE (análise de solo)  |  SQL Server (T-SQL)
   Versão: v4  |  Gerado em: 2026-06-27

   Linha do tempo do escopo:
     v1  modelo normalizado (parâmetro -> amostra -> resultado) + interpretação.
     v2  talhão por geolocalização (+conflito), visões de interpretação
         versionadas, modelos de cálculo configuráveis, pontos de coleta.
     v3  perfis de profundidade por ponto (checklist) + zonas/prescrição VRA.
     v4  (esta) PRESCRIÇÃO/ZONAS EXTRAÍDAS para o módulo genérico VRA_* (ver
         VRA_module_mssql.sql), reaproveitável por NDVI/semeadura/etc. A
         fertilidade apenas ALIMENTA o VRA (acoplamento solto: o backend gera
         a zonagem e grava VRA_ZONE_SET com source_type='FERTILITY').

   Fluxo do módulo:
     Plano de coleta -> Pontos (perfil de profundidade) -> [app coleta]
       -> Amostra (talhão por GPS) -> Resultados -> Interpretação (visões)
       -> Cálculos (calagem/gesso)  ──►  módulo VRA gera zonas e o mapa.

   Estrutura (17 tabelas + 4 views + 1 procedure):
     Catálogo : FERT_LAB, FERT_PARAMETER
     Visões   : FERT_INTERPRETATION_SET, FERT_SET_PARAMETER, FERT_INTERPRETATION
     Auditoria: FERT_IMPORT, FERT_IMPORT_ERROR
     Profund. : FERT_DEPTH_PROFILE, FERT_DEPTH_PROFILE_ITEM
     Coleta   : FERT_SAMPLE_PLAN, FERT_SAMPLE_POINT, FERT_POINT_DEPTH
     Núcleo   : FERT_SAMPLE, FERT_RESULT
     Cálculo  : FERT_CALC_MODEL, FERT_CALC_INPUT, FERT_CALC_RESULT
     Views    : VW_FERT_SAMPLE_WIDE, VW_FERT_RESULT_CLASSIFIED,
                VW_FERT_SAMPLE_LATEST, VW_FERT_POINT_STATUS
     Proc     : usp_fert_resolve_field_geo

   Zonas de manejo e prescrição VRA: módulo separado VRA_module_mssql.sql.
   Rodar em GCS_FARM, DEPOIS de FARM_FARMS / FARM_FIELDS / FARM_FIELD_GEOMETRY
   e do módulo FARM_SEASON (cultura/safra/ciclo).
   ===================================================================== */
-- USE GCS_FARM;
-- GO

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

/* =====================================================================
   0) DROP em ordem reversa de dependência (re-execução segura)
   ===================================================================== */
IF OBJECT_ID('dbo.usp_fert_resolve_field_geo') IS NOT NULL DROP PROCEDURE dbo.usp_fert_resolve_field_geo;
GO
IF OBJECT_ID('dbo.VW_FERT_POINT_STATUS')      IS NOT NULL DROP VIEW dbo.VW_FERT_POINT_STATUS;
IF OBJECT_ID('dbo.VW_FERT_SAMPLE_LATEST')     IS NOT NULL DROP VIEW dbo.VW_FERT_SAMPLE_LATEST;
IF OBJECT_ID('dbo.VW_FERT_RESULT_CLASSIFIED') IS NOT NULL DROP VIEW dbo.VW_FERT_RESULT_CLASSIFIED;
IF OBJECT_ID('dbo.VW_FERT_SAMPLE_WIDE')       IS NOT NULL DROP VIEW dbo.VW_FERT_SAMPLE_WIDE;
GO
-- FERT_CROP_EXPORT (FK -> FARM_CULTURE / FERT_EXPORT_SET / FARM_VARIETY) e sua view já são
-- dropados no módulo agro, antes de FARM_CULTURE. Aqui o catálogo e o perfil de exportação.
IF OBJECT_ID('dbo.FERT_EXPORT_NUTRIENT')      IS NOT NULL DROP TABLE dbo.FERT_EXPORT_NUTRIENT;
IF OBJECT_ID('dbo.FERT_EXPORT_SET')           IS NOT NULL DROP TABLE dbo.FERT_EXPORT_SET;
IF OBJECT_ID('dbo.FERT_CALC_RESULT')          IS NOT NULL DROP TABLE dbo.FERT_CALC_RESULT;
IF OBJECT_ID('dbo.FERT_CALC_INPUT')           IS NOT NULL DROP TABLE dbo.FERT_CALC_INPUT;
IF OBJECT_ID('dbo.FERT_CALC_MODEL')           IS NOT NULL DROP TABLE dbo.FERT_CALC_MODEL;
IF OBJECT_ID('dbo.FERT_RESULT')               IS NOT NULL DROP TABLE dbo.FERT_RESULT;
IF OBJECT_ID('dbo.FERT_SAMPLE')               IS NOT NULL DROP TABLE dbo.FERT_SAMPLE;
IF OBJECT_ID('dbo.FERT_POINT_DEPTH')          IS NOT NULL DROP TABLE dbo.FERT_POINT_DEPTH;
IF OBJECT_ID('dbo.FERT_SAMPLE_POINT')         IS NOT NULL DROP TABLE dbo.FERT_SAMPLE_POINT;
IF OBJECT_ID('dbo.FERT_SAMPLE_PLAN')          IS NOT NULL DROP TABLE dbo.FERT_SAMPLE_PLAN;
IF OBJECT_ID('dbo.FERT_DEPTH_PROFILE_ITEM')   IS NOT NULL DROP TABLE dbo.FERT_DEPTH_PROFILE_ITEM;
IF OBJECT_ID('dbo.FERT_DEPTH_PROFILE')        IS NOT NULL DROP TABLE dbo.FERT_DEPTH_PROFILE;
IF OBJECT_ID('dbo.FERT_IMPORT_ERROR')         IS NOT NULL DROP TABLE dbo.FERT_IMPORT_ERROR;
IF OBJECT_ID('dbo.FERT_IMPORT')               IS NOT NULL DROP TABLE dbo.FERT_IMPORT;
IF OBJECT_ID('dbo.FERT_INTERPRETATION')       IS NOT NULL DROP TABLE dbo.FERT_INTERPRETATION;
IF OBJECT_ID('dbo.FERT_SET_PARAMETER')        IS NOT NULL DROP TABLE dbo.FERT_SET_PARAMETER;
IF OBJECT_ID('dbo.FERT_INTERPRETATION_SET')   IS NOT NULL DROP TABLE dbo.FERT_INTERPRETATION_SET;
IF OBJECT_ID('dbo.FERT_PARAMETER')            IS NOT NULL DROP TABLE dbo.FERT_PARAMETER;
IF OBJECT_ID('dbo.FERT_LAB')                  IS NOT NULL DROP TABLE dbo.FERT_LAB;
GO

/* =====================================================================
   1) FERT_LAB  -- laboratório (proveniência; opcional)
   ===================================================================== */
CREATE TABLE dbo.FERT_LAB (
    id          BIGINT        IDENTITY(1,1) CONSTRAINT PK_FERT_LAB PRIMARY KEY,
    code        VARCHAR(40)   NULL,
    name        NVARCHAR(150) NOT NULL,
    city        VARCHAR(120)  NULL,
    state       CHAR(2)       NULL,
    notes       NVARCHAR(MAX) NULL,
    active      BIT           NULL CONSTRAINT DF_FERT_LAB_active DEFAULT 1,
    created_at  DATETIME2(3)  NULL CONSTRAINT DF_FERT_LAB_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3)  NULL,
    deleted_at  DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_FERT_LAB_code ON dbo.FERT_LAB (code) WHERE code IS NOT NULL;
GO

/* =====================================================================
   2) FERT_PARAMETER  -- catálogo de parâmetros analíticos (de/para)
   ===================================================================== */
CREATE TABLE dbo.FERT_PARAMETER (
    id            BIGINT        IDENTITY(1,1) CONSTRAINT PK_FERT_PARAMETER PRIMARY KEY,
    code          VARCHAR(40)   NOT NULL,
    name          NVARCHAR(120) NOT NULL,
    short_label   NVARCHAR(40)  NULL,
    unit          VARCHAR(20)   NULL,
    category      VARCHAR(10)   NOT NULL,
    method        VARCHAR(40)   NULL,
    decimals      TINYINT       NULL CONSTRAINT DF_FERT_PARAMETER_dec DEFAULT 2,
    display_order INT           NULL,
    active        BIT           NULL CONSTRAINT DF_FERT_PARAMETER_active DEFAULT 1,
    created_at    DATETIME2(3)  NULL CONSTRAINT DF_FERT_PARAMETER_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3)  NULL,
    deleted_at    DATETIME2(3)  NULL,
    CONSTRAINT CK_FERT_PARAMETER_cat CHECK
        (category IN ('MACRO','MICRO','ACIDEZ','CTC','RELACAO','PH','MO','FISICA','OUTRO'))
);
GO
CREATE UNIQUE INDEX UX_FERT_PARAMETER_code ON dbo.FERT_PARAMETER (code) WHERE deleted_at IS NULL;
GO

/* =====================================================================
   3) FERT_INTERPRETATION_SET  -- "Visão de agrônomo"
   ===================================================================== */
CREATE TABLE dbo.FERT_INTERPRETATION_SET (
    id           BIGINT        IDENTITY(1,1) CONSTRAINT PK_FERT_INTERPRETATION_SET PRIMARY KEY,
    code         VARCHAR(40)   NOT NULL,
    name         NVARCHAR(120) NOT NULL,
    agronomist   NVARCHAR(120) NULL,
    description  NVARCHAR(MAX) NULL,
    is_default   BIT           NULL CONSTRAINT DF_FERT_SET_default DEFAULT 0,
    active       BIT           NULL CONSTRAINT DF_FERT_SET_active  DEFAULT 1,
    created_at   DATETIME2(3)  NULL CONSTRAINT DF_FERT_SET_created DEFAULT SYSUTCDATETIME(),
    updated_at   DATETIME2(3)  NULL,
    deleted_at   DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_FERT_SET_code    ON dbo.FERT_INTERPRETATION_SET (code) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX UX_FERT_SET_default ON dbo.FERT_INTERPRETATION_SET (is_default) WHERE is_default = 1 AND deleted_at IS NULL;
GO

/* =====================================================================
   4) FERT_SET_PARAMETER  -- parâmetros exibidos por cada visão
   ===================================================================== */
CREATE TABLE dbo.FERT_SET_PARAMETER (
    id            BIGINT       IDENTITY(1,1) CONSTRAINT PK_FERT_SET_PARAMETER PRIMARY KEY,
    set_id        BIGINT       NOT NULL,
    parameter_id  BIGINT       NOT NULL,
    display_order INT          NULL,
    active        BIT          NULL CONSTRAINT DF_FERT_SET_PARAM_active DEFAULT 1,
    created_at    DATETIME2(3) NULL CONSTRAINT DF_FERT_SET_PARAM_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3) NULL,
    deleted_at    DATETIME2(3) NULL,
    CONSTRAINT FK_FERT_SET_PARAM_set   FOREIGN KEY (set_id)       REFERENCES dbo.FERT_INTERPRETATION_SET(id),
    CONSTRAINT FK_FERT_SET_PARAM_param FOREIGN KEY (parameter_id) REFERENCES dbo.FERT_PARAMETER(id)
);
GO
CREATE UNIQUE INDEX UX_FERT_SET_PARAM ON dbo.FERT_SET_PARAMETER (set_id, parameter_id) WHERE deleted_at IS NULL;
GO

/* =====================================================================
   5) FERT_INTERPRETATION  -- faixas agronômicas POR VISÃO e parâmetro
   ===================================================================== */
CREATE TABLE dbo.FERT_INTERPRETATION (
    id            BIGINT        IDENTITY(1,1) CONSTRAINT PK_FERT_INTERPRETATION PRIMARY KEY,
    set_id        BIGINT        NOT NULL,
    parameter_id  BIGINT        NOT NULL,
    class_label   NVARCHAR(30)  NOT NULL,
    class_rank    TINYINT       NOT NULL,
    min_value     DECIMAL(18,6) NULL,
    max_value     DECIMAL(18,6) NULL,
    color_hex     CHAR(7)       NULL,
    clay_min      SMALLINT      NULL,
    clay_max      SMALLINT      NULL,
    context       NVARCHAR(60)  NULL,
    source        NVARCHAR(120) NULL,
    active        BIT           NULL CONSTRAINT DF_FERT_INTERPRETATION_active DEFAULT 1,
    created_at    DATETIME2(3)  NULL CONSTRAINT DF_FERT_INTERPRETATION_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3)  NULL,
    deleted_at    DATETIME2(3)  NULL,
    CONSTRAINT FK_FERT_INTERPRETATION_set   FOREIGN KEY (set_id)       REFERENCES dbo.FERT_INTERPRETATION_SET(id),
    CONSTRAINT FK_FERT_INTERPRETATION_param FOREIGN KEY (parameter_id) REFERENCES dbo.FERT_PARAMETER(id)
);
GO
CREATE INDEX IX_FERT_INTERPRETATION_lookup ON dbo.FERT_INTERPRETATION (set_id, parameter_id, class_rank);
GO

/* =====================================================================
   6) FERT_IMPORT  -- lote de importação de planilha (auditoria)
   ===================================================================== */
CREATE TABLE dbo.FERT_IMPORT (
    id                 BIGINT        IDENTITY(1,1) CONSTRAINT PK_FERT_IMPORT PRIMARY KEY,
    source_filename    NVARCHAR(255) NULL,
    sheet_name         NVARCHAR(120) NULL,
    file_hash          CHAR(64)      NULL,
    producer_label     NVARCHAR(150) NULL,
    farm_label         NVARCHAR(150) NULL,
    lab_id             BIGINT        NULL,
    header_snapshot    NVARCHAR(MAX) NULL,
    total_rows         INT           NULL,
    imported_rows      INT           NULL,
    rejected_rows      INT           NULL,
    status             VARCHAR(15)   NULL,
    imported_by        VARCHAR(60)   NULL,
    notes              NVARCHAR(MAX) NULL,
    created_at         DATETIME2(3)  NULL CONSTRAINT DF_FERT_IMPORT_created DEFAULT SYSUTCDATETIME(),
    updated_at         DATETIME2(3)  NULL,
    deleted_at         DATETIME2(3)  NULL,
    CONSTRAINT FK_FERT_IMPORT_lab    FOREIGN KEY (lab_id) REFERENCES dbo.FERT_LAB(id),
    CONSTRAINT CK_FERT_IMPORT_status CHECK (status IS NULL OR status IN ('IN_PROGRESS','SUCCESS','PARTIAL','ERROR')),
    CONSTRAINT CK_FERT_IMPORT_json   CHECK (header_snapshot IS NULL OR ISJSON(header_snapshot) = 1)
);
GO
CREATE INDEX        IX_FERT_IMPORT_created ON dbo.FERT_IMPORT (created_at);
CREATE UNIQUE INDEX UX_FERT_IMPORT_hash    ON dbo.FERT_IMPORT (file_hash) WHERE file_hash IS NOT NULL AND deleted_at IS NULL;
GO

/* =====================================================================
   7) FERT_IMPORT_ERROR  -- erros por linha/coluna na importação
   ===================================================================== */
CREATE TABLE dbo.FERT_IMPORT_ERROR (
    id          BIGINT        IDENTITY(1,1) CONSTRAINT PK_FERT_IMPORT_ERROR PRIMARY KEY,
    import_id   BIGINT        NOT NULL,
    source_row  INT           NULL,
    column_name NVARCHAR(80)  NULL,
    error_type  VARCHAR(30)   NULL,
    message     NVARCHAR(MAX) NULL,
    raw_value   NVARCHAR(MAX) NULL,
    created_at  DATETIME2(3)  NULL CONSTRAINT DF_FERT_IMPORT_ERROR_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3)  NULL,
    deleted_at  DATETIME2(3)  NULL,
    CONSTRAINT FK_FERT_IMPORT_ERROR_import FOREIGN KEY (import_id) REFERENCES dbo.FERT_IMPORT(id),
    CONSTRAINT CK_FERT_IMPORT_ERROR_type CHECK (error_type IS NULL OR error_type IN ('MISSING_COLUMN','INVALID_VALUE','DUPLICATE_KEY','OTHER'))
);
GO
CREATE INDEX IX_FERT_IMPORT_ERROR_import ON dbo.FERT_IMPORT_ERROR (import_id);
GO

/* =====================================================================
   8) FERT_DEPTH_PROFILE  -- perfil de profundidades reutilizável
      Ex.: SIMPLES (0-20); DUPLA (0-20, 20-40); COMPLETA (0-20,20-40,40-60)
   ===================================================================== */
CREATE TABLE dbo.FERT_DEPTH_PROFILE (
    id          BIGINT        IDENTITY(1,1) CONSTRAINT PK_FERT_DEPTH_PROFILE PRIMARY KEY,
    code        VARCHAR(40)   NOT NULL,
    name        NVARCHAR(120) NOT NULL,
    description NVARCHAR(MAX) NULL,
    active      BIT           NULL CONSTRAINT DF_FERT_DPROFILE_active DEFAULT 1,
    created_at  DATETIME2(3)  NULL CONSTRAINT DF_FERT_DPROFILE_created DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2(3)  NULL,
    deleted_at  DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_FERT_DPROFILE_code ON dbo.FERT_DEPTH_PROFILE (code) WHERE deleted_at IS NULL;
GO

/* =====================================================================
   9) FERT_DEPTH_PROFILE_ITEM  -- as profundidades de cada perfil
   ===================================================================== */
CREATE TABLE dbo.FERT_DEPTH_PROFILE_ITEM (
    id            BIGINT       IDENTITY(1,1) CONSTRAINT PK_FERT_DEPTH_PROFILE_ITEM PRIMARY KEY,
    profile_id    BIGINT       NOT NULL,
    depth_label   VARCHAR(30)  NOT NULL,                 -- "0 a 20 cm"
    depth_from_cm SMALLINT     NULL,
    depth_to_cm   SMALLINT     NULL,
    display_order INT          NULL,
    created_at    DATETIME2(3) NULL CONSTRAINT DF_FERT_DITEM_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3) NULL,
    deleted_at    DATETIME2(3) NULL,
    CONSTRAINT FK_FERT_DITEM_profile FOREIGN KEY (profile_id) REFERENCES dbo.FERT_DEPTH_PROFILE(id)
);
GO
CREATE UNIQUE INDEX UX_FERT_DITEM ON dbo.FERT_DEPTH_PROFILE_ITEM (profile_id, depth_label) WHERE deleted_at IS NULL;
GO

/* =====================================================================
   10) FERT_SAMPLE_PLAN  -- campanha/grade de coleta
   ===================================================================== */
CREATE TABLE dbo.FERT_SAMPLE_PLAN (
    id                      BIGINT        IDENTITY(1,1) CONSTRAINT PK_FERT_SAMPLE_PLAN PRIMARY KEY,
    code                    VARCHAR(40)   NULL,
    name                    NVARCHAR(150) NOT NULL,
    farm_id                 BIGINT        NULL,
    field_id                BIGINT        NULL,
    season                  VARCHAR(20)   NULL,            -- fallback texto; preferir season_id
    season_id               BIGINT        NULL,            -- FK -> FARM_SEASON (safra)
    season_cycle_id         BIGINT        NULL,            -- FK -> FARM_SEASON_CYCLE (cultura), se p/ adubação
    default_depth_profile_id BIGINT       NULL,           -- perfil de profundidade padrão da campanha
    grid_spec               NVARCHAR(MAX) NULL,           -- JSON: tipo de grade, tamanho_ha...
    analysis_type           VARCHAR(20)   NULL,           -- QUIMICA | FOLIAR | NEMATOIDE | DRES
    status                  VARCHAR(15)   NULL,
    created_by              VARCHAR(60)   NULL,
    published_at            DATETIME2(3)  NULL,
    notes                   NVARCHAR(MAX) NULL,
    created_at              DATETIME2(3)  NULL CONSTRAINT DF_FERT_PLAN_created DEFAULT SYSUTCDATETIME(),
    updated_at              DATETIME2(3)  NULL,
    deleted_at              DATETIME2(3)  NULL,
    CONSTRAINT FK_FERT_PLAN_farm    FOREIGN KEY (farm_id)  REFERENCES dbo.FARM_FARMS(id),
    CONSTRAINT FK_FERT_PLAN_field   FOREIGN KEY (field_id) REFERENCES dbo.FARM_FIELDS(id),
    CONSTRAINT FK_FERT_PLAN_profile FOREIGN KEY (default_depth_profile_id) REFERENCES dbo.FERT_DEPTH_PROFILE(id),
    CONSTRAINT FK_FERT_PLAN_season  FOREIGN KEY (season_id)       REFERENCES dbo.FARM_SEASON(id),
    CONSTRAINT FK_FERT_PLAN_cycle   FOREIGN KEY (season_cycle_id) REFERENCES dbo.FARM_SEASON_CYCLE(id),
    CONSTRAINT CK_FERT_PLAN_status CHECK (status IS NULL OR status IN ('DRAFT','PUBLISHED','IN_FIELD','DONE','CANCELLED')),
    CONSTRAINT CK_FERT_PLAN_analysis CHECK (analysis_type IS NULL OR analysis_type IN ('QUIMICA','FOLIAR','NEMATOIDE','DRES')),
    CONSTRAINT CK_FERT_PLAN_json   CHECK (grid_spec IS NULL OR ISJSON(grid_spec) = 1)
);
GO
CREATE UNIQUE INDEX UX_FERT_PLAN_code ON dbo.FERT_SAMPLE_PLAN (code) WHERE code IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX        IX_FERT_PLAN_farm ON dbo.FERT_SAMPLE_PLAN (farm_id);
GO

/* =====================================================================
   11) FERT_SAMPLE_POINT  -- ponto de coleta georreferenciado (vai p/ o app)
       depth_profile_id define QUAIS profundidades coletar neste ponto.
   ===================================================================== */
CREATE TABLE dbo.FERT_SAMPLE_POINT (
    id               BIGINT        IDENTITY(1,1) CONSTRAINT PK_FERT_SAMPLE_POINT PRIMARY KEY,
    plan_id          BIGINT        NOT NULL,
    point_code       VARCHAR(60)   NOT NULL,
    field_id         BIGINT        NULL,
    field_id_geo     BIGINT        NULL,
    latitude         DECIMAL(10,7) NULL,
    longitude        DECIMAL(10,7) NULL,
    geom             GEOGRAPHY     NULL,
    depth_profile_id BIGINT        NULL,                  -- perfil deste ponto (ex.: Completa)
    status           VARCHAR(15)   NULL,                  -- PLANNED|COLLECTED|SYNCED|CANCELLED
    collected_at     DATETIME2(3)  NULL,
    collected_by     VARCHAR(60)   NULL,
    device_info      NVARCHAR(200) NULL,
    external_id      VARCHAR(80)   NULL,
    notes            NVARCHAR(MAX) NULL,
    created_at       DATETIME2(3)  NULL CONSTRAINT DF_FERT_POINT_created DEFAULT SYSUTCDATETIME(),
    updated_at       DATETIME2(3)  NULL,
    deleted_at       DATETIME2(3)  NULL,
    CONSTRAINT FK_FERT_POINT_plan      FOREIGN KEY (plan_id)          REFERENCES dbo.FERT_SAMPLE_PLAN(id),
    CONSTRAINT FK_FERT_POINT_field     FOREIGN KEY (field_id)         REFERENCES dbo.FARM_FIELDS(id),
    CONSTRAINT FK_FERT_POINT_field_geo FOREIGN KEY (field_id_geo)     REFERENCES dbo.FARM_FIELDS(id),
    CONSTRAINT FK_FERT_POINT_profile   FOREIGN KEY (depth_profile_id) REFERENCES dbo.FERT_DEPTH_PROFILE(id),
    CONSTRAINT CK_FERT_POINT_status CHECK (status IS NULL OR status IN ('PLANNED','COLLECTED','SYNCED','CANCELLED'))
);
GO
CREATE UNIQUE INDEX UX_FERT_POINT_plan_code ON dbo.FERT_SAMPLE_POINT (plan_id, point_code) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX UX_FERT_POINT_external  ON dbo.FERT_SAMPLE_POINT (external_id) WHERE external_id IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX        IX_FERT_POINT_status    ON dbo.FERT_SAMPLE_POINT (status);
GO

/* =====================================================================
   12) FERT_POINT_DEPTH  -- checklist concreto de profundidades por ponto
       (expandido do perfil; o app marca cada furo; cada um vira 1 amostra)
   ===================================================================== */
CREATE TABLE dbo.FERT_POINT_DEPTH (
    id            BIGINT       IDENTITY(1,1) CONSTRAINT PK_FERT_POINT_DEPTH PRIMARY KEY,
    point_id      BIGINT       NOT NULL,
    depth_label   VARCHAR(30)  NOT NULL,
    depth_from_cm SMALLINT     NULL,
    depth_to_cm   SMALLINT     NULL,
    display_order INT          NULL,
    status        VARCHAR(15)  NULL,                      -- PLANNED|COLLECTED|CANCELLED
    collected_at  DATETIME2(3) NULL,
    created_at    DATETIME2(3) NULL CONSTRAINT DF_FERT_PDEPTH_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3) NULL,
    deleted_at    DATETIME2(3) NULL,
    CONSTRAINT FK_FERT_PDEPTH_point FOREIGN KEY (point_id) REFERENCES dbo.FERT_SAMPLE_POINT(id),
    CONSTRAINT CK_FERT_PDEPTH_status CHECK (status IS NULL OR status IN ('PLANNED','COLLECTED','CANCELLED'))
);
GO
CREATE UNIQUE INDEX UX_FERT_PDEPTH ON dbo.FERT_POINT_DEPTH (point_id, depth_label) WHERE deleted_at IS NULL;
GO

/* =====================================================================
   13) FERT_SAMPLE  -- amostra de solo (cabeçalho / identidade)
   ===================================================================== */
CREATE TABLE dbo.FERT_SAMPLE (
    id             BIGINT        IDENTITY(1,1) CONSTRAINT PK_FERT_SAMPLE PRIMARY KEY,
    import_id      BIGINT        NULL,
    lab_id         BIGINT        NULL,
    plan_point_id  BIGINT        NULL,                     -- ponto de coleta de origem
    point_depth_id BIGINT        NULL,                     -- profundidade específica do ponto
    producer_name  NVARCHAR(150) NULL,
    farm_label     NVARCHAR(150) NOT NULL,
    plot_label     VARCHAR(60)   NOT NULL,
    point_code     VARCHAR(60)   NOT NULL,
    farm_id        BIGINT        NULL,
    field_id       BIGINT        NULL,                     -- talhão EFETIVO (default = geo)
    field_id_geo   BIGINT        NULL,                     -- por geolocalização
    field_id_label BIGINT        NULL,                     -- por de/para do texto
    field_source   VARCHAR(10)   NULL,                     -- GEO|LABEL|MANUAL
    geo_conflict   BIT           NULL,
    sample_date    DATE          NOT NULL,
    latitude       DECIMAL(10,7) NULL,
    longitude      DECIMAL(10,7) NULL,
    geom           GEOGRAPHY     NULL,
    depth_label    VARCHAR(30)   NOT NULL,
    depth_from_cm  SMALLINT      NULL,
    depth_to_cm    SMALLINT      NULL,
    source_row     INT           NULL,
    payload        NVARCHAR(MAX) NULL,
    created_at     DATETIME2(3)  NULL CONSTRAINT DF_FERT_SAMPLE_created DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)  NULL,
    deleted_at     DATETIME2(3)  NULL,
    CONSTRAINT FK_FERT_SAMPLE_import     FOREIGN KEY (import_id)      REFERENCES dbo.FERT_IMPORT(id),
    CONSTRAINT FK_FERT_SAMPLE_lab        FOREIGN KEY (lab_id)         REFERENCES dbo.FERT_LAB(id),
    CONSTRAINT FK_FERT_SAMPLE_point      FOREIGN KEY (plan_point_id)  REFERENCES dbo.FERT_SAMPLE_POINT(id),
    CONSTRAINT FK_FERT_SAMPLE_pdepth     FOREIGN KEY (point_depth_id) REFERENCES dbo.FERT_POINT_DEPTH(id),
    CONSTRAINT FK_FERT_SAMPLE_farm       FOREIGN KEY (farm_id)        REFERENCES dbo.FARM_FARMS(id),
    CONSTRAINT FK_FERT_SAMPLE_field      FOREIGN KEY (field_id)       REFERENCES dbo.FARM_FIELDS(id),
    CONSTRAINT FK_FERT_SAMPLE_field_geo  FOREIGN KEY (field_id_geo)   REFERENCES dbo.FARM_FIELDS(id),
    CONSTRAINT FK_FERT_SAMPLE_field_lbl  FOREIGN KEY (field_id_label) REFERENCES dbo.FARM_FIELDS(id),
    CONSTRAINT CK_FERT_SAMPLE_src  CHECK (field_source IS NULL OR field_source IN ('GEO','LABEL','MANUAL')),
    CONSTRAINT CK_FERT_SAMPLE_json CHECK (payload IS NULL OR ISJSON(payload) = 1)
);
GO
CREATE UNIQUE INDEX UX_FERT_SAMPLE_natural
    ON dbo.FERT_SAMPLE (farm_label, plot_label, point_code, depth_label, sample_date)
    WHERE deleted_at IS NULL;
CREATE INDEX IX_FERT_SAMPLE_field    ON dbo.FERT_SAMPLE (field_id, sample_date) WHERE field_id IS NOT NULL;
CREATE INDEX IX_FERT_SAMPLE_date     ON dbo.FERT_SAMPLE (sample_date);
CREATE INDEX IX_FERT_SAMPLE_import   ON dbo.FERT_SAMPLE (import_id);
CREATE INDEX IX_FERT_SAMPLE_conflict ON dbo.FERT_SAMPLE (geo_conflict) WHERE geo_conflict = 1;
GO

/* =====================================================================
   14) FERT_RESULT  -- resultado normalizado: 1 linha por (amostra, parâmetro)
   ===================================================================== */
CREATE TABLE dbo.FERT_RESULT (
    id            BIGINT        IDENTITY(1,1) CONSTRAINT PK_FERT_RESULT PRIMARY KEY,
    sample_id     BIGINT        NOT NULL,
    parameter_id  BIGINT        NOT NULL,
    value_num     DECIMAL(18,6) NULL,
    value_text    VARCHAR(50)   NULL,
    created_at    DATETIME2(3)  NULL CONSTRAINT DF_FERT_RESULT_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3)  NULL,
    deleted_at    DATETIME2(3)  NULL,
    CONSTRAINT FK_FERT_RESULT_sample    FOREIGN KEY (sample_id)    REFERENCES dbo.FERT_SAMPLE(id),
    CONSTRAINT FK_FERT_RESULT_parameter FOREIGN KEY (parameter_id) REFERENCES dbo.FERT_PARAMETER(id)
);
GO
CREATE UNIQUE INDEX UX_FERT_RESULT_sample_param ON dbo.FERT_RESULT (sample_id, parameter_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_FERT_RESULT_param ON dbo.FERT_RESULT (parameter_id, value_num) WHERE deleted_at IS NULL;
GO

/* =====================================================================
   15) FERT_CALC_MODEL  -- modelo de cálculo (fórmula como dado)
   ===================================================================== */
CREATE TABLE dbo.FERT_CALC_MODEL (
    id            BIGINT        IDENTITY(1,1) CONSTRAINT PK_FERT_CALC_MODEL PRIMARY KEY,
    code          VARCHAR(40)   NOT NULL,
    name          NVARCHAR(150) NOT NULL,
    category      VARCHAR(15)   NOT NULL,
    description   NVARCHAR(MAX) NULL,
    formula_expr  NVARCHAR(MAX) NOT NULL,
    result_unit   VARCHAR(20)   NULL,
    result_label  NVARCHAR(80)  NULL,
    version       INT           NULL CONSTRAINT DF_FERT_CALC_MODEL_ver DEFAULT 1,
    is_default    BIT           NULL CONSTRAINT DF_FERT_CALC_MODEL_def DEFAULT 0,
    active        BIT           NULL CONSTRAINT DF_FERT_CALC_MODEL_active DEFAULT 1,
    source        NVARCHAR(150) NULL,
    created_at    DATETIME2(3)  NULL CONSTRAINT DF_FERT_CALC_MODEL_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3)  NULL,
    deleted_at    DATETIME2(3)  NULL,
    CONSTRAINT CK_FERT_CALC_MODEL_cat CHECK (category IN ('LIMING','GYPSUM','FERTILITY','CUSTOM'))
);
GO
CREATE UNIQUE INDEX UX_FERT_CALC_MODEL_code ON dbo.FERT_CALC_MODEL (code, version) WHERE deleted_at IS NULL;
GO

/* =====================================================================
   16) FERT_CALC_INPUT  -- variáveis/coeficientes de um modelo
   ===================================================================== */
CREATE TABLE dbo.FERT_CALC_INPUT (
    id            BIGINT        IDENTITY(1,1) CONSTRAINT PK_FERT_CALC_INPUT PRIMARY KEY,
    model_id      BIGINT        NOT NULL,
    var_name      VARCHAR(40)   NOT NULL,
    label         NVARCHAR(120) NULL,
    source_type   VARCHAR(10)   NOT NULL,
    parameter_code VARCHAR(40)  NULL,
    default_value DECIMAL(18,6) NULL,
    unit          VARCHAR(20)   NULL,
    required      BIT           NULL CONSTRAINT DF_FERT_CALC_INPUT_req DEFAULT 1,
    display_order INT           NULL,
    created_at    DATETIME2(3)  NULL CONSTRAINT DF_FERT_CALC_INPUT_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3)  NULL,
    deleted_at    DATETIME2(3)  NULL,
    CONSTRAINT FK_FERT_CALC_INPUT_model FOREIGN KEY (model_id) REFERENCES dbo.FERT_CALC_MODEL(id),
    CONSTRAINT CK_FERT_CALC_INPUT_src CHECK (source_type IN ('PARAMETER','CONSTANT','USER','FIELD'))
);
GO
CREATE UNIQUE INDEX UX_FERT_CALC_INPUT_var ON dbo.FERT_CALC_INPUT (model_id, var_name) WHERE deleted_at IS NULL;
GO

/* =====================================================================
   17) FERT_CALC_RESULT  -- recomendação calculada (histórico)
   ===================================================================== */
CREATE TABLE dbo.FERT_CALC_RESULT (
    id             BIGINT        IDENTITY(1,1) CONSTRAINT PK_FERT_CALC_RESULT PRIMARY KEY,
    sample_id      BIGINT        NOT NULL,
    model_id       BIGINT        NOT NULL,
    result_value   DECIMAL(18,6) NULL,
    result_unit    VARCHAR(20)   NULL,
    inputs_snapshot NVARCHAR(MAX) NULL,
    computed_at    DATETIME2(3)  NULL CONSTRAINT DF_FERT_CALC_RESULT_at DEFAULT SYSUTCDATETIME(),
    computed_by    VARCHAR(60)   NULL,
    notes          NVARCHAR(MAX) NULL,
    deleted_at     DATETIME2(3)  NULL,
    CONSTRAINT FK_FERT_CALC_RESULT_sample FOREIGN KEY (sample_id) REFERENCES dbo.FERT_SAMPLE(id),
    CONSTRAINT FK_FERT_CALC_RESULT_model  FOREIGN KEY (model_id)  REFERENCES dbo.FERT_CALC_MODEL(id),
    CONSTRAINT CK_FERT_CALC_RESULT_json   CHECK (inputs_snapshot IS NULL OR ISJSON(inputs_snapshot) = 1)
);
GO
CREATE INDEX IX_FERT_CALC_RESULT_sample ON dbo.FERT_CALC_RESULT (sample_id, model_id, computed_at);
GO

/* =====================================================================
   17b) EXPORTAÇÃO DE NUTRIENTES — catálogo + coeficiente por cultura
        "Extração" = total absorvido; "Exportação" = removido na colheita.
        Coef. em kg/t (macro) ou g/t (micro) do produto; no mapa:
        kg/ha removidos = produtividade (t/ha) × coef.
   ===================================================================== */
CREATE TABLE dbo.FERT_EXPORT_NUTRIENT (
    id            BIGINT        IDENTITY(1,1) CONSTRAINT PK_FERT_EXPORT_NUTRIENT PRIMARY KEY,
    code          VARCHAR(12)   NOT NULL,              -- 'N','P2O5','K2O','CA','MG','S','B','CU','FE','MN','ZN','NI','MO','CL'
    name          NVARCHAR(60)  NOT NULL,
    symbol        NVARCHAR(12)  NULL,
    category      VARCHAR(10)   NOT NULL,              -- MACRO | MICRO
    coef_unit     VARCHAR(8)    NULL CONSTRAINT DF_FERT_EXPNUT_cunit DEFAULT 'kg/t', -- MACRO=kg/t, MICRO=g/t
    map_unit      VARCHAR(16)   NULL CONSTRAINT DF_FERT_EXPNUT_unit  DEFAULT 'kg/ha',
    color_hex     CHAR(7)       NULL,
    display_order INT           NULL,
    active        BIT           NULL CONSTRAINT DF_FERT_EXPNUT_active  DEFAULT 1,
    created_at    DATETIME2(3)  NULL CONSTRAINT DF_FERT_EXPNUT_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3)  NULL,
    deleted_at    DATETIME2(3)  NULL,
    CONSTRAINT CK_FERT_EXPNUT_cat CHECK (category IN ('MACRO','MICRO'))
);
GO
CREATE UNIQUE INDEX UX_FERT_EXPORT_NUTRIENT_code ON dbo.FERT_EXPORT_NUTRIENT (code) WHERE deleted_at IS NULL;
GO

-- Perfil/visão pesquisada dos coeficientes (ICL, Embrapa, Fundação MT…). 1 padrão (is_default).
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
GO
CREATE UNIQUE INDEX UX_FERT_EXPORT_SET_code ON dbo.FERT_EXPORT_SET(code) WHERE deleted_at IS NULL;
-- invariante: no máximo UM perfil padrão ativo (garantido pelo banco)
CREATE UNIQUE INDEX UX_FERT_EXPORT_SET_onedefault ON dbo.FERT_EXPORT_SET(is_default) WHERE is_default = 1 AND deleted_at IS NULL;
GO
-- perfil ICL padrão (literais via NCHAR → independentes do codepage do sqlcmd)
INSERT INTO dbo.FERT_EXPORT_SET (code, name, agronomist, description, is_default)
VALUES ('ICL',
        N'ICL (Nutri' + NCHAR(231) + NCHAR(227) + N'o Mineral)',
        N'ICL ' + NCHAR(8212) + N' Nutri' + NCHAR(231) + NCHAR(227) + N'o mineral de plantas',
        N'Coeficientes de exporta' + NCHAR(231) + NCHAR(227) + N'o/extra' + NCHAR(231) + NCHAR(227)
          + N'o da literatura ICL (base inicial; inclui convers' + NCHAR(245) + N'es por cultura).',
        1);
GO

CREATE TABLE dbo.FERT_CROP_EXPORT (
    id                     BIGINT        IDENTITY(1,1) CONSTRAINT PK_FERT_CROP_EXPORT PRIMARY KEY,
    set_id                 BIGINT        NOT NULL,           -- FK -> FERT_EXPORT_SET (perfil pesquisado)
    culture_id             BIGINT        NOT NULL,           -- FK -> FARM_CULTURE
    nutrient_id            BIGINT        NOT NULL,           -- FK -> FERT_EXPORT_NUTRIENT
    variety_id             BIGINT        NULL,               -- FK -> FARM_VARIETY (escopo variedade); NULL = tecnologia/padrão
    tech_value             NVARCHAR(120) NULL,               -- escopo tecnologia (= FARM_VARIETY.primary_tech); NULL c/ variety_id NULL = padrão
    basis                  VARCHAR(16)   NOT NULL CONSTRAINT DF_FERT_CROP_EXPORT_basis DEFAULT 'PRODUCT', -- PRODUCT | GRAIN | TOTAL
    export_kg_per_ton      DECIMAL(18,6) NULL,               -- EXPORTAÇÃO (removido na colheita) kg/t de produto
    extraction_kg_per_ton  DECIMAL(18,6) NULL,               -- EXTRAÇÃO (absorção total) kg/t (opcional)
    product_moisture_pct   DECIMAL(5,2)  NULL,
    source                 NVARCHAR(160) NULL,
    notes                  NVARCHAR(MAX) NULL,
    active                 BIT           NULL CONSTRAINT DF_FERT_CROP_EXPORT_active  DEFAULT 1,
    created_at             DATETIME2(3)  NULL CONSTRAINT DF_FERT_CROP_EXPORT_created DEFAULT SYSUTCDATETIME(),
    updated_at             DATETIME2(3)  NULL,
    deleted_at             DATETIME2(3)  NULL,
    -- colapsam os NULL do escopo p/ a unique (variedade=0/tech='' → padrão)
    k_variety AS (ISNULL(variety_id, CONVERT(BIGINT,0))) PERSISTED,
    k_tech    AS (ISNULL(tech_value, N'')) PERSISTED,
    CONSTRAINT FK_FERT_CROP_EXPORT_set      FOREIGN KEY (set_id)      REFERENCES dbo.FERT_EXPORT_SET(id),
    CONSTRAINT FK_FERT_CROP_EXPORT_culture  FOREIGN KEY (culture_id)  REFERENCES dbo.FARM_CULTURE(id),
    CONSTRAINT FK_FERT_CROP_EXPORT_nutrient FOREIGN KEY (nutrient_id) REFERENCES dbo.FERT_EXPORT_NUTRIENT(id),
    CONSTRAINT FK_FERT_CROP_EXPORT_variety  FOREIGN KEY (variety_id)  REFERENCES dbo.FARM_VARIETY(id),
    CONSTRAINT CK_FERT_CROP_EXPORT_basis CHECK (basis IN ('PRODUCT','GRAIN','TOTAL'))
);
GO
-- unique por ESCOPO: padrão / tecnologia / variedade coexistem por (perfil, cultura, nutriente, basis)
CREATE UNIQUE INDEX UX_FERT_CROP_EXPORT_scope
    ON dbo.FERT_CROP_EXPORT (set_id, culture_id, nutrient_id, basis, k_variety, k_tech) WHERE deleted_at IS NULL;
CREATE INDEX IX_FERT_CROP_EXPORT_culture
    ON dbo.FERT_CROP_EXPORT (culture_id) WHERE deleted_at IS NULL;
GO

CREATE VIEW dbo.VW_FERT_CROP_EXPORT AS
SELECT  ce.id,
        ce.culture_id, c.code AS culture_code, c.name AS culture_name,
        ce.nutrient_id, n.code AS nutrient_code, n.name AS nutrient_name,
        n.category AS nutrient_category, n.symbol AS nutrient_symbol,
        ce.basis, ce.export_kg_per_ton, ce.extraction_kg_per_ton,
        ce.product_moisture_pct, ce.source, ce.updated_at
FROM        dbo.FERT_CROP_EXPORT  ce
JOIN        dbo.FARM_CULTURE      c ON c.id = ce.culture_id  AND c.deleted_at IS NULL
JOIN        dbo.FERT_EXPORT_NUTRIENT n ON n.id = ce.nutrient_id AND n.deleted_at IS NULL
WHERE       ce.deleted_at IS NULL;
GO

/* =====================================================================
   17c) FERT_AMENDMENT_APPLICATION -- adubação de corretivos por talhão × safra
       (Calcário/Gesso/Fosfato). Dose aplicada + base p/ estimar "pontos" do
       nutriente. FK p/ FARM_FIELDS e FARM_SEASON — drop no módulo ESPACIAL
       (antes de FARM_FIELDS, linha ~2902).
   ===================================================================== */
CREATE TABLE dbo.FERT_AMENDMENT_APPLICATION (
    id             BIGINT        IDENTITY(1,1) CONSTRAINT PK_FERT_AMEND PRIMARY KEY,
    field_id       BIGINT        NOT NULL,                 -- FK -> FARM_FIELDS (pivô)
    season_id      BIGINT        NOT NULL,                 -- FK -> FARM_SEASON
    amendment_type VARCHAR(16)   NOT NULL,                 -- CALCARIO | GESSO | FOSFATO
    rate           DECIMAL(12,3) NOT NULL,                 -- dose aplicada
    unit           VARCHAR(8)    NOT NULL,                 -- 't/ha' | 'kg/ha'
    prnt           DECIMAL(5,2)  NULL,                     -- calcário: PRNT (%)
    grade_pct      DECIMAL(5,2)  NULL,                     -- fosfato: %P2O5 da fonte
    applied_date   DATE          NULL,
    notes          NVARCHAR(MAX) NULL,
    source         VARCHAR(12)   NOT NULL CONSTRAINT DF_FAMEND_source DEFAULT 'MANUAL',
    created_at     DATETIME2(3)  NULL CONSTRAINT DF_FAMEND_created DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)  NULL,
    deleted_at     DATETIME2(3)  NULL,
    CONSTRAINT FK_FAMEND_field  FOREIGN KEY (field_id)  REFERENCES dbo.FARM_FIELDS(id),
    CONSTRAINT FK_FAMEND_season FOREIGN KEY (season_id) REFERENCES dbo.FARM_SEASON(id),
    CONSTRAINT CK_FAMEND_type   CHECK (amendment_type IN ('CALCARIO','GESSO','FOSFATO')),
    CONSTRAINT CK_FAMEND_unit   CHECK (unit IN ('t/ha','kg/ha'))
);
GO
CREATE UNIQUE INDEX UX_FAMEND ON dbo.FERT_AMENDMENT_APPLICATION (field_id, season_id, amendment_type) WHERE deleted_at IS NULL;
CREATE INDEX IX_FAMEND_season ON dbo.FERT_AMENDMENT_APPLICATION (season_id);
GO

/* =====================================================================
   18) SEEDS
   ===================================================================== */

/* --- 18.1 Laboratório default --- */
INSERT INTO dbo.FERT_LAB (code, name) VALUES ('NAO_INFORMADO', N'Não informado');
GO

/* --- 18.2 Catálogo de parâmetros (de/para coluna -> código) --- */
INSERT INTO dbo.FERT_PARAMETER (code, name, short_label, unit, category, method, decimals, display_order) VALUES
 ('COT',       N'Carbono Orgânico Total', N'C.O.T.',  '%',         'MO',     'CHN',    2, 10),
 ('N_CHN',     N'Nitrogênio',             N'N',       '%',         'MACRO',  'CHN',    2, 20),
 ('MO',        N'Matéria Orgânica',       N'M.O.',    'g/dm³',     'MO',     NULL,     1, 30),
 ('P_RESINA',  N'Fósforo (resina)',       N'P (r)',   'mg/dm³',    'MACRO',  'resina', 1, 40),
 ('P_MEHLICH', N'Fósforo (Mehlich)',      N'P (m)',   'mg/dm³',    'MACRO',  'Mehlich',1, 50),
 ('PH_CACL2',  N'pH CaCl₂',               N'pH CaCl2','',          'PH',     'CaCl2',  1, 60),
 ('PH_AGUA',   N'pH Água',                N'pH H₂O',  '',          'PH',     'água',   1, 70),
 ('PH_SMP',    N'pH SMP',                 N'pH SMP',  '',          'PH',     'SMP',    2, 80),
 ('PH_KCL',    N'pH KCl',                 N'pH KCl',  '',          'PH',     'KCl',    1, 90),
 ('K',         N'Potássio',               N'K',       'mmolc/dm³', 'MACRO',  NULL,     2,100),
 ('CA',        N'Cálcio',                 N'Ca',      'mmolc/dm³', 'MACRO',  NULL,     1,110),
 ('MG',        N'Magnésio',               N'Mg',      'mmolc/dm³', 'MACRO',  NULL,     1,120),
 ('NA',        N'Sódio',                  N'Na',      'mmolc/dm³', 'OUTRO',  NULL,     2,130),
 ('H_AL',      N'Acidez Potencial (H+Al)',N'H+Al',    'mmolc/dm³', 'ACIDEZ', NULL,     1,140),
 ('AL',        N'Alumínio',               N'Al',      'mmolc/dm³', 'ACIDEZ', NULL,     1,150),
 ('CTC',       N'CTC a pH 7,0',           N'CTC',     'mmolc/dm³', 'CTC',    NULL,     1,160),
 ('SB',        N'Soma de Bases',          N'S.B.',    'mmolc/dm³', 'CTC',    NULL,     1,170),
 ('V',         N'Saturação por Bases',    N'V%',      '%',         'CTC',    NULL,     1,180),
 ('M_SAT',     N'Saturação por Alumínio', N'm%',      '%',         'ACIDEZ', NULL,     1,190),
 ('S',         N'Enxofre',                N'S',       'mg/dm³',    'MACRO',  NULL,     1,200),
 ('B',         N'Boro',                   N'B',       'mg/dm³',    'MICRO',  NULL,     2,210),
 ('CU',        N'Cobre',                  N'Cu',      'mg/dm³',    'MICRO',  NULL,     1,220),
 ('FE',        N'Ferro',                  N'Fe',      'mg/dm³',    'MICRO',  NULL,     1,230),
 ('MN',        N'Manganês',               N'Mn',      'mg/dm³',    'MICRO',  NULL,     1,240),
 ('ZN',        N'Zinco',                  N'Zn',      'mg/dm³',    'MICRO',  NULL,     1,250),
 ('K_CTC',     N'K na CTC',               N'K/CTC',   '%',         'RELACAO',NULL,     1,260),
 ('CA_CTC',    N'Ca na CTC',              N'Ca/CTC',  '%',         'RELACAO',NULL,     1,270),
 ('MG_CTC',    N'Mg na CTC',              N'Mg/CTC',  '%',         'RELACAO',NULL,     1,280),
 ('AL_CTC',    N'Al na CTC',              N'Al/CTC',  '%',         'RELACAO',NULL,     1,290),
 ('CA_MG',     N'Relação Ca/Mg',          N'Ca/Mg',   '',          'RELACAO',NULL,     1,300),
 ('ARGILA',    N'Argila',                 N'Argila',  'g/kg',      'FISICA', NULL,     0,310),
 ('SILTE',     N'Silte',                  N'Silte',   'g/kg',      'FISICA', NULL,     0,320),
 ('AREIA',     N'Areia Total',            N'Areia',   'g/kg',      'FISICA', NULL,     0,330);
GO

/* --- 18.3 Perfis de profundidade --- */
INSERT INTO dbo.FERT_DEPTH_PROFILE (code, name, description) VALUES
 ('SIMPLES',  N'Simples (0-20)',                 N'Apenas camada superficial.'),
 ('DUPLA',    N'Dupla (0-20, 20-40)',            N'Superfície + subsuperfície.'),
 ('COMPLETA', N'Completa (0-20, 20-40, 40-60)',  N'Perfil completo para calagem/gessagem.');
GO
INSERT INTO dbo.FERT_DEPTH_PROFILE_ITEM (profile_id, depth_label, depth_from_cm, depth_to_cm, display_order)
SELECT pr.id, d.lbl, d.f, d.t, d.ord
FROM dbo.FERT_DEPTH_PROFILE pr
JOIN (VALUES
  ('SIMPLES', '0 a 20 cm',  0,20,1),
  ('DUPLA',   '0 a 20 cm',  0,20,1),
  ('DUPLA',   '20 a 40 cm',20,40,2),
  ('COMPLETA','0 a 20 cm',  0,20,1),
  ('COMPLETA','20 a 40 cm',20,40,2),
  ('COMPLETA','40 a 60 cm',40,60,3)
) d(code,lbl,f,t,ord) ON d.code = pr.code;
GO

/* --- 18.4 Visões de interpretação (seed gerado do banco — 342 faixas) --- */
INSERT INTO dbo.FERT_INTERPRETATION_SET (code, name, agronomist, description, is_default) VALUES
 (N'PADRAO', N'Padrão GCS', N'Equipe Agronômica GCS', N'Faixas de referência operacionais (Cerrado/geral), 5 classes.', 1),
 (N'CERRADO', N'Cerrado (Embrapa)', N'Sousa & Lobato (Embrapa, 2017)', N'Interpretação para solos de Cerrado (Embrapa). P/M.O./CTC por classe de argila; demais macro/micro, pH, V%, m% e textura verificados do livro Correção do Solo e Adubação.', 0),
 (N'MACRO_FOCO', N'Foco Macronutrientes', N'Equipe Agronômica GCS', N'Foco em macronutrientes — mesmas faixas da visão Cerrado (Embrapa).', 0),
 (N'ICL', N'ICL (Nutrição Mineral)', N'ICL — Nutrição mineral de plantas', N'Níveis críticos do material ICL "Nutrição mineral de plantas para alta performance". 5 classes (Muito Baixo→Alto). K/Ca/Mg/CTC/Al em mmolc/dm³ (cmolc×10); M.O. em g/dm³; P-Mehlich por classe de argila; micros por Mehlich-1.', 0);
GO

INSERT INTO dbo.FERT_SET_PARAMETER (set_id, parameter_id, display_order)
SELECT s.id, p.id, p.display_order FROM dbo.FERT_INTERPRETATION_SET s
CROSS JOIN dbo.FERT_PARAMETER p WHERE s.code IN (N'PADRAO', N'CERRADO', N'MACRO_FOCO');
GO

/* --- 18.5 Faixas de interpretação de TODAS as visões (seed gerado do banco) --- */
;WITH bands(setc, code, rank, label, minv, maxv, color, claymin, claymax, ctx, src) AS (
  SELECT * FROM (VALUES
    (N'PADRAO',N'COT',1,N'Muito Baixo',NULL,0.6,N'#E8431C',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'COT',2,N'Baixo',0.6,1.2,N'#F5841F',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'COT',3,N'Médio',1.2,2,N'#F4C20D',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'COT',4,N'Alto',2,3,N'#ADCB38',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'COT',5,N'Muito Alto',3,NULL,N'#2E7D33',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'MO',1,N'Muito Baixo',NULL,10,N'#E8431C',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'MO',2,N'Baixo',10,20,N'#F5841F',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'MO',3,N'Médio',20,30,N'#F4C20D',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'MO',4,N'Alto',30,45,N'#ADCB38',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'MO',5,N'Muito Alto',45,NULL,N'#2E7D33',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'P_RESINA',1,N'Muito Baixo',NULL,8,N'#E8431C',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'P_RESINA',2,N'Baixo',8,16,N'#F5841F',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'P_RESINA',3,N'Médio',16,25,N'#F4C20D',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'P_RESINA',4,N'Alto',25,40,N'#ADCB38',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'P_RESINA',5,N'Muito Alto',40,NULL,N'#2E7D33',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'PH_CACL2',1,N'Muito Baixo',NULL,4.4,N'#E8431C',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'PH_CACL2',2,N'Baixo',4.4,5,N'#F5841F',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'PH_CACL2',3,N'Médio',5,5.5,N'#F4C20D',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'PH_CACL2',4,N'Alto',5.5,6,N'#ADCB38',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'PH_CACL2',5,N'Muito Alto',6,NULL,N'#2E7D33',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'PH_AGUA',1,N'Muito Baixo',NULL,5,N'#E8431C',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'PH_AGUA',2,N'Baixo',5,5.5,N'#F5841F',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'PH_AGUA',3,N'Médio',5.5,6,N'#F4C20D',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'PH_AGUA',4,N'Alto',6,6.5,N'#ADCB38',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'PH_AGUA',5,N'Muito Alto',6.5,NULL,N'#2E7D33',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'K',1,N'Muito Baixo',NULL,0.8,N'#E8431C',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'K',2,N'Baixo',0.8,1.5,N'#F5841F',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'K',3,N'Médio',1.5,3,N'#F4C20D',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'K',4,N'Alto',3,6,N'#ADCB38',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'K',5,N'Muito Alto',6,NULL,N'#2E7D33',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'CA',1,N'Muito Baixo',NULL,4,N'#E8431C',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'CA',2,N'Baixo',4,10,N'#F5841F',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'CA',3,N'Médio',10,20,N'#F4C20D',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'CA',4,N'Alto',20,40,N'#ADCB38',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'CA',5,N'Muito Alto',40,NULL,N'#2E7D33',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'MG',1,N'Muito Baixo',NULL,2,N'#E8431C',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'MG',2,N'Baixo',2,5,N'#F5841F',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'MG',3,N'Médio',5,8,N'#F4C20D',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'MG',4,N'Alto',8,15,N'#ADCB38',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'MG',5,N'Muito Alto',15,NULL,N'#2E7D33',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'CTC',1,N'Muito Baixo',NULL,40,N'#E8431C',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'CTC',2,N'Baixo',40,70,N'#F5841F',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'CTC',3,N'Médio',70,110,N'#F4C20D',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'CTC',4,N'Alto',110,160,N'#ADCB38',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'CTC',5,N'Muito Alto',160,NULL,N'#2E7D33',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'V',1,N'Muito Baixo',NULL,25,N'#E8431C',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'V',2,N'Baixo',25,35,N'#F5841F',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'V',3,N'Médio',35,50,N'#F4C20D',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'V',4,N'Alto',50,70,N'#ADCB38',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'V',5,N'Muito Alto',70,NULL,N'#2E7D33',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'M_SAT',1,N'Muito Baixo',NULL,5,N'#2E7D33',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'M_SAT',2,N'Baixo',5,15,N'#ADCB38',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'M_SAT',3,N'Médio',15,30,N'#F4C20D',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'M_SAT',4,N'Alto',30,45,N'#F5841F',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'M_SAT',5,N'Muito Alto',45,NULL,N'#E8431C',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'S',1,N'Muito Baixo',NULL,5,N'#E8431C',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'S',2,N'Baixo',5,10,N'#F5841F',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'S',3,N'Médio',10,15,N'#F4C20D',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'S',4,N'Alto',15,25,N'#ADCB38',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'S',5,N'Muito Alto',25,NULL,N'#2E7D33',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'B',1,N'Muito Baixo',NULL,0.2,N'#E8431C',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'B',2,N'Baixo',0.2,0.4,N'#F5841F',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'B',3,N'Médio',0.4,0.6,N'#F4C20D',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'B',4,N'Alto',0.6,1,N'#ADCB38',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'B',5,N'Muito Alto',1,NULL,N'#2E7D33',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'ZN',1,N'Muito Baixo',NULL,0.5,N'#E8431C',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'ZN',2,N'Baixo',0.5,1,N'#F5841F',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'ZN',3,N'Médio',1,1.6,N'#F4C20D',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'ZN',4,N'Alto',1.6,3,N'#ADCB38',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'ZN',5,N'Muito Alto',3,NULL,N'#2E7D33',NULL,NULL,N'geral',N'App'),
    (N'PADRAO',N'ARGILA',1,N'Arenosa',NULL,150,N'#E3C98F',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'PADRAO',N'ARGILA',2,N'Média',150,350,N'#C79A4A',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'PADRAO',N'ARGILA',3,N'Argilosa',350,600,N'#9A6B33',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'PADRAO',N'ARGILA',4,N'Muito argilosa',600,NULL,N'#5E3D1E',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'PADRAO',N'SILTE',1,N'Baixo',NULL,100,N'#DCE3D0',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'PADRAO',N'SILTE',2,N'Médio',100,140,N'#AEC08C',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'PADRAO',N'SILTE',3,N'Alto',140,180,N'#7E9B5A',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'PADRAO',N'SILTE',4,N'Muito alto',180,NULL,N'#4E6B34',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'PADRAO',N'AREIA',1,N'Baixa',NULL,600,N'#F0E4BE',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'PADRAO',N'AREIA',2,N'Média',600,700,N'#E6C870',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'PADRAO',N'AREIA',3,N'Alta',700,780,N'#D6A23E',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'PADRAO',N'AREIA',4,N'Muito alta',780,NULL,N'#B97D22',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'CERRADO',N'MO',1,N'Baixa',NULL,16,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MO',1,N'Baixa',NULL,8,N'#E8431C',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MO',2,N'Média',8,10,N'#F4C20D',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MO',2,N'Média',16,20,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MO',3,N'Adequada',20,30,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MO',3,N'Adequada',10,15,N'#ADCB38',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MO',4,N'Alta',15,NULL,N'#2E7D33',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MO',4,N'Alta',30,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MO',1,N'Baixa',NULL,16,N'#E8431C',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MO',2,N'Média',16,20,N'#F4C20D',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MO',3,N'Adequada',20,30,N'#ADCB38',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MO',4,N'Alta',30,NULL,N'#2E7D33',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MO',1,N'Baixa',NULL,24,N'#E8431C',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MO',2,N'Média',24,30,N'#F4C20D',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MO',3,N'Adequada',30,45,N'#ADCB38',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MO',4,N'Alta',45,NULL,N'#2E7D33',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MO',1,N'Baixa',NULL,28,N'#E8431C',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MO',2,N'Média',28,35,N'#F4C20D',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MO',3,N'Adequada',35,52,N'#ADCB38',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MO',4,N'Alta',52,NULL,N'#2E7D33',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_RESINA',1,N'Muito Baixo',NULL,8,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_RESINA',2,N'Baixo',8,15,N'#F5841F',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_RESINA',3,N'Médio',15,25,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_RESINA',4,N'Adequado',25,40,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_RESINA',5,N'Alto',40,60,N'#5FA83A',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_RESINA',6,N'Muito Alto',60,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',1,N'Muito Baixo',NULL,6,N'#E8431C',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',1,N'Muito Baixo',NULL,5,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',2,N'Baixo',5,10,N'#F5841F',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',2,N'Baixo',6,12,N'#F5841F',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',3,N'Médio',12,18,N'#F4C20D',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',3,N'Médio',10,15,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',4,N'Adequado',15,20,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',4,N'Adequado',18,25,N'#ADCB38',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',5,N'Alto',25,NULL,N'#2E7D33',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',5,N'Alto',20,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',1,N'Muito Baixo',NULL,5,N'#E8431C',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',2,N'Baixo',5,10,N'#F5841F',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',3,N'Médio',10,15,N'#F4C20D',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',4,N'Adequado',15,20,N'#ADCB38',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',5,N'Alto',20,NULL,N'#2E7D33',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',1,N'Muito Baixo',NULL,3,N'#E8431C',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',2,N'Baixo',3,5,N'#F5841F',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',3,N'Médio',5,8,N'#F4C20D',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',4,N'Adequado',8,12,N'#ADCB38',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',5,N'Alto',12,NULL,N'#2E7D33',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',1,N'Muito Baixo',NULL,2,N'#E8431C',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',2,N'Baixo',2,3,N'#F5841F',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',3,N'Médio',3,4,N'#F4C20D',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',4,N'Adequado',4,6,N'#ADCB38',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'P_MEHLICH',5,N'Alto',6,NULL,N'#2E7D33',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'PH_CACL2',1,N'Baixo',NULL,4.5,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'PH_CACL2',2,N'Médio',4.5,4.9,N'#F5841F',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'PH_CACL2',3,N'Adequado',4.9,5.6,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'PH_CACL2',4,N'Alto',5.6,5.9,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'PH_CACL2',5,N'Muito Alto',5.9,NULL,N'#EBA300',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'PH_AGUA',1,N'Baixo',NULL,5.2,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'PH_AGUA',2,N'Médio',5.2,5.6,N'#F5841F',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'PH_AGUA',3,N'Adequado',5.6,6.4,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'PH_AGUA',4,N'Alto',6.4,6.7,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'PH_AGUA',5,N'Muito Alto',6.7,NULL,N'#EBA300',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'K',1,N'Baixo',NULL,0.65,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'K',2,N'Médio',0.65,1.3,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'K',3,N'Adequado',1.3,2.05,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'K',4,N'Alto',2.05,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CA',1,N'Baixo',NULL,15,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CA',2,N'Adequado',15,70,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CA',3,N'Alto',70,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MG',1,N'Baixo',NULL,5,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MG',2,N'Adequado',5,20,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MG',3,N'Alto',20,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',1,N'Baixa',NULL,48,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',1,N'Baixa',NULL,32,N'#E8431C',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',2,N'Média',32,40,N'#F4C20D',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',2,N'Média',48,60,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',3,N'Adequada',60,90,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',3,N'Adequada',40,60,N'#ADCB38',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',4,N'Alta',60,NULL,N'#2E7D33',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',4,N'Alta',90,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',1,N'Baixa',NULL,48,N'#E8431C',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',2,N'Média',48,60,N'#F4C20D',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',3,N'Adequada',60,90,N'#ADCB38',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',4,N'Alta',90,NULL,N'#2E7D33',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',1,N'Baixa',NULL,72,N'#E8431C',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',2,N'Média',72,90,N'#F4C20D',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',3,N'Adequada',90,135,N'#ADCB38',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',4,N'Alta',135,NULL,N'#2E7D33',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',1,N'Baixa',NULL,96,N'#E8431C',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',2,N'Média',96,120,N'#F4C20D',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',3,N'Adequada',120,180,N'#ADCB38',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CTC',4,N'Alta',180,NULL,N'#2E7D33',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'V',1,N'Baixo',NULL,21,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'V',2,N'Médio',21,36,N'#F5841F',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'V',3,N'Adequado',36,61,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'V',4,N'Alto',61,71,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'V',5,N'Muito Alto',71,NULL,N'#EBA300',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'M_SAT',1,N'Baixa',NULL,20,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'M_SAT',2,N'Alta',20,60,N'#F5841F',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'M_SAT',3,N'Muito Alta',60,NULL,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'S',1,N'Baixo',NULL,5,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'S',2,N'Médio',5,10,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'S',3,N'Alto',10,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'B',1,N'Baixo',NULL,0.2,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'B',2,N'Médio',0.2,0.5,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'B',3,N'Alto',0.5,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CU',1,N'Baixo',NULL,0.4,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CU',2,N'Médio',0.4,0.8,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'CU',3,N'Alto',0.8,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MN',1,N'Baixo',NULL,2,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MN',2,N'Médio',2,5,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'MN',3,N'Alto',5,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'ZN',1,N'Baixo',NULL,1,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'ZN',2,N'Médio',1,1.6,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'ZN',3,N'Alto',1.6,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'K_CTC',1,N'Baixo',NULL,1,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'K_CTC',2,N'Médio',1,2,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'K_CTC',3,N'Adequado',2,3,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'K_CTC',4,N'Alta',3,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'CERRADO',N'ARGILA',1,N'Arenosa',NULL,150,N'#E3C98F',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'CERRADO',N'ARGILA',2,N'Média',150,350,N'#C79A4A',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'CERRADO',N'ARGILA',3,N'Argilosa',350,600,N'#9A6B33',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'CERRADO',N'ARGILA',4,N'Muito argilosa',600,NULL,N'#5E3D1E',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'CERRADO',N'SILTE',1,N'Baixo',NULL,100,N'#DCE3D0',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'CERRADO',N'SILTE',2,N'Médio',100,140,N'#AEC08C',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'CERRADO',N'SILTE',3,N'Alto',140,180,N'#7E9B5A',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'CERRADO',N'SILTE',4,N'Muito alto',180,NULL,N'#4E6B34',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'CERRADO',N'AREIA',1,N'Baixa',NULL,600,N'#F0E4BE',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'CERRADO',N'AREIA',2,N'Média',600,700,N'#E6C870',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'CERRADO',N'AREIA',3,N'Alta',700,780,N'#D6A23E',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'CERRADO',N'AREIA',4,N'Muito alta',780,NULL,N'#B97D22',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'MACRO_FOCO',N'MO',1,N'Baixa',NULL,8,N'#E8431C',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MO',1,N'Baixa',NULL,16,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MO',2,N'Média',16,20,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MO',2,N'Média',8,10,N'#F4C20D',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MO',3,N'Adequada',10,15,N'#ADCB38',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MO',3,N'Adequada',20,30,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MO',4,N'Alta',30,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MO',4,N'Alta',15,NULL,N'#2E7D33',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MO',1,N'Baixa',NULL,16,N'#E8431C',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MO',2,N'Média',16,20,N'#F4C20D',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MO',3,N'Adequada',20,30,N'#ADCB38',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MO',4,N'Alta',30,NULL,N'#2E7D33',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MO',1,N'Baixa',NULL,24,N'#E8431C',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MO',2,N'Média',24,30,N'#F4C20D',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MO',3,N'Adequada',30,45,N'#ADCB38',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MO',4,N'Alta',45,NULL,N'#2E7D33',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MO',1,N'Baixa',NULL,28,N'#E8431C',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MO',2,N'Média',28,35,N'#F4C20D',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MO',3,N'Adequada',35,52,N'#ADCB38',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MO',4,N'Alta',52,NULL,N'#2E7D33',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_RESINA',1,N'Muito Baixo',NULL,8,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_RESINA',2,N'Baixo',8,15,N'#F5841F',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_RESINA',3,N'Médio',15,25,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_RESINA',4,N'Adequado',25,40,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_RESINA',5,N'Alto',40,60,N'#5FA83A',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_RESINA',6,N'Muito Alto',60,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',1,N'Muito Baixo',NULL,5,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',1,N'Muito Baixo',NULL,6,N'#E8431C',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',2,N'Baixo',6,12,N'#F5841F',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',2,N'Baixo',5,10,N'#F5841F',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',3,N'Médio',10,15,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',3,N'Médio',12,18,N'#F4C20D',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',4,N'Adequado',18,25,N'#ADCB38',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',4,N'Adequado',15,20,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',5,N'Alto',20,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',5,N'Alto',25,NULL,N'#2E7D33',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',1,N'Muito Baixo',NULL,5,N'#E8431C',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',2,N'Baixo',5,10,N'#F5841F',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',3,N'Médio',10,15,N'#F4C20D',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',4,N'Adequado',15,20,N'#ADCB38',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',5,N'Alto',20,NULL,N'#2E7D33',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',1,N'Muito Baixo',NULL,3,N'#E8431C',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',2,N'Baixo',3,5,N'#F5841F',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',3,N'Médio',5,8,N'#F4C20D',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',4,N'Adequado',8,12,N'#ADCB38',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',5,N'Alto',12,NULL,N'#2E7D33',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',1,N'Muito Baixo',NULL,2,N'#E8431C',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',2,N'Baixo',2,3,N'#F5841F',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',3,N'Médio',3,4,N'#F4C20D',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',4,N'Adequado',4,6,N'#ADCB38',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'P_MEHLICH',5,N'Alto',6,NULL,N'#2E7D33',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'PH_CACL2',1,N'Baixo',NULL,4.5,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'PH_CACL2',2,N'Médio',4.5,4.9,N'#F5841F',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'PH_CACL2',3,N'Adequado',4.9,5.6,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'PH_CACL2',4,N'Alto',5.6,5.9,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'PH_CACL2',5,N'Muito Alto',5.9,NULL,N'#EBA300',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'PH_AGUA',1,N'Baixo',NULL,5.2,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'PH_AGUA',2,N'Médio',5.2,5.6,N'#F5841F',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'PH_AGUA',3,N'Adequado',5.6,6.4,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'PH_AGUA',4,N'Alto',6.4,6.7,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'PH_AGUA',5,N'Muito Alto',6.7,NULL,N'#EBA300',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'K',1,N'Baixo',NULL,0.65,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'K',2,N'Médio',0.65,1.3,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'K',3,N'Adequado',1.3,2.05,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'K',4,N'Alto',2.05,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CA',1,N'Baixo',NULL,15,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CA',2,N'Adequado',15,70,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CA',3,N'Alto',70,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MG',1,N'Baixo',NULL,5,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MG',2,N'Adequado',5,20,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MG',3,N'Alto',20,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',1,N'Baixa',NULL,48,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',1,N'Baixa',NULL,32,N'#E8431C',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',2,N'Média',32,40,N'#F4C20D',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',2,N'Média',48,60,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',3,N'Adequada',60,90,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',3,N'Adequada',40,60,N'#ADCB38',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',4,N'Alta',60,NULL,N'#2E7D33',NULL,150,N'argila arenosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',4,N'Alta',90,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',1,N'Baixa',NULL,48,N'#E8431C',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',2,N'Média',48,60,N'#F4C20D',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',3,N'Adequada',60,90,N'#ADCB38',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',4,N'Alta',90,NULL,N'#2E7D33',150,350,N'argila média',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',1,N'Baixa',NULL,72,N'#E8431C',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',2,N'Média',72,90,N'#F4C20D',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',3,N'Adequada',90,135,N'#ADCB38',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',4,N'Alta',135,NULL,N'#2E7D33',350,600,N'argila argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',1,N'Baixa',NULL,96,N'#E8431C',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',2,N'Média',96,120,N'#F4C20D',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',3,N'Adequada',120,180,N'#ADCB38',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CTC',4,N'Alta',180,NULL,N'#2E7D33',600,NULL,N'argila muito argilosa',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'V',1,N'Baixo',NULL,21,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'V',2,N'Médio',21,36,N'#F5841F',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'V',3,N'Adequado',36,61,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'V',4,N'Alto',61,71,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'V',5,N'Muito Alto',71,NULL,N'#EBA300',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'M_SAT',1,N'Baixa',NULL,20,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'M_SAT',2,N'Alta',20,60,N'#F5841F',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'M_SAT',3,N'Muito Alta',60,NULL,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'S',1,N'Baixo',NULL,5,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'S',2,N'Médio',5,10,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'S',3,N'Alto',10,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'B',1,N'Baixo',NULL,0.2,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'B',2,N'Médio',0.2,0.5,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'B',3,N'Alto',0.5,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CU',1,N'Baixo',NULL,0.4,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CU',2,N'Médio',0.4,0.8,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'CU',3,N'Alto',0.8,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MN',1,N'Baixo',NULL,2,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MN',2,N'Médio',2,5,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'MN',3,N'Alto',5,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'ZN',1,N'Baixo',NULL,1,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'ZN',2,N'Médio',1,1.6,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'ZN',3,N'Alto',1.6,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'K_CTC',1,N'Baixo',NULL,1,N'#E8431C',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'K_CTC',2,N'Médio',1,2,N'#F4C20D',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'K_CTC',3,N'Adequado',2,3,N'#ADCB38',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'K_CTC',4,N'Alta',3,NULL,N'#2E7D33',NULL,NULL,N'geral',N'Embrapa Cerrado 2017'),
    (N'MACRO_FOCO',N'ARGILA',1,N'Arenosa',NULL,150,N'#E3C98F',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'MACRO_FOCO',N'ARGILA',2,N'Média',150,350,N'#C79A4A',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'MACRO_FOCO',N'ARGILA',3,N'Argilosa',350,600,N'#9A6B33',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'MACRO_FOCO',N'ARGILA',4,N'Muito argilosa',600,NULL,N'#5E3D1E',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'MACRO_FOCO',N'SILTE',1,N'Baixo',NULL,100,N'#DCE3D0',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'MACRO_FOCO',N'SILTE',2,N'Médio',100,140,N'#AEC08C',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'MACRO_FOCO',N'SILTE',3,N'Alto',140,180,N'#7E9B5A',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'MACRO_FOCO',N'SILTE',4,N'Muito alto',180,NULL,N'#4E6B34',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'MACRO_FOCO',N'AREIA',1,N'Baixa',NULL,600,N'#F0E4BE',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'MACRO_FOCO',N'AREIA',2,N'Média',600,700,N'#E6C870',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'MACRO_FOCO',N'AREIA',3,N'Alta',700,780,N'#D6A23E',NULL,NULL,N'física',N'GCS (dados+Embrapa)'),
    (N'MACRO_FOCO',N'AREIA',4,N'Muito alta',780,NULL,N'#B97D22',NULL,NULL,N'física',N'GCS (dados+Embrapa)')
  ) v(setc, code, rank, label, minv, maxv, color, claymin, claymax, ctx, src)
)
INSERT INTO dbo.FERT_INTERPRETATION
  (set_id, parameter_id, class_rank, class_label, min_value, max_value, color_hex, clay_min, clay_max, context, source)
SELECT st.id, p.id, b.rank, b.label, b.minv, b.maxv, b.color, b.claymin, b.claymax, b.ctx, b.src
FROM bands b
  JOIN dbo.FERT_INTERPRETATION_SET st ON st.code = b.setc
  JOIN dbo.FERT_PARAMETER p ON p.code = b.code;
GO

/* --- 18.5b Visão ICL — níveis críticos (Nutrição mineral de plantas) ---
       Conversões: K/Ca/Mg/CTC/Al cmolc→mmolc (×10); M.O. %→g/dm³ (×10);
       argila em g/kg; micros por Mehlich-1 (B por água quente).
       Valores transcritos de imagens — revisar contra a fonte. */
INSERT INTO dbo.FERT_SET_PARAMETER (set_id, parameter_id, display_order)
SELECT s.id, p.id, p.display_order
FROM dbo.FERT_INTERPRETATION_SET s
JOIN dbo.FERT_PARAMETER p
  ON p.code IN ('PH_CACL2','PH_AGUA','V','M_SAT','MO','P_RESINA','P_MEHLICH','S',
                'CTC','AL','CA','MG','K','CA_CTC','MG_CTC','K_CTC','CA_MG',
                'B','CU','FE','MN','ZN')
WHERE s.code = N'ICL';
GO

;WITH bands(setc, code, rank, label, minv, maxv, color, claymin, claymax, ctx, src) AS (
  SELECT * FROM (VALUES
    (N'ICL',N'PH_CACL2',1,N'Muito Baixo',NULL,4.3,N'#E8431C',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'PH_CACL2',2,N'Baixo',4.3,5.0,N'#F5841F',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'PH_CACL2',3,N'Médio',5.0,5.5,N'#F4C20D',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'PH_CACL2',4,N'Adequado',5.5,6.0,N'#ADCB38',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'PH_CACL2',5,N'Alto',6.0,NULL,N'#2E7D33',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'PH_AGUA',1,N'Muito Baixo',NULL,4.5,N'#E8431C',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'PH_AGUA',2,N'Baixo',4.5,5.0,N'#F5841F',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'PH_AGUA',3,N'Médio',5.0,6.0,N'#F4C20D',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'PH_AGUA',4,N'Adequado',6.0,7.0,N'#ADCB38',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'PH_AGUA',5,N'Alto',7.0,NULL,N'#2E7D33',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'V',1,N'Muito Baixo',NULL,25,N'#E8431C',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'V',2,N'Baixo',25,40,N'#F5841F',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'V',3,N'Médio',40,55,N'#F4C20D',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'V',4,N'Adequado',55,70,N'#ADCB38',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'V',5,N'Alto',70,NULL,N'#2E7D33',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'M_SAT',1,N'Muito Baixo',NULL,15,N'#2E7D33',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'M_SAT',2,N'Baixo',15,30,N'#ADCB38',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'M_SAT',3,N'Médio',30,50,N'#F4C20D',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'M_SAT',4,N'Adequado',50,75,N'#F5841F',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'M_SAT',5,N'Alto',75,NULL,N'#E8431C',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MO',1,N'Muito Baixo',NULL,7,N'#E8431C',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MO',2,N'Baixo',7,20,N'#F5841F',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MO',3,N'Médio',20,40,N'#F4C20D',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MO',4,N'Adequado',40,70,N'#ADCB38',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MO',5,N'Alto',70,NULL,N'#2E7D33',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_RESINA',1,N'Muito Baixo',NULL,7,N'#E8431C',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_RESINA',2,N'Baixo',7,15,N'#F5841F',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_RESINA',3,N'Médio',15,25,N'#F4C20D',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_RESINA',4,N'Adequado',25,40,N'#ADCB38',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_RESINA',5,N'Alto',40,NULL,N'#2E7D33',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'S',1,N'Muito Baixo',NULL,6,N'#E8431C',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'S',2,N'Baixo',6,10,N'#F5841F',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'S',3,N'Médio',10,15,N'#F4C20D',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'S',4,N'Adequado',15,30,N'#ADCB38',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'S',5,N'Alto',30,NULL,N'#2E7D33',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CTC',1,N'Muito Baixo',NULL,16,N'#E8431C',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CTC',2,N'Baixo',16,43,N'#F5841F',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CTC',3,N'Médio',43,86,N'#F4C20D',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CTC',4,N'Adequado',86,150,N'#ADCB38',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CTC',5,N'Alto',150,NULL,N'#2E7D33',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'AL',1,N'Muito Baixo',NULL,2,N'#2E7D33',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'AL',2,N'Baixo',2,5,N'#ADCB38',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'AL',3,N'Médio',5,10,N'#F4C20D',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'AL',4,N'Adequado',10,20,N'#F5841F',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'AL',5,N'Alto',20,NULL,N'#E8431C',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CA',1,N'Muito Baixo',NULL,8,N'#E8431C',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CA',2,N'Baixo',8,15,N'#F5841F',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CA',3,N'Médio',15,25,N'#F4C20D',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CA',4,N'Adequado',25,40,N'#ADCB38',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CA',5,N'Alto',40,NULL,N'#2E7D33',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MG',1,N'Muito Baixo',NULL,5,N'#E8431C',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MG',2,N'Baixo',5,8,N'#F5841F',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MG',3,N'Médio',8,12,N'#F4C20D',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MG',4,N'Adequado',12,16,N'#ADCB38',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MG',5,N'Alto',16,NULL,N'#2E7D33',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'K',1,N'Muito Baixo',NULL,0.7,N'#E8431C',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'K',2,N'Baixo',0.7,1.5,N'#F5841F',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'K',3,N'Médio',1.5,2.3,N'#F4C20D',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'K',4,N'Adequado',2.3,3.0,N'#ADCB38',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'K',5,N'Alto',3.0,NULL,N'#2E7D33',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CA_CTC',1,N'Muito Baixo',NULL,20,N'#E8431C',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CA_CTC',2,N'Baixo',20,30,N'#F5841F',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CA_CTC',3,N'Médio',30,40,N'#F4C20D',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CA_CTC',4,N'Adequado',40,50,N'#ADCB38',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CA_CTC',5,N'Alto',50,NULL,N'#2E7D33',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MG_CTC',1,N'Muito Baixo',NULL,5,N'#E8431C',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MG_CTC',2,N'Baixo',5,10,N'#F5841F',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MG_CTC',3,N'Médio',10,15,N'#F4C20D',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MG_CTC',4,N'Adequado',15,20,N'#ADCB38',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MG_CTC',5,N'Alto',20,NULL,N'#2E7D33',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'K_CTC',1,N'Muito Baixo',NULL,1.5,N'#E8431C',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'K_CTC',2,N'Baixo',1.5,2.5,N'#F5841F',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'K_CTC',3,N'Médio',2.5,5.0,N'#F4C20D',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'K_CTC',4,N'Adequado',5.0,7.0,N'#ADCB38',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'K_CTC',5,N'Alto',7.0,NULL,N'#2E7D33',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CA_MG',1,N'Muito Baixo',NULL,1.0,N'#E8431C',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CA_MG',2,N'Baixo',1.0,2.0,N'#F5841F',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CA_MG',3,N'Médio',2.0,3.0,N'#F4C20D',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CA_MG',4,N'Adequado',3.0,5.0,N'#ADCB38',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CA_MG',5,N'Alto',5.0,NULL,N'#2E7D33',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',1,N'Muito Baixo',NULL,10,N'#E8431C',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',2,N'Baixo',10,15,N'#F5841F',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',3,N'Médio',15,20,N'#F4C20D',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',4,N'Adequado',20,35,N'#ADCB38',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',5,N'Alto',35,NULL,N'#2E7D33',NULL,NULL,N'geral',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',1,N'Muito Baixo',NULL,12,N'#E8431C',NULL,150,N'argila arenosa',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',2,N'Baixo',12,18,N'#F5841F',NULL,150,N'argila arenosa',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',3,N'Médio',18,25,N'#F4C20D',NULL,150,N'argila arenosa',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',4,N'Adequado',25,40,N'#ADCB38',NULL,150,N'argila arenosa',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',5,N'Alto',40,NULL,N'#2E7D33',NULL,150,N'argila arenosa',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',1,N'Muito Baixo',NULL,10,N'#E8431C',150,350,N'argila média',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',2,N'Baixo',10,15,N'#F5841F',150,350,N'argila média',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',3,N'Médio',15,20,N'#F4C20D',150,350,N'argila média',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',4,N'Adequado',20,35,N'#ADCB38',150,350,N'argila média',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',5,N'Alto',35,NULL,N'#2E7D33',150,350,N'argila média',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',1,N'Muito Baixo',NULL,5,N'#E8431C',350,600,N'argila argilosa',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',2,N'Baixo',5,8,N'#F5841F',350,600,N'argila argilosa',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',3,N'Médio',8,12,N'#F4C20D',350,600,N'argila argilosa',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',4,N'Adequado',12,18,N'#ADCB38',350,600,N'argila argilosa',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',5,N'Alto',18,NULL,N'#2E7D33',350,600,N'argila argilosa',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',1,N'Muito Baixo',NULL,3,N'#E8431C',600,NULL,N'argila muito argilosa',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',2,N'Baixo',3,4,N'#F5841F',600,NULL,N'argila muito argilosa',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',3,N'Médio',4,6,N'#F4C20D',600,NULL,N'argila muito argilosa',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',4,N'Adequado',6,9,N'#ADCB38',600,NULL,N'argila muito argilosa',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'P_MEHLICH',5,N'Alto',9,NULL,N'#2E7D33',600,NULL,N'argila muito argilosa',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'B',1,N'Muito Baixo',NULL,0.15,N'#E8431C',NULL,NULL,N'água quente',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'B',2,N'Baixo',0.15,0.35,N'#F5841F',NULL,NULL,N'água quente',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'B',3,N'Médio',0.35,0.60,N'#F4C20D',NULL,NULL,N'água quente',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'B',4,N'Adequado',0.60,0.90,N'#ADCB38',NULL,NULL,N'água quente',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'B',5,N'Alto',0.90,NULL,N'#2E7D33',NULL,NULL,N'água quente',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CU',1,N'Muito Baixo',NULL,0.30,N'#E8431C',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CU',2,N'Baixo',0.30,0.70,N'#F5841F',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CU',3,N'Médio',0.70,1.20,N'#F4C20D',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CU',4,N'Adequado',1.20,1.80,N'#ADCB38',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'CU',5,N'Alto',1.80,NULL,N'#2E7D33',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'FE',1,N'Muito Baixo',NULL,8,N'#E8431C',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'FE',2,N'Baixo',8,18,N'#F5841F',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'FE',3,N'Médio',18,30,N'#F4C20D',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'FE',4,N'Adequado',30,45,N'#ADCB38',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'FE',5,N'Alto',45,NULL,N'#2E7D33',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MN',1,N'Muito Baixo',NULL,2,N'#E8431C',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MN',2,N'Baixo',2,5,N'#F5841F',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MN',3,N'Médio',5,8,N'#F4C20D',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MN',4,N'Adequado',8,12,N'#ADCB38',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'MN',5,N'Alto',12,NULL,N'#2E7D33',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'ZN',1,N'Muito Baixo',NULL,0.40,N'#E8431C',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'ZN',2,N'Baixo',0.40,0.90,N'#F5841F',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'ZN',3,N'Médio',0.90,1.50,N'#F4C20D',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'ZN',4,N'Adequado',1.50,2.20,N'#ADCB38',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas'),
    (N'ICL',N'ZN',5,N'Alto',2.20,NULL,N'#2E7D33',NULL,NULL,N'Mehlich-1',N'ICL — Nutrição mineral de plantas')
  ) v(setc, code, rank, label, minv, maxv, color, claymin, claymax, ctx, src)
)
INSERT INTO dbo.FERT_INTERPRETATION
  (set_id, parameter_id, class_rank, class_label, min_value, max_value, color_hex, clay_min, clay_max, context, source)
SELECT st.id, p.id, b.rank, b.label, b.minv, b.maxv, b.color, b.claymin, b.claymax, b.ctx, b.src
FROM bands b
  JOIN dbo.FERT_INTERPRETATION_SET st ON st.code = b.setc
  JOIN dbo.FERT_PARAMETER p ON p.code = b.code;
GO

/* --- 18.6 Exportação de nutrientes — catálogo + coeficiente por cultura ---
       Valores transcritos de imagens (ICL) — revisar contra a fonte. */
INSERT INTO dbo.FERT_EXPORT_NUTRIENT (code, name, symbol, category, coef_unit, color_hex, display_order) VALUES
 ('N',    N'Nitrogênio',      N'N',    'MACRO', 'kg/t', '#2E7D33', 1),
 ('P2O5', N'Fósforo (P₂O₅)',  N'P₂O₅', 'MACRO', 'kg/t', '#F5841F', 2),
 ('K2O',  N'Potássio (K₂O)',  N'K₂O',  'MACRO', 'kg/t', '#E8431C', 3),
 ('CA',   N'Cálcio',          N'Ca',   'MACRO', 'kg/t', '#3E8FC4', 4),
 ('MG',   N'Magnésio',        N'Mg',   'MACRO', 'kg/t', '#15346B', 5),
 ('S',    N'Enxofre',         N'S',    'MACRO', 'kg/t', '#C8843C', 6),
 ('B',    N'Boro',            N'B',    'MICRO', 'g/t',  '#9AA7AE', 7),
 ('CU',   N'Cobre',           N'Cu',   'MICRO', 'g/t',  '#B87333', 8),
 ('FE',   N'Ferro',           N'Fe',   'MICRO', 'g/t',  '#7D4B32', 9),
 ('MN',   N'Manganês',        N'Mn',   'MICRO', 'g/t',  '#8E6FB0', 10),
 ('ZN',   N'Zinco',           N'Zn',   'MICRO', 'g/t',  '#6B8AA0', 11),
 ('NI',   N'Níquel',          N'Ni',   'MICRO', 'g/t',  '#5A6B73', 12),
 ('MO',   N'Molibdênio',      N'Mo',   'MICRO', 'g/t',  '#A0843C', 13),
 ('CL',   N'Cloro',           N'Cl',   'MICRO', 'g/t',  '#5FA86A', 14);
GO

/* Coeficientes por cultura × nutriente. Grãos: base GRAIN (kg/t de grão).
   Café/cana/silagem: base PRODUCT já convertida para kg/t do produto. */
;WITH src(crop, nut, exp_v, ext_v) AS (
  SELECT crop, nut, exp_v, ext_v FROM (VALUES
    ('SOJA','N',54.0,78.0),('SOJA','P2O5',11.0,15.6),('SOJA','K2O',21.8,58.1),('SOJA','CA',2.8,22.1),('SOJA','MG',2.5,10.7),('SOJA','S',2.8,15.4),
    ('SOJA','B',31.0,82.0),('SOJA','CU',11.5,19.8),('SOJA','FE',65.0,375.0),('SOJA','MN',39.0,198.0),('SOJA','MO',5.0,7.0),('SOJA','ZN',41.0,75.0),
    ('MILHO','N',9.3,26.1),('MILHO','P2O5',2.5,5.8),('MILHO','K2O',3.4,18.8),('MILHO','CA',0.5,4.7),('MILHO','MG',0.9,4.3),('MILHO','S',0.7,2.1),
    ('MILHO','B',2.4,15.2),('MILHO','CU',1.5,12.3),('MILHO','FE',10.1,225.0),('MILHO','MN',4.8,54.8),('MILHO','MO',0.4,1.0),('MILHO','ZN',16.7,56.2),
    ('SORGO','N',15.8,23.7),('SORGO','P2O5',6.7,9.8),('SORGO','K2O',8.1,34.7),('SORGO','CA',0.4,8.3),('SORGO','MG',1.7,3.0),('SORGO','S',1.5,3.0),
    ('SORGO','B',NULL,100.0),('SORGO','CU',NULL,73.0),('SORGO','FE',NULL,1893.0),('SORGO','MN',NULL,340.0),('SORGO','MO',NULL,2.7),('SORGO','ZN',NULL,162.0),
    ('FEIJAO','N',17.4,26.7),('FEIJAO','P2O5',2.9,3.6),('FEIJAO','K2O',7.9,16.4),('FEIJAO','CA',0.3,2.5),('FEIJAO','MG',0.9,2.2),('FEIJAO','S',1.2,2.4),
    ('FEIJAO','B',14.1,25.7),('FEIJAO','CU',3.5,7.4),('FEIJAO','FE',67.4,164.5),('FEIJAO','MN',24.6,91.1),('FEIJAO','MO',2.0,7.0),('FEIJAO','ZN',12.6,27.4),
    ('ALGODAO','N',14.0,58.0),('ALGODAO','P2O5',2.0,9.0),('ALGODAO','K2O',24.0,32.0),('ALGODAO','CA',3.0,32.0),('ALGODAO','MG',1.0,7.0),('ALGODAO','S',2.0,10.0),
    ('ALGODAO','B',18.0,74.0),('ALGODAO','CU',2.0,11.0),('ALGODAO','FE',16.1,283.0),('ALGODAO','MN',8.0,65.0),('ALGODAO','MO',NULL,1.0),('ALGODAO','ZN',7.0,57.0),
    ('TRIGO','N',33.3,53.7),('TRIGO','P2O5',4.6,8.2),('TRIGO','K2O',7.8,45.9),('TRIGO','CA',1.1,5.2),('TRIGO','MG',1.8,3.3),('TRIGO','S',1.7,7.9),
    ('TRIGO','B',43.7,101.7),('TRIGO','CU',14.8,29.6),('TRIGO','FE',20.3,2032.0),('TRIGO','MN',85.7,209.0),('TRIGO','MO',NULL,NULL),('TRIGO','ZN',44.5,56.3)
  ) v(crop, nut, exp_v, ext_v)
)
INSERT INTO dbo.FERT_CROP_EXPORT (set_id, culture_id, nutrient_id, basis, export_kg_per_ton, extraction_kg_per_ton, source)
SELECT es.id, c.id, n.id, 'GRAIN', src.exp_v, src.ext_v, N'ICL — Nutrição mineral de plantas'
FROM src
JOIN dbo.FARM_CULTURE         c ON c.code = src.crop AND c.deleted_at IS NULL
JOIN dbo.FERT_EXPORT_NUTRIENT n ON n.code = src.nut  AND n.deleted_at IS NULL
CROSS JOIN (SELECT TOP 1 id FROM dbo.FERT_EXPORT_SET WHERE code='ICL' AND deleted_at IS NULL) es;
GO

;WITH src(crop, nut, exp_v, ext_v, note) AS (
  SELECT crop, nut, exp_v, ext_v, note FROM (VALUES
    ('CAFE','N',     43.0000, 103.3333, NULL),
    ('CAFE','P2O5',   5.3333,  10.0000, NULL),
    ('CAFE','K2O',   46.5000,  88.3333, NULL),
    ('CAFE','CA',     7.0000,   5.0000, N'ATENÇÃO: exportação (0,42 kg/saca) > extração (0,3) na fonte — provável erro de transcrição; revisar.'),
    ('CAFE','MG',     3.0150,  19.0950, NULL),
    ('CAFE','S',      2.3333,   5.0000, NULL),
    ('CAFE','B',     73.3333, 108.3333, NULL),
    ('CAFE','CU',   200.0000, 146.6667, N'ATENÇÃO: exportação (12 g/saca) > extração (8,8) na fonte — provável erro de transcrição; revisar.'),
    ('CAFE','FE',    61.6667,1833.3333, NULL),
    ('CAFE','MN',      NULL, 1666.6667, NULL),
    ('CAFE','MO',      NULL,  166.6667, NULL),
    ('CAFE','ZN',    33.3333, 103.3333, NULL),
    ('CANA','N',      0.8380,   1.4580, NULL),
    ('CANA','P2O5',   0.2800,   0.5530, NULL),
    ('CANA','K2O',    1.4300,   2.5410, NULL),
    ('CANA','CA',     0.2030,   0.6196, NULL),
    ('CANA','MG',     0.3420,   0.4700, NULL),
    ('CANA','S',      0.2760,   0.3870, NULL),
    ('CANA','B',      2.0000,   4.3300, NULL),
    ('CANA','CU',     0.4300,   0.8700, NULL),
    ('CANA','FE',    31.7800,  32.9700, NULL),
    ('CANA','MN',    14.2400,  24.9700, NULL),
    ('CANA','MO',     0.0100,   0.0200, NULL),
    ('CANA','ZN',     3.4600,   5.8200, NULL),
    ('MILHO_SILAGEM','N',    2.9600, 2.9600, NULL),
    ('MILHO_SILAGEM','P2O5', 0.6500, 0.6500, NULL),
    ('MILHO_SILAGEM','K2O',  2.4400, 2.4400, NULL),
    ('MILHO_SILAGEM','CA',   0.5800, 0.5800, NULL),
    ('MILHO_SILAGEM','MG',   0.5900, 0.5900, NULL),
    ('MILHO_SILAGEM','S',    0.2800, 0.2800, NULL),
    ('MILHO_SILAGEM','B',    1.9000, 1.9000, NULL),
    ('MILHO_SILAGEM','CU',   1.9400, 1.9400, NULL),
    ('MILHO_SILAGEM','FE',  28.8000,28.8000, NULL),
    ('MILHO_SILAGEM','MN',   5.8300, 5.8300, NULL),
    ('MILHO_SILAGEM','MO',   0.1300, 0.1300, NULL),
    ('MILHO_SILAGEM','ZN',   8.4100, 8.4100, NULL)
  ) v(crop, nut, exp_v, ext_v, note)
)
INSERT INTO dbo.FERT_CROP_EXPORT (set_id, culture_id, nutrient_id, basis, export_kg_per_ton, extraction_kg_per_ton, source, notes)
SELECT es.id, c.id, n.id, 'PRODUCT', src.exp_v, src.ext_v,
       CASE src.crop
         WHEN 'CAFE'          THEN N'ICL — conv. kg/saca × 16,667 (saca 60 kg); MgO→Mg × 0,603'
         WHEN 'CANA'          THEN N'ICL/Otto et al. 2019 — conv. ÷100 t; CaO→Ca × 0,7147; exp=colmo, ext=total'
         WHEN 'MILHO_SILAGEM' THEN N'ICL — kg/t MF; exp≈ext (planta inteira ensilada)'
       END,
       src.note
FROM src
JOIN dbo.FARM_CULTURE         c ON c.code = src.crop AND c.deleted_at IS NULL
JOIN dbo.FERT_EXPORT_NUTRIENT n ON n.code = src.nut  AND n.deleted_at IS NULL
CROSS JOIN (SELECT TOP 1 id FROM dbo.FERT_EXPORT_SET WHERE code='ICL' AND deleted_at IS NULL) es;
GO

/* --- 18.7 Modelos de cálculo (calagem / gessagem) --- */
INSERT INTO dbo.FERT_CALC_MODEL (code, name, category, description, formula_expr, result_unit, result_label, is_default, source) VALUES
 ('CALAGEM_V', N'Calagem — Saturação por Bases', 'LIMING',
   N'Elevação da saturação por bases. Calibrar fator de profundidade/unidade conforme o laboratório.',
   N'CTC * (V2 - V1) / (10 * PRNT)', 't/ha', N'Necessidade de calcário', 1, N'Método V% (indicativo)'),
 ('CALAGEM_ALCAMG', N'Calagem — Neutralização Al + elevação Ca/Mg', 'LIMING',
   N'Neutralização do alumínio e elevação de Ca+Mg.',
   N'Al * f1 + (CaMg_min - (Ca + Mg))', 't/ha', N'Necessidade de calcário', 0, N'Método Al/Ca+Mg (indicativo)'),
 ('GESSO_ARGILA', N'Gessagem — função da argila', 'GYPSUM',
   N'Gesso agrícola em função do teor de argila (subsuperfície).',
   N'Argila * gypsum_factor', 'kg/ha', N'Necessidade de gesso', 1, N'Função da argila (indicativo)');
GO
INSERT INTO dbo.FERT_CALC_INPUT (model_id, var_name, label, source_type, parameter_code, default_value, unit, display_order)
SELECT m.id, v.var_name, v.label, v.src, v.pcode, v.defv, v.unit, v.ord
FROM dbo.FERT_CALC_MODEL m JOIN (VALUES
  ('CALAGEM_V','CTC',  N'CTC',              'PARAMETER','CTC', NULL,  'mmolc/dm³', 1),
  ('CALAGEM_V','V1',   N'V% atual',         'PARAMETER','V',   NULL,  '%',         2),
  ('CALAGEM_V','V2',   N'V% desejado',      'USER',     NULL,  60.0,  '%',         3),
  ('CALAGEM_V','PRNT', N'PRNT do calcário', 'CONSTANT', NULL,  100.0, '%',         4),
  ('CALAGEM_ALCAMG','Al',       N'Alumínio',     'PARAMETER','AL', NULL, 'mmolc/dm³', 1),
  ('CALAGEM_ALCAMG','Ca',       N'Cálcio',       'PARAMETER','CA', NULL, 'mmolc/dm³', 2),
  ('CALAGEM_ALCAMG','Mg',       N'Magnésio',     'PARAMETER','MG', NULL, 'mmolc/dm³', 3),
  ('CALAGEM_ALCAMG','f1',       N'Fator de Al',  'CONSTANT', NULL, 2.0,  '',          4),
  ('CALAGEM_ALCAMG','CaMg_min', N'Ca+Mg mínimo', 'USER',     NULL, 2.0,  'mmolc/dm³', 5),
  ('GESSO_ARGILA','Argila',        N'Argila',        'PARAMETER','ARGILA', NULL, 'g/kg', 1),
  ('GESSO_ARGILA','gypsum_factor', N'Fator de gesso','CONSTANT',  NULL,    5.0,  '',     2)
) v(mcode,var_name,label,src,pcode,defv,unit,ord) ON v.mcode = m.code;
GO

/* =====================================================================
   19) VIEWS
   ===================================================================== */

/* --- 19.1 VW_FERT_SAMPLE_WIDE --- */
CREATE VIEW dbo.VW_FERT_SAMPLE_WIDE AS
SELECT
    s.id AS sample_id,
    s.farm_label, s.plot_label, s.point_code,
    s.field_id, s.field_id_geo, s.geo_conflict,
    s.sample_date, s.depth_label, s.depth_from_cm, s.depth_to_cm,
    s.latitude, s.longitude,
    MAX(CASE WHEN p.code='PH_CACL2' THEN r.value_num END) AS pH_CaCl2,
    MAX(CASE WHEN p.code='MO'       THEN r.value_num END) AS MO,
    MAX(CASE WHEN p.code='P_RESINA' THEN r.value_num END) AS P_resina,
    MAX(CASE WHEN p.code='K'        THEN r.value_num END) AS K,
    MAX(CASE WHEN p.code='CA'       THEN r.value_num END) AS Ca,
    MAX(CASE WHEN p.code='MG'       THEN r.value_num END) AS Mg,
    MAX(CASE WHEN p.code='S'        THEN r.value_num END) AS S,
    MAX(CASE WHEN p.code='CTC'      THEN r.value_num END) AS CTC,
    MAX(CASE WHEN p.code='SB'       THEN r.value_num END) AS SB,
    MAX(CASE WHEN p.code='V'        THEN r.value_num END) AS V_pct,
    MAX(CASE WHEN p.code='M_SAT'    THEN r.value_num END) AS m_pct,
    MAX(CASE WHEN p.code='H_AL'     THEN r.value_num END) AS H_Al,
    MAX(CASE WHEN p.code='AL'       THEN r.value_num END) AS Al,
    MAX(CASE WHEN p.code='B'        THEN r.value_num END) AS B,
    MAX(CASE WHEN p.code='CU'       THEN r.value_num END) AS Cu,
    MAX(CASE WHEN p.code='FE'       THEN r.value_num END) AS Fe,
    MAX(CASE WHEN p.code='MN'       THEN r.value_num END) AS Mn,
    MAX(CASE WHEN p.code='ZN'       THEN r.value_num END) AS Zn,
    MAX(CASE WHEN p.code='CA_MG'    THEN r.value_num END) AS Ca_Mg,
    MAX(CASE WHEN p.code='ARGILA'   THEN r.value_num END) AS Argila,
    MAX(CASE WHEN p.code='SILTE'    THEN r.value_num END) AS Silte,
    MAX(CASE WHEN p.code='AREIA'    THEN r.value_num END) AS Areia
FROM dbo.FERT_SAMPLE s
LEFT JOIN dbo.FERT_RESULT    r ON r.sample_id = s.id AND r.deleted_at IS NULL
LEFT JOIN dbo.FERT_PARAMETER p ON p.id = r.parameter_id
WHERE s.deleted_at IS NULL
GROUP BY s.id, s.farm_label, s.plot_label, s.point_code, s.field_id, s.field_id_geo, s.geo_conflict,
         s.sample_date, s.depth_label, s.depth_from_cm, s.depth_to_cm, s.latitude, s.longitude;
GO

/* --- 19.2 VW_FERT_RESULT_CLASSIFIED (uma linha por resultado x visão) --- */
CREATE VIEW dbo.VW_FERT_RESULT_CLASSIFIED AS
SELECT
    r.id AS result_id, r.sample_id, s.field_id, s.field_id_geo, s.sample_date, s.depth_label,
    p.code AS parameter_code, p.short_label, p.unit, p.category,
    r.value_num, r.value_text,
    st.id AS set_id, st.code AS set_code, st.name AS set_name,
    i.class_label, i.class_rank, i.color_hex, i.context
FROM dbo.FERT_RESULT r
JOIN dbo.FERT_SAMPLE    s ON s.id = r.sample_id AND s.deleted_at IS NULL
JOIN dbo.FERT_PARAMETER p ON p.id = r.parameter_id
JOIN dbo.FERT_INTERPRETATION_SET st ON st.active = 1 AND st.deleted_at IS NULL
OUTER APPLY (
    SELECT TOP (1) clay.value_num AS clay
    FROM dbo.FERT_RESULT clay
    JOIN dbo.FERT_PARAMETER cp ON cp.id = clay.parameter_id AND cp.code = 'ARGILA'
    WHERE clay.sample_id = s.id AND clay.deleted_at IS NULL
) cc
OUTER APPLY (
    SELECT TOP (1) i.*
    FROM dbo.FERT_INTERPRETATION i
    WHERE i.set_id = st.id AND i.parameter_id = r.parameter_id
      AND i.active = 1 AND i.deleted_at IS NULL
      AND (i.min_value IS NULL OR r.value_num >= i.min_value)
      AND (i.max_value IS NULL OR r.value_num <  i.max_value)
      AND (i.clay_min  IS NULL OR cc.clay >= i.clay_min)
      AND (i.clay_max  IS NULL OR cc.clay <  i.clay_max)
    ORDER BY CASE WHEN i.clay_min IS NOT NULL OR i.clay_max IS NOT NULL THEN 0 ELSE 1 END
) i
WHERE r.deleted_at IS NULL AND i.id IS NOT NULL;
GO

/* --- 19.3 VW_FERT_SAMPLE_LATEST --- */
CREATE VIEW dbo.VW_FERT_SAMPLE_LATEST AS
SELECT s.*
FROM dbo.FERT_SAMPLE s
WHERE s.deleted_at IS NULL
  AND s.sample_date = (
      SELECT MAX(s2.sample_date) FROM dbo.FERT_SAMPLE s2
      WHERE s2.deleted_at IS NULL
        AND s2.farm_label = s.farm_label AND s2.plot_label = s.plot_label
        AND s2.point_code = s.point_code AND s2.depth_label = s.depth_label
  );
GO

/* --- 19.4 VW_FERT_POINT_STATUS (com progresso das profundidades) --- */
CREATE VIEW dbo.VW_FERT_POINT_STATUS AS
SELECT
    pt.id AS point_id, pt.plan_id, pl.name AS plan_name, pl.season,
    pt.point_code, pt.field_id, pt.field_id_geo, pt.latitude, pt.longitude,
    dp.name AS depth_profile, pt.status, pt.collected_at, pt.collected_by,
    (SELECT COUNT(*) FROM dbo.FERT_POINT_DEPTH d WHERE d.point_id = pt.id AND d.deleted_at IS NULL) AS depths_planned,
    (SELECT COUNT(*) FROM dbo.FERT_POINT_DEPTH d WHERE d.point_id = pt.id AND d.deleted_at IS NULL AND d.status='COLLECTED') AS depths_collected,
    CASE WHEN EXISTS (SELECT 1 FROM dbo.FERT_SAMPLE s WHERE s.plan_point_id = pt.id AND s.deleted_at IS NULL)
         THEN 1 ELSE 0 END AS has_lab_result
FROM dbo.FERT_SAMPLE_POINT pt
JOIN dbo.FERT_SAMPLE_PLAN pl ON pl.id = pt.plan_id
LEFT JOIN dbo.FERT_DEPTH_PROFILE dp ON dp.id = pt.depth_profile_id
WHERE pt.deleted_at IS NULL;
GO

/* =====================================================================
   20) PROCEDURE  usp_fert_resolve_field_geo
   ===================================================================== */
CREATE PROCEDURE dbo.usp_fert_resolve_field_geo
    @import_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Amostras
    UPDATE s SET
        field_id_geo = g.field_id,
        field_id     = COALESCE(g.field_id, s.field_id, s.field_id_label),
        field_source = CASE WHEN g.field_id IS NOT NULL THEN 'GEO'
                            WHEN s.field_id_label IS NOT NULL THEN 'LABEL'
                            ELSE s.field_source END,
        geo_conflict = CASE WHEN g.field_id IS NOT NULL AND s.field_id_label IS NOT NULL
                                 AND g.field_id <> s.field_id_label THEN 1 ELSE 0 END,
        updated_at   = SYSUTCDATETIME()
    FROM dbo.FERT_SAMPLE s
    OUTER APPLY (
        SELECT TOP (1) fg.field_id
        FROM dbo.FARM_FIELD_GEOMETRY fg
        WHERE fg.is_current = 1 AND fg.deleted_at IS NULL
          AND s.geom IS NOT NULL AND fg.geom.STIntersects(s.geom) = 1
        ORDER BY fg.field_id
    ) g
    WHERE s.deleted_at IS NULL
      AND (@import_id IS NULL OR s.import_id = @import_id);

    -- Pontos de coleta
    UPDATE pt SET
        field_id_geo = g.field_id,
        field_id     = COALESCE(g.field_id, pt.field_id),
        updated_at   = SYSUTCDATETIME()
    FROM dbo.FERT_SAMPLE_POINT pt
    OUTER APPLY (
        SELECT TOP (1) fg.field_id
        FROM dbo.FARM_FIELD_GEOMETRY fg
        WHERE fg.is_current = 1 AND fg.deleted_at IS NULL
          AND pt.geom IS NOT NULL AND fg.geom.STIntersects(pt.geom) = 1
        ORDER BY fg.field_id
    ) g
    WHERE pt.deleted_at IS NULL AND @import_id IS NULL;
END
GO

PRINT 'Modulo FERTILIDADE v4 criado com sucesso.';
GO


/* =====================================================================
   GCS_FARM  |  MÓDULO VRA — Mapas de Prescrição em Taxa Variável  |  T-SQL
   Versão: v3  |  Gerado em: 2026-06-27

   Por que SEPARADO da fertilidade?
     Zonas de manejo + mapas de aplicação são reaproveitados por várias fontes:
       FERTILIDADE -> ADUBAÇÃO/CALAGEM/GESSAGEM ; NDVI -> APLICAÇÃO ;
       PRODUTIVIDADE -> zonas ; SEMEADURA -> SEMENTES.
     A fertilidade apenas ALIMENTA o VRA (acoplamento SOLTO via source_type).

   Rastreio por calendário agrícola (FARM_SEASON):
     season_id (safra) · season_cycle_id (ciclo+CULTURA) · reference_date (data).
     CALAGEM/GESSAGEM bastam season_id; ADUBAÇÃO/SEMEADURA/APLICAÇÃO exigem
     season_cycle_id (cultura) -> VRA_MAP_TYPE.requires_cycle.

   Novidades da v3:
     - TAXA FIXA x VARIÁVEL: VRA_PRESCRIPTION.rate_mode (FIXED|VARIABLE).
         VARIABLE -> N zonas, dose por zona (VRA_PRESCRIPTION_DOSE).
         FIXED    -> dose única do produto (VRA_PRESCRIPTION_PRODUCT.flat_dose),
                     campo inteiro; zone_set_id pode ser NULL.
     - EXPORT DE MÁQUINA: VRA_EXPORT_FORMAT (catálogo por marca/modelo:
         John Deere, Fendt, Stara, Jacto...). Regras exatas em config_json
         (a definir no futuro); aqui já fica catalogado.

   Estrutura (7 tabelas + 2 views).
   Depende de FARM_FIELDS e do módulo FARM_SEASON. Rodar DEPOIS deles.
   ===================================================================== */
-- USE GCS_FARM;
-- GO

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

/* =====================================================================
   0) DROP em ordem reversa de dependência (re-execução segura)
   ===================================================================== */
IF OBJECT_ID('dbo.VW_VRA_PRESCRIPTION_MAP') IS NOT NULL DROP VIEW dbo.VW_VRA_PRESCRIPTION_MAP;
IF OBJECT_ID('dbo.VW_VRA_ZONE_CURRENT')     IS NOT NULL DROP VIEW dbo.VW_VRA_ZONE_CURRENT;
GO
IF OBJECT_ID('dbo.VRA_PRESCRIPTION_DOSE')    IS NOT NULL DROP TABLE dbo.VRA_PRESCRIPTION_DOSE;
IF OBJECT_ID('dbo.VRA_PRESCRIPTION_PRODUCT') IS NOT NULL DROP TABLE dbo.VRA_PRESCRIPTION_PRODUCT;
IF OBJECT_ID('dbo.VRA_PRESCRIPTION')         IS NOT NULL DROP TABLE dbo.VRA_PRESCRIPTION;
IF OBJECT_ID('dbo.VRA_ZONE')                 IS NOT NULL DROP TABLE dbo.VRA_ZONE;
IF OBJECT_ID('dbo.VRA_ZONE_SET')             IS NOT NULL DROP TABLE dbo.VRA_ZONE_SET;
IF OBJECT_ID('dbo.VRA_EXPORT_FORMAT')        IS NOT NULL DROP TABLE dbo.VRA_EXPORT_FORMAT;
IF OBJECT_ID('dbo.VRA_MAP_TYPE')             IS NOT NULL DROP TABLE dbo.VRA_MAP_TYPE;
GO

/* =====================================================================
   1) VRA_MAP_TYPE  -- categoria do mapa
      requires_cycle: 1 = exige cultura/ciclo ; 0 = basta a safra
   ===================================================================== */
CREATE TABLE dbo.VRA_MAP_TYPE (
    id            BIGINT        IDENTITY(1,1) CONSTRAINT PK_VRA_MAP_TYPE PRIMARY KEY,
    code          VARCHAR(40)   NOT NULL,
    name          NVARCHAR(120) NOT NULL,
    default_unit  VARCHAR(20)   NULL,
    requires_cycle BIT          NULL CONSTRAINT DF_VRA_MAP_TYPE_reqcyc DEFAULT 0,
    color_hex     CHAR(7)       NULL,
    display_order INT           NULL,
    active        BIT           NULL CONSTRAINT DF_VRA_MAP_TYPE_active DEFAULT 1,
    created_at    DATETIME2(3)  NULL CONSTRAINT DF_VRA_MAP_TYPE_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3)  NULL,
    deleted_at    DATETIME2(3)  NULL
);
GO
CREATE UNIQUE INDEX UX_VRA_MAP_TYPE_code ON dbo.VRA_MAP_TYPE (code) WHERE deleted_at IS NULL;
GO

/* =====================================================================
   2) VRA_EXPORT_FORMAT  -- catálogo de formato de export por máquina
      Cada marca/modelo aceita de um jeito; as regras exatas ficam em
      config_json (a tratar no futuro). file_format é o envelope do arquivo.
   ===================================================================== */
CREATE TABLE dbo.VRA_EXPORT_FORMAT (
    id             BIGINT        IDENTITY(1,1) CONSTRAINT PK_VRA_EXPORT_FORMAT PRIMARY KEY,
    code           VARCHAR(40)   NOT NULL,                 -- JOHN_DEERE_SHP, FENDT_ISOXML...
    brand          VARCHAR(40)   NOT NULL,                 -- JOHN_DEERE|FENDT|STARA|JACTO|GENERIC
    model          NVARCHAR(80)  NULL,                     -- console/software (ex.: Operations Center)
    name           NVARCHAR(120) NOT NULL,
    file_format    VARCHAR(20)   NOT NULL,                 -- SHAPEFILE|ISOXML|GEOJSON|CSV|OTHER
    rate_attribute NVARCHAR(40)  NULL,                     -- nome do atributo de dose no arquivo (dica)
    config_json    NVARCHAR(MAX) NULL,                     -- regras exatas (CRS, encoding, schema...) — FUTURO
    notes          NVARCHAR(MAX) NULL,
    active         BIT           NULL CONSTRAINT DF_VRA_EXPORT_FORMAT_active DEFAULT 1,
    created_at     DATETIME2(3)  NULL CONSTRAINT DF_VRA_EXPORT_FORMAT_created DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)  NULL,
    deleted_at     DATETIME2(3)  NULL,
    CONSTRAINT CK_VRA_EXPORT_fileformat CHECK (file_format IN ('SHAPEFILE','ISOXML','GEOJSON','CSV','OTHER')),
    CONSTRAINT CK_VRA_EXPORT_json CHECK (config_json IS NULL OR ISJSON(config_json) = 1)
);
GO
CREATE UNIQUE INDEX UX_VRA_EXPORT_FORMAT_code ON dbo.VRA_EXPORT_FORMAT (code) WHERE deleted_at IS NULL;
CREATE INDEX        IX_VRA_EXPORT_FORMAT_brand ON dbo.VRA_EXPORT_FORMAT (brand);
GO

/* =====================================================================
   3) VRA_ZONE_SET  -- uma ZONAGEM do talhão (versionável)
   ===================================================================== */
CREATE TABLE dbo.VRA_ZONE_SET (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_VRA_ZONE_SET PRIMARY KEY,
    field_id        BIGINT        NOT NULL,                 -- FK -> FARM_FIELDS
    code            VARCHAR(40)   NULL,
    name            NVARCHAR(150) NOT NULL,
    source_type     VARCHAR(15)   NULL,                     -- FERTILITY|NDVI|YIELD|SOIL_EC|TOPOGRAPHY|MANUAL|OTHER
    source_module   VARCHAR(40)   NULL,
    source_ref_id   BIGINT        NULL,
    method          VARCHAR(60)   NULL,
    season_id       BIGINT        NULL,                     -- FK -> FARM_SEASON
    season_cycle_id BIGINT        NULL,                     -- FK -> FARM_SEASON_CYCLE
    reference_date  DATE          NULL,
    status          VARCHAR(15)   NULL,                     -- DRAFT|ACTIVE|ARCHIVED
    is_current      BIT           NULL CONSTRAINT DF_VRA_ZONE_SET_cur DEFAULT 0,
    created_by      VARCHAR(60)   NULL,
    notes           NVARCHAR(MAX) NULL,
    created_at      DATETIME2(3)  NULL CONSTRAINT DF_VRA_ZONE_SET_created DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)  NULL,
    deleted_at      DATETIME2(3)  NULL,
    CONSTRAINT FK_VRA_ZONE_SET_field  FOREIGN KEY (field_id)        REFERENCES dbo.FARM_FIELDS(id),
    CONSTRAINT FK_VRA_ZONE_SET_season FOREIGN KEY (season_id)       REFERENCES dbo.FARM_SEASON(id),
    CONSTRAINT FK_VRA_ZONE_SET_cycle  FOREIGN KEY (season_cycle_id) REFERENCES dbo.FARM_SEASON_CYCLE(id),
    CONSTRAINT CK_VRA_ZONE_SET_src    CHECK (source_type IS NULL OR source_type IN ('FERTILITY','NDVI','YIELD','SOIL_EC','TOPOGRAPHY','MANUAL','OTHER')),
    CONSTRAINT CK_VRA_ZONE_SET_status CHECK (status IS NULL OR status IN ('DRAFT','ACTIVE','ARCHIVED'))
);
GO
CREATE UNIQUE INDEX UX_VRA_ZONE_SET_current ON dbo.VRA_ZONE_SET (field_id) WHERE is_current = 1 AND deleted_at IS NULL;
CREATE INDEX        IX_VRA_ZONE_SET_field   ON dbo.VRA_ZONE_SET (field_id);
CREATE INDEX        IX_VRA_ZONE_SET_season  ON dbo.VRA_ZONE_SET (season_id);
CREATE INDEX        IX_VRA_ZONE_SET_source  ON dbo.VRA_ZONE_SET (source_module, source_ref_id);
GO

/* =====================================================================
   4) VRA_ZONE  -- zona de manejo (polígono dentro do talhão)
   ===================================================================== */
CREATE TABLE dbo.VRA_ZONE (
    id            BIGINT        IDENTITY(1,1) CONSTRAINT PK_VRA_ZONE PRIMARY KEY,
    zone_set_id   BIGINT        NOT NULL,
    code          VARCHAR(40)   NULL,
    name          NVARCHAR(120) NULL,
    class_label   NVARCHAR(40)  NULL,
    class_rank    TINYINT       NULL,
    geom          GEOGRAPHY     NOT NULL,
    area_hectares DECIMAL(18,4) NULL,
    color_hex     CHAR(7)       NULL,
    attributes    NVARCHAR(MAX) NULL,
    notes         NVARCHAR(MAX) NULL,
    created_at    DATETIME2(3)  NULL CONSTRAINT DF_VRA_ZONE_created DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2(3)  NULL,
    deleted_at    DATETIME2(3)  NULL,
    CONSTRAINT FK_VRA_ZONE_set FOREIGN KEY (zone_set_id) REFERENCES dbo.VRA_ZONE_SET(id),
    CONSTRAINT CK_VRA_ZONE_json CHECK (attributes IS NULL OR ISJSON(attributes) = 1)
);
GO
CREATE INDEX        IX_VRA_ZONE_set  ON dbo.VRA_ZONE (zone_set_id);
CREATE UNIQUE INDEX UX_VRA_ZONE_code ON dbo.VRA_ZONE (zone_set_id, code) WHERE code IS NOT NULL AND deleted_at IS NULL;
GO

/* =====================================================================
   5) VRA_PRESCRIPTION  -- mapa de prescrição (cabeçalho)
      rate_mode: VARIABLE (N zonas, dose por zona) | FIXED (dose única do produto).
      zone_set_id NULL é válido em taxa FIXA (campo inteiro).
   ===================================================================== */
CREATE TABLE dbo.VRA_PRESCRIPTION (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_VRA_PRESCRIPTION PRIMARY KEY,
    code            VARCHAR(40)   NULL,
    name            NVARCHAR(150) NOT NULL,
    field_id        BIGINT        NOT NULL,                 -- FK -> FARM_FIELDS
    zone_set_id     BIGINT        NULL,                     -- zonagem (obrigatória só em VARIABLE)
    map_type_id     BIGINT        NOT NULL,
    rate_mode       VARCHAR(10)   NULL CONSTRAINT DF_VRA_PRESC_mode DEFAULT 'VARIABLE',
    season_id       BIGINT        NOT NULL,                 -- FK -> FARM_SEASON
    season_cycle_id BIGINT        NULL,                     -- FK -> FARM_SEASON_CYCLE (cultura)
    reference_date  DATE          NULL,
    status          VARCHAR(15)   NULL,                     -- DRAFT|APPROVED|EXPORTED|CANCELLED
    source_module   VARCHAR(40)   NULL,
    approved_by     VARCHAR(60)   NULL,
    approved_at     DATETIME2(3)  NULL,
    exported_at     DATETIME2(3)  NULL,
    created_by      VARCHAR(60)   NULL,
    notes           NVARCHAR(MAX) NULL,
    created_at      DATETIME2(3)  NULL CONSTRAINT DF_VRA_PRESC_created DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)  NULL,
    deleted_at      DATETIME2(3)  NULL,
    CONSTRAINT FK_VRA_PRESC_field    FOREIGN KEY (field_id)        REFERENCES dbo.FARM_FIELDS(id),
    CONSTRAINT FK_VRA_PRESC_set      FOREIGN KEY (zone_set_id)     REFERENCES dbo.VRA_ZONE_SET(id),
    CONSTRAINT FK_VRA_PRESC_maptype  FOREIGN KEY (map_type_id)     REFERENCES dbo.VRA_MAP_TYPE(id),
    CONSTRAINT FK_VRA_PRESC_season   FOREIGN KEY (season_id)       REFERENCES dbo.FARM_SEASON(id),
    CONSTRAINT FK_VRA_PRESC_cycle    FOREIGN KEY (season_cycle_id) REFERENCES dbo.FARM_SEASON_CYCLE(id),
    CONSTRAINT CK_VRA_PRESC_mode   CHECK (rate_mode IS NULL OR rate_mode IN ('VARIABLE','FIXED')),
    CONSTRAINT CK_VRA_PRESC_status CHECK (status IS NULL OR status IN ('DRAFT','APPROVED','EXPORTED','CANCELLED'))
);
GO
CREATE UNIQUE INDEX UX_VRA_PRESC_code   ON dbo.VRA_PRESCRIPTION (code) WHERE code IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX        IX_VRA_PRESC_field  ON dbo.VRA_PRESCRIPTION (field_id);
CREATE INDEX        IX_VRA_PRESC_type   ON dbo.VRA_PRESCRIPTION (map_type_id);
CREATE INDEX        IX_VRA_PRESC_season ON dbo.VRA_PRESCRIPTION (season_id, season_cycle_id);
GO

/* =====================================================================
   6) VRA_PRESCRIPTION_PRODUCT  -- produtos do mapa (1..N)
      flat_dose: usada em taxa FIXA (uma dose para o campo inteiro).
   ===================================================================== */
CREATE TABLE dbo.VRA_PRESCRIPTION_PRODUCT (
    id                BIGINT        IDENTITY(1,1) CONSTRAINT PK_VRA_PRESC_PRODUCT PRIMARY KEY,
    prescription_id   BIGINT        NOT NULL,
    product_code      VARCHAR(40)   NULL,
    product_name      NVARCHAR(150) NOT NULL,
    unit              VARCHAR(20)   NOT NULL,
    flat_dose         DECIMAL(18,6) NULL,                  -- dose única (taxa FIXA)
    source_calc_module VARCHAR(40)  NULL,
    source_calc_id    BIGINT        NULL,
    display_order     INT           NULL,
    notes             NVARCHAR(MAX) NULL,
    created_at        DATETIME2(3)  NULL CONSTRAINT DF_VRA_PRESC_PROD_created DEFAULT SYSUTCDATETIME(),
    updated_at        DATETIME2(3)  NULL,
    deleted_at        DATETIME2(3)  NULL,
    CONSTRAINT FK_VRA_PRESC_PROD_presc FOREIGN KEY (prescription_id) REFERENCES dbo.VRA_PRESCRIPTION(id)
);
GO
CREATE INDEX IX_VRA_PRESC_PROD_presc ON dbo.VRA_PRESCRIPTION_PRODUCT (prescription_id);
GO

/* =====================================================================
   7) VRA_PRESCRIPTION_DOSE  -- dose por (produto, zona)  [taxa VARIÁVEL]
   ===================================================================== */
CREATE TABLE dbo.VRA_PRESCRIPTION_DOSE (
    id              BIGINT        IDENTITY(1,1) CONSTRAINT PK_VRA_PRESC_DOSE PRIMARY KEY,
    prescription_id BIGINT        NOT NULL,
    product_id      BIGINT        NOT NULL,               -- FK -> VRA_PRESCRIPTION_PRODUCT
    zone_id         BIGINT        NOT NULL,               -- FK -> VRA_ZONE
    dose            DECIMAL(18,6) NULL,
    unit            VARCHAR(20)   NULL,
    source          VARCHAR(10)   NULL,                   -- MANUAL|CALC
    calc_snapshot   NVARCHAR(MAX) NULL,
    notes           NVARCHAR(MAX) NULL,
    created_at      DATETIME2(3)  NULL CONSTRAINT DF_VRA_PRESC_DOSE_created DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)  NULL,
    deleted_at      DATETIME2(3)  NULL,
    CONSTRAINT FK_VRA_PRESC_DOSE_presc   FOREIGN KEY (prescription_id) REFERENCES dbo.VRA_PRESCRIPTION(id),
    CONSTRAINT FK_VRA_PRESC_DOSE_product FOREIGN KEY (product_id)      REFERENCES dbo.VRA_PRESCRIPTION_PRODUCT(id),
    CONSTRAINT FK_VRA_PRESC_DOSE_zone    FOREIGN KEY (zone_id)         REFERENCES dbo.VRA_ZONE(id),
    CONSTRAINT CK_VRA_PRESC_DOSE_src  CHECK (source IS NULL OR source IN ('MANUAL','CALC')),
    CONSTRAINT CK_VRA_PRESC_DOSE_json CHECK (calc_snapshot IS NULL OR ISJSON(calc_snapshot) = 1)
);
GO
CREATE UNIQUE INDEX UX_VRA_PRESC_DOSE ON dbo.VRA_PRESCRIPTION_DOSE (product_id, zone_id) WHERE deleted_at IS NULL;
CREATE INDEX        IX_VRA_PRESC_DOSE_presc ON dbo.VRA_PRESCRIPTION_DOSE (prescription_id);
GO

/* =====================================================================
   8) SEEDS
   ===================================================================== */

/* --- 8.1 Categorias de mapa (requires_cycle: precisa de cultura?) --- */
INSERT INTO dbo.VRA_MAP_TYPE (code, name, default_unit, requires_cycle, color_hex, display_order) VALUES
 ('ADUBACAO',  N'Adubação',              'kg/ha',  1, '#2E7D33', 10),
 ('CALAGEM',   N'Calagem',               't/ha',   0, '#16324F', 20),
 ('GESSAGEM',  N'Gessagem',              'kg/ha',  0, '#ADCB38', 30),
 ('SEMENTES',  N'Semeadura',             'sem/ha', 1, '#F5841F', 40),
 ('APLICACAO', N'Aplicação (defensivos)','L/ha',   1, '#E8431C', 50),
 ('OUTRO',     N'Outro',                 NULL,     0, NULL,      90);
GO

/* --- 8.2 Formatos de export por máquina (regras exatas: futuro) --- */
INSERT INTO dbo.VRA_EXPORT_FORMAT (code, brand, model, name, file_format, rate_attribute) VALUES
 ('JOHN_DEERE_SHP', 'JOHN_DEERE', N'Operations Center / GreenStar', N'John Deere — Shapefile', 'SHAPEFILE', N'RATE'),
 ('FENDT_ISOXML',   'FENDT',      N'VarioDoc / VarioGuide',         N'Fendt — ISO-XML (TASKDATA)', 'ISOXML',  NULL),
 ('STARA_SHP',      'STARA',      N'Topper / Telemetria Stara',     N'Stara — Shapefile',       'SHAPEFILE', N'TAXA'),
 ('JACTO_ISOXML',   'JACTO',      N'Otmis',                         N'Jacto — ISO-XML',         'ISOXML',   NULL),
 ('GENERIC_SHP',    'GENERIC',    NULL,                             N'Genérico — Shapefile',    'SHAPEFILE', N'RATE'),
 ('GENERIC_ISOXML', 'GENERIC',    NULL,                             N'Genérico — ISO-XML',      'ISOXML',   NULL);
GO

/* =====================================================================
   9) VIEWS
   ===================================================================== */

/* --- 9.1 VW_VRA_ZONE_CURRENT : zonas da zonagem vigente de cada talhão --- */
CREATE VIEW dbo.VW_VRA_ZONE_CURRENT AS
SELECT
    zs.field_id, zs.id AS zone_set_id, zs.name AS zone_set_name, zs.source_type, zs.method,
    zs.season_id, zs.season_cycle_id,
    z.id AS zone_id, z.code AS zone_code, z.name AS zone_name, z.class_label, z.class_rank,
    z.area_hectares, z.color_hex, z.attributes, z.geom
FROM dbo.VRA_ZONE_SET zs
JOIN dbo.VRA_ZONE z ON z.zone_set_id = zs.id AND z.deleted_at IS NULL
WHERE zs.is_current = 1 AND zs.deleted_at IS NULL;
GO

/* --- 9.2 VW_VRA_PRESCRIPTION_MAP : mapa pronto p/ exportar
        Cobre taxa VARIÁVEL (dose por zona) e FIXA (flat_dose, sem zonas).
        dose efetiva = COALESCE(dose da zona, flat_dose do produto). --- */
CREATE VIEW dbo.VW_VRA_PRESCRIPTION_MAP AS
SELECT
    pr.id AS prescription_id, pr.code AS prescription_code, pr.name AS prescription_name,
    pr.field_id, pr.status, pr.rate_mode, pr.reference_date,
    mt.code AS map_type_code, mt.name AS map_type_name, mt.requires_cycle,
    se.code AS season_code, se.name AS season_name,
    cy.cycle_no, cy.name AS cycle_name, cu.code AS culture_code, cu.name AS culture_name,
    pp.id AS product_id, pp.product_name, pp.unit AS product_unit,
    z.id AS zone_id, z.code AS zone_code, z.name AS zone_name, z.class_label,
    z.area_hectares, z.color_hex,
    COALESCE(d.dose, pp.flat_dose) AS dose,
    COALESCE(d.unit, pp.unit) AS dose_unit,
    CASE WHEN pr.rate_mode = 'FIXED' THEN 'FIXED' ELSE d.source END AS dose_source,
    z.geom
FROM dbo.VRA_PRESCRIPTION pr
JOIN dbo.VRA_MAP_TYPE mt ON mt.id = pr.map_type_id
LEFT JOIN dbo.FARM_SEASON se ON se.id = pr.season_id
LEFT JOIN dbo.FARM_SEASON_CYCLE cy ON cy.id = pr.season_cycle_id
LEFT JOIN dbo.FARM_CULTURE cu ON cu.id = cy.culture_id
JOIN dbo.VRA_PRESCRIPTION_PRODUCT pp ON pp.prescription_id = pr.id AND pp.deleted_at IS NULL
LEFT JOIN dbo.VRA_ZONE z ON z.zone_set_id = pr.zone_set_id AND z.deleted_at IS NULL
LEFT JOIN dbo.VRA_PRESCRIPTION_DOSE d ON d.product_id = pp.id AND d.zone_id = z.id AND d.deleted_at IS NULL
WHERE pr.deleted_at IS NULL;
GO

PRINT 'Modulo VRA (mapas de prescricao) v3 criado com sucesso.';
GO


/* #####################################################################
   FIM DO SETUP — CONNECTOR_GCS_FARM + GCS_FARM
   ##################################################################### */
GO

GO
/* #####################################################################
   MÓDULO PAINEL DE OPERAÇÕES (OPS_*) — programa→etapa→subetapa→lançamento + equipes/membros/alvo-pivô/KML/arquivos (11 tabelas)
   ##################################################################### */
IF OBJECT_ID('dbo.OPS_PROGRAM','U') IS NULL
BEGIN
/* =========================================================================
   MÓDULO PAINEL DE OPERAÇÕES  (OPS_*)  —  GCS_FARM   [PROPOSTA / EM MODELAGEM]
   -------------------------------------------------------------------------
   Programa (Expansão/Destruição/…) → ETAPA → SUBETAPA (+ histórico/ledger).
   • Tipo: agricola | estrutura | manutencao. Agrícola exige safra + cultura.
   • Alvo do PROGRAMA: pivôs específicos (vazio = todos da cultura/safra).
   • Alvo da ETAPA: talhão (FARM_FIELDS) OU feição de KML (OPS_GEOMETRY_FEATURE,
     separada do módulo Farm, mesmo padrão geography SRID 4326).
   • SUBETAPA tem equipe, fonte (manual/solinftec/irricontrol/farmbox), tipo de
     medição (ha/mm/dose/marco/percent) e histórico de lançamentos.
   • PROGRESSO é DERIVADO (não armazenado): entry → subetapa → etapa → programa.
   Convenções: BIGINT IDENTITY, soft-delete (deleted_at), UTC, FK ao core Farm.
   ========================================================================= */

------------------------------------------------------------------ 1) PROGRAMA
CREATE TABLE dbo.OPS_PROGRAM (
  id            BIGINT IDENTITY(1,1) CONSTRAINT PK_OPS_PROGRAM PRIMARY KEY,
  name          NVARCHAR(160) NOT NULL,
  kind          VARCHAR(12)   NOT NULL,                 -- agricola | estrutura | manutencao
  visibility    VARCHAR(10)   NOT NULL CONSTRAINT DF_OPS_PROGRAM_vis DEFAULT 'private',
  farm_id       BIGINT NULL,                            -- FARM_FARMS (fazenda do programa; multi-fazenda)
  season_id     BIGINT NULL,                            -- FARM_SEASON  (obrigatório se agrícola)
  culture_id    BIGINT NULL,                            -- FARM_CULTURE (obrigatório se agrícola)
  owner_user_id BIGINT NULL,                            -- MANAGEMENT_USERS (criador)
  color_hex     CHAR(7) NULL,
  start_date    DATE NULL,
  deadline      DATE NULL,
  notes         NVARCHAR(1000) NULL,
  created_at    DATETIME2 NOT NULL CONSTRAINT DF_OPS_PROGRAM_ca DEFAULT SYSUTCDATETIME(),
  updated_at    DATETIME2 NULL,
  deleted_at    DATETIME2 NULL,
  CONSTRAINT CK_OPS_PROGRAM_kind CHECK (kind IN ('agricola','estrutura','manutencao')),
  CONSTRAINT CK_OPS_PROGRAM_vis  CHECK (visibility IN ('public','private')),
  CONSTRAINT CK_OPS_PROGRAM_agri CHECK (kind <> 'agricola' OR (season_id IS NOT NULL AND culture_id IS NOT NULL)),
  CONSTRAINT CK_OPS_PROGRAM_dates CHECK (start_date IS NULL OR deadline IS NULL OR start_date <= deadline),
  CONSTRAINT FK_OPS_PROGRAM_farm    FOREIGN KEY (farm_id)       REFERENCES dbo.FARM_FARMS(id),
  CONSTRAINT FK_OPS_PROGRAM_season  FOREIGN KEY (season_id)     REFERENCES dbo.FARM_SEASON(id),
  CONSTRAINT FK_OPS_PROGRAM_culture FOREIGN KEY (culture_id)    REFERENCES dbo.FARM_CULTURE(id),
  CONSTRAINT FK_OPS_PROGRAM_owner   FOREIGN KEY (owner_user_id) REFERENCES dbo.MANAGEMENT_USERS(id)
);

--------------------------------------------- 2) MEMBROS (responsáveis/compart.)
CREATE TABLE dbo.OPS_PROGRAM_MEMBER (
  id           BIGINT IDENTITY(1,1) CONSTRAINT PK_OPS_PROGRAM_MEMBER PRIMARY KEY,
  program_id   BIGINT NOT NULL,
  user_id      BIGINT NULL,                              -- MANAGEMENT_USERS (null = responsável em texto livre — v1)
  display_name NVARCHAR(120) NULL,                       -- nome digitado quando não há user_id
  role         NVARCHAR(60) NULL,                          -- cargo (Coordenador, Eng…)
  is_owner   BIT NOT NULL CONSTRAINT DF_OPS_MEMBER_owner DEFAULT 0,
  can_edit   BIT NOT NULL CONSTRAINT DF_OPS_MEMBER_edit  DEFAULT 1,
  created_at DATETIME2 NOT NULL CONSTRAINT DF_OPS_MEMBER_ca DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2 NULL,
  CONSTRAINT FK_OPS_MEMBER_program FOREIGN KEY (program_id) REFERENCES dbo.OPS_PROGRAM(id),
  CONSTRAINT FK_OPS_MEMBER_user    FOREIGN KEY (user_id)    REFERENCES dbo.MANAGEMENT_USERS(id)
);
CREATE UNIQUE INDEX UX_OPS_MEMBER ON dbo.OPS_PROGRAM_MEMBER(program_id, user_id) WHERE user_id IS NOT NULL AND deleted_at IS NULL;

------------------------ 3) ALVO DO PROGRAMA — pivôs (vazio = todos da cultura)
CREATE TABLE dbo.OPS_PROGRAM_FIELD (
  id         BIGINT IDENTITY(1,1) CONSTRAINT PK_OPS_PROGRAM_FIELD PRIMARY KEY,
  program_id BIGINT NOT NULL,
  field_id   BIGINT NOT NULL,                            -- FARM_FIELDS (pivô = talhão neste sistema)
  created_at DATETIME2 NOT NULL CONSTRAINT DF_OPS_PFLD_ca DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2 NULL,
  CONSTRAINT FK_OPS_PFLD_program FOREIGN KEY (program_id) REFERENCES dbo.OPS_PROGRAM(id),
  CONSTRAINT FK_OPS_PFLD_field   FOREIGN KEY (field_id)   REFERENCES dbo.FARM_FIELDS(id)
);
CREATE UNIQUE INDEX UX_OPS_PFLD ON dbo.OPS_PROGRAM_FIELD(program_id, field_id) WHERE deleted_at IS NULL;

------------------------------------------------------- 4) EQUIPES (por programa)
CREATE TABLE dbo.OPS_TEAM (
  id         BIGINT IDENTITY(1,1) CONSTRAINT PK_OPS_TEAM PRIMARY KEY,
  program_id BIGINT NOT NULL,
  kind       VARCHAR(12) NOT NULL,                       -- gcs | terceirizada
  name       NVARCHAR(120) NOT NULL,
  created_at DATETIME2 NOT NULL CONSTRAINT DF_OPS_TEAM_ca DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2 NULL,
  CONSTRAINT CK_OPS_TEAM_kind CHECK (kind IN ('gcs','terceirizada')),
  CONSTRAINT FK_OPS_TEAM_program FOREIGN KEY (program_id) REFERENCES dbo.OPS_PROGRAM(id)
);

----------------------------- 5) CAMADAS DE KML (separadas do Farm) + 6) FEIÇÕES
CREATE TABLE dbo.OPS_GEOMETRY_LAYER (
  id         BIGINT IDENTITY(1,1) CONSTRAINT PK_OPS_GEOMETRY_LAYER PRIMARY KEY,
  program_id BIGINT NOT NULL,
  name       NVARCHAR(160) NOT NULL,
  source     VARCHAR(10) NOT NULL CONSTRAINT DF_OPS_LAYER_src DEFAULT 'kml',
  file_id    BIGINT NULL,                                -- OPS_FILE do KML importado (FK ao fim)
  file_name  NVARCHAR(260) NULL,
  created_at DATETIME2 NOT NULL CONSTRAINT DF_OPS_LAYER_ca DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2 NULL,
  CONSTRAINT FK_OPS_LAYER_program FOREIGN KEY (program_id) REFERENCES dbo.OPS_PROGRAM(id)
);
CREATE TABLE dbo.OPS_GEOMETRY_FEATURE (
  id         BIGINT IDENTITY(1,1) CONSTRAINT PK_OPS_GEOMETRY_FEATURE PRIMARY KEY,
  layer_id   BIGINT NOT NULL,
  name       NVARCHAR(160) NULL,
  category   NVARCHAR(200) NULL,                         -- pasta/categoria do KML (ex.: PIVÔS / BLOCO A)
  icon       NVARCHAR(40) NULL,                          -- ícone (só pontos): chave da paleta de ícones no front
  opacity    FLOAT NULL,                                 -- 0..1 (NULL = padrão do mapa) por feição/categoria
  geom_type  VARCHAR(10) NOT NULL,                       -- polygon | line | point
  geom       geography NOT NULL,                         -- SRID 4326 (igual ao Farm)
  color_hex  CHAR(7) NULL,
  area_ha    DECIMAL(12,2) NULL,
  created_at DATETIME2 NOT NULL CONSTRAINT DF_OPS_FEAT_ca DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2 NULL,
  CONSTRAINT CK_OPS_FEAT_type CHECK (geom_type IN ('polygon','line','point')),
  CONSTRAINT CK_OPS_FEAT_srid CHECK (geom.STSrid = 4326),
  CONSTRAINT FK_OPS_FEAT_layer FOREIGN KEY (layer_id) REFERENCES dbo.OPS_GEOMETRY_LAYER(id)
);

------------------------------------------------------------- 7) ETAPA (operação)
CREATE TABLE dbo.OPS_TASK (
  id              BIGINT IDENTITY(1,1) CONSTRAINT PK_OPS_TASK PRIMARY KEY,
  program_id      BIGINT NOT NULL,
  description     NVARCHAR(200) NOT NULL,
  fleet           VARCHAR(12) NOT NULL,                  -- propria | terceirizada | ambos
  meta_value      DECIMAL(12,2) NULL,
  meta_unit       NVARCHAR(20) NULL,
  meta_period     VARCHAR(10) NULL,                      -- diaria | semanal | mensal
  deadline        DATE NULL,
  team_id         BIGINT NULL,
  notes           NVARCHAR(1000) NULL,
  progress_manual TINYINT NOT NULL CONSTRAINT DF_OPS_TASK_pm DEFAULT 0,  -- fallback (sem subetapa/feição)
  sort_order      INT NOT NULL CONSTRAINT DF_OPS_TASK_so DEFAULT 0,
  created_at      DATETIME2 NOT NULL CONSTRAINT DF_OPS_TASK_ca DEFAULT SYSUTCDATETIME(),
  updated_at      DATETIME2 NULL,
  deleted_at      DATETIME2 NULL,
  CONSTRAINT CK_OPS_TASK_fleet  CHECK (fleet IN ('propria','terceirizada','ambos')),
  CONSTRAINT CK_OPS_TASK_period CHECK (meta_period IS NULL OR meta_period IN ('diaria','semanal','mensal')),
  CONSTRAINT CK_OPS_TASK_prog   CHECK (progress_manual BETWEEN 0 AND 100),
  CONSTRAINT FK_OPS_TASK_program FOREIGN KEY (program_id) REFERENCES dbo.OPS_PROGRAM(id),
  CONSTRAINT FK_OPS_TASK_team    FOREIGN KEY (team_id)    REFERENCES dbo.OPS_TEAM(id)
);

----------------------- 8) ALVO DA ETAPA — talhão OU feição de KML (exatamente 1)
CREATE TABLE dbo.OPS_TASK_TARGET (
  id         BIGINT IDENTITY(1,1) CONSTRAINT PK_OPS_TASK_TARGET PRIMARY KEY,
  task_id    BIGINT NOT NULL,
  field_id   BIGINT NULL,                                -- FARM_FIELDS
  feature_id BIGINT NULL,                                -- OPS_GEOMETRY_FEATURE
  created_at DATETIME2 NOT NULL CONSTRAINT DF_OPS_TTGT_ca DEFAULT SYSUTCDATETIME(),
  deleted_at DATETIME2 NULL,
  CONSTRAINT CK_OPS_TTGT_one CHECK ((CASE WHEN field_id IS NULL THEN 0 ELSE 1 END)
                                  + (CASE WHEN feature_id IS NULL THEN 0 ELSE 1 END) = 1),
  CONSTRAINT FK_OPS_TTGT_task    FOREIGN KEY (task_id)    REFERENCES dbo.OPS_TASK(id),
  CONSTRAINT FK_OPS_TTGT_field   FOREIGN KEY (field_id)   REFERENCES dbo.FARM_FIELDS(id),
  CONSTRAINT FK_OPS_TTGT_feature FOREIGN KEY (feature_id) REFERENCES dbo.OPS_GEOMETRY_FEATURE(id)
);

------------------------------------------------------------------- 9) SUBETAPA
CREATE TABLE dbo.OPS_SUBTASK (
  id              BIGINT IDENTITY(1,1) CONSTRAINT PK_OPS_SUBTASK PRIMARY KEY,
  task_id         BIGINT NOT NULL,
  name            NVARCHAR(160) NOT NULL,
  team_id         BIGINT NULL,
  weight          DECIMAL(8,2) NOT NULL CONSTRAINT DF_OPS_SUB_w DEFAULT 1,
  source          VARCHAR(12) NOT NULL CONSTRAINT DF_OPS_SUB_src  DEFAULT 'manual', -- manual|solinftec|irricontrol|farmbox
  source_ref      NVARCHAR(120) NULL,                    -- op Solinftec / OS / AP Farmbox / pivô IrriControl
  measure         VARCHAR(10) NOT NULL CONSTRAINT DF_OPS_SUB_meas DEFAULT 'percent',-- ha|mm|dose|marco|percent
  target_qty      DECIMAL(14,3) NULL,                    -- meta total (ha, mm, doses)
  unit            NVARCHAR(20) NULL,
  done_date       DATE NULL,                             -- measure = marco
  progress_manual TINYINT NOT NULL CONSTRAINT DF_OPS_SUB_pm DEFAULT 0,  -- measure = percent
  sort_order      INT NOT NULL CONSTRAINT DF_OPS_SUB_so DEFAULT 0,
  created_at      DATETIME2 NOT NULL CONSTRAINT DF_OPS_SUB_ca DEFAULT SYSUTCDATETIME(),
  updated_at      DATETIME2 NULL,
  deleted_at      DATETIME2 NULL,
  CONSTRAINT CK_OPS_SUB_src  CHECK (source  IN ('manual','solinftec','irricontrol','farmbox')),
  CONSTRAINT CK_OPS_SUB_meas CHECK (measure IN ('ha','mm','dose','marco','percent')),
  CONSTRAINT CK_OPS_SUB_prog CHECK (progress_manual BETWEEN 0 AND 100),
  CONSTRAINT FK_OPS_SUB_task FOREIGN KEY (task_id) REFERENCES dbo.OPS_TASK(id),
  CONSTRAINT FK_OPS_SUB_team FOREIGN KEY (team_id) REFERENCES dbo.OPS_TEAM(id)
);

------------------ 10) HISTÓRICO DE LANÇAMENTOS (ledger) — opcional por feição/talhão
CREATE TABLE dbo.OPS_SUBTASK_ENTRY (
  id            BIGINT IDENTITY(1,1) CONSTRAINT PK_OPS_SUBTASK_ENTRY PRIMARY KEY,
  subtask_id    BIGINT NOT NULL,
  entry_date    DATE NOT NULL,
  amount        DECIMAL(14,3) NOT NULL,                  -- ha/mm/doses lançados
  field_id      BIGINT NULL,                             -- FARM_FIELDS (talhão avançado)
  feature_id    BIGINT NULL,                             -- OPS_GEOMETRY_FEATURE (feição avançada)
  origin        VARCHAR(12) NOT NULL CONSTRAINT DF_OPS_ENTRY_org DEFAULT 'manual',
  source_record NVARCHAR(200) NULL,                      -- chave-grão do fato de origem (ex.: op:field:yyyy-mm-dd) p/ idempotência
  note          NVARCHAR(300) NULL,
  created_by    BIGINT NULL,                             -- MANAGEMENT_USERS
  created_at    DATETIME2 NOT NULL CONSTRAINT DF_OPS_ENTRY_ca DEFAULT SYSUTCDATETIME(),
  updated_at    DATETIME2 NULL,
  deleted_at    DATETIME2 NULL,
  CONSTRAINT CK_OPS_ENTRY_origin CHECK (origin IN ('manual','solinftec','irricontrol','farmbox')),
  CONSTRAINT CK_OPS_ENTRY_amount CHECK (amount >= 0),
  CONSTRAINT CK_OPS_ENTRY_target CHECK ((CASE WHEN field_id IS NULL THEN 0 ELSE 1 END)
                                      + (CASE WHEN feature_id IS NULL THEN 0 ELSE 1 END) <= 1),
  CONSTRAINT FK_OPS_ENTRY_sub     FOREIGN KEY (subtask_id) REFERENCES dbo.OPS_SUBTASK(id),
  CONSTRAINT FK_OPS_ENTRY_field   FOREIGN KEY (field_id)   REFERENCES dbo.FARM_FIELDS(id),
  CONSTRAINT FK_OPS_ENTRY_feature FOREIGN KEY (feature_id) REFERENCES dbo.OPS_GEOMETRY_FEATURE(id)
);
-- idempotência: um mesmo fato de integração não entra 2×. source_record = CHAVE-GRÃO do fato
-- (ex.: op×talhão×dia). SEM filtro de deleted_at → o ETL faz upsert-com-undelete (não duplica após soft-delete).
CREATE UNIQUE INDEX UX_OPS_ENTRY_src ON dbo.OPS_SUBTASK_ENTRY(subtask_id, origin, source_record)
  WHERE source_record IS NOT NULL;

---------------------------------------------------- 11) ARQUIVOS (repositório)
CREATE TABLE dbo.OPS_FILE (
  id          BIGINT IDENTITY(1,1) CONSTRAINT PK_OPS_FILE PRIMARY KEY,
  program_id  BIGINT NOT NULL,
  task_id     BIGINT NULL,                               -- arquivo geral (NULL) ou de uma etapa
  name        NVARCHAR(260) NOT NULL,
  kind        VARCHAR(10) NOT NULL,                      -- xlsx|pdf|kml|image|other
  size_bytes  BIGINT NULL,
  storage_ref NVARCHAR(400) NULL,                        -- caminho/URL no storage
  uploaded_by BIGINT NULL,
  created_at  DATETIME2 NOT NULL CONSTRAINT DF_OPS_FILE_ca DEFAULT SYSUTCDATETIME(),
  deleted_at  DATETIME2 NULL,
  CONSTRAINT FK_OPS_FILE_program FOREIGN KEY (program_id) REFERENCES dbo.OPS_PROGRAM(id),
  CONSTRAINT FK_OPS_FILE_task    FOREIGN KEY (task_id)    REFERENCES dbo.OPS_TASK(id)
);

-- 1 alvo por etapa não duplicado
CREATE UNIQUE INDEX UX_OPS_TTGT_field   ON dbo.OPS_TASK_TARGET(task_id, field_id)   WHERE field_id   IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX UX_OPS_TTGT_feature ON dbo.OPS_TASK_TARGET(task_id, feature_id) WHERE feature_id IS NOT NULL AND deleted_at IS NULL;

------------------------------------------------------- índices de navegação (FKs)
CREATE INDEX IX_OPS_TASK_program ON dbo.OPS_TASK(program_id)           WHERE deleted_at IS NULL;
CREATE INDEX IX_OPS_TASK_team    ON dbo.OPS_TASK(team_id)              WHERE deleted_at IS NULL;
CREATE INDEX IX_OPS_SUB_task     ON dbo.OPS_SUBTASK(task_id)           WHERE deleted_at IS NULL;
CREATE INDEX IX_OPS_SUB_team     ON dbo.OPS_SUBTASK(team_id)           WHERE deleted_at IS NULL;
CREATE INDEX IX_OPS_ENTRY_sub    ON dbo.OPS_SUBTASK_ENTRY(subtask_id)  WHERE deleted_at IS NULL;
CREATE INDEX IX_OPS_TTGT_task    ON dbo.OPS_TASK_TARGET(task_id)       WHERE deleted_at IS NULL;
CREATE INDEX IX_OPS_FEAT_layer   ON dbo.OPS_GEOMETRY_FEATURE(layer_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_OPS_TEAM_program ON dbo.OPS_TEAM(program_id)           WHERE deleted_at IS NULL;
CREATE INDEX IX_OPS_LAYER_program ON dbo.OPS_GEOMETRY_LAYER(program_id) WHERE deleted_at IS NULL;
CREATE INDEX IX_OPS_FILE_program ON dbo.OPS_FILE(program_id)           WHERE deleted_at IS NULL;
CREATE INDEX IX_OPS_PROGRAM_farm ON dbo.OPS_PROGRAM(farm_id)           WHERE deleted_at IS NULL;
CREATE SPATIAL INDEX SX_OPS_FEAT_geom ON dbo.OPS_GEOMETRY_FEATURE(geom);

-- FK da camada -> arquivo KML (criada após OPS_FILE existir)
ALTER TABLE dbo.OPS_GEOMETRY_LAYER ADD CONSTRAINT FK_OPS_LAYER_file FOREIGN KEY (file_id) REFERENCES dbo.OPS_FILE(id);

/* PROGRESSO é derivado (views a criar):
   VW_OPS_SUBTASK_PROGRESS  = por medição (Σ entry.amount / target_qty; marco=done; percent).
   VW_OPS_TASK_PROGRESS     = média ponderada (weight) das subetapas; senão feições; senão manual.
   VW_OPS_PROGRAM_PROGRESS  = média das etapas + previsão (ritmo × meta) + avanço por equipe. */

END
GO
