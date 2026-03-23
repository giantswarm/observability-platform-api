# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Added new gRPC routes for Loki and Tempo write

### Changed

- Rename `mimir.writeRewritePaths` → `mimir.write.stripPrefixPaths` to clarify that the `/prometheus` prefix is stripped before forwarding; add equivalent `stripPrefixPaths: []` defaults to loki and tempo write config.
- Expose Tempo gRPC backend config in values (`tempo.read.grpc.backendService`, `tempo.read.grpc.backendPort`) instead of hardcoding in the template.
- Expose Loki and Mimir backend config in values (`loki.read.backendService`, `loki.read.backendPort`, `loki.write.backendService`, `loki.write.backendPort`, `mimir.read.backendService`, `mimir.read.backendPort`, `mimir.read.backendService`, `mimir.read.backendPort`) instead of hardcoding in the template.
- Restructure Helm templates into per-service subdirectories (`templates/loki/`, `templates/mimir/`, `templates/tempo/`).
- Share `HTTPRouteFilter` resources within each service: a single `headers-check` filter and (for Mimir/Tempo) a single `rewrite` filter are now referenced by all routes in that service namespace.

## [0.3.0] - 2026-03-11

### Added

- Add OTLP ingestion paths to Mimir and Loki HTTPRoutes

## [0.2.0] - 2026-03-04

### Added

- Add Gateway API `HTTPRoute` resources for Loki, Mimir, and Tempo (read and write), replacing the previous NGINX ingress setup.
- Add native JWT authentication via Envoy Gateway `SecurityPolicy.jwt`, supporting multiple OIDC providers (e.g. Dex, Azure AD). Configurable via `auth.jwt.providers`.
- Add `/loki/api/v1/rules` to the Loki read routes.
- Add `GRPCRoute` for Tempo gRPC traffic (port 9095), routing all `tempopb.*` services to `tempo-query-frontend` with JWT enforcement via `SecurityPolicy`.

### Changed

- Replace NGINX ingress-based auth (`nginx.ingress.kubernetes.io/auth-url`) with Envoy Gateway `SecurityPolicy` JWT validation — no external auth service (oauth2-proxy or Dex extAuth) required.
- Change missing `X-Scope-OrgID` response code from `400` to `401` across all routes.
- When `auth.jwt.providers` is empty and a service is enabled, routes are silently not rendered (no chart error). Previously the chart would fail with an error.
- Fix Tempo gRPC route service regex from `tempopb` to `tempopb\.[^/]+` to correctly match package-qualified service names (e.g. `tempopb.StreamingQuerier`).

### Removed

- Remove dependency on oauth2-proxy for write route authentication.
- Remove Envoy Gateway `Backend` CRD and `extAuth` configuration in favour of inline JWT validation.

## [0.1.2] - 2026-02-12

### Changed

- Change team annotation in `Chart.yaml` to OpenContainers format (`io.giantswarm.application.team`).

## [0.1.1] - 2026-01-30

### Changed

- Build with up-to-date pipelines.
- Enable TLS secret configuration for the ingresses. The default now changes to having a single shared secret per host in one namespace to avoid Let's Encrypt rate limiting
- Add Gateway API and Envoy Gateway resources.

## [0.1.0] - 2025-01-29

### Added

- add ingress template
- skaffolding of the application template

[Unreleased]: https://github.com/giantswarm/observability-platform-api/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/giantswarm/observability-platform-api/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/giantswarm/observability-platform-api/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/giantswarm/observability-platform-api/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/giantswarm/observability-platform-api/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/giantswarm/observability-platform-api/releases/tag/v0.1.0
