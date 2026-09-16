-- Real geography for the app icon: Great Britain, Ireland and the Isle of Man from
-- Overture Maps division areas (OSM, ODbL), generalised for a 1024px icon and
-- written as GeoJSON for design/icon/build-icons.mjs.
--
--   duckdb -f design/icon/geography.sql
LOAD spatial;
LOAD httpfs;
SET geometry_always_xy = true;
CREATE SECRET (TYPE S3, PROVIDER config, REGION 'us-west-2');

COPY (
  WITH countries AS (
    SELECT names.primary AS name, country, geometry
    FROM read_parquet('s3://overturemaps-us-west-2/release/2026-08-19.0/theme=divisions/type=division_area/*')
    WHERE bbox.xmin < 2.5 AND bbox.xmax > -11 AND bbox.ymin < 61 AND bbox.ymax > 49
      AND class = 'land'
      AND ((subtype = 'country' AND country IN ('GB', 'IE'))
           OR (subtype IN ('country', 'dependency') AND country = 'IM'))
  ),
  parts AS (
    SELECT name, country, UNNEST(ST_Dump(geometry), recursive := true)
    FROM countries
  ),
  -- Keep the landmasses and the larger islands; drop skerries, and Shetland
  -- (north of 59.5), which would stretch the extent for a speck in the corner.
  kept AS (
    SELECT name, country, geom, ST_Area(geom) AS area
    FROM parts
    WHERE ST_Area(geom) > 0.04 AND ST_YMin(geom) < 59.5
  )
  -- Generalise: a morphological closing (buffer out, then in, in degrees) fills the
  -- sea lochs and estuaries that would be hairline notches at Dock size, then
  -- Douglas-Peucker trims the vertex count.
  SELECT name, country, area,
         ST_AsGeoJSON(ST_Simplify(ST_Buffer(ST_Buffer(geom, 0.03), -0.03), 0.015)) AS geojson
  FROM kept
  ORDER BY area DESC
) TO '/Users/tom/Code/Claude/arcgis-explorer/design/icon/geography.json' (FORMAT JSON, ARRAY true);
