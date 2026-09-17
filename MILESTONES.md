# ArcGIS Explorer — Milestones

> Status: **Draft** · 2026-09-16 · See [SPEC.md](./SPEC.md) for the full spec.

Phased, read-only against servers throughout. The centre of gravity is the
**download engine** (M4); everything before it builds the metadata foundation it
needs, everything after it exploits the cache and the stored data. Each milestone
lists **Goal · Deliverables · Acceptance · Demo**. Every non-trivial unit gets tests;
commit per logical unit.

---
## Status — 2026-09-16

- **M0 complete.** `ArcGISCore` package (CDuckDB + DuckDBKit with Appender, prepared
  statements, and the migration runner; ArcGISKit with the initial schema and the
  `AppDatabase` actor), vendored Esri proto with generated Swift, xcodegen app that opens and
  migrates the database on launch, CI workflow.
- **M1 headless half complete** (no UI spec needed): URL normaliser, `ArcGISClient`
  (Origin/Referer on every request, token param, per-host cap, jittered retries, typed
  errors), lenient REST models, the metadata store (servers, services, layers, fields, raw
  JSON, pruning, cascade forget), and the `Crawler` (open-by-URL, shallow/service/deep crawls,
  bulk `layers` with per-layer fallback). 91 tests, plus an opt-in live test that passes
  against sampleserver6.
- **M1 complete.** The Sheet-on-Directory shell: hidden title bar with the path bar as the
  spine (segments, mono tail, ⌘L edit mode that takes any pasted URL), the 288px tree with
  server header, kind labels, staleness captions, and extent locators (WGS 84 boxes derived
  at crawl time through the spatial extension), directory / service / layer pages, the
  document-style layer page with Overview (verdict sentence, fact grid, fields), Fields, and
  Raw tabs, the add-server sheet, server settings (header overrides), the recent-servers
  popover, a `--open <url>` launch argument, and the transfers strip placeholder. Verified on
  sampleserver6 by window captures. Found and fixed on the way: DuckDB could not replay a
  write-ahead log holding `DEFAULT nextval(...)` DDL after a force quit, so ids are now
  allocated in the INSERT and the app checkpoints after migrating (regression test included).
  Not yet in the tree: a filter box (cheap, folded into M5 with column search).
- **M2 complete.** Extractability rules (layer type, Query capability with service fallback,
  PBF/JSON transport, the offset → OID-range → OID-list ladder, page size) as a pure
  assessment with the statement wording; FeatureServer twin discovery that crawls the twin
  once and prefers it when it offers PBF or paging the MapServer lacks; the count probe that
  confirms the verdict and records the count or overturns it with the server's message; the
  verdict sentence, primary button, and links on the Overview; tile-cache flag on the service
  page; deep crawl with progress, cancel, and resume (fresh services skipped). 115 tests.
- **Storage switched to SQLite** (decision 16): the app database is `explorer.sqlite` behind
  the new `SQLiteKit`; DuckDB is now only the spatial engine (in-memory, for extents) and,
  from M4, the staging and export engine.
- **M3 complete.** Esri JSON geometry parsing with grid summaries, feature-set decoding,
  query options → parameters, client calls for features and extents, the Query tab (where
  editor, fields / spatial reference / order / geometry options, Count · Extent · Preview ·
  Distinct · Statistics gated by capability with reasons, Next page on offset paging), the
  `NSTableView` results grid ported to the Sheet palette, and per-layer history that
  restores a past query. `--tab` and `--run preview` launch arguments for scripted captures.
  132 tests; verified on sampleserver6.
- **M4 complete.** PBF decoder (dequantisation with per-part deltas and the upper-left y
  flip, validated feature for feature against JSON pages of three real layers), Esri
  geometry → ISO WKB with orientation-based ring assembly, the download engine (offset /
  OID-range / OID-list planning from probes, bounded parallel fetching, per-run staging in
  DuckDB through the Appender with chunk-tagged rows, validation of every page against the
  plan, pause on token errors, resume without refetching, sticky JSON fallback), GeoParquet
  export from the WKB column with our own `geo` metadata (types, bbox, PROJJSON from
  DuckDB's CRS registry) plus optional domain-label columns and a SHA-256, and the UI: the
  Download tab (plan sentence, format / spatial reference / labels / where / output path,
  manual strategy only when automatic failed, run history), the transfers strip and drawer
  with chunk grid, progress bars, and per-state actions, overwrite confirmation, resume
  after relaunch. Also: hover states on links, buttons, rows, segments, and tabs; a spinner
  in place of the chevron while a service loads. Found live: sampleserver6 times out on a
  1,000-county page, so refused chunks are now halved until they fit (per-chunk limits,
  migration 0002). Runs left running by a quit are parked as paused at launch. 156 tests; a
  real 4-page, 3,219-county download verified with the DuckDB CLI (geometry typed
  `epsg:4326` from our PROJJSON, 0 null and 6 source-invalid geometries reported).
- **M5 complete.** Column search over cached fields joined to layers, services, and servers:
  case-insensitive partial by default, exact, case-sensitive, regex (filtered in Swift), alias
  matching, scoped to the current server or all; a results view that replaces the page while
  the field has text, with options, a banner counting uncrawled services that offers the deep
  crawl, and double-click navigation across servers; ⌘F focuses the field; the tree gets its
  filter box.
- **M6 complete.** MapLibre GL in a `WKWebView` with MapTiler basemaps by appearance (key
  from the untracked xcconfig), drawn as a survey sheet: 1px frame, tick labels in the
  margins, a graticule injected by Swift in the layer's spatial reference — degrees for
  geographic layers, eastings and northings in km for projected ones via DuckDB transforms
  through the CRS registry, wrapped past the antimeridian. Sources: a bounded server sample
  in WGS 84 (extent dashed, sample fitted when the extent is a world-sized default), a stored
  GeoParquet read back through the spatial engine with a DuckDB where box and display
  simplification, and the Query tab's last preview. The transfers Map action opens a finished
  run on the map. 174 tests.
- **Polish after first use (post-M6).** Map: feature-state hover with tweened fades, the
  clicked feature cross-faded between two highlight slots while the rest dim, page calls
  queued on the page's own ready flag (a `setData` reparse makes `isStyleLoaded()` false, so
  calls parked on a second `load` were lost), page errors in the unified log; sample loads
  stream with "Waiting for the server…" then bytes, total, and percentage (unencoded so the
  length is honest). Tree: single-tap handler reading the click count (a double-tap gesture
  had been holding every click), atomic page swaps, filter over a case-folded byte index built once per
  tree and scanned with `memmem` (1–7 ms for 4,000 names in either build configuration;
  the remaining 40–70 ms per keystroke is SwiftUI re-rendering the panel and its ~35
  visible rows, measured with `--bench-filter`), the mono font cached. Raw tab in an `NSTextView` with off-main pretty-printing. New
  screens: a **start page** (known servers with counts, or a URL field) instead of landing
  in the last server, and an **opening page** that names the server and the crawler's
  current step while a new server is added; "Start page" in the recents popover.
- **M7 complete** (2026-09-17). Export formats: GeoJSON through the spatial extension's GDAL
  writer (RFC 7946, so always WGS 84: the Download tab's spatial reference picker locks to it)
  and CSV with the geometry as WKT, written from the staging table at download time (a real
  format menu; the plan sentence and output path follow it) or as **re-exports** of a stored
  GeoParquet read back through DuckDB, landing beside it and recorded in a new `export` table
  (migration 0004). The **Stored** tab: the file's facts (rows, columns, size, spatial
  reference, age, invalid geometries as received), Show in Finder and Map, an Exports section
  with the two re-export links and the files written so far, and a DuckDB SQL scratch box over
  the file as the table `data` with the results grid (first 1,000 rows, geometry as WKT for
  points or a shape summary, nested types as text, DuckDB errors verbatim), all on the file's
  own engine so the app database never waits. The transfers drawer's Re-export and the run
  history's Stored link open it. Found on the way: DuckDB 1.5.5 reads a GeoParquet's CRS onto
  the geometry type (`GEOMETRY('EPSG:27700')`), so column type checks match by prefix; the
  GDAL writer wants `geometry_always_xy` set and an `SRS`; attribute values with carriage
  returns (multi-line addresses) drew as a squeezed stack in the grid and now show a ↵ mark;
  the Overview's primary button was still disabled "until M4" and now starts a download with
  the defaults. 183 tests; verified live: a 378-feature stored layer re-exported as GeoJSON
  reads back in DuckDB with 378 features inside Teesside's longitude and latitude.
- **M8 complete** (2026-09-17). **Tree on `NSOutlineView`**: cells are reused, so filtering
  costs only the visible rows, and arrows, Home and End, type-ahead, Return and double-click
  to expand come from AppKit; the Sheet row (chevron or spinner, mono layer id, name, kind
  label, stale caption, locator or error glyph, the selection rail with the name in
  semibold) is drawn by one custom cell with Cabin and Fira Code as `NSFont`s; the model
  stays the source of truth for expansion and selection, the outline mirrors them and
  reports the user's changes back, so a pasted URL still expands the ancestors and lands on
  the layer. **Folder listings as rows** (migration 0006): the crawler records every folder
  a directory lists and the outcome of listing it; a failed folder keeps what was cached,
  shows the error glyph with the message as its tooltip in the tree and the directory rows,
  and its page offers Retry; column search's banner counts the folders it cannot see. The
  **error banner** now spans the top of the page with Retry where the step can run again,
  slides in unless Reduce Motion is on, and the MapLibre page's hover and selection fades
  honour Reduce Motion too. **Housekeeping**: `KeychainMigration` and its marker setting
  gone (migration 0005), `--bench-filter` and `Perf.swift` gone; no `--row` capture
  variants were left in the tree. Capture hooks added: `--stored <id>`,
  `--run export-geojson|export-csv`, `--filter <text>`. Found on the way: a `sed` over the
  model's error sites turned `clearError` into a call to itself; the compiler's recursion
  warning caught it on the next build. 186 tests; verified by captures on sampleserver6
  (expanded service, selected layer) and ONS (3,937 services filtered flat).
- **M8 follow-up** (2026-09-17, from first use): the outline refused `collapseItem` while the
  delegate hid the outline cell (`shouldShowOutlineCellForItem`), so nothing collapsed by
  chevron or by Left; the cell now gets a zero frame instead. Left and Right are handled
  explicitly (collapse or parent; expand or first child), Space toggles, a click takes
  keyboard focus, and the tree is handed focus after a server opens and on Escape or Down
  from the filter and column-search fields, so typing no longer lands in the search box.
  Found with a CGEvent-driven capture script (`claude-scripts/key_test.sh`), which also
  showed that synthetic arrow keys need the function-key and keypad flags before AppKit's
  key bindings recognise them.
- **M9 complete** (2026-09-17). **Preferences** (⌘,): download folder, default format and
  spatial reference (locked to WGS 84 for GeoJSON), domain labels, requests per host,
  attempts per request, appearance; kept in the `setting` table, seeding each layer's
  Download tab and the Overview's primary button; the client's per-host cap and retry policy
  and the engine's per-run concurrency are settable at runtime (a raised cap wakes waiters;
  tested). **Packaging** as in DuckLake Explorer: `scripts/bundle-duckdb-engine.sh` copies
  `libduckdb` into `Contents/Frameworks` and rewrites the install name and rpath;
  `scripts/release.sh` builds Release, bundles, signs with Developer ID and the hardened
  runtime under `Config/ArcGISExplorer.entitlements` (`disable-library-validation` only),
  runs the signed binary's `--selftest` (a packaged build points DuckDB's default
  configuration at `~/Library/Application Support/ArcGIS Explorer/duckdb-extensions`, so
  `INSTALL spatial` lands there and every engine finds it), notarises, staples, and packages
  the DMG; `release.yml` does the same on a `v*` tag. Verified on this Mac: the signature
  verifies, the self-test fetched `spatial` v1.5.5 into the per-user folder and reprojected
  London through it under library validation, no Homebrew reference remains in the bundle,
  `notarytool` accepted the submission, the staple validates, and `spctl` reports
  "accepted, source=Notarized Developer ID"; an 18 MB DMG. Not done: the app icon, which is
  being designed under `design/icon` in a separate session and is not wired into the bundle.
  187 tests.

---

## M0 — Scaffold & engine  *(de-risk the toolchain)* — ✅ done 2026-09-16
**Goal:** a building, testing, signed-ad-hoc app with a migrated DuckDB app database.
- **Deliverables**
  - `Package.swift` (`ArcGISCore`: `CDuckDB`, `DuckDBKit`, `ArcGISKit`, tests) and
    `project.yml` (xcodegen app target, macOS 26, Swift 6, ad-hoc signing), mirroring
    DuckLake Explorer; `.gitignore` for generated project, build dirs, and the
    MapTiler local xcconfig.
  - `DuckDBKit` copied from DuckLake Explorer, plus an **Appender** wrapper and a
    **migration runner** over numbered SQL files with a `schema_migrations` table.
  - `0001_initial.sql` creating the SPEC §7.2 schema; the app opens or creates
    `~/Library/Application Support/ArcGIS Explorer/explorer.duckdb` on launch and
    migrates it.
  - `claude-scripts/build_app.sh`; `.github/workflows/ci.yml` on `macos-26`.
  - SwiftProtobuf dependency wired; Esri `FeatureCollection.proto` vendored with
    generated Swift committed (decoder itself is M4).
- **Acceptance:** `swift test` green (engine, appender, migration idempotence);
  the app launches to a placeholder window and the DB file exists with all tables;
  `spatial` loads from `~/.duckdb/extensions`.
- **Demo:** launch, quit, inspect the DB with the DuckDB CLI.

## M1 — Servers & browsing — ✅ done 2026-09-16
**Goal:** paste any URL, get a named server and a navigable tree.
- **Deliverables**
  - URL normaliser resolving root / folder / service / layer / query URLs; typed
    errors for non-ArcGIS input.
  - `ArcGISClient`: per-server `Origin` + `Referer` (defaults per SPEC §5.1,
    overrides in a server settings sheet), per-host concurrency cap, retry policy,
    ArcGIS error-envelope parsing. Recorded-fixture `URLProtocol` for tests.
  - Add-server sheet with friendly name; recents list with rename, forget, re-crawl.
  - Shallow crawl (root, folders, services) persisted; service crawl on select using
    the bulk `layers` endpoint with per-layer fallback; layers and tables persisted
    with raw JSON and `fetched_at`.
  - Sidebar tree: server → folder → service → layer / table, with type glyphs and
    a filter box. Staleness shown; Refresh at each level.
  - Pasting a URL for a known server navigates instead of duplicating.
- **Acceptance:** add three public servers (a Server-style root, an ArcGIS Online
  hosted FeatureServer, a MapServer with group and raster layers); tree matches the
  live directory; relaunch shows them from cache with no network; a bogus URL and an
  unreachable host both give clear errors; every request in the test fixtures
  carries the two headers.
- **Demo:** paste a layer URL, land on it in the tree.

## M2 — Layer inspector & extractability — ✅ done 2026-09-16
**Goal:** answer "what is this and can I get it out?" for every layer.
- **Deliverables**
  - Overview, Fields, and Raw tabs per SPEC §5.4, including mapped DuckDB types and
    inline domains.
  - Extractability rules (SPEC §5.3) with reasons; count probe; sibling
    FeatureServer discovery and linking; tile-cache flag at service level.
  - Deep crawl of a whole server in the background with progress and cancel.
- **Acceptance:** rule tests cover Feature / Group / Raster / table / no-Query /
  PBF-vs-JSON cases from fixtures; a MapServer layer with a PBF-capable
  FeatureServer twin shows the twin as the download source; deep crawl of a server
  with 100+ services completes and is resumable.
- **Demo:** paste a MapServer URL, read the per-layer verdicts.

## M3 — Read-only query — ✅ done 2026-09-16
**Goal:** poke at a layer before downloading it.
- **Deliverables**
  - Query tab: `where`, `outFields`, `outSR`, `orderByFields`, geometry toggle;
    Count, Extent, Preview, Distinct, Statistics actions gated by capability flags.
  - `NSTableView` results grid (ported from DuckLake Explorer) with type-aware
    cells; page forward through previews.
  - Query history per layer.
- **Acceptance:** count and preview agree with the server for a fixture layer;
  an invalid `where` shows the server's own error text; grid stays responsive at
  the maximum page size.
- **Demo:** filter a layer, count, preview, page.

## M4 — Download engine & GeoParquet  *(the core)* — ✅ done 2026-09-16
**Goal:** complete, correct, resumable layer downloads to GeoParquet.
- **Deliverables**
  - PBF decoder with dequantisation; Esri JSON decoder; both → WKB with the ring
    rules in SPEC §5.6; field type mapping; coded-domain label option.
  - Strategy selection (offset paging → OID range → OID list → manual) and the
    chunk planner; `POST` queries; per-host parallelism; retry with backoff; token
    pause on 498/499.
  - Staging DuckDB per run via the Appender; `download` and `download_chunk`
    records; resume of incomplete runs on next launch or on demand; cancel.
  - GeoParquet export via `COPY … (FORMAT PARQUET)` to the configured directory
    with the `<server>/<service>/<layer>.parquet` layout; overwrite confirmation;
    output hash recorded.
  - Downloads pane with progress, rate, ETA, errors, and the run history.
- **Acceptance:** PBF and JSON decodes of the same fixture page produce identical
  WKB and attributes; every geometry type round-trips and passes `ST_IsValid`;
  the fake server exercises short pages, a lying `exceededTransferLimit`, 429 then
  success, and token expiry mid-run, and the planner does the right thing in each;
  a simulated crash resumes without refetching completed chunks; a real
  public layer with more than `maxRecordCount` features downloads completely and
  the feature count equals the server's count; the exported file reads back in
  DuckDB with its CRS and geometry intact.
- **Demo:** download a 100k-feature layer, open the Parquet in the DuckDB CLI.

## M5 — Column search — ✅ done 2026-09-16
**Goal:** find a column across everything the app has seen.
- **Deliverables**
  - Search view over `field`: case-insensitive, partial, regex, alias, scope
    current server / all servers; results with layer context and extractability;
    double-click navigates.
  - Prompt to deep-crawl when the scope has uncrawled services.
- **Acceptance:** search SQL tests cover each option; results across two servers
  are correct and instant from cache.
- **Demo:** find every layer with a `UPRN` column across all known servers.

## M6 — Map — ✅ done 2026-09-16
**Goal:** see a layer or a download on a basemap.
- **Deliverables**
  - `GeoMapView` (MapLibre GL in `WKWebView`) ported from DuckLake Explorer; MapTiler
    key plumbing via `Config/maptiler.xcconfig` + untracked local override; light and
    dark basemaps following appearance.
  - Live layer preview: extent rectangle plus bounded sample in 4326.
  - Query-results map for the current preview page.
  - Stored-data map over a downloaded GeoParquet through DuckDB `ST_AsGeoJSON`,
    with a SQL `where` box and display simplification for large sets.
- **Acceptance:** a projected-SR layer previews in the right place; a 1M-feature
  GeoParquet renders a simplified view without freezing; no key in the repo (a
  history scan script confirms).
- **Demo:** preview a layer, download it, map the file.

## M7 — Export formats & stored data — ✅ done 2026-09-17
**Goal:** get data into every format the user asked for, from server or from disk.
- **Deliverables**
  - GeoJSON and CSV (WKT), through the DuckDB COPY() TO syntax;
    format picker at download time and for
    re-export of an existing GeoParquet without touching the server.
  - Stored-data tab: grid over the file, a DuckDB SQL scratch box, row count and
    file size, open-in-Finder.
- **Acceptance:** each format round-trips a fixture layer's count and geometry
  types when read back with DuckDB; re-export never issues a network request.
- **Demo:** re-export a (small) stored layer as GeoJSON.

## M8 — Stretch Goals — ✅ done 2026-09-17
**Goal:** the rough edges noted after a week of real use; none blocks the others.
- **Tree keyboard navigation.** The tree is a SwiftUI `LazyVStack`: no arrow keys, no
  type-to-select, and every filter keystroke costs 40–70 ms of row rebuilding on a
  4,000-service server. Rebuild it on `NSOutlineView` (the results grid already uses
  `NSTableView`) with cell reuse, so arrows, Home/End, type-ahead, and Return-to-open
  come free and filtering is bounded by the visible rows. Keep the Sheet row: chevron or
  spinner, mono layer id, name, kind label, stale caption, locator, selection rail.
- **Folders that fail to list.** Folder rows are derived from the paths of the services
  under them, so a folder the shallow crawl could not read (a 500, a timeout, a
  permission wall) has no row; the banner names it and that is all. Persist the folder
  listing itself (name, parent, last error, `fetched_at`) as rows, build folder nodes
  from that table, and show a failed folder with the error glyph, its message in the
  tooltip, and Retry on its page. Deep crawl and column search then know what they
  could not see.
- **Housekeeping.** Delete `KeychainMigration` and the `cookies_moved_from_keychain`
  setting once no pre-decision-17 build exists (the only one was a day old). Drop the
  `--bench-filter` argument, `Perf.swift`, and the `--row` capture variants, or move the
  hang observer behind a Debug-only flag. Make the MapLibre hover and selection fades
  respect Reduce Motion the way the SwiftUI ones do (pass the setting into the page).
- **Error banner at the top.** Errors surface in a banner overlaid at the bottom, above
  the transfers strip, where it competes with the strip and is easy to miss, so a
  failed open reads as "nothing happened". Move it to the top of the content area, under
  the title bar and spanning the page (not the tree), with the same dismiss control, a
  Retry where one applies, and Reduce-Motion-aware slide-in. Keep run failures in the
  transfers drawer where they are.

## M9 — Preferences & packaging — ✅ done 2026-09-17 (icon pending)
**Goal:** secured servers and a shippable app.
- **Deliverables**
  - Preferences: download directory, default format and SR, concurrency, retry
    limits, domain-label default.
  - Packaging as in DuckLake Explorer: bundle `libduckdb`, runtime-install `spatial`
    under `disable-library-validation`, Developer ID + hardened runtime, notarise,
    staple, DMG; `release.yml` on tag; app icon.
- **Acceptance:** `notarytool` accepts and `spctl` passes the release build; a
  clean-Mac first run autoinstalls `spatial` and downloads a layer.

---

### Backlog / post-v1 (explicitly out of scope now)
- Attachments download; related-record joins.
- Image service and tile cache extraction.
- OAuth / enterprise sign-in.
- Remote export targets (S3 via `httpfs`).
- Shared `DuckDBKit` package across the Explorer apps.
- Scheduled re-downloads and change detection (`editingInfo.lastEditDate`).
