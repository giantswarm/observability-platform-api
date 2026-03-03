# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add Gateway API `HTTPRoute` resources for Loki, Mimir, and Tempo (read and write), replacing the previous NGINX ingress setup.
- Add native JWT authentication via Envoy Gateway `SecurityPolicy.jwt`, supporting multiple OIDC providers (e.g. Dex, Azure AD). Configurable via `auth.jwt.providers`.
- Add `/loki/api/v1/rules` to the Loki read routes.

### Changed

- Replace NGINX ingress-based auth (`nginx.ingress.kubernetes.io/auth-url`) with Envoy Gateway `SecurityPolicy` JWT validation — no external auth service (oauth2-proxy or Dex extAuth) required.
- Change missing `X-Scope-OrgID` response code from `400` to `401` across all routes.
- `auth.jwt.providers` is required when any of `loki.enabled`, `mimir.enabled`, or `tempo.enabled` is `true`.

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

[Unreleased]: https://github.com/giantswarm/observability-platform-api/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/giantswarm/observability-platform-api/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/giantswarm/observability-platform-api/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/giantswarm/observability-platform-api/releases/tag/v0.1.0
