# Testing Guide

This document describes how to configure and test all exposed routes (Loki, Mimir, Tempo — read and write).

## Prerequisites

- Access to a management cluster with the app deployed
- `curl` and `jq` installed
- `grpcurl` installed (for Tempo gRPC testing)
- An Azure AD app registration with a client secret, or a Dex OIDC client

## 1. Helm template check

Before deploying, verify the rendered output has no stale `extAuth` references and that auth blocks are rendered correctly:

```bash
helm template observability-platform-api \
  ./helm/observability-platform-api \
  -f helm/observability-platform-api/ci/test-values.yaml

# Confirm jwt: and basicAuth: blocks are present in SecurityPolicy, no extAuth: blocks
helm template observability-platform-api \
  ./helm/observability-platform-api \
  -f helm/observability-platform-api/ci/test-values.yaml \
  | grep -A12 'kind: SecurityPolicy'

helm template observability-platform-api \
  ./helm/observability-platform-api \
  -f helm/observability-platform-api/ci/test-values.yaml \
  | grep -c extAuth
# expect: 0

# Verify that enabling a service with no auth configured renders nothing (no routes created)
helm template observability-platform-api ./helm/observability-platform-api \
  --set loki.enabled=true | grep -c 'kind:'
# expect: 0

# Verify basicAuth-only rendering (no JWT providers)
helm template observability-platform-api ./helm/observability-platform-api \
  --set loki.enabled=true \
  --set loki.basicAuth.secretName=loki-basic-auth \
  | grep -A6 'kind: SecurityPolicy'
# expect: SecurityPolicy with only basicAuth: block (no jwt: block)
```

### What happens when auth is not configured?

Each route template renders only when the service is enabled **and** at least one auth method is configured for that service.

| Services enabled | `auth.jwt.providers` | `<svc>.basicAuth.secretName` | Result |
|-----------------|---------------------|-------------------------------------|--------|
| All false (default) | `[]` | `""` | Chart renders fine (no routes created) |
| Any true | `[]` | `""` | Chart renders fine (no routes created) |
| Any true | populated | `""` | Routes rendered with JWT only |
| Any true | `[]` | set | Routes rendered with Basic Auth only |
| Any true | populated | set | Routes rendered with both JWT and Basic Auth |

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

# For Basic Auth testing (replace with actual credentials from the .htpasswd secret)
BASIC_USER="myuser"
BASIC_PASS="mypassword"
BASIC_AUTH="Authorization: Basic $(echo -n "$BASIC_USER:$BASIC_PASS" | base64)"
```

## 4. Test all paths

For every path, the following scenarios are validated:

| Scenario | Expected (HTTP) | Expected (gRPC) |
|----------|----------------|-----------------|
| Valid JWT + `X-Scope-OrgID` present | 2xx (backend response) | grpc-status: 12 (backend reached) |
| Valid Basic Auth + `X-Scope-OrgID` present | 2xx (backend response) | grpc-status: 12 (backend reached) |
| Valid JWT, `X-Scope-OrgID` missing | 401 | no-route rejection (not a strict 401) |
| No auth credential | 401 | grpc-status: 16 (UNAUTHENTICATED) |

### Loki read

Backend: `loki-gateway:80`. No path rewrite.

```bash
# Full auth scenario test on representative path
curl -si "$BASE/loki/api/v1/labels" -H "$AUTH" -H "$SCOPE"        # expect 2xx (JWT)
curl -si "$BASE/loki/api/v1/labels" -H "$BASIC_AUTH" -H "$SCOPE"  # expect 2xx (Basic Auth)
curl -si "$BASE/loki/api/v1/labels" -H "$AUTH"                     # expect 401
curl -si "$BASE/loki/api/v1/labels" -H "$SCOPE"                    # expect 401

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
  -H "$BASIC_AUTH" -H "$SCOPE" -H "Content-Type: application/json" -d "$PAYLOAD"
# expect: 204 (Basic Auth)

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
curl -si "$BASE/prometheus/api/v1/labels" -H "$AUTH" -H "$SCOPE"        # expect 2xx (JWT)
curl -si "$BASE/prometheus/api/v1/labels" -H "$BASIC_AUTH" -H "$SCOPE"  # expect 2xx (Basic Auth)
curl -si "$BASE/prometheus/api/v1/labels" -H "$AUTH"                     # expect 401
curl -si "$BASE/prometheus/api/v1/labels" -H "$SCOPE"                    # expect 401

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

### Tempo read — HTTP

Backend: `tempo-query-frontend:3200`. Path rewrite: `/tempo` prefix stripped before forwarding.

```bash
curl -si "$BASE/tempo/api/echo" -H "$AUTH" -H "$SCOPE"        # expect 200, body: "echo" (JWT)
curl -si "$BASE/tempo/api/echo" -H "$BASIC_AUTH" -H "$SCOPE"  # expect 200, body: "echo" (Basic Auth)
curl -si "$BASE/tempo/api/echo" -H "$AUTH"                     # expect 401
curl -si "$BASE/tempo/api/echo" -H "$SCOPE"                    # expect 401

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

### Tempo read — gRPC

Backend: `tempo-query-frontend:9095`. Separate HTTPRoute from the HTTP routes above.

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

Backend: `tempo-distributor:4318`. OTLP HTTP only — no gRPC write route (matches old NGINX config).

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

## 5. Verify SecurityPolicy status in-cluster

After deployment, confirm Envoy accepted all SecurityPolicies:

```bash
kubectl get securitypolicy -A
# All policies should show ACCEPTED=True

RELEASE="observability-platform-api"
for NS_NAME in \
  "loki/$RELEASE-loki-read-api" \
  "loki/$RELEASE-loki-write-api" \
  "mimir/$RELEASE-mimir-read-api" \
  "mimir/$RELEASE-mimir-write-api" \
  "tempo/$RELEASE-tempo-read-api" \
  "tempo/$RELEASE-tempo-read-api-grpc" \
  "tempo/$RELEASE-tempo-otlp-write-api"; do
  NS=$(echo $NS_NAME | cut -d/ -f1)
  NAME=$(echo $NS_NAME | cut -d/ -f2)
  STATUS=$(kubectl get securitypolicy -n $NS $NAME -o json 2>/dev/null \
    | jq -r '(.status.ancestors // [])[].conditions[] | select(.type=="Accepted") | .status')
  echo "$NS_NAME → ${STATUS:-NOT FOUND}"
done
# expect: True for all
```
