-- Real geography for the app icon: Great Britain and Ireland from Overture Maps
-- division areas (OSM, ODbL), generalised to logo grade for a 1024px icon and
-- written as GeoJSON for design/icon/build-icons.mjs.
--
--   duckdb -f design/icon/geography.sql
--
-- Two strengths are written: geography.json (smooth) and geography-bold.json
-- (bolder). Each is: union the land parts, then a morphological closing (buffer
-- out, then in) that fills firths and estuaries, an opening (in, then out) that
-- shaves peninsulas thinner than the radius, then Douglas-Peucker to trim the
-- vertex count, then keep only the two main islands. Distances are degrees.
LOAD spatial;
LOAD httpfs;
SET geometry_always_xy = true;
CREATE SECRET (TYPE S3, PROVIDER config, REGION 'us-west-2');

CREATE TEMP TABLE land AS
  WITH countries AS (
    SELECT geometry
    FROM read_parquet('s3://overturemaps-us-west-2/release/2026-08-19.0/theme=divisions/type=division_area/*')
    WHERE bbox.xmin < 2.5 AND bbox.xmax > -11 AND bbox.ymin < 61 AND bbox.ymax > 49
      AND class = 'land'
      AND subtype = 'country'
      AND country IN ('GB', 'IE')
  ),
  parts AS (
    SELECT UNNEST(ST_Dump(geometry), recursive := true) FROM countries
  )
  -- Drop skerries and Shetland (north of 59.5) before merging.
  SELECT ST_Union_Agg(geom) AS geom
  FROM parts
  WHERE ST_Area(geom) > 0.04 AND ST_YMin(geom) < 59.5;

-- Smooth: closing 0.08, opening 0.04, simplify 0.025.
COPY (
  WITH shaped AS (
    SELECT ST_Simplify(ST_Buffer(ST_Buffer(ST_Buffer(geom, 0.08), -0.12), 0.04), 0.025) AS geom FROM land
  ),
  parts AS (
    SELECT UNNEST(ST_Dump(geom), recursive := true) FROM shaped
  )
  SELECT ST_Area(geom) AS area, ST_AsGeoJSON(geom) AS geojson
  FROM parts
  WHERE ST_Area(geom) > 0.5
  ORDER BY area DESC
) TO '/Users/tom/Code/Claude/arcgis-explorer/design/icon/geography.json' (FORMAT JSON, ARRAY true);

-- Bold: closing 0.14, opening 0.08, simplify 0.05.
COPY (
  WITH shaped AS (
    SELECT ST_Simplify(ST_Buffer(ST_Buffer(ST_Buffer(geom, 0.14), -0.22), 0.08), 0.05) AS geom FROM land
  ),
  parts AS (
    SELECT UNNEST(ST_Dump(geom), recursive := true) FROM shaped
  )
  SELECT ST_Area(geom) AS area, ST_AsGeoJSON(geom) AS geojson
  FROM parts
  WHERE ST_Area(geom) > 0.5
  ORDER BY area DESC
) TO '/Users/tom/Code/Claude/arcgis-explorer/design/icon/geography-bold.json' (FORMAT JSON, ARRAY true);
