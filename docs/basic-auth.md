# Basic Auth routes

Some clients cannot present an OIDC token. Two cases exist:

- An external, customer-managed Grafana: its core Prometheus and Loki
  datasources have no OAuth2 client-credentials support, and *Forward OAuth
  identity* only covers interactive queries. Alerting rules evaluate without a
  user session, so they have no token to forward.
- Agents holding an [AgentCredential](https://github.com/giantswarm/observability-operator):
  self-service, per-agent and per-backend credentials, created, rotated and
  revoked through Kubernetes.

For those clients, `basicAuth.enabled` serves routes on a **separate hostname**,
authenticated with HTTP Basic Auth instead of a JWT. The JWT routes are
untouched, and `auth.jwt.providers` stays required.

## Reads and writes

The hostname serves two independent route sets, each with its own users:

| | Read routes | Write routes |
|---|---|---|
| Users | hand-managed, one Secret: `basicAuth.usersSecret` | AgentCredentials, one Secret per backend: `basicAuth.agentCredential.usersSecrets.{metrics,logs,traces}` |
| Mimir | read paths | remote-write (`/prometheus` prefix stripped), OTLP metrics |
| Loki | read paths | native push, OTLP logs |
| Tempo | none (JWT only) | OTLP/HTTP, OTLP/gRPC |
| Rendered when | `usersSecret.name` and `.namespace` are set (the defaults) | `agentCredential.enabled` is set (off by default) |

Both sets need `basicAuth.enabled` and `basicAuth.hostname`, and either can run
without the other: set `usersSecret.name: ""` to serve writes only.

Each route carries exactly one `SecurityPolicy`, and each policy reads exactly
one Secret: `<release>-<service>-basicauth` checks the read route against the
hand-managed Secret, `<release>-<service>-basicauth-write` checks that backend's
write routes against its AgentCredential Secret. So:

- a hand-managed read user gets `401` on every write route;
- an AgentCredential gets `401` on every read route;
- an AgentCredential for one backend gets `401` on the other backends' write
  routes.

In short, reads use hand-managed htpasswd users or a JWT, and writes use
AgentCredentials or a JWT.

Each route on the Basic Auth hostname mirrors the paths, rewrites and backends
of the matching JWT route: they render from the same templates.

### Read routes

```yaml
basicAuth:
  enabled: true
  hostname: "observability-basicauth.<codename>.<base-domain>"
  parentRefs:
  - name: giantswarm-default
    namespace: envoy-gateway-system
  usersSecret:
    name: observability-platform-api-basic-auth-credentials
    namespace: monitoring   # default
```

This renders, per enabled service (Mimir, Loki), an `HTTPRoute` on
`basicAuth.hostname` reusing that service's existing `read.paths` /
`read.backendService` / `read.backendPort`, plus a `SecurityPolicy` carrying
only `basicAuth`, plus a headers-check `HTTPRouteFilter`. A single
`ReferenceGrant` in `usersSecret.namespace` lets both SecurityPolicies read the
one Secret.

### Write routes

```yaml
basicAuth:
  enabled: true
  hostname: "observability-basicauth.<codename>.<base-domain>"
  agentCredential:
    enabled: true
    usersSecrets:          # the defaults
      metrics:
        name: mimir-gateway-httproute-auth
        namespace: ""      # empty: mimir.namespace
      logs:
        name: loki-gateway-httproute-auth
        namespace: ""      # empty: loki.namespace
      traces:
        name: tempo-gateway-httproute-auth
        namespace: ""      # empty: tempo.namespace
```

The defaults are the HTTPRoute Secrets the observability-operator writes for
each backend from the AgentCredentials. This renders, per enabled service, the
write routes in the table above on `basicAuth.hostname`, one `SecurityPolicy`
targeting them with that backend's Secret, and the backend's headers-check
`HTTPRouteFilter` (shared with its read route, if any).

- A Secret in its backend's namespace (the default) needs no `ReferenceGrant`.
  A Secret in another namespace gets its own, which lets only that backend's
  write SecurityPolicy read only that Secret.
- A backend whose Secret `name` is empty gets no write routes.
- A backend with **no AgentCredentials** answers `500` on its write routes. The operator writes that backend's Secret only once a credential exists, and leaves its `.htpasswd` empty after the last one is deleted. Envoy Gateway rejects a missing or empty users Secret and fails closed. This is expected: create an AgentCredential for the backend.

### Both

`X-Scope-OrgID` is enforced exactly as on the JWT routes: present and non-empty,
or `401` on HTTP routes. The OTLP/gRPC route doesn't match without it, so the
request is rejected with no route match. Basic Auth authenticates the caller;
it does not scope them to a tenant. The same is true of the JWT routes today.

> **Prerequisite:** the `giantswarm-default` Gateway's wildcard listener and
> certificate span a single label, so `basicAuth.hostname` must be of the form
> `observability-basicauth.<codename>.<base-domain>`. A dotted variant such as
> `observability.basicauth.<codename>.<base-domain>` would need an explicit SAN
> on the certificate.

## Why a separate hostname

Envoy Gateway runs the `jwt` and `basicAuth` filters of a `SecurityPolicy`
sequentially, with AND semantics: a route configured with both rejects every
request, whichever credential it carries — a JWT gets `Expected 'Basic'
authentication scheme`, Basic credentials get `Jwt is missing`. See
[envoyproxy/gateway#8491](https://github.com/envoyproxy/gateway/issues/8491).

Separate routes on a separate hostname is the workaround: each route carries
exactly one auth method, so the two never meet in one filter chain.

## Basic Auth credential format

The chart does **not** create, template or manage the users Secrets. The
observability-operator writes the AgentCredential Secrets of the write routes.
The hand-managed Secret of the read routes is provisioned and rotated out of
band by whoever owns the credentials, so no password or password hash passes
through this chart's values or through Giant Swarm configuration. The rest of
this section and [Rotation](#rotation) describe the hand-managed Secret; the
format is the same for both.

The chart renders the routes based on the *values* alone — it never looks the
Secret up in the cluster — so the Secret and the chart can be applied in either
order, and creating the Secret afterwards needs no redeploy:

- If the Secret is missing when the chart deploys, Envoy Gateway cannot resolve
  the `SecurityPolicy` and sets a **500 direct response** on the affected routes.
  It fails closed: the routes are never briefly unauthenticated.
- Envoy Gateway watches Secrets and indexes `basicAuth.users` references, so it
  picks the Secret up on its own once created. The same applies to later edits,
  which is what makes [rotation](#rotation) a Secret-only operation.

The Secret must contain a `.htpasswd` key, one `user:hash` entry per line:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: observability-platform-api-basic-auth-credentials
  namespace: monitoring
type: Opaque
stringData:
  .htpasswd: |
    acme-grafana-1:{SHA}3WBs1Ju70GtMJgb8JEn4+4eXV4Y=
```

**Only the `{SHA}` scheme is supported.** Modern `htpasswd` defaults to bcrypt,
which Envoy rejects — pass `-s` explicitly:

```bash
# prompts for the password (keeps it out of shell history)
htpasswd -ns acme-grafana-1

# or, without apache2-utils:
printf '%s' '<password>' | openssl sha1 -binary | openssl base64
# prefix the result with {SHA} and the username
```

Conventions worth keeping to:

- **Use a long random password.** `{SHA}` is unsalted SHA-1, so a weak password
  is cheap to recover from the hash. 32+ random characters, not a passphrase.
- **Name the user after the consumer and its generation** — `acme-grafana-1`,
  not `grafana`. The suffix is what makes rotation possible.
- CRLF line endings are normalised, so a file authored on Windows is fine.

## Rotation

The `.htpasswd` key holds a *list*, which is the rotation mechanism. There is no
coordinated cutover and no involvement from Giant Swarm:

1. Add a second entry with a new username and password. Both now work.
2. Switch the client (e.g. the Grafana datasource) to the new credential. If
   anything goes wrong, the old one is still live — switch back.
3. Delete the old entry.

Giant Swarm cannot read, recover or reset these credentials. If they are lost,
the holder replaces the hash themselves.

Revocation does not depend on the credential holder: emptying the `.htpasswd`
key, or setting `basicAuth.enabled: false`, removes access without touching the
JWT routes.

## Troubleshooting

A malformed Secret surfaces on the `SecurityPolicy` status rather than in the
chart, since the chart never validates its contents:

```bash
kubectl get securitypolicy -n mimir <release>-mimir-basicauth -o yaml         # read
kubectl get securitypolicy -n mimir <release>-mimir-basicauth-write -o yaml   # write (also loki, tempo)
```

| Symptom | Cause |
|---|---|
| Every request gets `500` | The `SecurityPolicy` did not translate — see its status for which of the two below it is. Envoy Gateway fails closed rather than serving the routes unauthenticated |
| `secret <ns>/<name> does not exist` | Secret missing, or `ReferenceGrant` not applied |
| `secret <ns>/<name> must contain a non-empty ".htpasswd" key` | Wrong key name, or empty value. On a write route this also means the backend has no AgentCredentials yet, or its last one was deleted |
| Policy accepted, but every request gets `401` | Hash is not `{SHA}` (bcrypt/MD5), or the password does not match |
| `401` with a valid credential | `X-Scope-OrgID` header missing or empty |

`500` means the policy is broken; `401` means the policy is working and the
credential is not. That distinction is the fastest way to tell a Kubernetes-level
problem from a credential-level one.

If `basicAuth.enabled` is set but `hostname` is empty *in the values*, nothing
is rendered at all; if `usersSecret.name` or `usersSecret.namespace` is, no read
route is —
the same convention the JWT routes follow with an empty `auth.jwt.providers`.
This is a values check, not a cluster lookup: a configured but non-existent
Secret still renders the routes, and produces the `500` above.

## Removing Basic Auth (maintainers)

> This subsection is for maintainers of this chart. It is not part of operating
> or using the Basic Auth routes — if you are configuring an installation or
> managing credentials, stop at the previous subsection.

This is a stopgap, to be removed once
[envoyproxy/gateway#8491](https://github.com/envoyproxy/gateway/issues/8491)
lands and a single route can accept either credential. The upstream Envoy half
is already merged ([envoyproxy/envoy#43911](https://github.com/envoyproxy/envoy/pull/43911),
adding `allow_missing` to the basic_auth filter); what remains is the Envoy
Gateway API for it.

The feature is deliberately self-contained — no existing template references it.
Its routes render from the JWT routes' named templates in
`templates/<service>/_routes.tpl`, which stay. To remove it: delete
`templates/basicauth/`, `tests/basicauth_*_test.yaml`,
`ci/agentcredential-values.yaml`, delete the `basicAuth` block from
`values.yaml` and `values.schema.json`, and drop the hostname from the parent
Gateway. To migrate instead of remove, move `basicAuth.users` into the
per-service `SecurityPolicy` alongside `jwt`.
