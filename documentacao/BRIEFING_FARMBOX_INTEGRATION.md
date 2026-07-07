# BRIEFING — Integração Farmbox no GCS Connection Farm

> **Para:** Claude Code (gcs-backend / gcs-farm-front)
> **De:** Claude Cowork (arquitetura / banco de dados)
> **Data:** Junho/2026
> **Assunto:** Nova integração Farmbox — contexto, documentação e atualização do TESTE-DE-FOGO

---

## 0. O que acabou de acontecer

Uma sessão inteira de trabalho foi concluída no lado do banco de dados e da documentação.
O resultado está em `C:\Developer\Arquivos Suporte\`. Antes de escrever uma linha de código,
você **deve** ler os documentos listados abaixo — eles são a fonte de verdade.

---

## 1. Leia estes arquivos AGORA (nesta ordem)

### 1.1 Escopo e arquitetura geral
```
C:\Developer\Arquivos Suporte\GCS_Connection_Farm_Escopo_v1.docx
```
Leia tudo. Entenda a arquitetura de duas camadas (raw → master), os 3 conectores
implementados (Solinftec, IrriControl, Farmbox), o fluxo ETL, as convenções globais
e o glossário. Este é o documento de entrada.

### 1.2 DDL da camada raw — CONNECTOR_GCS_FARM
```
C:\Developer\Arquivos Suporte\FARMBOX_connector_raw_mssql_v3.sql
```
30 tabelas raw do conector Farmbox. Leia especialmente:
- O cabeçalho (seções 1-3): formatos de data, regras ETL obrigatórias, enums
- SEÇÃO 4: FARMBOX_INGESTION_LOG e FARMBOX_INTEGRATION_ERROR (controle de ingestão)
- SEÇÃO 5: FARMBOX_PLANTATION (campo harvest_name, campo processed)
- SEÇÃO 8: FARMBOX_MONITORING + FARMBOX_MONITORING_NOTE (image_addresses JSON)
- SEÇÃO 10: CONFIG_CONNECTORS pattern (como fazer plot_id → field_id)
- SEÇÃO 11: as duas views de monitoramento (STALE + PENDING)

### 1.3 DDL da camada master — GCS_FARM
```
C:\Developer\Arquivos Suporte\FARMBOX_master_gcsfarm_mssql_v2.sql
```
18 tabelas master normalizadas. Leia especialmente:
- SEÇÃO 3: FARMBOX_PLANTATION com `field_id BIGINT NULL` → FK para FARM_FIELDS
- SEÇÃO 5: FARMBOX_APPLICATION (code, app_date, end_date, responsible_name, retroactive)
- SEÇÃO 6: FARMBOX_MONITORING (field_id, phenological_stage_name, recommendation, delivered)
- SEÇÃO 7: FARMBOX_MONITORING_NOTE (image_addresses JSON, field_id)
- SEÇÃO 8: as 3 views — VW_FARMBOX_PLANTATION_SUMMARY, VW_FARMBOX_MONITORING_INFEST,
           VW_FARMBOX_FIELD_NOTES_WITH_IMAGES

### 1.4 Referência DBA completa
```
C:\Developer\Arquivos Suporte\CONNECTOR_GCS_FARM_Documentacao_DBA_v3.docx
```
Seção 4 completa sobre o Farmbox: autenticação, fluxo de requisição, regras ETL,
3 variantes de data, tabelas-chave com todas as colunas documentadas.

### 1.5 Relatório de auditoria da simulação de ingestion
```
C:\Developer\Arquivos Suporte\FARMBOX_Auditoria_Ingestion_v1.md
```
Resultado da simulação com dados reais. Documenta todos os edge cases encontrados
(datas, lat/lng como string, harvest_id ausente, modified_at null nos traps,
id composto em monitoring_day_results). Leia antes de implementar qualquer parser.

### 1.6 Setup SQL unificado
```
C:\Developer\Arquivos Suporte\GCS_databases_full_setup_mssql.sql
```
3.660 linhas. Cria CONNECTOR_GCS_FARM + GCS_FARM do zero, incluindo todos os
módulos: Solinftec, IrriControl, Farmbox raw e Farmbox master. Este arquivo
**substitui** o setup anterior. O TESTE-DE-FOGO precisa apontar para ele.

---

## 2. Contexto técnico que você PRECISA saber

### 2.1 Autenticação Farmbox
```
Authorization: <TOKEN>
```
SEM "Bearer". SEM aspas. Token estático armazenado cifrado em
`GCS_FARM.dbo.CONFIG_API` (campo `token`, AES-256, chave SK_CONFIG_API).

Base URL: `https://farmbox.cc/api/v1`

### 2.2 Os 3 formatos de data — CRÍTICO
```
Variante A: "2019-09-19T10:54:53.000-03:00"  → datetime.fromisoformat() → UTC → DATETIME2
Variante B: "2026-06-26 12:04:00"             → replace(' ', 'T') → DATETIME2
Variante C: "2019-09-11"                      → passthrough → DATE
```
A função `parse_farmbox_dt()` deve cobrir os 3 casos. Sem ela, 100% das
inserções de data falharão.

### 2.3 Paginação da API
```
GET /api/v1/<endpoint>?per_page=30&page=1&updated_since=<ISO8601>
```
Resposta: `{"<recurso>": [...], "pagination": {"total_pages": N, ...}}`
Iterar até `current_page == total_pages`.

### 2.4 Regras ETL obrigatórias (não pule nenhuma)
1. `lat/lng` chegam como STRING em alguns endpoints → `float(val)` antes de INSERT
2. `harvest_id` NÃO existe na API → resolver via `JOIN FARMBOX_HARVEST WHERE name = harvest_name`
3. `trap_monitoring.modified_at` = NULL em todos → fallback: `modified_at ?? date`
4. `monitoring_day_results.id` é string composta ex: `"1568204700-12345"` → VARCHAR(60)
5. `image_addresses[]` = URLs S3 diretas → gravar como JSON string (ISJSON CHECK). Ignorar `attachments[]`
6. Credenciais NUNCA no `request_payload` dos logs de erro
7. Ordem de carga: `farms → harvests → plots → plantations → monitorings → dependentes`

### 2.5 Linkagem Farmbox → GCS_FARM (plot → field)
```sql
-- NÃO usar farm_id (inconsistente entre endpoints da API)
-- USAR CONFIG_CONNECTORS:
SELECT field_id
FROM GCS_FARM.dbo.CONFIG_CONNECTORS
WHERE type = 'farmbox'
  AND code = CAST(@plot_id AS VARCHAR(20))
  AND deleted_at IS NULL;
```
O ETL popula `FARMBOX_PLANTATION.field_id` e `FARMBOX_MONITORING.field_id` com esse valor.

### 2.6 Imagens no monitoramento
`image_addresses[]` em `notes` e em `monitoring_day_results[].notes[]` contêm URLs
Amazon S3 diretas. O front-end pode renderizá-las diretamente sem proxy.
Guardar como JSON array em `NVARCHAR(MAX)` com `CHECK (ISJSON()=1)`.

---

## 3. O que MUDA no projeto de código

Você precisa implementar (ou confirmar o que já existe) para o módulo Farmbox:

### 3.1 Back-end (gcs-backend)
- [ ] Serviço de autenticação Farmbox (CONFIG_API.token, sem Bearer)
- [ ] Paginação genérica reutilizável (updated_since incremental)
- [ ] `parse_farmbox_dt()` cobrindo 3 variantes
- [ ] Ingestion de todos os 30 endpoints (na ordem correta — seção 2.4 item 7)
- [ ] ETL raw → master (MERGE por farmbox_id, field_id via CONFIG_CONNECTORS)
- [ ] Endpoints de API para disparar ingestão e ETL (ex: POST /farmbox/integrate)
- [ ] Log de ingestão em FARMBOX_INGESTION_LOG + erros em FARMBOX_INTEGRATION_ERROR

### 3.2 Front-end (gcs-farm-front)
- [ ] Renderização de `image_addresses[]` nos módulos de monitoramento e notas
- [ ] Exibição de `infestation_level` (infested | damaged | clear)
- [ ] Scripts de cadastro se existirem (ex: CONFIG_CONNECTORS via script/import)

---

## 4. O que MUDA no TESTE-DE-FOGO.sh

O arquivo atual é `C:\Developer\TESTE-DE-FOGO.sh`. Você precisa atualizá-lo:

### 4.1 Corrigir o caminho do SETUP_SQL
```bash
# ANTES (caminho antigo — arquivo anterior):
SETUP_SQL='C:\Developer\GCS_databases_full_setup_mssql.sql'

# DEPOIS (novo arquivo unificado com Farmbox):
SETUP_SQL='C:\Developer\Arquivos Suporte\GCS_databases_full_setup_mssql.sql'
```

### 4.2 Ampliar o sanity check do schema (passo 3)
```bash
# Adicionar ao IF do sanity check:
OBJECT_ID('GCS_FARM.dbo.FARMBOX_PLANTATION') IS NOT NULL
AND OBJECT_ID('CONNECTOR_GCS_FARM.dbo.FARMBOX_INGESTION_LOG') IS NOT NULL
```

### 4.3 Adicionar passo 5b — Cadastrar API Farmbox na CONFIG_API
Após o cadastro do Solinftec (passo 5), inserir a configuração da Farmbox:
```bash
hr; echo "[5b/9] $(ts) Cadastrando API Farmbox (CONFIG_API + token)..."
sql -I -b -Q "SET NOCOUNT ON; USE GCS_FARM;
IF NOT EXISTS (SELECT 1 FROM dbo.CONFIG_API WHERE name='FARMBOX')
  INSERT INTO dbo.CONFIG_API (name,url,auth_type,active,created_at)
  VALUES ('FARMBOX','https://farmbox.cc/api/v1','TOKEN',1,SYSUTCDATETIME());
-- ATENÇÃO: substitua FARMBOX_TOKEN_AQUI pelo token real antes de rodar
OPEN SYMMETRIC KEY SK_CONFIG_API DECRYPTION BY CERTIFICATE CERT_CONFIG_API;
UPDATE dbo.CONFIG_API
  SET token = ENCRYPTBYKEY(KEY_GUID('SK_CONFIG_API'), N'FARMBOX_TOKEN_AQUI'),
      updated_at = SYSUTCDATETIME()
  WHERE name = 'FARMBOX';
CLOSE SYMMETRIC KEY SK_CONFIG_API; PRINT 'farmbox config_api ok';"
```
> **ATENÇÃO:** O token real não deve ser hardcoded no script versionado.
> Usar variável de ambiente: `FARMBOX_TOKEN="${FARMBOX_TOKEN:-}"` e validar antes de rodar.

### 4.4 Adicionar passo 8b — Ingestion Farmbox + ETL
Após a integração Solinftec (passo 8), adicionar:
```bash
hr; echo "[8b/9] $(ts) Farmbox — ingestion completo (todos os endpoints)..."
curl -s -m 600 -X POST "$API/farmbox/integrate" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mode":"full"}' | sed 's/^/    FARMBOX-INGEST: /'

echo "    rodando ETL Farmbox (raw -> GCS_FARM)..."
curl -s -m 300 -X POST "$API/farmbox/etl" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"source":"all"}' | sed 's/^/    FARMBOX-ETL: /'
echo

# verificação: plantations e monitorings no master
sql -h-1 -W -Q "SET NOCOUNT ON;
SELECT CONCAT(
  (SELECT COUNT(*) FROM GCS_FARM.dbo.FARMBOX_PLANTATION WHERE deleted_at IS NULL),' plantations, ',
  (SELECT COUNT(*) FROM GCS_FARM.dbo.FARMBOX_MONITORING WHERE deleted_at IS NULL),' monitorings, ',
  (SELECT COUNT(*) FROM GCS_FARM.dbo.FARMBOX_MONITORING_NOTE WHERE deleted_at IS NULL),' notas'
);" 2>/dev/null | grep -vE '^\s*$' | sed 's/^/    farmbox master: /'
```

### 4.5 Atualizar o total de passos de [9] para [10]
O script atual tem 9 passos. Com Farmbox ficam 10 (ou reagrupar os sub-passos).

---

## 5. Perguntas para mim (Cowork) ANTES de implementar

Se surgir qualquer dúvida sobre banco de dados, DDL, regras ETL ou arquitetura,
**pergunte antes de implementar**. Em especial:

1. Os endpoints da API (`POST /farmbox/integrate`, `POST /farmbox/etl`) já existem
   no back-end ou precisam ser criados do zero?
2. Como o back-end implementa a ingestão dos outros conectores (Solinftec)?
   O padrão de paginação e log já está genérico ou é específico?
3. O token Farmbox (para o TESTE-DE-FOGO) será passado por variável de ambiente,
   arquivo `.env` ou como? Confirme antes de hardcodar.
4. A tabela `CONFIG_CONNECTORS` já tem registros de mapeamento `plot_id → field_id`
   para os talhões da Celeiro BA, ou isso ainda precisa ser feito via seed/script?
5. Existe algum script de seed no back-end que precisa ser atualizado para incluir
   o módulo Farmbox (ex: seeder de MANAGEMENT_MODULES)?

---

## 6. Arquivos de suporte disponíveis

| Arquivo | Descrição |
|---|---|
| `Arquivos Suporte/farmbox_responses/*.json` | 36 JSONs de resposta real da API Farmbox (use para testes) |
| `Arquivos Suporte/farmbox_test_endpoints.py` | Script Python de teste dos endpoints |
| `Arquivos Suporte/farmbox_test_endpoints.ps1` | Versão PowerShell |
| `Arquivos Suporte/FARMBOX_Auditoria_Ingestion_v1.md` | Relatório completo da simulação |

---

## 7. Resumo do que foi entregue pelo Cowork

| Artefato | Status |
|---|---|
| `FARMBOX_connector_raw_mssql_v3.sql` | ✅ 30 tabelas raw, 2 views, índices |
| `FARMBOX_master_gcsfarm_mssql_v2.sql` | ✅ 18 tabelas master, 3 views, field_id |
| `GCS_databases_full_setup_mssql.sql` | ✅ Setup unificado (85 tabelas totais) |
| `GCS_reset_databases_mssql.sql` | ✅ Sem alterações necessárias |
| `GCS_Connection_Farm_Documentacao_Bancos_v4.docx` | ✅ Documentação completa v4 |
| `CONNECTOR_GCS_FARM_Documentacao_DBA_v3.docx` | ✅ Referência DBA v3 |
| `GCS_Connection_Farm_Escopo_v1.docx` | ✅ Módulos, arquitetura, roadmap |
| Simulação de ingestion | ✅ ZERO issues bloqueantes (187 notas, 190 imagens validadas) |

**O lado do banco está pronto. O lado do código é com você.**

---

*Este briefing foi gerado pelo Claude Cowork em Junho/2026.*
*Dúvidas sobre banco/DDL/arquitetura → pergunte aqui antes de implementar.*
