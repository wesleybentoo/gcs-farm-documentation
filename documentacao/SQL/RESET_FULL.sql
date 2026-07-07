/* =====================================================================
   GCS CONNECTION FARM  |  RESET DOS BANCOS (apaga e permite recriar)
   SQL Server  |  USE COM CUIDADO: apaga CONNECTOR_GCS_FARM e GCS_FARM.

   Quando usar: para recriar do zero sem os erros de "ja existe / nao pode
   dropar por FK". Rode este reset e depois execute o
   GCS_databases_full_setup_mssql.sql novamente (build limpo).

   So para ambiente local/teste. Em producao, NUNCA dropar bancos assim.

   Cobre TODOS os modulos (drop do banco inteiro), incluindo os agronomicos
   adicionados em 2026-06-27: Calendario Agricola (FARM_SEASON/CULTURE/CYCLE),
   FERTILIDADE (FERT_*) e VRA (VRA_*); e o grid de clima por talhao de
   2026-06-28 (FIELD_WEATHER_HOURLY / FIELD_WEATHER_COVERAGE). Como dropa o
   banco inteiro, nao precisa de drops por tabela.
   ===================================================================== */

USE master;
GO

IF DB_ID('CONNECTOR_GCS_FARM') IS NOT NULL
BEGIN
    ALTER DATABASE CONNECTOR_GCS_FARM SET SINGLE_USER WITH ROLLBACK IMMEDIATE; -- derruba conexoes
    DROP DATABASE CONNECTOR_GCS_FARM;
END
GO

IF DB_ID('GCS_FARM') IS NOT NULL
BEGIN
    ALTER DATABASE GCS_FARM SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE GCS_FARM;
END
GO

PRINT 'Reset concluido. Agora rode o GCS_databases_full_setup_mssql.sql.';
GO
