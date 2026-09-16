#!/usr/bin/env bash
# Record ArcGIS REST responses from public servers into Fixtures/ for offline tests.
# Sends the same Origin/Referer headers the app does. Re-run to refresh; review the diff.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Fixtures"
mkdir -p "$OUT"

fetch() {
  local name="$1" url="$2"
  local host
  host="$(printf '%s' "$url" | sed -E 's#^(https?://[^/]+).*#\1#')"
  if curl -sSf -o "$OUT/$name" -H "Origin: $host" -H "Referer: $host/" "$url"; then
    echo "ok   $name  ($(wc -c < "$OUT/$name") bytes)"
  else
    echo "FAIL $name  $url"
  fi
}

S6="https://sampleserver6.arcgisonline.com/arcgis/rest/services"
fetch s6-root.json                 "$S6?f=json"
fetch s6-census-mapserver.json     "$S6/Census/MapServer?f=json"
fetch s6-census-layers.json        "$S6/Census/MapServer/layers?f=json"
fetch s6-census-layer3.json        "$S6/Census/MapServer/3?f=json"
fetch s6-census-layer99.json       "$S6/Census/MapServer/99?f=json"
fetch s6-wildfire-featureserver.json "$S6/Wildfire/FeatureServer?f=json"
fetch s6-wildfire-layer0.json      "$S6/Wildfire/FeatureServer/0?f=json"
fetch s6-wildfire-count.json       "$S6/Wildfire/FeatureServer/0/query?where=1%3D1&returnCountOnly=true&f=json"
fetch s6-folder-utilities.json     "$S6/Utilities?f=json"

AGOL="https://services.arcgisonline.com/ArcGIS/rest/services"
fetch agol-world-street-map.json   "$AGOL/World_Street_Map/MapServer?f=json"

HOSTED="https://services3.arcgis.com/GVgbJbqm8hXASVYi/arcgis/rest/services"
fetch hosted-trailheads-featureserver.json "$HOSTED/Trailheads/FeatureServer?f=json"
fetch hosted-trailheads-layer0.json        "$HOSTED/Trailheads/FeatureServer/0?f=json"

# Query responses (M3): a small feature page with geometry, an extent, distinct values,
# statistics, and the server's error for a bad where clause.
Q="$S6/Census/MapServer/3/query"
fetch s6-census-l3-features.json    "$Q?where=1%3D1&outFields=STATE_NAME,POP2000,STATE_ABBR&returnGeometry=true&outSR=4326&orderByFields=OBJECTID&resultOffset=0&resultRecordCount=3&f=json"
fetch s6-census-l3-features-page2.json "$Q?where=1%3D1&outFields=STATE_NAME,OBJECTID&returnGeometry=false&orderByFields=OBJECTID&resultOffset=3&resultRecordCount=3&f=json"
fetch s6-census-l3-extent.json      "$Q?where=1%3D1&returnExtentOnly=true&outSR=4326&f=json"
fetch s6-census-l3-distinct.json    "$Q?where=1%3D1&outFields=SUB_REGION&returnDistinctValues=true&returnGeometry=false&f=json"
fetch s6-census-l3-stats.json       "$Q?where=1%3D1&outStatistics=%5B%7B%22statisticType%22%3A%22min%22%2C%22onStatisticField%22%3A%22POP2000%22%2C%22outStatisticFieldName%22%3A%22min_POP2000%22%7D%2C%7B%22statisticType%22%3A%22max%22%2C%22onStatisticField%22%3A%22POP2000%22%2C%22outStatisticFieldName%22%3A%22max_POP2000%22%7D%2C%7B%22statisticType%22%3A%22avg%22%2C%22onStatisticField%22%3A%22POP2000%22%2C%22outStatisticFieldName%22%3A%22avg_POP2000%22%7D%2C%7B%22statisticType%22%3A%22count%22%2C%22onStatisticField%22%3A%22POP2000%22%2C%22outStatisticFieldName%22%3A%22count_POP2000%22%7D%5D&returnGeometry=false&f=json"
fetch s6-census-l3-bad-where.json   "$Q?where=NOPE%20%3D%3D%201&returnCountOnly=true&f=json"
fetch s6-wildfire-l0-features.json  "$S6/Wildfire/FeatureServer/0/query?where=1%3D1&outFields=*&returnGeometry=true&outSR=4326&resultRecordCount=2&f=json"
