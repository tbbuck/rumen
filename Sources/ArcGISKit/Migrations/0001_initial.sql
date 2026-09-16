-- ArcGIS Explorer app database, initial schema (SPEC §7.2).
-- No function-call column defaults: DuckDB cannot bind them when replaying a write-ahead log
-- after an unclean exit. Ids are allocated with nextval() in the INSERT statements instead.
-- Metadata cache and download bookkeeping only: downloaded data never lives here.
-- Raw server JSON is kept verbatim as VARCHAR so normalised columns can be re-derived.

CREATE SEQUENCE seq_server START 1;
CREATE TABLE server (
    id                  BIGINT PRIMARY KEY,
    root_url            VARCHAR NOT NULL UNIQUE,     -- normalised .../rest/services
    friendly_name       VARCHAR NOT NULL,
    origin_override     VARCHAR,                     -- NULL = server's own origin
    referer_override    VARCHAR,                     -- NULL = origin + '/'
    auth_kind           VARCHAR NOT NULL DEFAULT 'none',  -- none | token | api_key
    username            VARCHAR,                     -- secrets live in the Keychain
    token_service_url   VARCHAR,
    arcgis_version      DOUBLE,                      -- currentVersion from the root JSON
    created_at          TIMESTAMP NOT NULL,
    last_visited_at     TIMESTAMP,
    last_deep_crawl_at  TIMESTAMP
);

CREATE SEQUENCE seq_service START 1;
CREATE TABLE service (
    id                      BIGINT PRIMARY KEY,
    server_id               BIGINT NOT NULL,
    folder_path             VARCHAR NOT NULL DEFAULT '',   -- '' = root; 'A/B' nested
    name                    VARCHAR NOT NULL,              -- as listed, e.g. 'Folder/Name'
    type                    VARCHAR NOT NULL,              -- MapServer | FeatureServer | ...
    url                     VARCHAR NOT NULL,
    capabilities            VARCHAR,
    max_record_count        INTEGER,
    supported_query_formats VARCHAR,
    is_tile_cache           BOOLEAN,
    raw_json                VARCHAR,
    fetched_at              TIMESTAMP,
    UNIQUE (server_id, url)
);

CREATE SEQUENCE seq_layer START 1;
CREATE TABLE layer (
    id                      BIGINT PRIMARY KEY,
    service_id              BIGINT NOT NULL,
    layer_id                INTEGER NOT NULL,          -- the server's numeric id
    name                    VARCHAR NOT NULL,
    type                    VARCHAR,                   -- Feature Layer | Group Layer | Table | ...
    is_table                BOOLEAN NOT NULL DEFAULT FALSE,
    geometry_type           VARCHAR,
    parent_layer_id         INTEGER,
    object_id_field         VARCHAR,
    global_id_field         VARCHAR,
    has_z                   BOOLEAN,
    has_m                   BOOLEAN,
    has_attachments         BOOLEAN,
    extent_json             VARCHAR,                   -- native-SR extent, verbatim
    wkid                    INTEGER,
    latest_wkid             INTEGER,
    max_record_count        INTEGER,
    supported_query_formats VARCHAR,
    capabilities            VARCHAR,
    supports_pagination     BOOLEAN,
    supports_statistics     BOOLEAN,
    supports_order_by       BOOLEAN,
    supports_result_type    BOOLEAN,
    transport               VARCHAR,                   -- pbf | json | NULL (undecided)
    extractable             BOOLEAN,                   -- NULL = unknown
    extractable_reason      VARCHAR,
    sibling_layer_id        BIGINT,                    -- FeatureServer twin (layer.id)
    feature_count           BIGINT,
    feature_count_at        TIMESTAMP,
    raw_json                VARCHAR,
    fetched_at              TIMESTAMP,
    UNIQUE (service_id, layer_id)
);

CREATE SEQUENCE seq_field START 1;
CREATE TABLE field (
    id          BIGINT PRIMARY KEY,
    layer_id    BIGINT NOT NULL,                       -- layer.id
    position    INTEGER NOT NULL,                      -- order in the layer definition
    name        VARCHAR NOT NULL,
    alias       VARCHAR,
    esri_type   VARCHAR NOT NULL,
    duck_type   VARCHAR NOT NULL,
    length      INTEGER,
    nullable    BOOLEAN,
    editable    BOOLEAN,
    domain_json VARCHAR,
    UNIQUE (layer_id, name)
);

CREATE SEQUENCE seq_download START 1;
CREATE TABLE download (
    id                     BIGINT PRIMARY KEY,
    layer_id               BIGINT NOT NULL,
    started_at             TIMESTAMP NOT NULL,
    finished_at            TIMESTAMP,
    status                 VARCHAR NOT NULL,   -- planned | running | paused | failed | cancelled | complete
    transport              VARCHAR NOT NULL,   -- pbf | json
    strategy               VARCHAR NOT NULL,   -- offset | oid_range | oid_list | manual
    where_clause           VARCHAR NOT NULL DEFAULT '1=1',
    out_wkid               INTEGER NOT NULL,
    format                 VARCHAR NOT NULL,   -- geoparquet | gpkg | geojson | fgb | csv | duckdb
    domain_labels          BOOLEAN NOT NULL DEFAULT FALSE,
    staging_path           VARCHAR,            -- per-run staging DuckDB, removed on completion
    output_path            VARCHAR,
    output_sha256          VARCHAR,
    feature_count          BIGINT,
    invalid_geometry_count BIGINT,
    bytes                  BIGINT,
    error                  VARCHAR
);

CREATE TABLE download_chunk (
    download_id BIGINT NOT NULL,
    seq         INTEGER NOT NULL,
    kind        VARCHAR NOT NULL,              -- offset | oid_range | oid_list
    lo          BIGINT,                        -- oid_range: first OID
    hi          BIGINT,                        -- oid_range: last OID
    "offset"    BIGINT,                        -- offset: resultOffset
    object_ids  VARCHAR,                       -- oid_list: comma-separated OIDs
    count       BIGINT,                        -- features received
    status      VARCHAR NOT NULL,              -- pending | done | failed
    attempts    INTEGER NOT NULL DEFAULT 0,
    last_error  VARCHAR,
    PRIMARY KEY (download_id, seq)
);

CREATE SEQUENCE seq_query_history START 1;
CREATE TABLE query_history (
    id           BIGINT PRIMARY KEY,
    layer_id     BIGINT NOT NULL,
    where_clause VARCHAR NOT NULL,
    out_fields   VARCHAR,
    ran_at       TIMESTAMP NOT NULL,
    count        BIGINT,
    duration_ms  BIGINT
);

CREATE TABLE setting (
    key   VARCHAR PRIMARY KEY,
    value VARCHAR
);
