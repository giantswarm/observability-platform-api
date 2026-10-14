#!/usr/bin/env bash
#
# End-to-end test of Tempo through observability-platform-api.
#
# Writes traces over OTLP HTTP and OTLP gRPC, reads them back over the Tempo
# HTTP and gRPC APIs, then checks auth rejections and tenant isolation.
#
# Usage: BASE_URL=https://observability.<codename>.<base-domain> TOKEN=<jwt> test-tempo.sh
#
# Environment:
#   BASE_URL  API base URL (required)
#   TOKEN     JWT from a configured OIDC provider (required, see hack/dex-token.sh)
#   TENANT    X-Scope-OrgID value (default: giantswarm)
#   TIMEOUT   Seconds to wait for ingested data (default: 60)
#
# Dependencies: curl, jq, grpcurl, telemetrygen.
# The gRPC checks use hack/tempo.protoset (make update-tempo-protoset).

set -euo pipefail

: "${BASE_URL:?BASE_URL is required}"
: "${TOKEN:?TOKEN is required}"
TENANT="${TENANT:-giantswarm}"
TIMEOUT="${TIMEOUT:-60}"

PROTOSET="$(cd "$(dirname "$0")" && pwd)/tempo.protoset"
BASE_URL="${BASE_URL%/}"
HOST="${BASE_URL#https://}"
GRPC_HOST="${HOST%%/*}:443"

RUN_ID="$(date +%s)-$$"
SVC_HTTP="e2e-otlp-http-$RUN_ID"
SVC_GRPC="e2e-otlp-grpc-$RUN_ID"
OTHER_TENANT="$TENANT-isolation-$RUN_ID"
QUERY_HTTP="{resource.service.name=\"$SVC_HTTP\"}"
QUERY_GRPC="{resource.service.name=\"$SVC_GRPC\"}"
QUERY_METRICS="$QUERY_HTTP | count_over_time()"
TRACE_ID=""

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

passed=0
total=0
missing=0
for dep in curl:"" jq:"" \
  grpcurl:"go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest" \
  telemetrygen:"go install github.com/open-telemetry/opentelemetry-collector-contrib/cmd/telemetrygen@latest"; do
  if ! command -v "${dep%%:*}" >/dev/null; then
    echo "missing dependency: ${dep%%:*} ${dep#*:}" >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1
[ -f "$PROTOSET" ] || { echo "missing $PROTOSET, run: make update-tempo-protoset" >&2; exit 1; }

# Time window in unix seconds.
start() { echo $(( $(date +%s) - 600 )); }
end() { echo $(( $(date +%s) + 60 )); }

# check NAME CMD...: runs CMD once and records the result.
check() {
  local name="$1" out; shift
  total=$((total + 1))
  if out="$("$@" 2>&1)"; then
    passed=$((passed + 1))
    echo -e "${GREEN}OK${NC}   $name"
  else
    echo -e "${RED}FAIL${NC} $name: $(echo "$out" | tail -n 3)"
  fi
}

# poll NAME CMD...: retries CMD every 2s until it succeeds or TIMEOUT expires.
poll() {
  local name="$1" deadline=$(( $(date +%s) + TIMEOUT )); shift
  until "$@" >/dev/null 2>&1 || [ "$(date +%s)" -ge "$deadline" ]; do
    sleep 2
  done
  check "$name" "$@"
}

# api PATH [CURL_ARGS...]: authenticated GET on the Tempo read API.
api() {
  local path="$1"; shift
  curl -sSf -G "$BASE_URL$path" \
    -H "Authorization: Bearer $TOKEN" -H "X-Scope-OrgID: $TENANT" "$@"
}

# grpc METHOD JSON: authenticated call on tempopb.StreamingQuerier, stream slurped to one JSON array.
grpc() {
  grpcurl -protoset "$PROTOSET" \
    -H "Authorization: Bearer $TOKEN" -H "X-Scope-OrgID: $TENANT" \
    -d "$2" "$GRPC_HOST" "tempopb.StreamingQuerier/$1" | jq -s .
}

# status [CURL_ARGS...]: prints the HTTP status code.
status() {
  curl -s -o /dev/null -w '%{http_code}' "$@"
}

# expect WANT GOT: fails with a message when GOT differs from WANT.
expect() {
  [ "$1" = "$2" ] || { echo "want $1, got $2"; return 1; }
}

# write_otlp ENDPOINT [TELEMETRYGEN_ARGS...]
write_otlp() {
  # telemetrygen exits 0 on export failures and logs them as "traces export: <error>".
  local endpoint="$1" out; shift
  out="$(telemetrygen traces --traces 1 --otlp-endpoint "$endpoint" \
    --otlp-header "Authorization=\"Bearer $TOKEN\"" \
    --otlp-header "X-Scope-OrgID=\"$TENANT\"" "$@" 2>&1)"
  ! echo "$out" | grep 'traces export:'
}

search_finds() {
  api /tempo/api/search --data-urlencode "q=$1" -d "start=$(start)" -d "end=$(end)" \
    | jq -e '.traces | length > 0' >/dev/null
}

save_trace_id() {
  TRACE_ID="$(api /tempo/api/search --data-urlencode "q=$QUERY_HTTP" -d "start=$(start)" -d "end=$(end)" \
    | jq -er '.traces[0].traceID')"
}

echo "Testing $BASE_URL as tenant $TENANT (run $RUN_ID)"

echo "== Write"
check "write/otlp-http" write_otlp "$GRPC_HOST" --otlp-http --service "$SVC_HTTP"
# passthrough skips the gRPC Go DNS resolver, which can hang where the system resolver works.
check "write/otlp-grpc" write_otlp "passthrough:///$GRPC_HOST" --service "$SVC_GRPC"

http_echo() {
  expect echo "$(api /tempo/api/echo)"
}
http_buildinfo() {
  api /tempo/api/status/buildinfo | jq -e '.version | length > 0' >/dev/null
}
http_traces_v1() {
  api "/tempo/api/traces/$TRACE_ID" | jq -e '(.batches // .resourceSpans) | length > 0' >/dev/null
}
http_traces_v2() {
  api "/tempo/api/v2/traces/$TRACE_ID" | jq -e '.trace.resourceSpans | length > 0' >/dev/null
}
http_tags_v1() {
  api /tempo/api/search/tags -d "start=$(start)" -d "end=$(end)" \
    | jq -e '.tagNames | index("service.name")' >/dev/null
}
http_tag_values_v1() {
  api /tempo/api/search/tag/service.name/values -d "start=$(start)" -d "end=$(end)" \
    | jq -e --arg a "$SVC_HTTP" --arg b "$SVC_GRPC" '.tagValues | index($a) and index($b)' >/dev/null
}
http_tags_v2() {
  api /tempo/api/v2/search/tags -d "start=$(start)" -d "end=$(end)" \
    | jq -e '[.scopes[].tags[]] | index("service.name")' >/dev/null
}
http_tag_values_v2() {
  api /tempo/api/v2/search/tag/resource.service.name/values -d "start=$(start)" -d "end=$(end)" \
    | jq -e --arg a "$SVC_HTTP" --arg b "$SVC_GRPC" '[.tagValues[].value] | index($a) and index($b)' >/dev/null
}
http_metrics() {
  api /tempo/api/metrics/query_range --data-urlencode "q=$QUERY_METRICS" \
    -d "start=$(start)" -d "end=$(end)" -d "step=60s" | jq -e '.series | length > 0' >/dev/null
}

echo "== Read HTTP"
check "http/echo" http_echo
check "http/buildinfo" http_buildinfo
poll "http/search otlp-http" search_finds "$QUERY_HTTP"
poll "http/search otlp-grpc" search_finds "$QUERY_GRPC"
save_trace_id 2>/dev/null || true
check "http/traces v1" http_traces_v1
check "http/traces v2" http_traces_v2
check "http/search/tags v1" http_tags_v1
check "http/search/tag/values v1" http_tag_values_v1
check "http/search/tags v2" http_tags_v2
check "http/search/tag/values v2" http_tag_values_v2
poll "http/metrics/query_range" http_metrics

echo "== Read gRPC"
grpc_search() {
  grpc Search "{\"Query\": $(jq -n --arg q "$QUERY_HTTP" '$q'), \"start\": $(start), \"end\": $(end)}" \
    | jq -e --arg id "$TRACE_ID" '[.[].traces[]?.traceID] | index($id)' >/dev/null
}
grpc_tags() {
  grpc SearchTagsV2 "{\"start\": $(start), \"end\": $(end)}" \
    | jq -e '[.[].scopes[]?.tags[]?] | index("service.name")' >/dev/null
}
grpc_tag_values() {
  grpc SearchTagValuesV2 "{\"tagName\": \"resource.service.name\", \"start\": $(start), \"end\": $(end)}" \
    | jq -e --arg a "$SVC_HTTP" --arg b "$SVC_GRPC" '[.[].tagValues[]?.value] | index($a) and index($b)' >/dev/null
}
grpc_metrics() {
  grpc MetricsQueryRange "{\"query\": $(jq -n --arg q "$QUERY_METRICS" '$q'), \"start\": $(start)000000000, \"end\": $(end)000000000, \"step\": 60000000000}" \
    | jq -e '[.[].series[]?] | length > 0' >/dev/null
}
check "grpc/Search" grpc_search
check "grpc/SearchTagsV2" grpc_tags
check "grpc/SearchTagValuesV2" grpc_tag_values
poll "grpc/MetricsQueryRange" grpc_metrics

echo "== Auth rejections"
check "http/read no token" expect 401 "$(status "$BASE_URL/tempo/api/echo" -H "X-Scope-OrgID: $TENANT")"
check "http/read no tenant" expect 401 "$(status "$BASE_URL/tempo/api/echo" -H "Authorization: Bearer $TOKEN")"
check "http/write no token" expect 401 "$(status -X POST "$BASE_URL/v1/traces" -H "X-Scope-OrgID: $TENANT" \
  -H "Content-Type: application/json" -d '{"resourceSpans":[]}')"
grpc_no_token() {
  local out
  out="$(grpcurl -protoset "$PROTOSET" -H "X-Scope-OrgID: $TENANT" -d '{}' \
    "$GRPC_HOST" tempopb.StreamingQuerier/SearchTagsV2 2>&1)" || true
  echo "$out" | grep Unauthenticated
}
check "grpc/read no token" grpc_no_token

echo "== Tenant isolation"
check "http/traces v1 other tenant" expect 404 "$(status "$BASE_URL/tempo/api/traces/$TRACE_ID" \
  -H "Authorization: Bearer $TOKEN" -H "X-Scope-OrgID: $OTHER_TENANT")"
# The v2 endpoint answers 200 with an empty trace when the trace does not exist.
traces_v2_other_tenant() {
  curl -sSf "$BASE_URL/tempo/api/v2/traces/$TRACE_ID" \
    -H "Authorization: Bearer $TOKEN" -H "X-Scope-OrgID: $OTHER_TENANT" \
    | jq -e '(.trace.resourceSpans // []) | length == 0' >/dev/null
}
check "http/traces v2 other tenant" traces_v2_other_tenant
search_other_tenant() {
  curl -sSf -G "$BASE_URL/tempo/api/search" \
    -H "Authorization: Bearer $TOKEN" -H "X-Scope-OrgID: $OTHER_TENANT" \
    --data-urlencode "q=$QUERY_HTTP" -d "start=$(start)" -d "end=$(end)" \
    | jq -e '(.traces // []) | length == 0' >/dev/null
}
check "http/search other tenant" search_other_tenant

echo "== $passed/$total checks passed"
[ "$passed" -eq "$total" ]
