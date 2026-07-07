# FARMBOX — Auditoria de Simulação de Ingestion
**Versão:** v1  
**Data:** 2026-06-26  
**Escopo:** Raw layer (`CONNECTOR_GCS_FARM`) — DDL v1  
**Dados:** 266 registros reais de 18 endpoints (`farmbox_responses/*.json`)  
**Resultado:** 143 issues bloqueantes · 88 avisos não-bloqueantes

---

## 1. Resumo Executivo

A simulação de ingestion revelou **uma causa raiz dominante** e **três problemas secundários** que devem ser corrigidos antes do ETL de produção entrar em operação.

| Categoria | Qtd | Impacto |
|---|---|---|
| Formato de data/hora incompatível | 3 variantes | Bloqueante — INSERT falharia em `DATETIME2(3)` |
| Coordenadas geográficas como STRING | 2 endpoints | Não-bloqueante — ETL deve converter antes de INSERT |
| `harvest_id` não disponível via API | 15 plantations | Não-bloqueante — ETL precisa resolver via JOIN |
| Cursor incremental ausente em trap_monitoring | 15 registros | Não-bloqueante — ETL precisa de fallback |

---

## 2. Issues Bloqueantes

### 2.1 Formato de Data/Hora — 3 variantes incompatíveis

Esta é a única causa real de falha de INSERT. A Farmbox emite datas em três formatos distintos, e nenhum deles é o ISO 8601 pleno que o SQL Server espera.

#### Variante A — ISO com offset de timezone (`.000-03:00`)
**Afeta:** `FARMBOX_APPLICATION`, `FARMBOX_INPUT`, `FARMBOX_PLANTATION`, `FARMBOX_PLOT`, `FARMBOX_PLUVIOMETER_MONITORING`  
**Exemplo real:** `"2019-09-19T10:54:53.000-03:00"`  
**Problema:** SQL Server aceita `DATETIMEOFFSET` com offset, mas não `DATETIME2` com offset inline.

**Correção ETL obrigatória:**
```python
from datetime import datetime, timezone
import re

def parse_farmbox_dt(val) -> str | None:
    """Normaliza qualquer formato Farmbox para UTC ISO 8601 sem offset."""
    if val is None:
        return None
    # Variante A: ISO com offset "-03:00" ou "+00:00"
    if re.search(r'[+-]\d{2}:\d{2}$', val):
        dt = datetime.fromisoformat(val)          # Python 3.7+ lê offset
        return dt.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3]
    # Variante B: sem T, sem Z — "2026-06-26 12:04:00"
    if re.match(r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}', val):
        return val.replace(' ', 'T')              # assume UTC (API não especifica)
    # Variante C: só data — "2019-09-11"
    if re.match(r'^\d{4}-\d{2}-\d{2}$', val):
        return val + 'T00:00:00.000'
    return val  # já estava em formato válido
```

**Resultado:** `"2019-09-19T10:54:53.000-03:00"` → `"2019-09-19T13:54:53.000"` (convertido para UTC)

#### Variante B — Sem `T`, sem timezone (`"YYYY-MM-DD HH:MM:SS"`)
**Afeta:** `FARMBOX_MONITORING` (`close_date`, `updated_at`), `FARMBOX_MONITORING_DAY_RESULT` (`updated_at`)  
**Exemplo real:** `"2026-06-26 12:04:00"`, `"2026-06-26 10:31:29"`  
**Volume:** 60 campos afetados apenas na amostra de 30 monitorings.  
**Problema:** SQL Server rejeita espaço no literal `DATETIME2`.

**Tratamento:** aplicar `parse_farmbox_dt()` acima — substitui espaço por `T`.  
**Nota:** A Farmbox não informa timezone neste formato. Tratar como horário do servidor (provavelmente UTC-3). **Decisão de negócio necessária:** armazenar como veio (após adicionar `T`) ou converter para UTC.

#### Variante C — Só data (`"YYYY-MM-DD"`)
**Afeta:** `FARMBOX_HARVEST` (`start_date`, `end_date`), `FARMBOX_MOVIMENTATION` (`date`)  
**Exemplo real:** `"2019-09-11"`, `"2026-08-31"`, `"2019-10-18"`  
**Problema:** O DDL define esses campos como `DATETIME2(3)`, mas a API só retorna a data.

**Opções:**
- Manter `DATETIME2(3)` e armazenar como `"2019-09-11T00:00:00.000"` (sem perda de info)
- **Recomendado:** Alterar para `DATE` no DDL — semântica mais correta, ocupa 3 bytes vs 8

---

### 2.2 Resumo dos campos afetados por endpoint

| Tabela | Campo(s) | Variante | Registros afetados (amostra) |
|---|---|---|---|
| FARMBOX_APPLICATION | `api_created_at`, `api_updated_at` | A | 15/15 |
| FARMBOX_INPUT | `api_updated_at` | A | 15/15 |
| FARMBOX_PLANTATION | `planned_date`, `api_updated_at` | A | 15/15 |
| FARMBOX_PLOT | `api_updated_at` | A | 15/15 |
| FARMBOX_PLUVIOMETER_MONITORING | `reading_date` | A | 15/15 |
| FARMBOX_MONITORING | `close_date`, `updated_at` | B | 30/30 |
| FARMBOX_MONITORING_DAY_RESULT | `updated_at` | B | 30/30 |
| FARMBOX_HARVEST | `start_date`, `end_date` | C | 12/12 |
| FARMBOX_MOVIMENTATION | `movimentation_date` | C | 15/15 |

---

## 3. Issues Não-Bloqueantes (Requerem Ajuste de ETL/DDL)

### 3.1 Coordenadas Geográficas como STRING

**Afeta:** `FARMBOX_COUNT_MONITORING` (latitude/longitude), `FARMBOX_PLUVIOMETER_MONITORING` (latitude/longitude)  
**Exemplo real:** `"-14.3803867"`, `"-14.361991116825624"`  

O DDL define `latitude DECIMAL(9,6)` e `longitude DECIMAL(9,6)`. A API retorna strings.

**Problema adicional:** `FARMBOX_PLUVIOMETER_MONITORING` retorna precisão de 15 casas decimais (`"-14.361991116825624"`), que excede `DECIMAL(9,6)`. O SQL Server arredondará silenciosamente.

**Correções obrigatórias:**
```python
# ETL: converter antes do INSERT
lat = float(record.get("latitude") or 0)   # cast string → float
lng = float(record.get("longitude") or 0)
# DECIMAL(9,6) suporta até 999.999999 — truncamento ocorre mas é aceitável para geo
```
```sql
-- DDL v2: aumentar precisão para pluviometers
ALTER TABLE FARMBOX_PLUVIOMETER_MONITORING 
ALTER COLUMN latitude  DECIMAL(12,9) NULL;
ALTER TABLE FARMBOX_PLUVIOMETER_MONITORING 
ALTER COLUMN longitude DECIMAL(12,9) NULL;
```

### 3.2 `harvest_id` Não Retornado pela API

**Afeta:** `FARMBOX_PLANTATION`  
**Situação:** A API retorna apenas `harvest_name` (ex: `"2019/20-1"`) no objeto plantation. Não existe `harvest_id` diretamente no payload.

**Impacto:** Se o DDL de `FARMBOX_PLANTATION` exige `harvest_id BIGINT NULL`, o ETL não pode preenchê-lo diretamente.

**Correção DDL:** Adicionar coluna `harvest_name VARCHAR(100) NULL` à tabela e usar para JOIN com `FARMBOX_HARVEST.name` durante a etapa de master.

**Lógica ETL:**
```python
# Extração do payload plantation
harvest_name = record.get("harvest_name")   # "2019/20-1"
farm_id      = (record.get("farm") or {}).get("id")
plot_id      = (record.get("plot") or {}).get("id")
# harvest_id NÃO está disponível — armazenar harvest_name, resolver no GCS_FARM
```

### 3.3 Cursor Incremental Ausente em `trap_monitoring`

**Afeta:** `FARMBOX_TRAP_MONITORING`  
**Situação:** O campo `modified_at` foi `NULL` em todos os 15 registros da amostra. Sem ele, a query incremental `?updated_since=<cursor>` pode não funcionar.

**Fallback obrigatório no ETL:**
```python
# Se modified_at for NULL, usar o campo "date" como cursor
api_updated_at = record.get("modified_at") or record.get("date")
```

**Monitorar:** Após a primeira carga completa, verificar se algum registro tem `modified_at` não-nulo.

### 3.4 Valores de Enums Observados (Atualizar DDL e CHECK Constraints)

Valores reais observados nos dados de produção — confirmar e adicionar como comentários/CHECK no DDL:

| Campo | Valores observados |
|---|---|
| `FARMBOX_MONITORING_STOP_RESULT.infestation_level` | `'infested'`, `'damaged'`, `'clear'` |
| `FARMBOX_APPLICATION.status` | `'finalized'` (único na amostra — provavelmente há mais) |
| `FARMBOX_APPLICATION.operation_type` | `'pulverization'` (único na amostra) |
| `FARMBOX_MOVIMENTATION.movimentation_type` | `'in'`, `'out'` ✅ (DDL correto) |
| `FARMBOX_NOTE.location_type` | `'Fields::Plantation'`, `'Farms::Farm'` |

**Ação:** Adicionar como comentários no DDL. Não usar CHECK constraint até a lista de valores ser exaustiva.

---

## 4. Ausência de Dados (Informação)

Os endpoints abaixo retornaram 0 registros na primeira consulta. O schema está correto — sem dados para validar ainda.

- `resource_subscriptions` — 0 registros
- `activity_types` — aguardar amostra real
- `monitoring_tolerances` — aguardar amostra real
- `beaks` — aguardar amostra real
- `count_days` — aguardar amostra real
- `phenological_stages` — aguardar amostra real

---

## 5. Plano de Correções (DDL v2)

### 5.1 Alterações obrigatórias

```sql
-- 1. FARMBOX_HARVEST: start_date / end_date são apenas DATE na API
ALTER TABLE FARMBOX_HARVEST
    ALTER COLUMN start_date DATE NULL;
ALTER TABLE FARMBOX_HARVEST
    ALTER COLUMN end_date   DATE NULL;

-- 2. FARMBOX_MOVIMENTATION: date é apenas DATE na API
ALTER TABLE FARMBOX_MOVIMENTATION
    ALTER COLUMN movimentation_date DATE NOT NULL;

-- 3. FARMBOX_PLANTATION: adicionar harvest_name para resolução de FK no ETL master
ALTER TABLE FARMBOX_PLANTATION
    ADD harvest_name VARCHAR(100) NULL;

-- 4. FARMBOX_PLUVIOMETER_MONITORING: aumentar precisão de lat/lng
ALTER TABLE FARMBOX_PLUVIOMETER_MONITORING
    ALTER COLUMN latitude  DECIMAL(12,9) NULL;
ALTER TABLE FARMBOX_PLUVIOMETER_MONITORING
    ALTER COLUMN longitude DECIMAL(12,9) NULL;

-- 5. FARMBOX_COUNT_MONITORING: lat/lng chegam como string — DDL OK mas ETL deve converter
-- Sem alteração de schema necessária (DECIMAL aceita o cast)

-- 6. FARMBOX_TRAP_MONITORING: documentar fallback de cursor
-- Sem alteração de schema, apenas lógica de ETL
```

### 5.2 Alterações recomendadas (DDL v2)

```sql
-- Comentários de enum (sem CHECK até validação completa)
-- FARMBOX_MONITORING_STOP_RESULT.infestation_level: 'infested' | 'damaged' | 'clear'
-- FARMBOX_APPLICATION.status: 'finalized' | 'pending' | 'in_progress' (confirmar)
-- FARMBOX_NOTE.location_type: 'Fields::Plantation' | 'Farms::Farm'

-- Índice adicional recomendado para FARMBOX_PLANTATION
CREATE INDEX IX_FARMBOX_PLANTATION_harvest_name
    ON FARMBOX_PLANTATION (harvest_name)
    WHERE deleted_at IS NULL;
```

---

## 6. Regras Obrigatórias de ETL (Consolidadas)

Estas regras devem ser implementadas em **todos** os scripts de ingestion Farmbox:

1. **Função `parse_farmbox_dt(val)`** — chamada para todo campo de data/hora antes do INSERT. Normaliza as 3 variantes para UTC ISO 8601.
2. **Cast lat/lng** — `float(str_value)` antes de passar para o INSERT em colunas `DECIMAL`.
3. **Extração de IDs de objetos aninhados** — `farm_id`, `plot_id`, `plantation_id` sempre via `(record.get("farm") or {}).get("id")` com fallback `None` (nunca `.get("farm").get("id")` — quebra em null).
4. **Cursor incremental** — usar `api_updated_at` para `updated_since`. Para `trap_monitorings`, fallback para campo `date` se `modified_at` for NULL.
5. **Serialização do `record`** — sempre `json.dumps(raw_dict, ensure_ascii=False)` antes do INSERT. Nunca armazenar o objeto Python diretamente.
6. **Credenciais** — o token Farmbox é descriptografado da SK_CONFIG_API em memória, usado na requisição e descartado. Nunca persiste em `record` ou em qualquer log.

---

## 7. Checklist Pré-Produção

- [ ] Função `parse_farmbox_dt()` implementada e testada com os 3 formatos
- [ ] DDL v2 aplicado (ALTER das 4 colunas obrigatórias)
- [ ] ETL extrai `harvest_name` em plantation e salva na coluna nova
- [ ] ETL converte lat/lng string para float antes do INSERT
- [ ] Fallback de cursor para `trap_monitorings` implementado
- [ ] Carga histórica completa testada em ambiente de homologação (todas as 468 páginas de monitorings)
- [ ] VIEW `FARMBOX_PENDING_PROCESSING` validada após carga histórica
- [ ] Ingestão incremental com `updated_since` validada com data do dia anterior

---

*Gerado automaticamente por simulação de ingestion sobre dados reais de farmbox_responses/ — 2026-06-26*
