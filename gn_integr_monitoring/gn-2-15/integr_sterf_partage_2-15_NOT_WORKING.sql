-- CREATION DE LA TABLE D'IMPORT

CREATE TABLE _qgis.test_sterf (
	fid SERIAL PRIMARY KEY, 
	transect TEXT, 
	annee INTEGER, 
	num_passage INTEGER, 
	visit_date_min timestamp without time zone , 
	tp VARCHAR(50), 
	cn VARCHAR(50), 
	vt VARCHAR(50), 
	os_1 TEXT, 
	os_2 TEXT, 
	hab_1 TEXT, 
	hab_2 TEXT, 
	visit_comment TEXT, 
	determiner TEXT, 
	cd_nom INTEGER, 
	nom_complet TEXT, 
	effectif INTEGER, 
	obs_comment TEXT,
	id_sites_group INTEGER,
	id_base_site INTEGER,
	id_base_visit INTEGER,
	id_observation INTEGER,
	geom_local GEOMETRY(LINESTRING,2154)
);

-- INTEGRATION DES DONNEES DU FICHIER FOURNI

-- SCRIPT D'INTEGRATION AU MODULE

-- Groupe de site
WITH sterf_module as (
	SELECT
		id_module,
		module_code
	FROM gn_commons.t_modules
	WHERE module_code = 'sterf'
)
INSERT INTO gn_monitoring.t_sites_groups(
	sites_group_name,
	id_module
)
SELECT
	SPLIT_PART(transect, '_', 1) as sites_group_name,
	id_module
FROM _qgis.test_sterf
LEFT JOIN sterf_module on module_code = 'sterf'
GROUP BY SPLIT_PART(transect, '_', 1) , id_module
;

UPDATE _qgis.test_sterf i
SET id_sites_group = tsg.id_sites_group
FROM gn_monitoring.t_sites_groups tsg
WHERE lower(sites_group_code) LIKE '%' || lower(SPLIT_PART(transect, '_', 1)) || '%'
;

-- transect

WITH sterf_module as (
	SELECT
		id_module,
		id_nomenclature as id_type_site,
		module_code
	FROM gn_commons.t_modules
	LEFT JOIN ref_nomenclatures.t_nomenclatures ON cd_nomenclature = 'STERF'
	WHERE module_code = 'sterf'
)
INSERT INTO gn_monitoring.t_base_sites(
	base_site_name,
	base_site_code,
	id_type_site,
	geom
	geom_local
)
SELECT
	transect as base_site_name,
	'T' || SPLIT_PART(transect, '_', 2)  as base_site_code,
	id_type_site,
	ST_transform(geom_local, 4326) as geom,
	geom_local
FROM _qgis.test_sterf
LEFT JOIN sterf_module on module_code = 'sterf'
GROUP BY transect, SPLIT_PART(transect, '_', 2), id_type_site, geom_local
;

UPDATE _qgis.test_sterf i
	SET id_base_site = tbs.id_base_site
FROM gn_monitoring.t_base_sites tbs WHERE transect = base_site_name
-- rajouter un lien avec tbs.id_type_site si besoin
;

WITH sterf_module as (
	SELECT
		id_module,
		module_code
	FROM gn_commons.t_modules
	WHERE module_code = 'sterf'
)
INSERT INTO gn_monitoring.t_site_complements(
	id_base_site,
	id_sites_group,
	id_module,
	data
)
SELECT
	id_base_site,
	id_sites_group,
	id_module,
	jsonb_build_object(
		'occ_sol', STRING_AGG(DISTINCT os_1, ', ') ,
		'occ_sol_detail', STRING_AGG(DISTINCT os_2, ', '),
		'hab_1', STRING_AGG(DISTINCT hab_1, ', '),
		'lisiere', CASE WHEN  STRING_AGG(DISTINCT hab_2, ', ') IS NULL THEN 'Non' ELSE 'Oui' END,
		'hab_2',  STRING_AGG(DISTINCT os_2, ', ')
	) -- Il faudrait plutôt faire une formule avec LAST VALUE pour une intégration en masse mais ici non nécessaire
FROM _qgis.test_sterf i 
LEFT JOIN sterf_module on module_code = 'sterf'
GROUP BY id_sites_group, id_base_site, id_module
;

-- Passages
WITH sterf_module as (
	SELECT
		id_module,
		module_code
	FROM gn_commons.t_modules
	WHERE module_code = 'sterf'
)
INSERT INTO gn_monitoring.t_base_visits(
	id_base_site,
	id_module,
	id_dataset,
	visit_date_min,
	id_digitiser,
	id_nomenclature_tech_collect_campanule,
	id_nomenclature_grp_typ,
	comments
)
SELECT
	id_base_site,
	id_dataset, -- voir si la formule ci-dessous de jointure aux jdd est ok chez vous
	id_module,
	visit_date_min::date as visit_date_min,
	id_role as id_digitiser, -- ajouter l'observateur à la base ou mettre un id_role fixe
	ref_nomenclatures.get_id_nomenclature('TECHNIQUE_OBS'::character varying, '59'::character varying)  as id_nomenclature_tech_collect_campanule , -- Observation directe terrestre diurne (chasse à vue de jour)
	ref_nomenclatures.get_id_nomenclature('TYP_GRP'::character varying, 'PASS'::character varying) as id_nomenclature_grp_typ,  -- Passage
	visit_comment
FROM _qgis.test_sterf i 
LEFT JOIN sterf_module on module_code = 'sterf'
LEFT JOIN utilisateurs.t_roles ON LOWER(determiner) = lower(nom_role) || ' ' || lower(prenom_role)
LEFT JOIN gn_meta.t_datasets ON lower(dataset_name) LIKE '%sterf%'
GROUP BY id_base_site, id_module, visit_date_min, id_role, id_dataset
;

WITH sterf_module as (
	SELECT
		id_module,
		module_code
	FROM gn_commons.t_modules
	WHERE module_code = 'sterf'
),
v as (
	SELECT
		*
	FROM gn_monitoring.t_base_visits tbv
	LEFT JOIN gn_monitoring.t_base_sites tbs USING (id_base_site)
	INNER JOIN sterf_module USING (id_module)
)
UPDATE _qgis.test_sterf i 
SET id_base_visit = v.id_base_visit
FROM v
WHERE v.id_base_site = i.id_base_site 
AND v.base_site_name = i.transect
AND v.visit_date_min = i.visit_date_min::date
;

INSERT INTO gn_monitoring.t_visit_complements(
	id_base_visit,
	data
)
SELECT
	id_base_visit,
	jsonb_build_object(
		'num_passage', min(num_passage),
		'annee', min(annee),
		'heure_min', visit_date_min::time,
		'occ_sol', STRING_AGG(DISTINCT os_1, ', ') ,
		'occ_sol_detail', STRING_AGG(DISTINCT os_2, ', '),
		'hab_1', STRING_AGG(DISTINCT hab_1, ', '),
		'lisiere', CASE WHEN  STRING_AGG(DISTINCT hab_2, ', ') IS NULL THEN 'Non' ELSE 'Oui' END,
		'hab_2',  STRING_AGG(DISTINCT os_2, ', '),
		'id_nomenclature_tp', STRING_AGG(DISTINCT tp, ', '),
		'id_nomenclature_cn', STRING_AGG(DISTINCT cn, ', '),
		'id_nomenclature_vt', STRING_AGG(DISTINCT vt, ', ')
	) -- Il faudrait plutôt faire une formule avec LAST VALUE pour une intégration en masse mais ici non nécessaire
FROM _qgis.test_sterf i
GROUP BY id_base_visit, visit_date_min
;

-- Observateurs du passage
WITH obs as 
(
	SELECT
		id_base_visit,
		determiner
	FROM _qgis.test_sterf i 
	GROUP BY id_base_visit, determiner
)
INSERT INTO gn_monitoring.cor_visit_observer(
	id_base_visit,
	id_role
)
SELECT
	id_base_visit,
	id_role
FROM obs
INNER JOIN utilisateurs.t_roles ON LOWER(determiner) = lower(nom_role) || ' ' || lower(prenom_role)
;

-- observations

INSERT INTO gn_monitoring.t_observations(
	id_base_visit,
	cd_nom,
	comments
)
SELECT
	id_base_visit,
	cd_nom, 
	nom_complet
FROM _qgis.test_sterf i
ORDER BY nom_complet
;

UPDATE _qgis.test_sterf i 
SET id_observation = o.id_observation
FROM gn_monitoring.t_observations o
WHERE o.cd_nom = i.cd_nom and i.id_base_visit = o.id_base_visit
;

SELECT
	id_observation,
	jsonb_build_object(
		'effectif', effectif,
		'id_nomenclature_obs_technique', ref_nomenclatures.get_id_nomenclature('METH_OBS'::character varying, '0'::character varying),
		'id_nomenclature_determination_method', ref_nomenclatures.get_id_nomenclature('METH_DETERMIN'::character varying, '0'::character varying),
		'id_nomenclature_type_count', ref_nomenclatures.get_id_nomenclature('TYP_DENBR'::character varying, 'Co'::character varying) ,
		'id_nomenclature_obj_count', ref_nomenclatures.get_id_nomenclature('OBJ_DENBR'::character varying, 'IND'::character varying) 
	)
FROM _qgis.test_sterf i 
WHERE NOT id_observation IS NULL


