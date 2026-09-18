-- OGC sources (M10): a server is either an ArcGIS REST root or an OGC endpoint that answers
-- WMS, WFS and WMTS GetCapabilities. An OGC layer keeps the identifier its requests use (the
-- WFS typeName, the WMS layer Name, the WMTS layer Identifier) beside its title, and both the
-- service and the layer keep a normalised JSON detail (version, formats, CRS list, styles, tile
-- matrix sets) that the page, the download planner and the map read.
ALTER TABLE server ADD COLUMN kind TEXT NOT NULL DEFAULT 'arcgis';   -- arcgis | ogc
ALTER TABLE service ADD COLUMN ogc_json TEXT;
ALTER TABLE layer ADD COLUMN ogc_name TEXT;
ALTER TABLE layer ADD COLUMN ogc_json TEXT;
