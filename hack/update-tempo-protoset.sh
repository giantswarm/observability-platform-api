#!/usr/bin/env bash
#
# Regenerates hack/tempo.protoset, the descriptor set grpcurl uses in hack/test-tempo.sh.
# Reproduces the proto patching of Tempo's gen-proto target, without buf.
#
# Usage: TEMPO_VERSION=v2.10.7 update-tempo-protoset.sh
#
# Dependencies: git, protoc.

set -euo pipefail

: "${TEMPO_VERSION:?TEMPO_VERSION is required}"
out="$(cd "$(dirname "$0")" && pwd)/tempo.protoset"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git -c advice.detachedHead=false clone -q --depth 1 --branch "$TEMPO_VERSION" https://github.com/grafana/tempo.git "$tmp"
cd "$tmp"
git submodule update -q --init --depth 1

# Move the OpenTelemetry protos into the tempopb package, as Tempo's gen-proto target does.
mkdir -p pkg/.patched-proto
cp -R opentelemetry-proto/opentelemetry/proto/* pkg/.patched-proto/
find pkg/.patched-proto -name '*.proto' -exec sed -i.bak \
  -e 's+ opentelemetry.proto+ tempopb+g' \
  -e 's+import "opentelemetry/proto/+import "+g' {} \;

protoc --proto_path . -Ipkg/.patched-proto -Ivendor -Ivendor/github.com/gogo/protobuf \
  --descriptor_set_out="$out" --include_imports ./pkg/tempopb/tempo.proto
echo "wrote $out for Tempo $TEMPO_VERSION"
