/* =========================================================================
   ESPAÇAMENTO ENTRE LINHAS (cm) — dado curado do cadastro (não do monitor)
   -------------------------------------------------------------------------
   Motivação: o Farmbox só tem o espaçamento como parâmetro DIGITADO por
   contagem ("Espaçamento entre linhas (cm)", p2407) — inconsistente entre
   monitores (ex.: 42 em vez de 40,5). Guardamos o valor CURADO no cadastro:
     - default POR CULTURA em FARM_CULTURE.default_row_spacing_cm (base);
     - override POR PLANTIO em FARM_FIELD_PLANTING.row_spacing_cm (opcional).
   Resolução no cálculo de stand (plantas/ha): plantio.override
     -> default da cultura -> fallback do código.
   Idempotente. Roda depois de SETUP_FULL / planejamento.
   ========================================================================= */

IF COL_LENGTH('dbo.FARM_CULTURE', 'default_row_spacing_cm') IS NULL
  ALTER TABLE dbo.FARM_CULTURE ADD default_row_spacing_cm DECIMAL(6,2) NULL;
GO

IF COL_LENGTH('dbo.FARM_FIELD_PLANTING', 'row_spacing_cm') IS NULL
  ALTER TABLE dbo.FARM_FIELD_PLANTING ADD row_spacing_cm DECIMAL(6,2) NULL;
GO

/* Seed do padrão da fazenda (só onde ainda não foi definido — não sobrescreve edição manual). */
UPDATE dbo.FARM_CULTURE SET default_row_spacing_cm = 81.0
 WHERE deleted_at IS NULL AND default_row_spacing_cm IS NULL AND LOWER(name) LIKE 'algod%';

UPDATE dbo.FARM_CULTURE SET default_row_spacing_cm = 40.5
 WHERE deleted_at IS NULL AND default_row_spacing_cm IS NULL
   AND LOWER(name) IN (N'soja', N'milho', N'sorgo');
GO
