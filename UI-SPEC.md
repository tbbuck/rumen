# ArcGIS Explorer — UI component spec (Sheet on Directory → SwiftUI)

> Status: **Accepted** · 2026-09-16 · Companion to [SPEC.md](./SPEC.md) and
> [DESIGN-TOKENS.md](./DESIGN-TOKENS.md). Maps the chosen design — the **Sheet**
> design language on the **Directory** layout, prototyped on the design canvas
> (`design/*.dc.html`, three frames: Overview, Map tab, Transfers drawer) — onto
> SwiftUI/AppKit components. One line per component: what it *is* and what it's *for*.

## The idea in three sentences

The **URL is the spine**: the title bar holds the parsed path of whatever you are
looking at, every segment is a node, and pasting any ArcGIS URL into it takes you
there. The **layer page reads like a document** and answers "can I get this out?" in
one sentence before anything else. **Extents are the subject**: every node in the tree
carries a locator, and the map is drawn as a survey sheet with grid coordinates in its
margins.

## Architecture anchors

- **Structure/nav:** SwiftUI on macOS 26, Observation framework, Swift 6 strict
  concurrency. The query results grid drops to **AppKit via `NSViewRepresentable`**
  (`NSTableView`, ported from DuckLake Explorer); the map is MapLibre GL in a
  `WKWebView` (`GeoMapView`, also ported). Everything else is SwiftUI.
- **Theming:** the Day / Night palettes live as **semantic colours in an Asset
  Catalog** (`Any` + `Dark`), so the system appearance is honoured for free. A manual
  override in Preferences sets `.preferredColorScheme`.
- **Fonts:** bundle **Cabin** (UI/display) and **Fira Code** (data, ligatures off);
  expose as `Font.sheetDisplay/.sheetUI/.sheetMono`. Values in DESIGN-TOKENS.md.
- **Engine:** all network goes through `ArcGISClient`, all DuckDB through a
  per-connection actor (SPEC §6.2, §7.3); views bind to `@Observable` models.
- **Copy:** sentence case; plain verbs; a control says what it does ("Download as
  GeoParquet", "Sign in and resume"); numbers grouped (`184,212`); times relative
  ("14 minutes ago"); server and DuckDB errors shown verbatim with the URL that
  produced them; lists joined with commas, never middle dots.

---

## Shell

- **`ArcGISExplorerApp: App`** — `@main` + `WindowGroup` + `Settings`; owns menu
  `Commands` (Open URL ⌘L, Find column ⌘F, Refresh ⌘R, Transfers ⌘⇧T). *Entry point.*
- **`AppModel` (`@Observable`)** — known servers, current node (server / folder /
  service / layer), open tab, transfers, column search state, appearance override.
  *Single source of truth, injected via `@Environment`.*
- **`ExplorerView`** — the window: `PathBar` in the toolbar, then the tree beside the
  page with `PanelDivider` between them (drag to resize the tree between 220 and 560px,
  double-click to reset, remembered), then `TransfersStrip` (or `TransfersDrawer`)
  pinned to the bottom. *The Directory layout.*
- **`Theme`** — semantic colour + type tokens read from the Asset Catalog. *Keeps
  every view on-palette in both appearances.*

## Path bar — the spine

- **`PathBar`** — toolbar principal item, fills the width: `HostSegment` + one
  `PathSegment` per level (folder, service, `MapServer`/`FeatureServer`, `3 BLPU
  Addresses`) separated by chevrons, a mono tail (`arcgis/rest/services`), and an
  edit mode. *Where you are, always; the one place a URL is pasted.*
- **`HostSegment`** — server glyph + host; click opens `RecentServersPopover`.
  *Switch servers without leaving the bar.*
- **`PathSegment`** — one level; click navigates there; the current segment is
  highlighted (`accent-soft`, 600). *Every level is a link.*
- **`URLEditField`** — replaces the segments on click or ⌘L: a mono text field
  holding the full URL; paste anything in the hierarchy, Return runs the normaliser
  (SPEC §5.1) and navigates or offers **Add server**; Escape restores the segments.
  *Paste a URL, land on it.*
- **`ColumnSearchField`** — 190px field at the right (⌘F), placeholder "Find a
  column". Typing opens `ColumnSearchResults` in place of the layer page. *Column
  search is always one keystroke away.*

## Server tree

- **`ServerTree`** — the server header, the filter box, and `TreeOutline`: an
  `NSOutlineView` over folder → service → layer / table with reused cells, so arrows,
  Home and End, type-ahead, Return-to-open, and double-click-to-expand come with it and
  filtering costs only the visible rows; 288px. The model owns expansion and selection;
  the outline mirrors them. *Navigate structure; drives the layer page.*
- **`ServerHeader`** — friendly name (14/700) + caption "ArcGIS Server 11.3, cached
  14 minutes ago"; context menu: Rename, Refresh, Deep crawl, Settings, Forget.
  *The server at a glance.*
- **`TreeRow`** — chevron, layer id (mono, right-aligned), name, `KindLabel` for
  services, `ExtentLocator` at the right. Non-extractable layers are dimmed; an
  uncrawled service shows a chevron and crawls on expand; a stale node gets a `warn`
  caption; a folder whose listing failed, or a service whose crawl failed, shows the
  error glyph in place of the locator with the message as its tooltip, and its page
  offers Retry. *One node, its kind, its extent, its verdict, in one row.*
- **`KindLabel`** — `MapServer` / `FeatureServer` / `ImageServer` in 9.5 `muted2`
  after a service name. *Kind without a glyph.*
- **`ExtentLocator`** — 22 × 15 `Canvas`: frame = the server's union extent, filled
  rect = this node's extent. Dashed and empty for non-extractable; frame-only dashed
  for tables. *See where a layer is and how big before you touch it; a world-sized
  or empty extent is spotted from the tree.*
- **`ServerNode` / `FolderNode` / `ServiceNode` / `LayerNode` (models)** — from the
  `server` / `service` / `layer` tables, with `fetchedAt`, `extractable`,
  `extractableReason`, `extent`, `siblingLayerId`. *Backing data for the tree.*

## Layer page

- **`LayerPage`** — `LayerHeader` + `LayerTabs` + the active tab; padding 22 / 36.
  *"What is this and can I get it out?"*
- **`LayerHeader`** — name (24/700) + sub-line "Layer 3 in LLPG (MapServer), Property
  folder. Cached 14 minutes ago, refresh." *Identity and freshness.*
- **`LayerTabs`** — Overview · Fields · Query · Download · Stored · Map · Raw as underlined
  text tabs. *Seven views of one layer.*

### Overview tab
- **`OverviewTab`** — `ExtractionStatement` + `PrimaryActions` + `FactList` +
  `FieldsTable` (read-only, no filter). *Everything you need before downloading.*
- **`ExtractionStatement`** — one sentence, 15px, the verdict word in bold
  `yes`/`no`/`muted2`: "**Extractable.** PBF through the FeatureServer twin, offset
  paging at 2,000 records per request. 184,212 features in 93 requests." /
  "**Not extractable.** This is a raster layer; nothing to query." /
  "**Unknown.** The count probe has not run, probe now." Built from the rules in
  SPEC §5.3 plus the cached count. *The product's honest answer, first.*
- **`PrimaryActions`** — "Download as GeoParquet" (primary) + links "Change format
  or spatial reference" (→ Download tab) and "Preview a sample on the map" (→ Map
  tab). Not extractable: no button; a twin, if any, is offered as "Use the
  FeatureServer twin". *One primary action, two ways to adjust it.*
- **`FactList` / `FactRow`** — two-column-pair grid of label / value: geometry and
  SR, extents (native and WGS 84), count with its age, max record count,
  capabilities, formats, paging support, OID and GlobalID fields, Z/M, attachments,
  twin link, layer type. Values in mono where they are codes. *SPEC §5.4 Overview,
  as a document.*

### Fields tab
- **`FieldsTab`** — filter field + sortable `FieldsTable` with domains expanded.
  *Find a column in this layer.*
- **`FieldsTable`** — SwiftUI `Table`: Name (mono), Alias, Esri type (mono), DuckDB
  type (mono, SPEC §5.6 mapping), Domain. *Schema and its DuckDB shape together.*
- **`DomainCell`** — coded values inline ("1 Under construction, 2 In use, …"),
  truncated with an ellipsis; click expands. *Domains without a second screen.*

### Query tab
- **`QueryTab`** — `WhereEditor` + `OutFieldsPicker` + `OutSRPicker` +
  `OrderByField` + `ReturnGeometryToggle` + `QueryActions` + `ResultsGrid` +
  `QueryHistoryList`. *Read-only poking before a download (SPEC §5.5).*
- **`WhereEditor`** — `NSTextView` in mono, default `1=1`, server error text shown
  verbatim beneath on failure. *The where clause.*
- **`QueryActions`** — Count · Extent · Preview · Distinct · Statistics, each
  disabled with a reason when the layer lacks the capability. *Only what the server
  can do.*
- **`ResultsGrid`** — `NSViewRepresentable` over `NSTableView` from DuckLake
  Explorer; type-aware cells, geometry as WKT summary, dates ISO 8601, page forward.
  *Fast grid at the server's max page size.*
- **`QueryHistoryList`** — where, outFields, count, duration, ran-at; click restores.
  *Per-layer history from `query_history`.*

### Download tab
- **`DownloadTab`** — `DownloadPlan` + `FormatPicker` + `SRPicker` +
  `DomainLabelsToggle` + `OutputPathPreview` + `ManualStrategyDisclosure` +
  "Start download", then `RunHistory` for this layer. *Configure, then run
  (SPEC §5.6–5.7).*
- **`FormatPicker`** — "Format: GeoParquet" menu over GeoParquet, GeoJSON, CSV; choosing
  GeoJSON locks the `SRPicker` to WGS 84 (RFC 7946). *The file's shape, in one word.*

### Stored tab
- **`StoredTab`** — `StoredFileHeader` + `ExportsSection` + `ScratchBox` + `ResultsGrid`.
  *The layer's data on disk (SPEC §5.7): rows, SQL, re-export, none of it touching the server.*
- **`StoredFileHeader`** — format chip, the file's path in mono with Show in Finder and Map,
  a "File: name, age" menu when the layer has several downloads, and one fact line: rows,
  columns, size, spatial reference, age, invalid-geometry count, how the geometry travels.
  *Which file, where, what.*
- **`ExportsSection`** — "Exports" with "Export as GeoJSON" · "Export as CSV" links, a
  spinner while writing, and one row per file written beside the stored one (chip, path,
  features, size, SR, age, Show in Finder). An existing target asks before it is replaced.
  *Other formats from the file, not the server.*
- **`ScratchBox`** — "Query the file": a mono `TextEditor` holding DuckDB SQL over the
  file, which is the table `data`; Run (⌘↩). The grid shows the first 1,000 rows and says
  how many there are; geometry cells read as WKT for points and "POLYGON, 33 vertices"
  otherwise; DuckDB's error text verbatim. *Poke at what you fetched.*
- **`DownloadPlan`** — transport, strategy, page size, request count, where, outSR,
  as plain sentences in the statement's voice. *What will happen, before it does.*
- **`ManualStrategyDisclosure`** — collapsed until automatic selection has failed;
  page size, strategy, partitioning `where` template. *The override, only when
  needed.*
- **`OutputPathPreview`** — `<dir>/<server>/<service>/<layer>.parquet` in mono with
  Change and Reveal. *Where the file will land.*

### Map tab
- **`MapTab`** — `SampleCaption` + `SheetMap`. *See the layer (SPEC §5.9).*
- **`SampleCaption`** — "Sample" chip + "800 of 184,212 features, drawn in WGS 84.
  Dashed box is the layer extent in its native British National Grid." + "Draw a
  fresh sample". *Never pretend a sample is the layer.*
- **`SheetMap`** — `GeoMapView` (MapLibre in `WKWebView`, MapTiler basemaps by
  appearance) inside `SheetMargins`. *The map as a survey sheet.*
- **`SheetMargins`** — SwiftUI overlay drawing the frame and tick labels: eastings
  top and bottom, northings rotated at the left, in the layer's native SR when it is
  projected, lon/lat otherwise; a light graticule is drawn by the map page in the
  same SR. *Coordinates on the margins, like a paper sheet.*
- **`ExtentOutline` / `SampleLayer`** — dashed `accent` rectangle and 4px `accent`
  points/lines/fills injected as GeoJSON. *The layer's footprint and a taste of it.*
- **`StoredDataFilterField`** — only on the stored-data map: a DuckDB `where` box
  over the GeoParquet. *Filter a download on disk.*

### Raw tab
- **`RawJSONView`** — `NSTextView`, mono, pretty-printed layer JSON with a search
  field and Copy. *The truth the server sent.*

## Transfers — strip and drawer

- **`TransfersStrip`** — 40px bar along the bottom: label, the most relevant run
  (running > paused > latest) with `StatusDot`, name, `ProgressBar` 220 × 4, mono
  stats "138 of 207 requests, 4.2k features/s, 1:40 left", and "Show all n".
  Clicking anywhere on it opens the drawer. *Downloads are visible from every screen
  without owning one.*
- **`TransfersDrawer`** — the strip grown to 340px: `DrawerHeader` ("Transfers",
  "3 runs, 1 running, 4 requests in flight to gis.ashcombe.gov.uk", Clear finished,
  collapse; clicking anywhere on the header collapses) + scrolling `RunRow`s. *The full
  picture of what is moving.*
- **`RunRow`** — three columns: who (name, chips, mono target line "Planning /
  PlanningApplications / 0, where 1=1, WGS 84, GeoParquet" or the output path when
  done, one stats sentence), progress (`ChunkGrid` while running, `RunProgressBar`
  otherwise), `RunActions`. *One run per row, its state in one glance.*
- **`ChunkGrid`** — `Canvas` of 7px cells: pending, done, in flight, retrying. 23
  columns for up to eight rows, then wider (to 48 columns) before taller; the run row
  grows to fit. Drawn from `download_chunk`. *The honest picture of a download; a
  stalled run shows exactly which requests are stuck.*
- **`RunProgressBar`** — 6px bar, `yes` when done, `warn` when paused. *Progress
  for runs without a chunk plan, and a quiet summary for finished ones.*
- **`RunActions`** — running: Pause; done: Show in Finder · Re-export (opens the
  layer's Stored tab on that file) · Map; paused (a 498/499 mid-run): Resume (small
  primary) · Settings… (the server's Cookie) · Remove; failed: Retry · Remove. The bar
  and the stats of a paused or failed run show the requests already kept. *Every state
  has its next step.*
- **`Chip`** — `PBF`, `Offset paging`, `OID range`, `Done`, `Paused`, `Failed`.
  *Transport, strategy and state in form.*
- **`DownloadRun` / `DownloadChunk` (models)** — from the `download` and
  `download_chunk` tables. *Backing data; a resumed run re-reads its chunks.*

## Column search

- **`ColumnSearchResults`** — replaces the layer page while the search field has
  text: `SearchOptions` row (case, partial, regex, alias, scope current server / all
  servers) + results table Field · Layer · Service · Server · Type · Verdict;
  double-click navigates and clears. *SPEC §5.8, without a mode.*
- **`DeepCrawlPrompt`** — banner above results when the scope has uncrawled
  services or folders that could not be listed: "12 services on this server have not
  been crawled and 2 folders could not be listed, crawl them now". *Say what the
  results cannot see.*

## Servers, auth, sheets

- **`AddServerSheet`** — pasted URL (from `URLEditField`) → resolved node preview
  ("This is layer 3 of LLPG on gis.ashcombe.gov.uk") + friendly name field (default
  the host) + Add. *Register a server from any of its URLs.*
- **`RecentServersPopover`** — list of known servers by last visit with rename,
  forget, re-crawl; "Add a server". *Switch or manage servers from the host segment.*
- **`ServerSettingsSheet`** — friendly name, `Origin` and `Referer` overrides
  (defaults shown greyed), auth kind, concurrency cap for this host. *Per-server
  knobs from SPEC §5.1.*
- **`SignInSheet`** — username + password, or a pasted API key; stored in the
  Keychain; offered from the paused run and from server settings. *Token auth,
  nothing else (SPEC §5.10).* **Not built:** on the backlog; the Cookie field on
  server settings is the way through a login for now.
- **`DeepCrawlProgress`** — popover from the server header: services done / total,
  cancel. *Background crawl with a way out.*
- **`OverwriteConfirmation`** — alert naming the existing file and its age. *Never
  overwrite silently (SPEC §5.7).*
- **`PreferencesView`** (⌘,, the `Settings` scene) — Downloads: folder with Change and
  Reveal, default format (segmented), spatial reference (the layer's own or WGS 84, locked
  to WGS 84 for GeoJSON), domain labels; Network: requests per host and attempts per
  request as steppers, applied to the client at once; Appearance: Day, Night, System. Each
  layer's Download tab starts from these and changes them for that run only. *SPEC M9.*

## Shared primitives

- **`VerdictWord`** — `Extractable` / `Not extractable` / `Unknown` in 700 and the
  matching colour. *The one word that matters.*
- **`ExtentLocator`**, **`ChunkGrid`**, **`ProgressBar`**, **`StatusDot`**, **`Chip`**
  — as above.
- **`PrimaryButton` / `SmallPrimaryButton` / `LinkButton`** — one filled button per
  view; everything secondary is a link. *Hierarchy by form.*
- **`MonoText`** — Fira Code with tabular numerals and ligatures off. *Data looks
  like data.*
- **`Caption`** — 11–12.5 `muted`/`muted2`. *Ages, counts, notes.*

## Empty and error states

- Errors that are not a transfer's: a banner across the top of the page, under the title
  bar and beside the tree, with the message verbatim, Dismiss, and Retry when the step can
  run again; it slides in unless Reduce Motion is on. *A failed open never reads as
  "nothing happened".*
- No servers yet: the layer page shows "Paste an ArcGIS URL into the bar above, or
  press ⌘L" with two example shapes of URL. *An empty screen is an invitation.*
- Uncrawled service selected: "Loading 7 layers from the server…" then the tree
  fills; failure shows the server's message and Retry. *Faithful, never vague.*
- Extractability unknown: the statement says why ("count probe not run", "server
  returned an error: …") and offers the probe. *Unknown is a state, not a blank.*
- Transfer failed: the run row keeps the chunk grid with the failed cells in `no`
  and the last error verbatim. *Resume from where it broke.*
