# GCS FARM — Documentação

Repositório central da documentação e dos arquivos de suporte do projeto **GCS FARM**
(Fazenda Jacúba / GCS Agro): backend (`gcs-backend`) + front (`gcs-farm-front`), integrações
(Farmbox, Solinftec, IrriControl), banco SQL Server e ETLs.

> A partir de agora a documentação é **versionada aqui**. Edite os arquivos neste repositório
> (não mais nas pastas soltas em `C:\Developer`), faça commit e push.

## Estrutura

```
documentacao/     # documentação de escopo, arquitetura, banco, ETLs, especificações e SQL
  sql/            # scripts SQL canônicos (setup, módulos, materialização, reset)
suporte/          # arquivos de apoio (planilhas, KMLs, logs de voo, coleções Postman, respostas de API)
```

### `documentacao/`

| Arquivo | Conteúdo |
|---|---|
| `00_Consistencias_e_Inconsistencias.md` | Estado de consistência entre código e banco |
| `01_Escopo_e_Modulos_App.md` | Escopo geral e módulos do app |
| `02_Bancos_de_Dados.md` | Modelagem e catálogo dos bancos |
| `03_ETLs.md` | Pipelines de ETL (Farmbox, Solinftec) |
| `04_Guia_Arquitetura_e_Novos_Modulos.md` | Guia de arquitetura e como criar novos módulos |
| `05_Arquitetura_Multicliente_e_Escopos.md` | Arquitetura multicliente (CLIENTE_GRUPO), escopos globais (geográfico/safra/config), herança + copy-on-write e plano de ataque faseado |
| `06_Fase3_Homologacao_e_Mapa_de_Impacto.md` | Fase 3: homologação do escopo no GCS_FARM_TEST + mapa de impacto ranqueado (P0/P1/P2) do que alterar no código |
| `Niveis_criticos_e_exportacao_ICL.md` | Níveis críticos de solo e exportação de nutrientes (base ICL) |
| `BRIEFING_FARMBOX_INTEGRATION.md` | Briefing da integração com o Farmbox |
| `*.pdf` | Especificações funcionais das APIs Solinftec (Operação, Meteorológicos) |
| `*.docx` | Documentação de DBA e escopo (versões históricas — mantidas por referência) |

### `documentacao/sql/`

| Script | Função |
|---|---|
| `SETUP_FULL.sql` | Setup canônico completo do schema do domínio |
| `MODULE_AGRO_V1.sql` | Módulo agronômico próprio (produtos, bulário, monitoramento, estimativa) |
| `FLIGHT_LOG.sql` | Tabelas da Aplicação Aérea (roda depois do MODULE_AGRO — FK → FARM_APPLICATION) |
| `MATERIALIZE_FARM.sql` | Materialização do domínio FARM_* a partir do espelho Farmbox |
| `FERT_EXPORT_PROFILES.sql` / `FERT_CROP_EXPORT_SCOPE.sql` | Perfis e escopo de exportação de fertilidade |
| `DROP_FARMBOX_MIRROR.sql` / `RESET_FULL.sql` | Limpeza / reset |
| `README.md` | Ordem de execução e notas dos scripts |

### `suporte/`

| Pasta / arquivo | Conteúdo |
|---|---|
| `Cadastro Análises de Solo/` | Resultados analíticos de solo (xlsx) por fazenda |
| `Cadastros SOLINFTEC/` | Exportações de cadastro do Solinftec (equipamentos, operações, etc.) |
| `Log Avião/` | Log bruto do GPS do Air Tractor (`.log`) + trilha GeoJSON + decoder de referência (Python) |
| `Polignos/` | Contornos de pivôs/talhões (KMZ/KML) — Celeiro 1/2/3/6, projeto de irrigação |
| `Postman - APIs/` | Coleções/ambientes Postman (Farmbox, IrriControl) |
| `farmbox_responses/` | Amostras de resposta da API do Farmbox (JSON) por endpoint |
| `FARMBOX_Auditoria_Ingestion_v1.md` | Auditoria da ingestão do Farmbox |
| `SOLINFTEC_CLIMA_Grid_v1.md` | Arquitetura do grid de clima (Solinftec) |
| `farmbox_test_endpoints.{ps1,py}` | Scripts de teste dos endpoints do Farmbox |
| `maquinas_farmbox.xlsx` | Máquinas/equipamentos (Farmbox) |
| `pontos_descartados_algodao_2526.csv` | Pontos descartados na estimativa de algodão (safra 25/26) |

## Repositórios relacionados

- `gcs-backend` — API (Node/Express/TypeScript/Sequelize + SQL Server)
- `gcs-farm-front` — front (React/TypeScript/Vite + maplibre-gl)
