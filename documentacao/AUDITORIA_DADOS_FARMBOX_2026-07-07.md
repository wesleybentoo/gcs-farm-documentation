# Auditoria de Dados — Farmbox × GCS_FARM (2026-07-07)

Confronto entre o que o **Farmbox** entregou (landing cru `CONNECTOR_GCS_FARM.dbo.FARMBOX_*`, coluna `record` JSON) e o que **temos hoje** materializado no domínio nativo (`GCS_FARM.dbo.FARM_*`). Todas as contagens são de linhas **não deletadas** (`deleted_at IS NULL`), lidas direto do banco vivo.

## 1. Reconciliação por entidade

| Entidade | Raw Farbox (ativo) | FARM_* (mapeado) | Cobertura | Gap | Leitura |
|---|---:|---:|---:|---:|---|
| **Produtos** (inputs) | 898 | 898 | **100%** | 0 | ✅ completo |
| **Aplicações** | 7.946 | 7.946 | **100%** | 0 | ✅ completo |
| **Contagens** | 21.860 | 21.860 | **100%** | 0 | ✅ completo |
| **Monitoramentos** | 14.103 | 14.099 | **~100%** | 4 | ✅ 4 sem plot mapeado |
| **Talhões** (plots) | 227 | 210 | 92,5% | 17 | plots não-cadastrados (não são fazendas nossas) |
| **Culturas** | 11 | 10 | 90,9% | 1 | "Mix Cobertura" não cadastrada |
| **Day-results** | 13.934 | 12.662 | 90,9% | 1.272 | dia sem `monitors[]` / plantação não resolvida |
| **Variedades** | 162 | 130 | 80,2% | 32 | faltam no cadastro (culturas já existem) |
| **Plantios** | 1.987 | 1.528 | 76,9% | 459 | ver §3 (maioria vazio/futuro) |

> FARM_* total (inclui cadastro manual, não-Farmbox): Culturas 14, Variedades 131, Talhões 207.

## 2. Filhos materializados (profundidade dos eventos)

| Tabela | Linhas |
|---|---:|
| FARM_MONITORING_POINT (paradas) | 132.302 |
| FARM_MONITORING_FINDING (achado/praga agregado) | 85.649 |
| **FARM_MONITORING_STOP_RESULT** (achado por ponto — mapa de calor) | 842.660 |
| **FARM_MONITORING_NOTE** (notas georreferenciadas) | 57.184 (**47.518 com foto**) |
| FARM_APPLICATION_INPUT (insumos aplicados) | 30.543 |
| FARM_APPLICATION_TARGET (alvos) | 40.895 (**100% com talhão**) |
| FARM_COUNT_PARAM (pIDs de contagem) | 62.692 |

## 3. Análise dos gaps (o que é perda × o que é escopo)

**Plantios — 459 gap decomposto:**
- **17** → plot sem talhão nosso (não dá pra materializar; §1 talhões).
- **442** → plot mapeado, mas plantio não materializado. Destes:
  - **368 sem cultura** = plantios **vazios/futuros** (ex.: 267 da safra **2026/2027** ainda sem cultura atribuída) — nada a materializar.
  - **74 com cultura real** = plantios **históricos** de safras antigas (2019–2023). Efetivamente o único "gap de conteúdo" (0,37% do total), e é histórico.
- **Conclusão:** cobertura de plantio é **efetivamente completa para a safra corrente**; o "76,9%" é puxado por vazios/futuros + histórico antigo, não por perda.

**Monitoramentos sem `planting_id`: 588** (de 14.099) — têm talhão (`field_id` 100% preenchido), só não têm o elo de plantio (porque a plantação cai nos 442 acima). Views por talhão/data seguem funcionando; a cultura é derivável por talhão+data.

**Variedades — 32 faltantes**: todas de culturas **já mapeadas** (Soja 16, Milho 7, Algodão 5, Sorgo 3, Indefinido 1). É backfill de cadastro, não perda de evento.

**Cultura — 1 faltante**: "Mix Cobertura" (mix de cobertura). Cadastrar ou mapear p/ Pousio se for monitorar.

## 4. Dados Farmbox que ainda NÃO aproveitamos (oportunidades)

Entidades presentes no landing cru mas **sem materialização** hoje:

| Entidade raw | Linhas | Oportunidade |
|---|---:|---|
| FARMBOX_NOTE (notas gerais) | 37.119 | notas de campo (possivelmente com fotos) fora do monitoramento |
| FARMBOX_MOVIMENTATION | 33.575 | módulo **Estoque** (futuro) |
| FARMBOX_PLUVIOMETER_MONITORING | 22.499 | **chuva** do pluviômetro Farmbox (complementa Solinftec/grid) |
| FARMBOX_PHENOLOGICAL_STAGE_SAMPLE | 15.078 | fenologia detalhada por amostra |
| FARMBOX_INPUT_VALUE | 7.551 | preços/valores de insumo |
| FARMBOX_COUNT_DAY | 5.500 | cabeçalho-dia da contagem |
| FARMBOX_TRAP_MONITORING | 2.466 | monitoramento por **armadilha** |
| FARMBOX_MONITORING_TOLERANCE | 307 | (já usada como seed da tolerância) |
| FARMBOX_PLUVIOMETER / BATCH / HARVEST / STORAGE | 76 / 65 / 12 / 2 | cadastros auxiliares |

## 5. Veredito

- **Dados operacionais (produtos, aplicações + insumos/alvos, monitoramentos + pontos/achados/stop-results, contagens + parâmetros) estão 100% / ~100% materializados. Não há perda relevante.**
- Os gaps são de **cadastro/escopo**, não de perda de dado: variedades (32) e cultura (1) para backfill; plantios efetivamente completos na safra corrente; talhões faltantes são de fazendas não nossas.
- Há um **acervo Farbox ainda não aproveitado** (notas gerais, chuva, fenologia, armadilhas, movimentações) — matéria-prima para módulos futuros.

## 6. Recomendações

1. **Backfill das 32 variedades** faltantes (culturas já existem) — fecha o cadastro de cultivares.
2. **Cadastrar "Mix Cobertura"** (ou mapear → Pousio) se for monitorar cobertura.
3. *(opcional)* Materializar os **74 plantios históricos com cultura** se quiser histórico de produtividade completo.
4. **Reiniciar/rebuild do backend** para o ETL passar a usar o novo bloco 4c (thresholds por cultura); enquanto rodar o código antigo, o ETL reintroduz linhas `culture_id=NULL` (limpeza: `DELETE FROM FARM_PEST_THRESHOLD WHERE culture_id IS NULL AND source='farmbox'`).
5. *(roadmap)* Avaliar aproveitar **chuva do pluviômetro** (22k), **notas gerais** (37k), **fenologia** (15k) e **armadilhas** (2,5k) em módulos dedicados.

---
*Método: `sqlcmd` read-only sobre o banco vivo; contagens `deleted_at IS NULL`; cross-db `CONNECTOR_GCS_FARM.dbo.*` × `GCS_FARM.dbo.FARM_*`. Scripts em `scratchpad/_audit_*.sql`.*
