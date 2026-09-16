#!/usr/bin/env bash
# Regenerate Sources/ArcGISKit/Proto/FeatureCollection.pb.swift from the vendored Esri proto.
# Needs `protoc` and `protoc-gen-swift` (brew install protobuf swift-protobuf). The generated
# file is committed so normal builds and CI need neither tool.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROTO_DIR="$ROOT/Sources/ArcGISKit/Proto"
protoc \
  --proto_path="$PROTO_DIR" \
  --swift_out="$PROTO_DIR" \
  --swift_opt=Visibility=Public \
  "$PROTO_DIR/FeatureCollection.proto"
echo "generated $PROTO_DIR/FeatureCollection.pb.swift"
