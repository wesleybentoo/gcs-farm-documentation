/* =========================================================================
   MODULE_MULTITENANT_V1 — Fase 2 (núcleo) da arquitetura multicliente
   -------------------------------------------------------------------------
   Ver documentacao/05_Arquitetura_Multicliente_e_Escopos.md
   Escopo desta passada (2a): tenant core + safra global (janela de datas) +
   espaçamento curado. A camada GEOGRÁFICA (GEO_UNIT/malha IBGE/bioma) é a
   Fase 2b (depende das malhas oficiais do IBGE) e NÃO está aqui.
   Idempotente. Alvo: GCS_FARM_TEST (homologação). NÃO rodar em produção ainda.
   ========================================================================= */

/* ---------- A) TENANT: CLIENTE_GRUPO + client_group_id em FARM_FARMS ---------- */
IF OBJECT_ID('dbo.CLIENTE_GRUPO','U') IS NULL
BEGIN
  CREATE TABLE dbo.CLIENTE_GRUPO (
    id          BIGINT IDENTITY(1,1) PRIMARY KEY,
    code        VARCHAR(30)  NOT NULL,
    name        NVARCHAR(120) NOT NULL,
    doc         VARCHAR(20)  NULL,            -- CNPJ/identificador do grupo (opcional)
    is_platform BIT NOT NULL DEFAULT 0,       -- grupo dono do baseline global / plataforma
    active      BIT NOT NULL DEFAULT 1,
    created_at  DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at  DATETIME2 NULL
  );
  CREATE UNIQUE INDEX UQ_CLIENTE_GRUPO_code ON dbo.CLIENTE_GRUPO(code) WHERE deleted_at IS NULL;
END
GO

IF COL_LENGTH('dbo.FARM_FARMS','client_group_id') IS NULL
  ALTER TABLE dbo.FARM_FARMS ADD client_group_id BIGINT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_FARM_FARMS_cliente_grupo')
  ALTER TABLE dbo.FARM_FARMS ADD CONSTRAINT FK_FARM_FARMS_cliente_grupo
    FOREIGN KEY (client_group_id) REFERENCES dbo.CLIENTE_GRUPO(id);
GO

/* seed dos 2 grupos (idempotente por code) */
IF NOT EXISTS (SELECT 1 FROM dbo.CLIENTE_GRUPO WHERE code='GCS')
  INSERT dbo.CLIENTE_GRUPO(code,name,active) VALUES ('GCS', N'GCS Agro', 1);
IF NOT EXISTS (SELECT 1 FROM dbo.CLIENTE_GRUPO WHERE code='TESTE')
  INSERT dbo.CLIENTE_GRUPO(code,name,active) VALUES ('TESTE', N'Grupo Teste (sintético)', 1);
GO

/* as 7 fazendas atuais entram no grupo GCS Agro (só onde ainda não tem grupo) */
UPDATE ff SET ff.client_group_id = g.id
  FROM dbo.FARM_FARMS ff CROSS JOIN (SELECT id FROM dbo.CLIENTE_GRUPO WHERE code='GCS') g
 WHERE ff.deleted_at IS NULL AND ff.client_group_id IS NULL;
GO

/* 1 fazenda fake no grupo-teste, só p/ homologar isolamento (idempotente por code) */
IF NOT EXISTS (SELECT 1 FROM dbo.FARM_FARMS WHERE code='FZ-TESTE-01')
  INSERT dbo.FARM_FARMS(code,name,city,state,total_area_hectares,active,client_group_id)
  SELECT 'FZ-TESTE-01', N'Fazenda Teste (isolamento)', N'—', 'GO', 0, 1, g.id
    FROM dbo.CLIENTE_GRUPO g WHERE g.code='TESTE';
GO

/* ---------- B) SAFRA GLOBAL: REF_SAFRA (janela de datas; SEM FK p/ a safra da fazenda) ---------- */
IF OBJECT_ID('dbo.REF_SAFRA','U') IS NULL
BEGIN
  CREATE TABLE dbo.REF_SAFRA (
    id          BIGINT IDENTITY(1,1) PRIMARY KEY,
    code        VARCHAR(10) NOT NULL,          -- '25/26'
    data_inicio DATE NOT NULL,
    data_fim    DATE NOT NULL,
    label       NVARCHAR(60) NULL,
    active      BIT NOT NULL DEFAULT 1,
    created_at  DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at  DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    deleted_at  DATETIME2 NULL,
    CONSTRAINT CK_REF_SAFRA_janela CHECK (data_fim > data_inicio)
  );
  CREATE UNIQUE INDEX UQ_REF_SAFRA_code ON dbo.REF_SAFRA(code) WHERE deleted_at IS NULL;
END
GO

/* seed de janelas contíguas e sem sobreposição (ano-safra 01/09 -> 31/08) */
MERGE dbo.REF_SAFRA AS t
USING (VALUES
  ('23/24','2023-09-01','2024-08-31'),
  ('24/25','2024-09-01','2025-08-31'),
  ('25/26','2025-09-01','2026-08-31'),
  ('26/27','2026-09-01','2027-08-31')
) AS s(code,di,df) ON t.code = s.code AND t.deleted_at IS NULL
WHEN NOT MATCHED THEN INSERT(code,data_inicio,data_fim) VALUES(s.code,s.di,s.df);
GO

/* ---------- C) ESPAÇAMENTO CURADO (default por cultura + override por plantio) ---------- */
IF COL_LENGTH('dbo.FARM_CULTURE','default_row_spacing_cm') IS NULL
  ALTER TABLE dbo.FARM_CULTURE ADD default_row_spacing_cm DECIMAL(6,2) NULL;
GO
IF COL_LENGTH('dbo.FARM_FIELD_PLANTING','row_spacing_cm') IS NULL
  ALTER TABLE dbo.FARM_FIELD_PLANTING ADD row_spacing_cm DECIMAL(6,2) NULL;
GO

/* seed do padrão da fazenda (só onde ainda não definido — não sobrescreve edição) */
UPDATE dbo.FARM_CULTURE SET default_row_spacing_cm = 81.0
 WHERE deleted_at IS NULL AND default_row_spacing_cm IS NULL AND LOWER(name) LIKE 'algod%';
UPDATE dbo.FARM_CULTURE SET default_row_spacing_cm = 40.5
 WHERE deleted_at IS NULL AND default_row_spacing_cm IS NULL AND LOWER(name) IN (N'soja', N'milho', N'sorgo');
GO

/* ---------- D) IDENTIDADE DO USUARIO: tenant (client_group_id) + nivel de acesso ----------
   Ancora de tenant DIRETA no usuario (nao derivada do mapeamento de fazendas, que pode
   estar incompleto). access_scope define o alcance:
     GLOBAL  = ve TODAS as fazendas (super admin da plataforma);
     GRUPO   = ve todas as fazendas do proprio grupo (default seguro = preserva o hoje);
     FAZENDA = ve apenas as fazendas mapeadas em MANAGEMENT_USER_FARM (dentro do grupo).
   O entitlement efetivo (allowedFarmIds) e resolvido no backend a partir de (scope, grupo). */
IF COL_LENGTH('dbo.MANAGEMENT_USERS','client_group_id') IS NULL
  ALTER TABLE dbo.MANAGEMENT_USERS ADD client_group_id BIGINT NULL;
GO
IF COL_LENGTH('dbo.MANAGEMENT_USERS','access_scope') IS NULL
  ALTER TABLE dbo.MANAGEMENT_USERS ADD access_scope VARCHAR(10) NOT NULL
    CONSTRAINT DF_MANAGEMENT_USERS_access_scope DEFAULT 'GRUPO';
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name='FK_MANAGEMENT_USERS_cliente_grupo')
  ALTER TABLE dbo.MANAGEMENT_USERS ADD CONSTRAINT FK_MANAGEMENT_USERS_cliente_grupo
    FOREIGN KEY (client_group_id) REFERENCES dbo.CLIENTE_GRUPO(id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name='CK_MANAGEMENT_USERS_access_scope')
  ALTER TABLE dbo.MANAGEMENT_USERS ADD CONSTRAINT CK_MANAGEMENT_USERS_access_scope
    CHECK (access_scope IN ('GLOBAL','GRUPO','FAZENDA'));
GO

/* tenant do usuario = grupo das fazendas que ele mapeia (o mais frequente); so onde ainda NULL */
UPDATE u SET u.client_group_id = x.cg
  FROM dbo.MANAGEMENT_USERS u
 CROSS APPLY (
   SELECT TOP 1 fa.client_group_id AS cg
     FROM dbo.MANAGEMENT_USER_FARM uf
     JOIN dbo.FARM_FARMS fa ON fa.id = uf.farm_id AND fa.deleted_at IS NULL
    WHERE uf.user_id = u.id AND uf.active = 1 AND uf.deleted_at IS NULL AND fa.client_group_id IS NOT NULL
    GROUP BY fa.client_group_id ORDER BY COUNT(*) DESC
 ) x
 WHERE u.deleted_at IS NULL AND u.client_group_id IS NULL;
GO
/* quem ficou sem grupo (sem mapeamento) -> grupo GCS (tenant do baseline atual) */
UPDATE u SET u.client_group_id = (SELECT id FROM dbo.CLIENTE_GRUPO WHERE code='GCS')
  FROM dbo.MANAGEMENT_USERS u
 WHERE u.deleted_at IS NULL AND u.client_group_id IS NULL;
GO
