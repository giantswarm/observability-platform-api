# Testing Guide

This document describes how to configure and test all exposed routes (Loki, Mimir, Tempo — read and write).

## Prerequisites

- Access to a management cluster with the app deployed
- `curl` and `jq` installed
- `grpcurl` installed (for Tempo and Loki gRPC testing)
- An Azure AD app registration with a client secret, or a Dex OIDC client

## 1. Helm template check

Before deploying, verify the rendered output has no stale `extAuth` references and that auth blocks are rendered correctly:

```bash
helm template observability-platform-api \
  ./helm/observability-platform-api \
  -f helm/observability-platform-api/ci/test-values.yaml

# Confirm jwt: blocks are present in SecurityPolicy, no extAuth: blocks
helm template observability-platform-api \
  ./helm/observability-platform-api \
  -f helm/observability-platform-api/ci/test-values.yaml \
  | grep -A8 'kind: SecurityPolicy'

helm template observability-platform-api \
  ./helm/observability-platform-api \
  -f helm/observability-platform-api/ci/test-values.yaml \
  | grep -c extAuth
# expect: 0

# Verify that enabling a service with no auth configured renders nothing (no routes created)
helm template observability-platform-api ./helm/observability-platform-api \
  --set loki.enabled=true | grep -c 'kind:'
# expect: 0
```

### What happens when auth is not configured?

Each route template renders only when the service is enabled **and** `auth.jwt.providers` is configured.

| Services enabled | `auth.jwt.providers` | Result |
|-----------------|---------------------|--------|
| All false (default) | `[]` | Chart renders fine (no routes created) |
| Any true | `[]` | Chart renders fine (no routes created) |
| Any true | populated | Routes rendered with JWT |

## 2. Get a test token

### From Azure AD (service principal)

The `ci/test-values.yaml` file is pre-configured for tenant `31f75bf9-3d8c-4691-95c0-83dd71613db8`. You need an app registration in that tenant with a client secret.

```bash
TENANT_ID="31f75bf9-3d8c-4691-95c0-83dd71613db8"
CLIENT_ID="clientID"
CLIENT_SECRET="clientSecret"

TOKEN=$(curl -s -X POST \
  "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret=$CLIENT_SECRET" \
  --data-urlencode "scope=$CLIENT_ID/.default" \
  --data-urlencode "grant_type=client_credentials" \
  | jq -r '.access_token')

# Verify the iss claim matches the issuer configured in test-values.yaml
echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | jq '{iss, aud, exp}'
# iss should be: https://login.microsoftonline.com/31f75bf9-3d8c-4691-95c0-83dd71613db8/v2.0
```

> **Note on token versions**: the `iss` claim differs between v1.0 and v2.0 tokens:
> - v2.0 (`/oauth2/v2.0/token`): `https://login.microsoftonline.com/<tenant-id>/v2.0`
> - v1.0 (`/oauth2/token`): `https://sts.windows.net/<tenant-id>/`
>
> The `ci/test-values.yaml` is configured for v2.0. If you use v1.0 tokens, update the `issuer` and `remoteJWKS.uri` accordingly.

### From Dex

```bash
TOKEN=$(kubectl oidc-login get-token \
  --oidc-issuer-url="https://dex.<codename>.<base-domain>" \
  --oidc-client-id=<client-id> | jq -r '.status.token')
```

## 3. Set test variables

```bash
BASE="https://observability.<codename>.<base-domain>"
ORG="my-tenant"
AUTH="Authorization: Bearer $TOKEN"
SCOPE="X-Scope-OrgID: $ORG"
GRPC_HOST="${BASE#https://}"
```

## 4. Test all paths

For every path, the following scenarios are validated:

| Scenario | Expected (HTTP) | Expected (gRPC) |
|----------|----------------|-----------------|
| Valid JWT + `X-Scope-OrgID` present | 2xx (backend response) | grpc-status: 12 (backend reached) |
| Valid JWT, `X-Scope-OrgID` missing | 401 | no-route rejection (not a strict 401) |
| No auth credential | 401 | grpc-status: 16 (UNAUTHENTICATED) |

### Loki read

Backend: `loki-gateway:80`. No path rewrite.

```bash
# Full auth scenario test on representative path
curl -si "$BASE/loki/api/v1/labels" -H "$AUTH" -H "$SCOPE"  # expect 2xx (JWT)
curl -si "$BASE/loki/api/v1/labels" -H "$AUTH"               # expect 401
curl -si "$BASE/loki/api/v1/labels" -H "$SCOPE"              # expect 401

# Smoke test all paths (valid auth)
for p in \
  /loki/api/v1/label \
  /loki/api/v1/rules \
  /loki/api/v1/query \
  /loki/api/v1/query_range \
  /loki/api/v1/index/stats \
  /loki/api/v1/series \
  /loki/api/v1/detected_labels; do
  echo "$p → $(curl -so /dev/null -w '%{http_code}' "$BASE$p" -H "$AUTH" -H "$SCOPE")"
done
# expect: 200 or 400 (params required) — not 401/403
```

Note: `/loki/api/v1/rules` is a new path not present in the old NGINX config.

### Loki write

Backend: `loki-gateway:80`.

```bash
PAYLOAD='{"streams":[{"stream":{"job":"test"},"values":[["'"$(date +%s%N)"'","test log line"]]}]}'

curl -si -X POST "$BASE/loki/api/v1/push" \
  -H "$AUTH" -H "$SCOPE" -H "Content-Type: application/json" -d "$PAYLOAD"
# expect: 204 (JWT)

curl -si -X POST "$BASE/loki/api/v1/push" \
  -H "$AUTH" -H "Content-Type: application/json" -d "$PAYLOAD"
# expect: 401 (missing X-Scope-OrgID)

curl -si -X POST "$BASE/loki/api/v1/push" \
  -H "$SCOPE" -H "Content-Type: application/json" -d "$PAYLOAD"
# expect: 401 (no auth credential)
```

### Mimir read

Backend: `mimir-gateway:80`. No path rewrite.

```bash
curl -si "$BASE/prometheus/api/v1/labels" -H "$AUTH" -H "$SCOPE"  # expect 2xx (JWT)
curl -si "$BASE/prometheus/api/v1/labels" -H "$AUTH"               # expect 401
curl -si "$BASE/prometheus/api/v1/labels" -H "$SCOPE"              # expect 401

for p in \
  /prometheus/api/v1/label/__name__/values \
  /prometheus/api/v1/rules \
  /prometheus/api/v1/query \
  /prometheus/api/v1/query_range \
  /prometheus/api/v1/query_exemplars \
  /prometheus/api/v1/status/buildinfo \
  /prometheus/api/v1/metadata; do
  echo "$p → $(curl -so /dev/null -w '%{http_code}' "$BASE$p" -H "$AUTH" -H "$SCOPE")"
done
# expect: 200 or 400 (params required) — not 401/403
```

### Mimir write

Backend: `mimir-gateway:80`. Path rewrite: `/prometheus/api/v1/push` → `/api/v1/push`.

```bash
curl -si -X POST "$BASE/prometheus/api/v1/push" \
  -H "$AUTH" -H "$SCOPE" \
  -H "Content-Type: application/x-protobuf" \
  -H "X-Prometheus-Remote-Write-Version: 0.1.0" \
  --data-binary @/dev/null
# expect: 204 or 400 (backend validates payload) — not 401

curl -si -X POST "$BASE/prometheus/api/v1/push" -H "$AUTH"   # expect 401
curl -si -X POST "$BASE/prometheus/api/v1/push" -H "$SCOPE"  # expect 401
```

### Mimir write — OTLP HTTP

Backend: `mimir-gateway:80`. No path rewrite. Path: `/otlp/v1/metrics`.

> **Label promotion**: Mimir maps `service.name` + `service.namespace` to `job` as `"<namespace>/<name>"`.
> Other resource attributes are written to a separate `target_info` metric rather than promoted to labels.

```bash
# Push a counter with resource attributes
curl -si -X POST "$BASE/otlp/v1/metrics" \
  -H "$AUTH" -H "$SCOPE" \
  -H "Content-Type: application/json" \
  -d '{
    "resourceMetrics": [{
      "resource": {
        "attributes": [
          {"key": "service.name", "value": {"stringValue": "otlp-test"}},
          {"key": "service.namespace", "value": {"stringValue": "my-namespace"}}
        ]
      },
      "scopeMetrics": [{
        "metrics": [{
          "name": "test_counter_total",
          "sum": {
            "aggregationTemporality": 2,
            "isMonotonic": true,
            "dataPoints": [{"asDouble": 1.0, "timeUnixNano": "'"$(date +%s%N)"'"}]
          }
        }]
      }]
    }]
  }'
# expect: 200 {}

# Verify ingestion — job label is "my-namespace/otlp-test"
curl -s "$BASE/prometheus/api/v1/query" \
  -H "$AUTH" -H "$SCOPE" \
  --data-urlencode 'query=test_counter_total{job="my-namespace/otlp-test"}' | jq '.data.result'
# expect: non-empty result with value 1

curl -si -X POST "$BASE/otlp/v1/metrics" -H "$AUTH"   # expect 401
curl -si -X POST "$BASE/otlp/v1/metrics" -H "$SCOPE"  # expect 401
```

### Tempo read — HTTP

Backend: `tempo-query-frontend:3200`. Path rewrite: `/tempo` prefix stripped before forwarding.

```bash
curl -si "$BASE/tempo/api/echo" -H "$AUTH" -H "$SCOPE"  # expect 200, body: "echo" (JWT)
curl -si "$BASE/tempo/api/echo" -H "$AUTH"               # expect 401
curl -si "$BASE/tempo/api/echo" -H "$SCOPE"              # expect 401

for p in \
  /tempo/api/status/buildinfo \
  /tempo/api/search \
  /tempo/api/v2/search/tags \
  /tempo/api/metrics/query_range \
  /tempo/api/traces/0000000000000000 \
  /tempo/api/v2/traces/0000000000000000; do
  echo "$p → $(curl -so /dev/null -w '%{http_code}' "$BASE$p" -H "$AUTH" -H "$SCOPE")"
done
# expect: 200, 400 (params required), or 404 (trace not found) — not 401/403
```

### Loki write — HTTP OTLP

Backend: `loki-gateway:80`. Path: `/otlp/v1/logs`.

> **Label promotion**: Loki maps `service.name` to the `service_name` stream label (not `job`).
> Query logs with `{service_name="<value>"}` after ingestion.

```bash
curl -si -X POST "$BASE/otlp/v1/logs" \
  -H "$AUTH" -H "$SCOPE" \
  -H "Content-Type: application/json" \
  -d '{
    "resourceLogs": [{
      "resource": {
        "attributes": [
          {"key": "service.name", "value": {"stringValue": "otlp-test"}}
        ]
      },
      "scopeLogs": [{
        "logRecords": [{
          "timeUnixNano": "'"$(date +%s%N)"'",
          "severityText": "INFO",
          "body": {"stringValue": "hello from otlp http"}
        }]
      }]
    }]
  }'
# expect: 204

# Verify ingestion — service.name maps to service_name stream label
curl -s "$BASE/loki/api/v1/query_range" \
  -H "$AUTH" -H "$SCOPE" \
  --data-urlencode 'query={service_name="otlp-test"}' \
  --data-urlencode "start=$(date -d '5 minutes ago' +%s%N)" \
  --data-urlencode "end=$(date +%s%N)" \
  | jq '.data.result'
# expect: non-empty array with your log line

curl -si -X POST "$BASE/otlp/v1/logs" -H "$AUTH"   # expect 401
curl -si -X POST "$BASE/otlp/v1/logs" -H "$SCOPE"  # expect 401
```

### Loki write — gRPC OTLP

Backend: `loki-distributor:9095`. Separate `GRPCRoute` — bypasses `loki-gateway` (nginx does not handle gRPC).

> **Note on missing `X-Scope-OrgID`**: `GRPCRoute` does not support `HTTPRouteFilter` via `ExtensionRef`, so requests missing `X-Scope-OrgID` get a no-route rejection rather than a strict 401.

```bash
# Push logs with a real payload using grpcurl
grpcurl \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Scope-OrgID: $ORG" \
  -d '{
    "resourceLogs": [{
      "resource": {
        "attributes": [{"key": "service.name", "value": {"stringValue": "otlp-test-grpc"}}]
      },
      "scopeLogs": [{
        "logRecords": [{
          "severityText": "INFO",
          "body": {"stringValue": "hello from otlp grpc"}
        }]
      }]
    }]
  }' \
  "$GRPC_HOST:443" \
  opentelemetry.proto.collector.logs.v1.LogsService/Export
# expect: {} (empty response = success)

# Verify ingestion
curl -s "$BASE/loki/api/v1/query_range" \
  -H "$AUTH" -H "$SCOPE" \
  --data-urlencode 'query={service_name="otlp-test-grpc"}' \
  --data-urlencode "start=$(date -d '5 minutes ago' +%s%N)" \
  --data-urlencode "end=$(date +%s%N)" \
  | jq '.data.result'

# Auth check — bare gRPC frame (no payload), grpc-status: 12 = backend reached
curl -si --http2 -X POST "https://$GRPC_HOST/opentelemetry.proto.collector.logs.v1.LogsService/Export" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Scope-OrgID: $ORG" \
  -H "Content-Type: application/grpc" \
  --data-binary $'\x00\x00\x00\x00\x00'
# expect: grpc-status: 12 (not 16)

# No JWT — SecurityPolicy returns grpc-status: 16 (UNAUTHENTICATED)
curl -si --http2 -X POST "https://$GRPC_HOST/opentelemetry.proto.collector.logs.v1.LogsService/Export" \
  -H "X-Scope-OrgID: $ORG" \
  -H "Content-Type: application/grpc" \
  --data-binary $'\x00\x00\x00\x00\x00'
# expect: grpc-status: 16
```

### Tempo read — gRPC

Backend: `tempo-query-frontend:9095`. Separate `GRPCRoute` from the HTTP routes above.

> **Note on GRPCRoute**: The gRPC route uses `GRPCRoute` (not `HTTPRoute`) because Envoy
> Gateway's SecurityPolicy JWT enforcement does not correctly apply to gRPC traffic routed
> via HTTPRoute. `GRPCRoute` does not support `HTTPRouteFilter` via `ExtensionRef`, so the
> single rule only matches requests that include `X-Scope-OrgID`. Requests missing the header
> do not match any rule and are rejected by Envoy (no route match — not a strict 401).
>
> **Note on HTTP/2**: If gRPC calls return `INTERNAL` errors, a `BackendTrafficPolicy` with
> `http2.enabled: true` may be needed on the `tempo-read-api-grpc` GRPCRoute.

```bash
GRPC_HOST="${BASE#https://}"

# Valid auth — request reaches Tempo, which returns grpc-status: 12 (UNIMPLEMENTED)
# because the bare gRPC frame has no payload. grpc-status: 12 confirms routing and
# auth succeeded; grpc-status: 16 would indicate JWT rejection.
curl -si --http2 -X POST "https://$GRPC_HOST/tempopb.StreamingQuerier/SearchTagsV2" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Scope-OrgID: $ORG" \
  -H "Content-Type: application/grpc" \
  --data-binary $'\x00\x00\x00\x00\x00'
# expect: grpc-status: 12 (not 16)

# Missing X-Scope-OrgID — no rule matches, Envoy rejects (not a strict 401 for gRPC)
curl -si --http2 -X POST "https://$GRPC_HOST/tempopb.StreamingQuerier/SearchTagsV2" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/grpc" \
  --data-binary $'\x00\x00\x00\x00\x00'
# expect: rejection (grpc-status: 12 or similar — request does not reach backend)

# No JWT — SecurityPolicy returns grpc-status: 16 (UNAUTHENTICATED)
curl -si --http2 -X POST "https://$GRPC_HOST/tempopb.StreamingQuerier/SearchTagsV2" \
  -H "X-Scope-OrgID: $ORG" \
  -H "Content-Type: application/grpc" \
  --data-binary $'\x00\x00\x00\x00\x00'
# expect: grpc-status: 16
```

### Tempo OTLP write

Backend: `tempo-distributor:4318`. OTLP HTTP trace ingestion.

```bash
curl -si -X POST "$BASE/v1/traces" \
  -H "$AUTH" -H "$SCOPE" \
  -H "Content-Type: application/json" \
  -d '{"resourceSpans":[]}'
# expect: 200 with {"partialSuccess":{}}

curl -si -X POST "$BASE/v1/traces" \
  -H "$AUTH" -H "Content-Type: application/json" -d '{}'
# expect: 401

curl -si -X POST "$BASE/v1/traces" \
  -H "$SCOPE" -H "Content-Type: application/json" -d '{}'
# expect: 401
```

### Tempo write — gRPC OTLP

Backend: `tempo-distributor:4317`. Separate `GRPCRoute` — routes directly to `tempo-distributor` (nginx does not handle gRPC).

> **Note on missing `X-Scope-OrgID`**: `GRPCRoute` does not support `HTTPRouteFilter` via `ExtensionRef`, so requests missing `X-Scope-OrgID` get a no-route rejection rather than a strict 401.

```bash
# With auth and X-Scope-OrgID — reaches backend
grpcurl -H "Authorization: Bearer $TOKEN" \
  -H "X-Scope-OrgID: $ORG" \
  "$GRPC_HOST:443" \
  opentelemetry.proto.collector.trace.v1.TraceService/Export
# expect: response from tempo-distributor (grpc-status: 0 or similar — not 16)

# No JWT — SecurityPolicy returns grpc-status: 16 (UNAUTHENTICATED)
curl -si --http2 -X POST "https://$GRPC_HOST/opentelemetry.proto.collector.trace.v1.TraceService/Export" \
  -H "X-Scope-OrgID: $ORG" \
  -H "Content-Type: application/grpc" \
  --data-binary $'\x00\x00\x00\x00\x00'
# expect: grpc-status: 16
```

## 5. Verify SecurityPolicy status in-cluster

After deployment, confirm Envoy accepted all SecurityPolicies:

```bash
kubectl get securitypolicy -A
# All policies should show ACCEPTED=True

RELEASE="observability-platform-api"
# One consolidated SecurityPolicy per service (covers all routes in that namespace).
for NS_NAME in \
  "loki/$RELEASE-loki" \
  "mimir/$RELEASE-mimir" \
  "tempo/$RELEASE-tempo"; do
  NS=$(echo $NS_NAME | cut -d/ -f1)
  NAME=$(echo $NS_NAME | cut -d/ -f2)
  STATUS=$(kubectl get securitypolicy -n $NS $NAME -o json 2>/dev/null \
    | jq -r '(.status.ancestors // [])[].conditions[] | select(.type=="Accepted") | .status')
  echo "$NS_NAME → ${STATUS:-NOT FOUND}"
done
# expect: True for all
```
