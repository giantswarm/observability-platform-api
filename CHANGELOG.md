# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Enable TLS secret configuration for the ingresses. The default now changes to having a single shared secret per host in one namespace to avoid Let's Encrypt rate limiting

## [0.1.0] - 2025-01-29

### Added

- add ingress template
- skaffolding of the application template

[Unreleased]: https://github.com/giantswarm/observability-platform-api/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/giantswarm/observability-platform-api/releases/tag/v0.1.0
