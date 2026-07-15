/* =========================================================================
   MODULE_INTEGRATION_MULTITENANT_V1 — Fase 0: fundação de credenciais de
   integração por GRUPO+FAZENDA (substitui o CONFIG_API single-tenant).
   -------------------------------------------------------------------------
   Modelo aprovado (ver 08_Escopo_Integracoes_Multitenant + memória):
     INTEGRATION_CREDENTIAL         — credencial do GRUPO (1 token, N fazendas)
     INTEGRATION_CREDENTIAL_FARM    — N:N credencial<->fazenda (UNIQUE provider,farm)
     INTEGRATION_CREDENTIAL_CONFIG  — 1 linha por job (cadência própria; UNIQUE cred,job)
     INTEGRATION_INGESTION_LOG      — estado + cursor (updated_since) por credencial/job
   Segredos: mesma cifra do CONFIG_API (SK/CERT_CONFIG_API) — copiados AS-IS no backfill.
   Aditivo/idempotente. Tabelas NOVAS (zero impacto no código atual até o deploy).
   Alvo: GCS_FARM_TEST (homologar) -> depois GCS_FARM. Requer sqlcmd -I (índices filtrados).
   ========================================================================= */

/* ---------- 1) INTEGRATION_CREDENTIAL ---------- */
IF OBJECT_ID('dbo.INTEGRATION_CREDENTIAL','U') IS NULL
BEGIN
  CREATE TABLE dbo.INTEGRATION_CREDENTIAL (
    id                BIGINT IDENTITY(1,1) PRIMARY KEY,
    client_group_id   BIGINT NOT NULL,
    provider          VARCHAR(30) NOT NULL,   -- FARMBOX | SOLINFTEC | IRRICONTROL | FARMBOX_WEBHOOK
    label             NVARCHAR(120) NULL,
    url               NVARCHAR(400) NULL,
    auth_type         VARCHAR(30) NULL,
    username          NVARCHAR(200) NULL,
    password          VARBINARY(MAX) NULL,    -- cifrado (ENCRYPTBYKEY, igual CONFIG_API)
    token             VARBINARY(MAX) NULL,    -- cifrado
    token_expires_at  DATETIME2 NULL,
    api_key           VARBINARY(MAX) NULL,    -- cifrado
    client_id         NVARCHAR(200) NULL,
    client_secret     VARBINARY(MAX) NULL,    -- cifrado
    legacy_config_api_id BIGINT NULL,         -- rastro da migracao CONFIG_API
    active            BIT NOT NULL DEFAULT 1,
    created_at        DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at        DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at        DATETIME2 NULL,
    CONSTRAINT FK_INTCRED_grupo FOREIGN KEY (client_group_id) REFERENCES dbo.CLIENTE_GRUPO(id),
    CONSTRAINT CK_INTCRED_provider CHECK (provider IN ('FARMBOX','SOLINFTEC','IRRICONTROL','FARMBOX_WEBHOOK'))
  );
  CREATE INDEX IX_INTCRED_lookup ON dbo.INTEGRATION_CREDENTIAL(provider, client_group_id) WHERE deleted_at IS NULL;
END
GO

/* ---------- 2) INTEGRATION_CREDENTIAL_FARM (N:N) ---------- */
IF OBJECT_ID('dbo.INTEGRATION_CREDENTIAL_FARM','U') IS NULL
BEGIN
  CREATE TABLE dbo.INTEGRATION_CREDENTIAL_FARM (
    id             BIGINT IDENTITY(1,1) PRIMARY KEY,
    credential_id  BIGINT NOT NULL,
    provider       VARCHAR(30) NOT NULL,   -- denormalizado da credencial p/ a trava por provider
    farm_id        BIGINT NOT NULL,
    created_at     DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at     DATETIME2 NULL,
    CONSTRAINT FK_INTCREDFARM_cred FOREIGN KEY (credential_id) REFERENCES dbo.INTEGRATION_CREDENTIAL(id),
    CONSTRAINT FK_INTCREDFARM_farm FOREIGN KEY (farm_id) REFERENCES dbo.FARM_FARMS(id)
  );
  -- uma fazenda so pode estar em 1 credencial POR PROVIDER (senao o ETL nao sabe qual token usar)
  CREATE UNIQUE INDEX UQ_INTCREDFARM_prov_farm ON dbo.INTEGRATION_CREDENTIAL_FARM(provider, farm_id) WHERE deleted_at IS NULL;
  CREATE UNIQUE INDEX UQ_INTCREDFARM_cred_farm ON dbo.INTEGRATION_CREDENTIAL_FARM(credential_id, farm_id) WHERE deleted_at IS NULL;
END
GO

/* ---------- 3) INTEGRATION_CREDENTIAL_CONFIG (1 linha por job) ---------- */
IF OBJECT_ID('dbo.INTEGRATION_CREDENTIAL_CONFIG','U') IS NULL
BEGIN
  CREATE TABLE dbo.INTEGRATION_CREDENTIAL_CONFIG (
    id             BIGINT IDENTITY(1,1) PRIMARY KEY,
    credential_id  BIGINT NOT NULL,
    job_key        VARCHAR(60) NOT NULL,   -- applications | monitoring | plantations | ...
    cadence_type   VARCHAR(20) NOT NULL DEFAULT 'interval',
    cadence_value  NVARCHAR(60) NOT NULL,  -- '1h', '6h', ...
    enabled        BIT NOT NULL DEFAULT 1,
    created_at     DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at     DATETIME2 NULL,
    CONSTRAINT FK_INTCFG_cred FOREIGN KEY (credential_id) REFERENCES dbo.INTEGRATION_CREDENTIAL(id)
  );
  CREATE UNIQUE INDEX UQ_INTCFG_cred_job ON dbo.INTEGRATION_CREDENTIAL_CONFIG(credential_id, job_key) WHERE deleted_at IS NULL;
END
GO

/* ---------- 4) INTEGRATION_INGESTION_LOG (estado + cursor) ---------- */
IF OBJECT_ID('dbo.INTEGRATION_INGESTION_LOG','U') IS NULL
BEGIN
  CREATE TABLE dbo.INTEGRATION_INGESTION_LOG (
    id                   BIGINT IDENTITY(1,1) PRIMARY KEY,
    credential_id        BIGINT NOT NULL,
    job_key              VARCHAR(60) NULL,
    started_at           DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    finished_at          DATETIME2 NULL,
    status               VARCHAR(20) NOT NULL DEFAULT 'running',  -- running | ok | error
    row_count            INT NULL,
    cursor_updated_since  DATETIME2 NULL,   -- high-watermark incremental (por credencial+job)
    message              NVARCHAR(600) NULL,
    created_at           DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_INTLOG_cred FOREIGN KEY (credential_id) REFERENCES dbo.INTEGRATION_CREDENTIAL(id)
  );
  CREATE INDEX IX_INTLOG_cred_job ON dbo.INTEGRATION_INGESTION_LOG(credential_id, job_key, started_at DESC);
END
GO

/* ========================= BACKFILL (idempotente) =========================
   Migra CONFIG_API (FARMBOX, SOLINFTEC) -> INTEGRATION_CREDENTIAL no grupo GCS,
   copiando os segredos JA CIFRADOS as-is (mesma chave). Vincula a todas as
   fazendas do grupo GCS. Semeia os jobs de cadencia. So insere se ainda nao existe. */
DECLARE @gcs BIGINT = (SELECT id FROM dbo.CLIENTE_GRUPO WHERE code='GCS' AND deleted_at IS NULL);

/* 4.1 credenciais a partir do CONFIG_API legado */
INSERT INTO dbo.INTEGRATION_CREDENTIAL
  (client_group_id, provider, label, url, auth_type, username, password, token, token_expires_at, api_key, client_id, client_secret, legacy_config_api_id, active)
SELECT @gcs, a.name, a.name, a.url, a.auth_type, a.username, a.password, a.token, a.token_expires_at, a.api_key, a.client_id, a.client_secret, a.id, a.active
  FROM dbo.CONFIG_API a
 WHERE a.deleted_at IS NULL AND a.name IN ('FARMBOX','SOLINFTEC')
   AND NOT EXISTS (SELECT 1 FROM dbo.INTEGRATION_CREDENTIAL c WHERE c.legacy_config_api_id = a.id);
GO

/* 4.2 vincula cada credencial migrada a TODAS as fazendas do grupo GCS */
DECLARE @gcs2 BIGINT = (SELECT id FROM dbo.CLIENTE_GRUPO WHERE code='GCS' AND deleted_at IS NULL);
INSERT INTO dbo.INTEGRATION_CREDENTIAL_FARM (credential_id, provider, farm_id)
SELECT c.id, c.provider, f.id
  FROM dbo.INTEGRATION_CREDENTIAL c
  JOIN dbo.FARM_FARMS f ON f.deleted_at IS NULL AND f.client_group_id = @gcs2
 WHERE c.client_group_id = @gcs2 AND c.deleted_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM dbo.INTEGRATION_CREDENTIAL_FARM x WHERE x.credential_id=c.id AND x.farm_id=f.id AND x.deleted_at IS NULL);
GO

/* 4.3 jobs de cadencia — FARMBOX: applications=1h, monitoring=6h; SOLINFTEC: operations=1h */
MERGE dbo.INTEGRATION_CREDENTIAL_CONFIG AS t
USING (
  SELECT c.id AS credential_id, j.job_key, j.cadence_value
    FROM dbo.INTEGRATION_CREDENTIAL c
    CROSS APPLY (VALUES
      ('FARMBOX','applications','1h'), ('FARMBOX','monitoring','6h'),
      ('SOLINFTEC','operations','1h')
    ) j(provider, job_key, cadence_value)
   WHERE c.provider = j.provider AND c.deleted_at IS NULL
) s ON t.credential_id = s.credential_id AND t.job_key = s.job_key AND t.deleted_at IS NULL
WHEN NOT MATCHED THEN
  INSERT (credential_id, job_key, cadence_type, cadence_value, enabled)
  VALUES (s.credential_id, s.job_key, 'interval', s.cadence_value, 1);
GO
