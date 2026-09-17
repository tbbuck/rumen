#!/bin/bash
# Real contours for the app icon: Schiehallion (Perthshire), the mountain for which
# contour lines were first drawn (Charles Hutton reducing Maskelyne's 1774 survey), cut
# from the Copernicus GLO-30 DEM on AWS Open Data by HTTP range requests and contoured
# at 50 m. Writes design/icon/contours.json (GeoJSON LineStrings with an `elev` field).
#
#   bash design/icon/contours.sh
#
# Needs GDAL (brew install gdal) and network; about ten seconds.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
TILE="https://copernicus-dem-30m.s3.amazonaws.com/Copernicus_DSM_COG_10_N56_00_W005_00_DEM/Copernicus_DSM_COG_10_N56_00_W005_00_DEM.tif"

# 6 km x 6 km around the summit (56.6667 N, 4.0989 W): ulx uly lrx lry.
gdal_translate -q "/vsicurl/$TILE" -projwin -4.148 56.694 -4.050 56.640 "$WORK/schiehallion.tif"
gdal_contour -q -f GeoJSON -a elev -i 50 "$WORK/schiehallion.tif" "$HERE/contours.json"
rm -rf "$WORK"
echo "wrote $HERE/contours.json"
