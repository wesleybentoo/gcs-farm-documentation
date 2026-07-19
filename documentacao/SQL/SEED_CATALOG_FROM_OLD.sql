/* =========================================================================
   SEED_CATALOG_FROM_OLD - catalogos padrao de inicio (Variedades + Estagios
   Fenologicos + culturas extras) copiados do banco antigo GCS_FARM_OLD.
   -------------------------------------------------------------------------
   ALVO: GCS_FARM (master). Rodar: sqlcmd -d GCS_FARM -I -b

   Popula o catalogo curado que o app precisa antes do re-import do Farbox:
     - 5 culturas que faltam no SETUP (Braquiaria/Eucalipto/Indefinido/Milheto/Mix Cobertura);
     - FARM_VARIETY  (163) — remapeando cultura por NOME (ids de cultura diferem entre bancos);
     - FARM_PHENOLOGICAL_STAGE (216) — idem; confused_with_ids fica NULL (ids de estagio mudam);
     - FARM_VARIETY_TRAIT_VALUE — best-effort por nome de cultura/variedade/trait.
   Idempotente (NOT EXISTS por chave natural). Roda DEPOIS de SETUP_FULL +
   MODULE_MULTITENANT_V1 (cultura seed) + MODULE_AGRO/planejamento (tabelas).

   DEPENDENCIA: le de GCS_FARM_OLD (o banco antigo preservado no rename). Uma vez
   que o OLD for aposentado, a fonte permanente de variedades/estagios passa a ser
   o re-import do Farbox (materialize por farbox_variety_id/farbox_stage_id, que
   reconcilia com estas linhas). Ao aposentar o OLD, gerar a versao inlined deste
   seed a partir do GCS_FARM ja populado.
   ========================================================================= */
SET NOCOUNT ON;
GO

-- culturas extras (idempotente por nome)
INSERT INTO dbo.FARM_CULTURE (code, name, scientific_name, color_hex, productivity_unit, productivity_kg_per_unit, farmbox_culture_id, active, default_row_spacing_cm)
SELECT o.code, o.name, o.scientific_name, o.color_hex, o.productivity_unit, o.productivity_kg_per_unit, o.farmbox_culture_id, o.active, o.default_row_spacing_cm
  FROM GCS_FARM_OLD.dbo.FARM_CULTURE o
 WHERE o.deleted_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM dbo.FARM_CULTURE f WHERE f.name=o.name AND f.deleted_at IS NULL);
GO

-- variedades (cultura por nome)
INSERT INTO dbo.FARM_VARIETY (culture_id, code, name, kind, tech, primary_tech, maturity_group, company, farmbox_variety_id, active, notes)
SELECT c.id, v.code, v.name, v.kind, v.tech, v.primary_tech, v.maturity_group, v.company, v.farmbox_variety_id, v.active, v.notes
  FROM GCS_FARM_OLD.dbo.FARM_VARIETY v
  JOIN GCS_FARM_OLD.dbo.FARM_CULTURE oc ON oc.id=v.culture_id
  JOIN dbo.FARM_CULTURE c ON c.name=oc.name AND c.deleted_at IS NULL
 WHERE v.deleted_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM dbo.FARM_VARIETY fv WHERE fv.culture_id=c.id AND fv.name=v.name AND fv.deleted_at IS NULL);
GO

-- estagios fenologicos (cultura por nome; confused_with_ids NULL).
-- source='app' (NAO 'farmbox'): protege do NOT MATCHED BY SOURCE do materialize da
-- fenologia, que soft-deleta source='farmbox' ausente do connector (vazio ate o
-- re-import). Mantem farbox_stage_id -> o Farbox reconcilia por id no re-import.
INSERT INTO dbo.FARM_PHENOLOGICAL_STAGE (culture_id, code, position, classification, description, ignore_infestations, farmbox_stage_id, source, id_tips, days_after_emergence_min, days_after_emergence_max)
SELECT c.id, s.code, s.position, s.classification, s.description, s.ignore_infestations, s.farmbox_stage_id, 'app', s.id_tips, s.days_after_emergence_min, s.days_after_emergence_max
  FROM GCS_FARM_OLD.dbo.FARM_PHENOLOGICAL_STAGE s
  JOIN GCS_FARM_OLD.dbo.FARM_CULTURE oc ON oc.id=s.culture_id
  JOIN dbo.FARM_CULTURE c ON c.name=oc.name AND c.deleted_at IS NULL
 WHERE s.deleted_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM dbo.FARM_PHENOLOGICAL_STAGE fs WHERE fs.culture_id=c.id AND fs.code=s.code AND fs.deleted_at IS NULL);
GO

-- valores de caracteristicas (best-effort por nome)
INSERT INTO dbo.FARM_VARIETY_TRAIT_VALUE (variety_id, trait_id, value)
SELECT nv.id, nt.id, tv.value
  FROM GCS_FARM_OLD.dbo.FARM_VARIETY_TRAIT_VALUE tv
  JOIN GCS_FARM_OLD.dbo.FARM_VARIETY ov ON ov.id=tv.variety_id
  JOIN GCS_FARM_OLD.dbo.FARM_CULTURE ovc ON ovc.id=ov.culture_id
  JOIN GCS_FARM_OLD.dbo.FARM_VARIETY_TRAIT ot ON ot.id=tv.trait_id
  JOIN dbo.FARM_CULTURE nvc ON nvc.name=ovc.name AND nvc.deleted_at IS NULL
  JOIN dbo.FARM_VARIETY nv ON nv.culture_id=nvc.id AND nv.name=ov.name AND nv.deleted_at IS NULL
  JOIN dbo.FARM_VARIETY_TRAIT nt ON nt.name=ot.name AND nt.deleted_at IS NULL
 WHERE tv.deleted_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM dbo.FARM_VARIETY_TRAIT_VALUE x WHERE x.variety_id=nv.id AND x.trait_id=nt.id AND x.deleted_at IS NULL);
GO
