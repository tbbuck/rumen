-- WGS 84 bounding boxes for the tree's extent locators (UI-SPEC: ExtentLocator). Derived at
-- crawl time from the native extent via the spatial extension; NULL when the native spatial
-- reference is unknown to PROJ or the extent is empty. Stored as JSON
-- {"minX":…,"minY":…,"maxX":…,"maxY":…}.

ALTER TABLE layer ADD COLUMN extent_wgs84_json VARCHAR;
ALTER TABLE service ADD COLUMN extent_wgs84_json VARCHAR;
