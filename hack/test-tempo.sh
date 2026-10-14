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
# Dependencies:
#   curl, jq
#   grpcurl       go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest
#   telemetrygen  go install github.com/open-telemetry/opentelemetry-collector-contrib/cmd/telemetrygen@latest
# The gRPC checks use hack/tempo.protoset (make update-tempo-protoset).

# The jq filters reference $a, $b and $id in single quotes on purpose (see assert).
# shellcheck disable=SC2016

set -euo pipefail

: "${BASE_URL:?BASE_URL is required}"
: "${TOKEN:?TOKEN is required}"
TENANT="${TENANT:-giantswarm}"
TIMEOUT="${TIMEOUT:-60}"

PROTOSET="$(cd "$(dirname "$0")" && pwd)/tempo.protoset"
BASE_URL="${BASE_URL%/}"
HOST="${BASE_URL#https://}"
GRPC_HOST="${HOST%%/*}:443"

# Unique names per run, so each run only finds its own traces.
RUN_ID="$(date +%s)-$$"
SVC_HTTP="e2e-otlp-http-$RUN_ID"
SVC_GRPC="e2e-otlp-grpc-$RUN_ID"
OTHER_TENANT="$TENANT-isolation-$RUN_ID"
QUERY_HTTP="{resource.service.name=\"$SVC_HTTP\"}"
QUERY_GRPC="{resource.service.name=\"$SVC_GRPC\"}"
QUERY_METRICS="$QUERY_HTTP | count_over_time()"
TRACE_ID=""

# Query time window in unix seconds. END covers the longest possible run (4 polls).
START=$(( $(date +%s) - 600 ))
END=$(( $(date +%s) + 4 * TIMEOUT + 60 ))
WINDOW=(-d "start=$START" -d "end=$END")

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

passed=0
total=0

for dep in curl jq grpcurl telemetrygen; do
  command -v "$dep" >/dev/null || { echo "missing dependency: $dep" >&2; exit 1; }
done
[ -f "$PROTOSET" ] || { echo "missing $PROTOSET, run: make update-tempo-protoset" >&2; exit 1; }

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
# The retries run in the current shell, so variables CMD sets stay set.
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

# assert FILTER: tests stdin JSON against the jq FILTER.
# FILTER can use $a (SVC_HTTP), $b (SVC_GRPC) and $id (TRACE_ID).
assert() {
  jq -e --arg a "$SVC_HTTP" --arg b "$SVC_GRPC" --arg id "$TRACE_ID" "$1" >/dev/null
}

# http_json PATH FILTER [CURL_ARGS...]: GETs PATH and tests the JSON against FILTER.
http_json() {
  local path="$1" filter="$2"; shift 2
  api "$path" "$@" | assert "$filter"
}

# grpc_json METHOD JSON FILTER: calls METHOD and tests the slurped JSON against FILTER.
grpc_json() {
  grpc "$1" "$2" | assert "$3"
}

# other_tenant CMD...: runs CMD with TENANT set to OTHER_TENANT.
other_tenant() {
  TENANT="$OTHER_TENANT" "$@"
}

# status [CURL_ARGS...]: prints the HTTP status code.
status() {
  curl -s -o /dev/null -w '%{http_code}' "$@"
}

# expect WANT GOT: fails with a message when GOT differs from WANT.
expect() {
  [ "$1" = "$2" ] || { echo "want $1, got $2"; return 1; }
}

# write_otlp ENDPOINT [TELEMETRYGEN_ARGS...]: sends one trace.
write_otlp() {
  # telemetrygen exits 0 on export failures and logs them as "traces export: <error>".
  local endpoint="$1" out; shift
  out="$(telemetrygen traces --traces 1 --otlp-endpoint "$endpoint" \
    --otlp-header "Authorization=\"Bearer $TOKEN\"" \
    --otlp-header "X-Scope-OrgID=\"$TENANT\"" "$@" 2>&1)"
  ! echo "$out" | grep 'traces export:'
}

# search QUERY: fails when QUERY finds no trace, else saves the first trace ID in TRACE_ID.
search() {
  TRACE_ID="$(api /tempo/api/search --data-urlencode "q=$1" "${WINDOW[@]}" | jq -er '.traces[0].traceID')"
}

# grpc_no_token: expects the gRPC API to reject a call without a token.
grpc_no_token() {
  local out
  out="$(grpcurl -protoset "$PROTOSET" -H "X-Scope-OrgID: $TENANT" -d '{}' \
    "$GRPC_HOST" tempopb.StreamingQuerier/SearchTagsV2 2>&1)" || true
  echo "$out" | grep Unauthenticated
}

echo "Testing $BASE_URL as tenant $TENANT (run $RUN_ID)"

echo "== Write"
check "write/otlp-http" write_otlp "$GRPC_HOST" --otlp-http --service "$SVC_HTTP"
# passthrough skips the gRPC Go DNS resolver, which can hang where the system resolver works.
check "write/otlp-grpc" write_otlp "passthrough:///$GRPC_HOST" --service "$SVC_GRPC"

echo "== Read HTTP"
check "http/echo" expect echo "$(api /tempo/api/echo)"
check "http/buildinfo" http_json /tempo/api/status/buildinfo '.version | length > 0'
# The otlp-http search runs last: the checks below use the TRACE_ID it saves.
poll "http/search otlp-grpc" search "$QUERY_GRPC"
poll "http/search otlp-http" search "$QUERY_HTTP"
check "http/traces v1" http_json "/tempo/api/traces/$TRACE_ID" '(.batches // .resourceSpans) | length > 0'
check "http/traces v2" http_json "/tempo/api/v2/traces/$TRACE_ID" '.trace.resourceSpans | length > 0'
check "http/search/tags v1" http_json /tempo/api/search/tags '.tagNames | index("service.name")' "${WINDOW[@]}"
check "http/search/tag/values v1" http_json /tempo/api/search/tag/service.name/values '.tagValues | index($a) and index($b)' "${WINDOW[@]}"
check "http/search/tags v2" http_json /tempo/api/v2/search/tags '[.scopes[].tags[]] | index("service.name")' "${WINDOW[@]}"
check "http/search/tag/values v2" http_json /tempo/api/v2/search/tag/resource.service.name/values '[.tagValues[].value] | index($a) and index($b)' "${WINDOW[@]}"
poll "http/metrics/query_range" http_json /tempo/api/metrics/query_range '.series | length > 0' --data-urlencode "q=$QUERY_METRICS" "${WINDOW[@]}" -d "step=60s"

echo "== Read gRPC"
check "grpc/Search" grpc_json Search "{\"Query\": $(jq -n --arg q "$QUERY_HTTP" '$q'), \"start\": $START, \"end\": $END}" '[.[].traces[]?.traceID] | index($id)'
check "grpc/SearchTagsV2" grpc_json SearchTagsV2 "{\"start\": $START, \"end\": $END}" '[.[].scopes[]?.tags[]?] | index("service.name")'
check "grpc/SearchTagValuesV2" grpc_json SearchTagValuesV2 "{\"tagName\": \"resource.service.name\", \"start\": $START, \"end\": $END}" '[.[].tagValues[]?.value] | index($a) and index($b)'
# MetricsQueryRange takes nanoseconds.
poll "grpc/MetricsQueryRange" grpc_json MetricsQueryRange "{\"query\": $(jq -n --arg q "$QUERY_METRICS" '$q'), \"start\": ${START}000000000, \"end\": ${END}000000000, \"step\": 60000000000}" '[.[].series[]?] | length > 0'

echo "== Auth rejections"
check "http/read no token" expect 401 "$(status "$BASE_URL/tempo/api/echo" -H "X-Scope-OrgID: $TENANT")"
check "http/read no tenant" expect 401 "$(status "$BASE_URL/tempo/api/echo" -H "Authorization: Bearer $TOKEN")"
check "http/write no token" expect 401 "$(status -X POST "$BASE_URL/v1/traces" -H "X-Scope-OrgID: $TENANT" -H "Content-Type: application/json" -d '{"resourceSpans":[]}')"
check "grpc/read no token" grpc_no_token

echo "== Tenant isolation"
check "http/traces v1 other tenant" expect 404 "$(status "$BASE_URL/tempo/api/traces/$TRACE_ID" -H "Authorization: Bearer $TOKEN" -H "X-Scope-OrgID: $OTHER_TENANT")"
# The v2 endpoint answers 200 with an empty trace when the trace does not exist.
check "http/traces v2 other tenant" other_tenant http_json "/tempo/api/v2/traces/$TRACE_ID" '(.trace.resourceSpans // []) | length == 0'
check "http/search other tenant" other_tenant http_json /tempo/api/search '(.traces // []) | length == 0' --data-urlencode "q=$QUERY_HTTP" "${WINDOW[@]}"

echo "== $passed/$total checks passed"
[ "$passed" -eq "$total" ]
