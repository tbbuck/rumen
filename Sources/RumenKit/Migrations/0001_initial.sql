-- Rumen app database (SQLite), initial schema (SPEC §7.2).
-- Metadata cache and download bookkeeping only: downloaded data never lives here.
-- Conventions: timestamps are INTEGER microseconds since the Unix epoch (UTC); booleans are
-- INTEGER 0/1; raw server JSON is kept verbatim as TEXT so normalised columns can be re-derived.

CREATE TABLE server (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    root_url            TEXT NOT NULL UNIQUE,        -- normalised .../rest/services
    friendly_name       TEXT NOT NULL,
    origin_override     TEXT,                        -- NULL = server's own origin
    referer_override    TEXT,                        -- NULL = origin + '/'
    auth_kind           TEXT NOT NULL DEFAULT 'none',   -- none | token | api_key
    username            TEXT,                        -- secrets live in the Keychain
    token_service_url   TEXT,
    arcgis_version      REAL,                        -- currentVersion from the root JSON
    created_at          INTEGER NOT NULL,
    last_visited_at     INTEGER,
    last_deep_crawl_at  INTEGER
);

CREATE TABLE service (
    id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id               INTEGER NOT NULL,
    folder_path             TEXT NOT NULL DEFAULT '',   -- '' = root; 'A/B' nested
    name                    TEXT NOT NULL,              -- as listed, e.g. 'Folder/Name'
    type                    TEXT NOT NULL,              -- MapServer | FeatureServer | ...
    url                     TEXT NOT NULL,
    capabilities            TEXT,
    max_record_count        INTEGER,
    supported_query_formats TEXT,
    is_tile_cache           INTEGER,
    extent_wgs84_json       TEXT,                       -- {"minX":…,"minY":…,"maxX":…,"maxY":…}
    raw_json                TEXT,
    fetched_at              INTEGER,
    UNIQUE (server_id, url)
);

CREATE TABLE layer (
    id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    service_id              INTEGER NOT NULL,
    layer_id                INTEGER NOT NULL,          -- the server's numeric id
    name                    TEXT NOT NULL,
    type                    TEXT,                      -- Feature Layer | Group Layer | Table | ...
    is_table                INTEGER NOT NULL DEFAULT 0,
    geometry_type           TEXT,
    parent_layer_id         INTEGER,
    object_id_field         TEXT,
    global_id_field         TEXT,
    has_z                   INTEGER,
    has_m                   INTEGER,
    has_attachments         INTEGER,
    extent_json             TEXT,                      -- native-SR extent, verbatim
    extent_wgs84_json       TEXT,                      -- reprojected at crawl time; NULL if unknown SR
    wkid                    INTEGER,
    latest_wkid             INTEGER,
    max_record_count        INTEGER,
    supported_query_formats TEXT,
    capabilities            TEXT,
    supports_pagination     INTEGER,
    supports_statistics     INTEGER,
    supports_order_by       INTEGER,
    supports_result_type    INTEGER,
    transport               TEXT,                      -- pbf | json | NULL (undecided)
    extractable             INTEGER,                   -- NULL = unknown
    extractable_reason      TEXT,
    sibling_layer_id        INTEGER,                   -- FeatureServer twin (layer.id)
    feature_count           INTEGER,
    feature_count_at        INTEGER,
    raw_json                TEXT,
    fetched_at              INTEGER,
    UNIQUE (service_id, layer_id)
);

CREATE TABLE field (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    layer_id    INTEGER NOT NULL,                      -- layer.id
    position    INTEGER NOT NULL,                      -- order in the layer definition
    name        TEXT NOT NULL,
    alias       TEXT,
    esri_type   TEXT NOT NULL,
    duck_type   TEXT NOT NULL,
    length      INTEGER,
    nullable    INTEGER,
    editable    INTEGER,
    domain_json TEXT,
    UNIQUE (layer_id, name)
);
CREATE INDEX field_name_idx ON field (name COLLATE NOCASE);

CREATE TABLE download (
    id                     INTEGER PRIMARY KEY AUTOINCREMENT,
    layer_id               INTEGER NOT NULL,
    started_at             INTEGER NOT NULL,
    finished_at            INTEGER,
    status                 TEXT NOT NULL,   -- planned | running | paused | failed | cancelled | complete
    transport              TEXT NOT NULL,   -- pbf | json
    strategy               TEXT NOT NULL,   -- offset | oid_range | oid_list | manual
    where_clause           TEXT NOT NULL DEFAULT '1=1',
    out_wkid               INTEGER NOT NULL,
    format                 TEXT NOT NULL,   -- geoparquet | gpkg | geojson | fgb | csv | duckdb
    domain_labels          INTEGER NOT NULL DEFAULT 0,
    staging_path           TEXT,            -- per-run staging DuckDB, removed on completion
    output_path            TEXT,
    output_sha256          TEXT,
    feature_count          INTEGER,
    invalid_geometry_count INTEGER,
    bytes                  INTEGER,
    error                  TEXT
);

CREATE TABLE download_chunk (
    download_id INTEGER NOT NULL,
    seq         INTEGER NOT NULL,
    kind        TEXT NOT NULL,                -- offset | oid_range | oid_list
    lo          INTEGER,                      -- oid_range: first OID
    hi          INTEGER,                      -- oid_range: last OID
    "offset"    INTEGER,                      -- offset: resultOffset
    object_ids  TEXT,                         -- oid_list: comma-separated OIDs
    count       INTEGER,                      -- features received
    status      TEXT NOT NULL,                -- pending | done | failed
    attempts    INTEGER NOT NULL DEFAULT 0,
    last_error  TEXT,
    PRIMARY KEY (download_id, seq)
);

CREATE TABLE query_history (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    layer_id     INTEGER NOT NULL,
    where_clause TEXT NOT NULL,
    out_fields   TEXT,
    ran_at       INTEGER NOT NULL,
    count        INTEGER,
    duration_ms  INTEGER
);

CREATE TABLE setting (
    key   TEXT PRIMARY KEY,
    value TEXT
);
