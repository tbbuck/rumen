# ArcGIS Explorer — Specification

> Status: **Draft** · 2026-09-16 · Target DuckDB **v1.5.5+** · macOS **26+**

A native macOS application for pointing at any **ArcGIS REST endpoint** (Server,
Enterprise, or Online), understanding what it exposes, querying layers read-only,
and **pulling complete layers down** into local files — GeoParquet by default — via
the most efficient transport the server supports. It is the sibling of
[DuckLake Explorer](../ducklake-explorer/SPEC.md) and reuses its engine layer,
project shape, and map embedding.

---

## 1. Vision

Paste a URL — a services root, a folder, a MapServer, a FeatureServer, a single
layer, even a `/query` URL someone sent you — and get, in one window:

- the **shape** of the server: folders, services, layers, tables, fields, types,
  extents, spatial references;
- an honest answer to **"can I extract features from this?"**, per layer, with the
  reason when the answer is no;
- a **query view** for read-only `where` clauses, counts, and paged previews;
- a **download engine** that picks the right pagination strategy, decodes Esri's
  PBF, survives flaky servers, resumes, and writes GeoParquet (or other formats);
- **column search** across every layer the app has ever seen, on this server or all
  of them;
- a **map** for previewing a live layer or a stored download.

It remembers every server it has visited, lets the user name them, and caches all
metadata so browsing and searching are instant even when the server is slow.

## 2. Goals & Non-goals

**Goals**
- Open any ArcGIS REST URL; normalise it; work out where in the hierarchy it points.
- Crawl and cache service and layer metadata; refresh on demand; show staleness.
- Detect feature-extractability per layer, including on MapServer layers that mix
  raster and feature content.
- Download complete layers via PBF where offered, falling back to Esri JSON, with
  automatic strategy selection and a manual override when nothing works.
- Export to **GeoParquet** by default; also GeoPackage, GeoJSON, FlatGeobuf, CSV.
- Downloads and exports live **outside** the app database, always.
- Search cached field metadata by name, case-insensitive and partial by default.
- Preview layers and stored data on a MapLibre GL map.
- Token authentication for secured services; no OAuth.
- Faithful error reporting: surface the server's or DuckDB's own message, never
  swallow it.

**Non-goals (v1)**
- **No writes to any server.** No applyEdits, no admin API, no publishing.
- **No OAuth / IWA / PKI / SAML** sign-in. ArcGIS token auth only.
- **No image service or tile cache extraction.** ImageServer and cached tile
  layers are listed and described, not downloaded.
- **No attachments download** and **no relationships or related records** (the
  `hasAttachments` flag is recorded and shown; nothing is fetched).
- Not cross-platform; not a general GIS; not a replacement for ArcGIS Pro.

## 3. Users & primary use cases

Primary user: a geospatial and data engineer who needs data *out* of ArcGIS servers
and into DuckDB, Parquet, and friends, without ArcGIS tooling.

1. "Someone sent me a MapServer URL. What is actually in there, and can I get the
   features out?"
2. "Give me the whole of layer 3 as GeoParquet, with real precision, in 4326."
3. "Which layers on this council's server have a `UPRN` column?"
4. "Show me what this layer looks like before I commit to a 2M-feature download."
5. "That download died at 60% overnight. Resume it."
6. "This server needs a token. Let me sign in once and forget about it."

## 4. Domain glossary (ArcGIS REST)

| Term | Meaning in this app |
|---|---|
| **Server root** | `https://host/<instance>/rest/services` (instance often `arcgis`; ArcGIS Online is `https://services*.arcgis.com/<orgId>/arcgis/rest/services`). The unit we remember and name. |
| **Folder** | A grouping under the root; `?f=json` on the root lists `folders` and `services`. |
| **Service** | `<name>/<type>` where type is `MapServer`, `FeatureServer`, `ImageServer`, `GPServer`, etc. Only Map and Feature services carry queryable layers. |
| **Layer** | A numbered child of a service (`…/FeatureServer/3`). Has a `type` (`Feature Layer`, `Group Layer`, `Raster Layer`, `Annotation Layer`, …), a `geometryType`, `fields`, and capability flags. |
| **Table** | A layer with no geometry; listed under `tables` in the service JSON. Downloadable like a layer, minus geometry. |
| **Capabilities** | Service and layer strings such as `Map,Query,Data`. `Query` is the gate for feature extraction. |
| **supportedQueryFormats** | Layer string such as `JSON, geoJSON, PBF`. Decides the transport. |
| **advancedQueryCapabilities** | Layer object carrying `supportsPagination`, `supportsStatistics`, `supportsOrderBy`, `supportsQueryWithResultType`, `supportsReturningQueryExtent`, and more. Decides the pagination strategy. |
| **maxRecordCount** | Server-imposed page size ceiling for a query. |
| **exceededTransferLimit** | Response flag meaning "there is more"; the loop condition for paging. |
| **OID** | The `objectIdField`; the only stable ordering key and the basis of range chunking. |
| **PBF** | Esri's `FeatureCollection` protobuf (**not** Mapbox Vector Tiles). Quantised, delta-encoded geometry with a `transform` to dequantise. |
| **Token** | An ArcGIS token from `generateToken`, sent as a `token` parameter. Stored in the Keychain. |

## 5. Functional requirements

### 5.1 URL intake & server registry
- Accept **any** pasted URL in the hierarchy: root, folder, service, layer, `/query`,
  or an ArcGIS Online item page. Normalise it (strip `f=`, trailing slashes, query
  strings) and resolve it to `(server root, optional folder, optional service,
  optional layer)`. Reject clearly non-ArcGIS URLs with a specific message.
- Register the **server root** with a **friendly name** (default: the host). Record
  `currentVersion` from the root JSON.
- Per server, the request headers are:
  - `Origin`: the server's own origin (`https://host`), overridable.
  - `Referer`: the server's own origin plus a trailing slash (`https://host/`),
    overridable.
  - Overrides are stored per server and editable in the server's settings sheet.
- **Recents** list ordered by last visit; rename, forget, and re-crawl actions.
- Opening a pasted URL that belongs to a known server selects that server and
  navigates to the target node rather than creating a duplicate.

### 5.2 Crawl & cache
- **Shallow crawl on add**: root → folders → service lists. Cheap, always done. Every folder
  listed is recorded with the outcome of listing it; a folder that fails keeps whatever was
  cached beneath it, shows its error in the tree and on its page, and offers Retry there.
- **Service crawl on select**: a service's `?f=json` (layers, tables, capabilities,
  `maxRecordCount`, `supportedQueryFormats`), then its layer definitions. Prefer the
  bulk `…/MapServer/layers?f=json` (also on FeatureServer) — one request per service —
  and fall back to per-layer requests when it is missing or errors.
- **Deep crawl on demand**: every service and layer under a server, in the
  background with a progress indicator and cancel. Required for column search
  across a whole server. Concurrency is capped per host (default 4).
- Everything fetched is stored twice: the **raw JSON** (verbatim, for a raw view and
  for re-deriving normalised columns later) and **normalised rows** (see §7.2).
  `fetched_at` is kept on every row; the UI shows age and offers **Refresh** at
  server, service, and layer level.
- Cache reads never hit the network. Network happens only on add, select of an
  uncrawled node, explicit refresh, deep crawl, query, or download.

### 5.3 Feature-extractability detection
For every layer the app answers **Extractable / Not extractable / Unknown** with a
reason, computed from cached metadata plus one optional probe:

1. Layer `type` is `Feature Layer` (or the node is a table). `Group Layer`,
   `Raster Layer`, `Annotation`, `Dimension`, and network layers are **not**.
2. Layer or service `capabilities` contains `Query`. If absent: **not**.
3. `supportedQueryFormats` decides transport: `PBF` → PBF; else `JSON` → Esri JSON.
   `geoJSON` is noted but never used for download (precision and ring semantics).
4. Pagination flags decide strategy (§5.5).
5. **Probe** (on demand, and automatically before a download):
   `query?where=1=1&returnCountOnly=true&f=json`. A count confirms extractability
   and stores `feature_count`; an error envelope stores the reason.
6. **Sibling FeatureServer check**: for a MapServer layer, also look for
   `…/FeatureServer/<id>` under the same service name. Many servers publish both, and
   the FeatureServer twin often offers PBF and pagination the MapServer does not.
   Prefer the twin for download when it is extractable; record the link.

A MapServer with `tileInfo` / `singleFusedMapCache: true` is flagged as **cached
tiles** at service level; its layers are still assessed individually.

### 5.4 Layer inspector
For a selected layer or table:
- **Overview**: name, id, type, geometry type, extent (native SR and 4326),
  `sourceSpatialReference`, `objectIdField`, `globalIdField`, `hasZ`/`hasM`,
  `hasAttachments`, `maxRecordCount`, `supportedQueryFormats`, capabilities,
  pagination and statistics support, feature count (cached, with a Refresh),
  extractability verdict and reason, sibling FeatureServer link.
- **Fields**: name, alias, Esri type, mapped DuckDB type (§5.6), length, nullable,
  editable, domain (coded values shown inline).
- **Raw**: the layer JSON, pretty-printed and searchable.
- **Query**, **Download**, **Map** tabs (§5.5, §5.7, §5.9).

### 5.5 Read-only query
- `where` editor (default `1=1`), `outFields` picker (default all), `outSR` choice
  (native or 4326), optional `orderByFields`, `returnGeometry` toggle.
- Actions: **Count** (`returnCountOnly`), **Extent** (`returnExtentOnly`),
  **Preview** (first page, `resultRecordCount` = min(maxRecordCount, 500)),
  **Distinct values** of one field (`returnDistinctValues`), **Statistics**
  (`outStatistics` min/max/count) where `supportsStatistics`.
- Results in an `NSTableView`-backed grid (same component as DuckLake Explorer),
  geometry rendered as WKT summary, dates as ISO 8601.
- Query history per layer (where, outFields, count, duration) in the app DB.
- Read-only by construction: the app only ever calls `query`, `generateToken`, and
  metadata endpoints. Nothing else is reachable from the UI.

### 5.6 Download engine

**Transport**
- `f=pbf` when the layer advertises `PBF`; decoded by a SwiftProtobuf-generated
  decoder from Esri's `FeatureCollection.proto` (`arcgis-pbf` repo, Apache-2.0,
  vendored under `Sources/ArcGISKit/Proto/`). Geometry is dequantised with the
  response `transform` (scale, translate, upper-left origin with Y flipped).
- `f=json` (Esri JSON) otherwise, or when PBF decoding fails for a layer (recorded
  as a per-layer preference so the fallback sticks).
- Always `POST` to `/query` with a form body; URLs with long `objectIds` or `where`
  lists would otherwise exceed server limits.
- `outSR` defaults to the layer's **native** spatial reference (first use showed that is
  what a GIS user reaches for); WGS 84 is the other option. Either way the CRS is recorded
  in the GeoParquet metadata.
- `returnZ` and `returnM` are set from the layer's `hasZ`/`hasM`.

**Strategy selection (automatic, in order)**
1. **Offset paging** — requires `advancedQueryCapabilities.supportsPagination`
   (or legacy `supportsPagination`). Page size = `maxRecordCount`; on hosted
   services with `supportsQueryWithResultType`, PBF pages may use
   `resultType=tile` and `maxRecordCountFactor` to enlarge pages. Always
   `orderByFields=<oid> ASC` so pages are stable. Loop while
   `exceededTransferLimit` is true.
2. **OID range chunking** — when paging is unsupported but statistics are:
   `outStatistics` min/max of the OID, then `where <oid> >= lo AND <oid> <= hi`
   in windows sized `maxRecordCount`. If a window still reports
   `exceededTransferLimit`, split it.
3. **OID list chunking** — when statistics are unsupported: `returnIdsOnly=true`
   once, then `objectIds=` batches of `maxRecordCount`. The ID fetch is capped
   (default 5M); past the cap the run pauses and asks for a manual partitioning
   `where` template instead.
4. **Manual** — offered in the UI only when 1–3 all fail: the user picks a page
   size, a strategy, and optionally a partitioning `where` template. The choice is
   remembered per layer.

**Execution**
- Chunks are planned up front (paging: lazily, until the flag clears) and recorded
  in `download_chunk` so a run is **resumable** after a crash, a quit, or a server
  outage. Resume re-plans nothing; it retries incomplete chunks.
- Concurrency per host is configurable (default 4). Chunks are fetched in parallel
  and appended in arrival order; ordering within the output is by OID at export.
- **Retry** on transport errors, HTTP 429/5xx, and ArcGIS error envelopes with codes
  that indicate transient failure, using exponential backoff with jitter (default
  5 attempts). Token errors (498/499) pause the download and prompt for auth.
- Each chunk's features are appended to a **staging DuckDB database** (one file per
  download, under Application Support, never the app DB) via the C Appender API,
  geometry as WKB into a `GEOMETRY` column.
- Every chunk validates that the received count matches expectations; a short
  chunk with `exceededTransferLimit` false is fine, a short chunk with it true is an
  error, not a warning.
- On completion the staging table is exported (§5.7) and the staging file removed.
  Progress (chunks, features, bytes, rate, ETA) is shown in a **Downloads** pane;
  runs are cancellable and their records persist.

**Geometry conversion**
- Esri point / multipoint / polyline / polygon → OGC WKB. Polylines with several
  paths become `MULTILINESTRING`. Polygons follow the Esri ring convention: outer
  rings clockwise, holes anticlockwise; holes are assigned to the outer ring that
  contains their first vertex; several outer rings become `MULTIPOLYGON`.
- Validity is checked in tests with the spatial extension, never silently repaired
  at download time. An invalid-geometry count is reported at the end of a run.

**Field type mapping**

| Esri type | DuckDB type |
|---|---|
| `esriFieldTypeOID`, `BigInteger` | `BIGINT` |
| `Integer` | `INTEGER` |
| `SmallInteger` | `SMALLINT` |
| `Double` | `DOUBLE` |
| `Single` | `FLOAT` |
| `String`, `XML` | `VARCHAR` |
| `Date` | `TIMESTAMP` (epoch milliseconds, UTC) |
| `DateOnly` | `DATE` |
| `TimeOnly` | `TIME` |
| `TimestampOffset` | `TIMESTAMPTZ` |
| `GUID`, `GlobalID` | `UUID` (falls back to `VARCHAR` on parse failure) |
| `Blob` | `BLOB` |
| `Geometry` | `GEOMETRY` |
| `Raster` | skipped, noted in the run summary |

Coded-value domains are exported as the raw code; an opt-in option (off by default) adds a sibling
`<field>_label` column decoded from the domain.

### 5.7 Export
- **GeoParquet** is the default: `COPY … TO '<path>' (FORMAT PARQUET)` from the
  staging table with the `GEOMETRY` column, which lets the spatial extension write
  the `geo` metadata (CRS, geometry types, bbox). Verify the exact behaviour and
  options against the DuckDB docs index at implementation time, not from memory.
- **GeoJSON** through the spatial extension's GDAL writer (`COPY … (FORMAT gdal, DRIVER
  'GeoJSON')`, RFC 7946, so always WGS 84: the download reprojects to it and the SR picker
  is locked) and **CSV** through DuckDB's writer with the geometry as WKT in a `geometry`
  column, in the chosen SR. GeoPackage, FlatGeobuf, and a plain DuckDB file are the same
  one-line additions if ever wanted (the GDAL drivers are present); not offered in v1.
- Output location: a user-chosen directory (default
  `~/Documents/ArcGIS Explorer/`), laid out `<server friendly name>/<service>/
  <layer>.<ext>`. Existing files are never overwritten without confirmation.
- **Exports and downloads never live inside the app database.** The app DB holds
  only the `download` record with the output path and a content hash.
- A stored download can be **re-exported** to another format without touching the
  server, by reading the GeoParquet back through DuckDB: the file lands beside the
  GeoParquet with the format's extension and is recorded in `export`. The layer's
  **Stored** tab is where that happens, alongside a grid over the file, a DuckDB SQL
  scratch box (the file is the table `data`), row count, size, and open-in-Finder.

### 5.8 Column search
- Searches the cached `field` table by **name** and optionally **alias**.
- Options: case-insensitive (default on), partial match (default on; off means
  exact), regex (off), scope **current server** or **all servers**.
- Results: field, layer, service, server, with the field's type and the layer's
  extractability; double-click navigates to the layer.
- If the current server has uncrawled services the results view says so and offers
  the deep crawl.

### 5.9 Visualisation
- **MapLibre GL in a `WKWebView`**, exactly as in DuckLake Explorer's `GeoMapView`:
  the page is loaded from a string, data is injected as GeoJSON via
  `evaluateJavaScript`, MapTiler `dataviz` / `dataviz-dark` basemaps follow the
  system appearance, and the MapTiler key is read at run time from the `MAPTILER_API_KEY`
  environment variable (`launchctl setenv` makes it visible to Dock launches), falling back
  to a plist value that dev builds get from `Config/maptiler.local.xcconfig` (untracked) →
  `Info.plist` → `MapConfig`. Releases bake nothing. **No key is ever committed.**
- **Live layer preview**: the layer's extent as a rectangle, plus a bounded sample of
  features (`resultRecordCount` ≤ 800, `outSR=4326`, `geometryPrecision=6`), with a
  note that it is a sample.
- **Stored data map**: features from a downloaded GeoParquet via DuckDB
  `ST_AsGeoJSON`, simplified for display when the count is large, with a `where`
  filter box that runs as DuckDB SQL over the file.
- **Query results map**: the current preview page's geometries.

### 5.10 Authentication
- Per-server **ArcGIS token** auth: username + password → `generateToken`
  (`…/rest/generateToken` on Server; `…/sharing/rest/generateToken` on Portal
  and Online, discovered from the root JSON or the `authInfo.tokenServicesUrl`
  field). `client=referer` with the server's referer value.
- Tokens and passwords go in the **macOS Keychain**; the app DB stores the username
  and the token service URL only. Tokens are refreshed on 498/499 responses.
- An API key can be pasted instead of a username/password and is sent the same way.
- A raw **Cookie** header can be set per server (the add sheet's Advanced section and
  server settings), sent verbatim on every request like curl's `-b`, with the session's own
  cookie handling off for that server. It is stored on the server row in the app DB
  (decision 17): a first cut kept it in the Keychain, which prompted on every rebuild for
  what is a low-value session cookie. Tokens and passwords still go in the Keychain.

## 6. Non-functional requirements

### 6.1 Performance
- The UI never blocks on network or DuckDB. All I/O runs off the main actor.
- A server with thousands of layers browses instantly from cache.
- A 5M-feature download must complete without unbounded memory: chunks stream into
  the staging DB and are released.

### 6.2 Concurrency model
- Swift 6 language mode with strict concurrency. Network and DB access live behind
  actors; models are `@Observable` and main-actor bound; DTOs are `Sendable`.
- One DuckDB connection is not safe for concurrent use; each staging database and
  the app database are owned by their own actor (the `DuckDBKit` pattern).
- Per-host request concurrency is a semaphore in the network layer, shared by
  crawl, query, and download so the app never exceeds the cap in aggregate.

### 6.3 Error handling
- Per the tree standard: **return or surface errors, never log-and-continue.**
  ArcGIS error envelopes (HTTP 200 with `{"error": {...}}`) are parsed into typed
  errors and shown verbatim with the URL that produced them. DuckDB errors are shown
  verbatim. Only DEBUG logging for pure optimisations (e.g. a count prefetch) may
  swallow.

### 6.4 Security & privacy
- Read-only against servers by construction. No telemetry.
- Credentials only in the Keychain; the app DB never contains a secret or a token.
- Header overrides are per server and visible; the app never sends headers to any
  host other than the one they were configured for.

## 7. Architecture

### 7.1 Modules
- **`ArcGISCore`** (SPM package at the repo root, `swift test`-able headlessly):
  - **`SQLiteKit`**: a thin wrapper over the system SQLite (WAL journal, prepared
    statements, typed values) and the **migration runner**. The app database lives here.
  - `CDuckDB` system module + **`DuckDBKit`**: copied from DuckLake Explorer as the
    starting point, plus an **Appender** wrapper and prepared statements. DuckDB is the
    spatial and data engine only: extent reprojection, download staging, export, map.
    Extracting a shared package across the two apps is a later, optional refactor.
  - **`ArcGISKit`**: URL normalisation, REST DTOs, the client (headers, retries,
    error envelopes, token refresh), the crawler, extractability rules, the PBF
    decoder, Esri JSON and PBF → WKB conversion, strategy selection, and the
    download planner/executor. No UI, no AppKit.
- **App target** (`Sources/App`, generated by xcodegen from `project.yml`): SwiftUI
  shell, `NSTableView` grid and `WKWebView` map via `NSViewRepresentable`, the
  `AppModel`, panes, sheets, preferences.

### 7.2 App database (SQLite, one file)
Located at `~/Library/Application Support/ArcGIS Explorer/explorer.sqlite`, WAL journal
mode. Timestamps are INTEGER microseconds since the Unix epoch; booleans INTEGER 0/1. Schema is
owned by numbered SQL migration files in `Sources/ArcGISKit/Migrations/`
(`0001_initial.sql`, …), applied in order by the runner and recorded in
`schema_migrations`. **No ad-hoc DDL anywhere else.**

Tables (initial):
- `server` — id, root_url, friendly_name, origin_override, referer_override,
  auth_kind, username, token_service_url, arcgis_version, created_at,
  last_visited_at, last_deep_crawl_at.
- `folder` — id, server_id, path, parent_path, name, last_error, fetched_at: every folder a
  directory listed, with the outcome of listing it, so a folder that could not be read (a
  500, a timeout, a permission wall) still has a place in the tree, with its error and a
  Retry (M8). Servers cached before this table existed still get their folders from the
  paths of the services under them.
- `service` — id, server_id, folder_path, name, type, url, capabilities,
  max_record_count, supported_query_formats, is_tile_cache, raw JSON, fetched_at.
- `layer` — id, service_id, layer_id, name, type, geometry_type, parent_layer_id,
  object_id_field, global_id_field, has_z, has_m, has_attachments, extent (JSON),
  wkid, latest_wkid, max_record_count, supported_query_formats, capabilities,
  supports_pagination, supports_statistics, supports_order_by,
  supports_result_type, transport ('pbf' | 'json' | null), extractable
  (true/false/null), extractable_reason, sibling_layer_id, feature_count,
  feature_count_at, raw JSON, fetched_at.
- `field` — id, layer_id, name, alias, esri_type, duck_type, length, nullable,
  editable, domain JSON.
- `download` — id, layer_id, started_at, finished_at, status, transport, strategy,
  where_clause, out_wkid, format, output_path, output_sha256, feature_count,
  invalid_geometry_count, bytes, error.
- `download_chunk` — download_id, seq, kind, lo, hi, offset, count, status,
  attempts, last_error.
- `export` — id, download_id, format, out_wkid, output_path, output_sha256, bytes,
  feature_count, created_at: a re-export of a stored download to another format (M7).
- `query_history` — id, layer_id, where_clause, out_fields, ran_at, count,
  duration_ms.
- `setting` — key, value.

Extents are stored as JSON text: the native one verbatim and a WGS 84 box reprojected at
crawl time through an in-memory DuckDB with the spatial extension (the "spatial engine",
owned by `AppDatabase`). DuckDB never holds app state.

### 7.3 Networking
- `URLSession` with a per-server `Origin` / `Referer` header set, a shared per-host
  semaphore, and a retry policy object. Every request goes through one
  `ArcGISClient` so the header rule cannot be bypassed.
- Fixture-driven tests use a custom `URLProtocol` that serves recorded responses
  from `Fixtures/`.

### 7.4 Engine
- Same as DuckLake Explorer: link Homebrew `libduckdb` in dev
  (`/opt/homebrew/opt/duckdb/lib`, header via `Sources/CDuckDB/module.modulemap`);
  distribution bundles libduckdb into `Contents/Frameworks` and autoinstalls the
  `spatial` extension at first run under `disable-library-validation` (the
  `.duckdb_extension` signature footer cannot be notarised —
  [duckdb#16926](https://github.com/duckdb/duckdb/issues/16926)). A packaged build
  (detected by the bundled dylib) sets DuckDB's default configuration at launch, before any
  engine opens, so every engine (spatial, staging, re-export, stored files) resolves
  extensions from the per-user folder; dev builds keep `~/.duckdb`.
- Extensions needed: **`spatial`** only (plus `httpfs` if a remote export target is
  ever added). Verify every spatial function signature against the DuckDB docs
  index before use.

### 7.5 Build & tooling
- `Package.swift` (engine + kit + tests) and `project.yml` (xcodegen, app target,
  `SWIFT_VERSION: 6.0`, macOS 26 deployment target, ad-hoc signing in dev).
- Build via `claude-scripts/build_app.sh`; tests via `swift test`.
- CI: `.github/workflows/ci.yml` on `macos-26` (build + `swift test`).
- Release (M9): `scripts/release.sh` builds Release, bundles `libduckdb` into
  `Contents/Frameworks` (`scripts/bundle-duckdb-engine.sh`, rewriting the install name and
  rpath so Homebrew is not needed), signs with Developer ID and the hardened runtime under
  `Config/ArcGISExplorer.entitlements` (only `disable-library-validation`, for the
  DuckDB-signed extension), runs the signed binary's `--selftest` (which installs `spatial`
  into `~/Library/Application Support/ArcGIS Explorer/duckdb-extensions` on a clean Mac and
  reprojects a point), notarises and staples, and packages a DMG. `.github/workflows/
  release.yml` runs it on a `v*` tag and attaches the DMG to a GitHub Release; the secrets it
  needs are listed at the top of the file. `SKIP_NOTARIZE=1` runs everything but the
  notarisation locally.
- SwiftProtobuf is the one third-party runtime dependency (for the PBF decoder).
  Generated Swift from the vendored `.proto` is committed so builds need no
  `protoc`.

## 8. Testing strategy
- **Unit** (in `Tests/ArcGISKitTests`, no network): URL normalisation table;
  extractability rules over recorded layer JSON (Feature, Group, Raster, table,
  no-Query, PBF/JSON variants); strategy selection over capability combinations;
  PBF decode of recorded responses, including dequantisation against the same
  features fetched as JSON; Esri geometry → WKB for every geometry type including
  multi-ring polygons with holes; field type mapping; the paging loop and the
  chunk planner against a fake server (short page, exceededTransferLimit
  mismatch, 429 then success, token expiry mid-run); resume after a simulated
  crash; migration runner idempotence.
- **Engine** (in `Tests/DuckDBKitTests`): appender round trip, GeoParquet export
  readable back with intact CRS and geometry.
- **Integration** (opt-in, network, behind an environment check in a script under
  `claude-scripts/`): a small public layer end to end.
- **Fixtures**: recorded JSON and PBF from public servers checked into `Fixtures/`,
  with a script that re-records them.

## 9. Decisions log
1. **PBF via SwiftProtobuf + vendored Esri proto** — accepted 2026-09-16.
2. **Strategy chosen automatically; manual override only once auto fails** —
   accepted 2026-09-16.
3. **MapServer layers downloadable when queryable; image services listed only** —
   accepted 2026-09-16. Extractability detection is a first-class feature.
4. **Origin = server origin, Referer = origin + `/`, both overridable per server** —
   accepted 2026-09-16.
5. **Single app database for metadata; downloads and exports always outside it** —
   accepted 2026-09-16. Originally DuckDB; the engine changed to SQLite in decision 16.
6. **GeoParquet default export** — accepted 2026-09-16.
7. **Read-only means no server mutation and no sign-in beyond tokens** — accepted
   2026-09-16. ArcGIS token auth in scope; OAuth out.
8. **Column search scoped to current server or all servers, selectable** —
   accepted 2026-09-16.
9. **MapLibre GL in a WKWebView, MapTiler basemaps, key via untracked xcconfig** —
   accepted 2026-09-16, same mechanism as DuckLake Explorer.
10. **macOS 26, Swift 6 strict concurrency, SPM + xcodegen** — accepted 2026-09-16.
11. **No attachments download** — accepted 2026-09-16. `hasAttachments` is still
    recorded and shown in the inspector; nothing is fetched.
12. **No relationships / related records** — accepted 2026-09-16. Not exposed in
    the UI at all; the raw JSON view is the only place they appear.
13. **Coded-domain label columns are opt-in** — accepted 2026-09-16. Off by
    default; a per-download toggle and a preference for the default.
14. **Very large `returnIdsOnly` responses: cap and ask** — accepted 2026-09-16.
    The OID-list strategy caps the ID fetch (default 5M OIDs); beyond that the
    download pauses and asks the user to supply a partitioning `where` template
    via the manual strategy. Never seen in practice; kept simple deliberately.
15. **Design direction: the "Sheet" language on the "Directory" layout** —
    accepted 2026-09-16. The app has its own token set (Cabin + Fira Code, sheet
    paper with a magenta accent), not DuckLake Explorer's Stratum; the parsed URL
    is the window's spine, the layer page is a document that leads with the
    extractability sentence, every tree node carries an extent locator, the map is
    a tab drawn as a survey sheet, and transfers live in a bottom strip that opens
    into a drawer. See [UI-SPEC.md](./UI-SPEC.md), [DESIGN-TOKENS.md](./DESIGN-TOKENS.md)
    and the frames under `design/`.
16. **App state in SQLite, not DuckDB** — accepted 2026-09-16. The metadata cache and
    download bookkeeping are small relational rows; SQLite's WAL is robust across force
    quits where DuckDB's replay proved fragile (it could not rebind sequence defaults), and
    the system library needs no bundling. DuckDB remains the spatial and data engine:
    extent reprojection now, staging, export, and map data later. This departs from the
    tree's "DuckDB first" default deliberately.
17. **Per-server cookies live in the app DB** — accepted 2026-09-17. A raw `Cookie` header
    (curl `-b`) is a low-value session credential; a first cut in the Keychain prompted on
    every rebuild and got in the way of resuming downloads. Tokens and passwords (M8) still
    go in the Keychain.

## 10. Open questions
1. ~~**Design direction**: reuse DuckLake Explorer's Stratum system or give this app
   its own?~~ Resolved 2026-09-16 as decision 15: its own, specified in
   [UI-SPEC.md](./UI-SPEC.md) and [DESIGN-TOKENS.md](./DESIGN-TOKENS.md).
