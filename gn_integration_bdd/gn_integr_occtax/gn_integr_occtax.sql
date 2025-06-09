/*
----------------------------------------------------
REMPLISSAGE DES ALTITUDES et OBSERVATEURS
----------------------------------------------------
*/
-- Correction des géométries invalides
UPDATE _qgis.import_data
    SET geom_local = ST_MakeValid(geom_local)
WHERE ST_IsValid(geom_local) IS false
;
-- Récupération de l'altitude minimale si elle existe pour remplir l'altitude maximale (cas des points)
UPDATE _qgis.import_data imp_data
    SET 
        altitude_max = altitude_min
WHERE import_valid is TRUE
    and date_import is NULL
    and altitude_max is NULL
    and not altitude_min is NULL
    and ST_GeometryType(geom_local) = 'ST_Point'
;
-- Calcul des altitudes pour les autres cas
WITH alti_data as (
    SELECT 
        fid,
        (to_jsonb(ref_geo.fct_get_altitude_intersection(imp.geom_local))->> 'altitude_min')::integer as alti_min
    FROM _qgis.import_data imp
    WHERE imp.altitude_min is null and import_valid is true
)
UPDATE _qgis.import_data imp_data
    SET 
        altitude_min =  alti_data.alti_min
FROM alti_data
WHERE 
    imp_data.altitude_min is null 
    and imp_data.fid = alti_data.fid 
    and import_valid is true
    and date_import is null
;
WITH alti_data as (
    SELECT 
        fid,
        (to_jsonb(ref_geo.fct_get_altitude_intersection(imp.geom_local))->> 'altitude_max')::integer as alti_max
    FROM _qgis.import_data imp
    WHERE imp.altitude_max is null and import_valid is true
)
UPDATE _qgis.import_data imp_data
    SET 
        altitude_max = alti_data.alti_max
FROM alti_data
WHERE 
    imp_data.altitude_max is null 
    and imp_data.fid = alti_data.fid 
    and import_valid is true
    and date_import is null
;
-- Modification des observateurs avec le numérisateur
UPDATE _qgis.import_data i SET observers = ARRAY[ i.id_digitiser ]
WHERE i.date_import IS NULL and i.observers IS NULL and import_valid is true
;
/*
----------------------------------------------------
INTEGRATION DES RELEVES
----------------------------------------------------
*/
-- Intégration des relevés à la table de pr_occtax.t_releves_occtax
WITH ids_observers as (
    SELECT 
        fid,
        UNNEST(observers)::integer  as id_observer
    FROM _qgis.import_data imp
),
observ as (
    SELECT
        o.fid,
        STRING_AGG(DISTINCT (r.nom_role || ' ' || r.prenom_role), ', ') as observers_txt
    FROM ids_observers o
    LEFT JOIN utilisateurs.t_roles r ON o.id_observer = r.id_role
    GROUP BY o.fid
),
import_data as (
SELECT 
    d.id_dataset, 
    d.id_digitiser, 
    COALESCE(d.observers_txt, observ.observers_txt) as observers_txt, 
    d.id_nomenclature_tech_collect_campanule, 
    d.id_nomenclature_grp_typ, 
    d.grp_method, 
    d.date_min::date as date_min, 
    COALESCE( d.date_max , d.date_min)::date as date_max, 
    (
        CASE
        WHEN d.date_min::time='00:00:00' THEN NULL 
        ELSE d.date_min::time END 
    ) as hour_min, 
    (
        CASE
        WHEN COALESCE( d.date_max ::time, d.date_min::time)='00:00:00' THEN NULL 
        ELSE COALESCE( d.date_max ::time, d.date_min::time) END
    ) as hour_max, 
    d.cd_hab, 
    d.altitude_min, 
    d.altitude_max, 
    d.place_name, 
    d.meta_device_entry, 
    d.geom_local, 
    -- Le relevé se fit à la colonne geom_4326 pour générer la géométrie 
    -- => pas de géométrie si geom_4326 est nulle même si geom_local ne l'est pas
    ST_Transform(d.geom_local, 4326) as geom_4326, 
    d.id_nomenclature_geo_object_nature,
    jsonb_build_object(	
        'fids_import',
        -- to_jsonb(
            array_agg(d.fid) 
        --)
    )  as additional_fields,
    d.id_module
FROM _qgis.import_data d
LEFT JOIN observ USING (fid)
WHERE d.date_import is null and d.id_releve_occtax is null  and import_valid is true
GROUP BY 
    d.id_dataset, 
    d.id_digitiser, 
    observ.observers_txt, 
    d.observers_txt,
    d.id_nomenclature_tech_collect_campanule, 
    d.id_nomenclature_grp_typ, 
    d.grp_method, 
    d.date_min, 
    d.date_max, 
    hour_min,
    hour_max,
    d.cd_hab, 
    d.altitude_min, 
    d.altitude_max, 
    d.place_name, 
    d.meta_device_entry, 
    d.geom_local, 
    d.id_nomenclature_geo_object_nature, 
    d.id_module
)
INSERT INTO pr_occtax.t_releves_occtax (
    id_dataset, 
    id_digitiser, 
    observers_txt, 
    id_nomenclature_tech_collect_campanule, 
    id_nomenclature_grp_typ, 
    grp_method, 
    date_min, 
    date_max , 
    hour_min,
    hour_max,
    cd_hab, 
    altitude_min, 
    altitude_max, 
    place_name, 
    meta_device_entry, 
    geom_local, 
    geom_4326,
    id_nomenclature_geo_object_nature,
    additional_fields,
    id_module
)
SELECT 
    *
FROM import_data
ORDER BY date_min
;   
-- Ajout des id_releves à la table d'import
WITH rel as (
    SELECT
        id_releve_occtax,
        (jsonb_array_elements_text(additional_fields -> 'fids_import'))::integer  as fid
    FROM pr_occtax.t_releves_occtax rel
    WHERE meta_device_entry = 'qgis' and not additional_fields -> 'fids_import' is null
)
UPDATE _qgis.import_data d
SET id_releve_occtax = rel.id_releve_occtax
FROM  rel 
WHERE d.fid = rel.fid
AND d.id_releve_occtax IS NULL
;
-- Intégration des observateurs des relevés
WITH rel_obs as (
    SELECT
        id_releve_occtax,
        UNNEST(observers) as id_role -- Eclatement de la colonne observers pour générer 1 ligne par relevé et observateur
    FROM _qgis.import_data d
    WHERE date_import is NULL and import_valid is true and not id_releve_occtax is null
    GROUP BY id_releve_occtax, id_role
)
INSERT INTO pr_occtax.cor_role_releves_occtax(
    id_role,
    id_releve_occtax
)
SELECT 
    rel_obs.id_role,
    rel_obs.id_releve_occtax
FROM rel_obs
ON CONFLICT DO NOTHING
;
/*
----------------------------------------------------
INTEGRATION DES OCCURRENCES
----------------------------------------------------
*/
-- Insertion des observations à la table des occurrences
INSERT INTO pr_occtax.t_occurrences_occtax(
    id_releve_occtax, 
    id_nomenclature_obs_technique, 
    id_nomenclature_bio_condition, 
    id_nomenclature_bio_status, 
    id_nomenclature_naturalness, 
    id_nomenclature_exist_proof, 
    --id_nomenclature_diffusion_level, 
    id_nomenclature_observation_status, 
    --id_nomenclature_blurring, 
    id_nomenclature_source_status, 
    id_nomenclature_behaviour, 
    determiner, 
    id_nomenclature_determination_method, 
    cd_nom,
    nom_cite, 
    meta_v_taxref,
    --sample_number_proof, 
    --digital_proof, 
    non_digital_proof, 
    comment, 
    additional_fields
)
SELECT 
    d.id_releve_occtax, 
    d.id_nomenclature_obs_technique, 
    d.id_nomenclature_bio_condition, 
    d.id_nomenclature_bio_status, 
    d.id_nomenclature_naturalness, 
    d.id_nomenclature_exist_proof, 
    --id_nomenclature_diffusion_level, 
    d.id_nomenclature_observation_status, 
    --id_nomenclature_blurring, 
    d.id_nomenclature_source_status, 
    d.id_nomenclature_behaviour, 
    d.determiner, 
    d.id_nomenclature_determination_method, 
    d.cd_nom,
    COALESCE(d.nom_cite, tx.nom_valide), 
    CASE WHEN d.meta_v_taxref IS NULL THEN 17 ELSE d.meta_v_taxref END, -- la valeur par défaut renvoie une erreur et bloque l'insertion => à modifier en fonction de votre GeoNature
    --sample_number_proof, 
    --digital_proof, 
    d.non_digital_proof, 
    d.comment, 
    jsonb_build_object(	
        'fid_import',
        d.fid
    ) as additional_fields
FROM _qgis.import_data d
LEFT JOIN taxonomie.taxref tx USING (cd_nom)
WHERE d.date_import is null and import_valid is true
ORDER BY id_releve_occtax, fid
;
-- ajout des id_occurrence à la table d'import
WITH obs as (
    SELECT
        id_releve_occtax,
        id_occurrence_occtax,
        (additional_fields -> 'fid_import')::integer  as fid
    FROM pr_occtax.t_occurrences_occtax o
    WHERE not additional_fields -> 'fid_import' is null
)
UPDATE _qgis.import_data d
SET id_occurrence_occtax = obs.id_occurrence_occtax
FROM  obs 
WHERE obs.fid = d.fid
AND d.id_occurrence_occtax is null 
AND NOT d.id_releve_occtax is null
;
/*
----------------------------------------------------
INTEGRATION DES DENOMBREMENTS
----------------------------------------------------
*/
-- Intégration des dénombrements
INSERT INTO pr_occtax.cor_counting_occtax(
    id_occurrence_occtax, 
    id_nomenclature_life_stage, 
    id_nomenclature_sex, 
    id_nomenclature_obj_count, 
    id_nomenclature_type_count, 
    count_min,
    count_max, 
    additional_fields
)
SELECT 
    d.id_occurrence_occtax, 
    d.id_nomenclature_life_stage, 
    d.id_nomenclature_sex, 
    d.id_nomenclature_obj_count, 
    d.id_nomenclature_type_count, 
    d.count_min,
    d.count_max, 
    jsonb_build_object(	
        'presence',
        CASE WHEN d.presence = 'true' THEN 'présence' ELSE 'dénombrement' END
    ) as additional_fields
FROM _qgis.import_data d
WHERE d.date_import is null and import_valid is true and not d.id_occurrence_occtax is null
ORDER BY id_occurrence_occtax
;
/*
----------------------------------------------------
COMPLETUDE DE LA TABLE D'IMPORT
----------------------------------------------------
*/
-- Ajout de la date d'import dans la table source afin d'identifier les données déjà intégrées
UPDATE _qgis.import_data d
SET date_import = now()
WHERE d.date_import is null and not id_occurrence_occtax IS NULL
;