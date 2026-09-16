-- Real geography for the app icon: the Isle of Wight (the feature) and the mainland
-- counties behind it (Hampshire, Dorset, West Sussex), from Overture Maps division
-- areas (ODbL via OSM).
-- Simplified for a 1024px icon and written as GeoJSON for design/icon/build-icons.mjs.
LOAD spatial;
LOAD httpfs;
SET geometry_always_xy = true;
CREATE SECRET (TYPE S3, PROVIDER config, REGION 'us-west-2');

COPY (
  WITH areas AS (
    SELECT names.primary AS name, subtype, geometry
    FROM read_parquet('s3://overturemaps-us-west-2/release/2026-08-19.0/theme=divisions/type=division_area/*')
    WHERE bbox.xmin < -0.8 AND bbox.xmax > -1.9 AND bbox.ymin < 51.1 AND bbox.ymax > 50.4
      AND country = 'GB'
      AND subtype = 'county'
      AND names.primary IN ('Isle of Wight', 'Hampshire', 'Dorset', 'West Sussex')
  )
  -- Generalise for icon use: a morphological closing (buffer out, then in by the
  -- same amount, in degrees) fills narrow estuaries and harbours that would read as
  -- hairline spikes at Dock size, then Douglas-Peucker trims the vertex count.
  SELECT name, subtype,
         ST_AsGeoJSON(ST_Simplify(ST_Buffer(ST_Buffer(geometry, 0.006), -0.006), 0.0015)) AS geojson
  FROM areas
) TO '/Users/tom/Code/Claude/arcgis-explorer/design/icon/geography.json' (FORMAT JSON, ARRAY true);
