-- Re-exports of a stored download to another format (M7, SPEC §5.7): one row per file
-- written from a GeoParquet without touching the server. The file itself lives beside the
-- GeoParquet, never in this database.
CREATE TABLE export (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    download_id    INTEGER NOT NULL,     -- download.id the file was read from
    format         TEXT NOT NULL,        -- geojson | csv
    out_wkid       INTEGER NOT NULL,     -- spatial reference of the written geometry
    output_path    TEXT NOT NULL,
    output_sha256  TEXT,
    bytes          INTEGER,
    feature_count  INTEGER,
    created_at     INTEGER NOT NULL
);
CREATE INDEX export_download_idx ON export (download_id);
