/* =========================================================================
   MODULE_GEO_V1 — Fase 2b: camada geográfica (referência global IBGE)
   -------------------------------------------------------------------------
   Ver documentacao/05_Arquitetura_Multicliente_e_Escopos.md
   Árvore ÚNICA auto-referenciada (meso/micro do IBGE não cruzam UF, então a
   contenção admin + regional colapsa numa árvore só):
     planeta → continente → país → estado → mesorregião(MACRO) → microrregião(MICRO) → município
   Grande Região (5) = atributo da UF. Bioma = overlay N:N (predominante no
   município + preciso no talhão via point-in-polygon).
   Idempotente. Alvo: GCS_FARM_TEST. Estrutura aqui; conteúdo (hierarquia +
   polígonos) carregado do IBGE por scripts de seed.
   ========================================================================= */

/* ---------- Bioma (overlay) ---------- */
IF OBJECT_ID('dbo.REF_BIOMA','U') IS NULL
BEGIN
  CREATE TABLE dbo.REF_BIOMA (
    id         BIGINT IDENTITY(1,1) PRIMARY KEY,
    code       VARCHAR(30) NOT NULL,
    nome       NVARCHAR(60) NOT NULL,
    geom       GEOGRAPHY NULL,
    created_at DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at DATETIME2 NULL
  );
  CREATE UNIQUE INDEX UQ_REF_BIOMA_code ON dbo.REF_BIOMA(code) WHERE deleted_at IS NULL;
END
GO
IF OBJECT_ID('dbo.REF_BIOMA_CARACTERISTICA','U') IS NULL
  CREATE TABLE dbo.REF_BIOMA_CARACTERISTICA (
    id         BIGINT IDENTITY(1,1) PRIMARY KEY,
    bioma_id   BIGINT NOT NULL REFERENCES dbo.REF_BIOMA(id),
    chave      NVARCHAR(80) NOT NULL,
    valor      NVARCHAR(400) NULL,
    created_at DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at DATETIME2 NULL
  );
GO
MERGE dbo.REF_BIOMA AS t
USING (VALUES ('CERRADO',N'Cerrado'),('AMAZONIA',N'Amazônia'),('MATA_ATLANTICA',N'Mata Atlântica'),
              ('CAATINGA',N'Caatinga'),('PAMPA',N'Pampa'),('PANTANAL',N'Pantanal')) AS s(code,nome)
  ON t.code=s.code AND t.deleted_at IS NULL
WHEN NOT MATCHED THEN INSERT(code,nome) VALUES(s.code,s.nome);
GO

/* ---------- Árvore geográfica (auto-referenciada) ---------- */
IF OBJECT_ID('dbo.GEO_UNIT','U') IS NULL
BEGIN
  CREATE TABLE dbo.GEO_UNIT (
    id            BIGINT IDENTITY(1,1) PRIMARY KEY,
    parent_id     BIGINT NULL REFERENCES dbo.GEO_UNIT(id),
    level         VARCHAR(16) NOT NULL,      -- planeta|continente|pais|estado|mesorregiao|microrregiao|municipio
    ibge_id       INT NULL,                  -- código IBGE do nível (NULL p/ planeta/continente)
    nome          NVARCHAR(150) NOT NULL,
    uf            CHAR(2) NULL,              -- estado/meso/micro/municipio
    regiao_sigla  CHAR(2) NULL,             -- Grande Região (atributo da UF): N/NE/CO/SE/S
    bioma_predominante_id BIGINT NULL REFERENCES dbo.REF_BIOMA(id),
    geom          GEOGRAPHY NULL,
    active        BIT NOT NULL DEFAULT 1,
    created_at    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at    DATETIME2 NULL,
    CONSTRAINT CK_GEO_UNIT_level CHECK (level IN ('planeta','continente','pais','estado','mesorregiao','microrregiao','municipio'))
  );
  CREATE INDEX IX_GEO_UNIT_parent ON dbo.GEO_UNIT(parent_id);
  CREATE UNIQUE INDEX UQ_GEO_UNIT_level_ibge ON dbo.GEO_UNIT(level, ibge_id) WHERE ibge_id IS NOT NULL AND deleted_at IS NULL;
END
GO

/* raízes fixas (planeta → continente → país) */
IF NOT EXISTS (SELECT 1 FROM dbo.GEO_UNIT WHERE level='planeta' AND nome=N'Terra')
  INSERT dbo.GEO_UNIT(parent_id,level,nome) VALUES (NULL,'planeta',N'Terra');
IF NOT EXISTS (SELECT 1 FROM dbo.GEO_UNIT WHERE level='continente' AND nome=N'América do Sul')
  INSERT dbo.GEO_UNIT(parent_id,level,nome) SELECT id,'continente',N'América do Sul' FROM dbo.GEO_UNIT WHERE level='planeta' AND nome=N'Terra';
IF NOT EXISTS (SELECT 1 FROM dbo.GEO_UNIT WHERE level='pais' AND nome=N'Brasil')
  INSERT dbo.GEO_UNIT(parent_id,level,nome,ibge_id) SELECT id,'pais',N'Brasil',76 FROM dbo.GEO_UNIT WHERE level='continente' AND nome=N'América do Sul';
GO

/* ---------- Carimbo geográfico derivado no talhão ---------- */
IF COL_LENGTH('dbo.FARM_FIELDS','municipio_geo_id') IS NULL
  ALTER TABLE dbo.FARM_FIELDS ADD municipio_geo_id BIGINT NULL;
GO
IF COL_LENGTH('dbo.FARM_FIELDS','bioma_id') IS NULL
  ALTER TABLE dbo.FARM_FIELDS ADD bioma_id BIGINT NULL;
GO
IF COL_LENGTH('dbo.FARM_FIELDS','geo_crosses_boundary') IS NULL
  ALTER TABLE dbo.FARM_FIELDS ADD geo_crosses_boundary BIT NULL;
GO
IF COL_LENGTH('dbo.FARM_FIELDS','geo_stamped_at') IS NULL
  ALTER TABLE dbo.FARM_FIELDS ADD geo_stamped_at DATETIME2 NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_FARM_FIELDS_municipio_geo')
  ALTER TABLE dbo.FARM_FIELDS ADD CONSTRAINT FK_FARM_FIELDS_municipio_geo FOREIGN KEY (municipio_geo_id) REFERENCES dbo.GEO_UNIT(id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_FARM_FIELDS_bioma')
  ALTER TABLE dbo.FARM_FIELDS ADD CONSTRAINT FK_FARM_FIELDS_bioma FOREIGN KEY (bioma_id) REFERENCES dbo.REF_BIOMA(id);
GO
