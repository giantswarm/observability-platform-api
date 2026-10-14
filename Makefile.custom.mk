##@ Testing

TEMPO_VERSION ?= v2.10.7

.PHONY: dex-token
dex-token: ## Print a Dex ID token from the device-code flow (needs BASE_URL).
	@./hack/dex-token.sh

.PHONY: test-tempo
test-tempo: ## Run the Tempo end-to-end test (needs BASE_URL; gets TOKEN from Dex when unset).
	@TOKEN="$${TOKEN:-$$(./hack/dex-token.sh)}" ./hack/test-tempo.sh

# Reproduces the proto patching of Tempo's gen-proto target, without buf.
.PHONY: update-tempo-protoset
update-tempo-protoset: ## Regenerate hack/tempo.protoset for TEMPO_VERSION (needs git, protoc).
	set -eu; \
	out="$(CURDIR)/hack/tempo.protoset"; \
	tmp="$$(mktemp -d)"; \
	trap 'rm -rf "$$tmp"' EXIT; \
	git -c advice.detachedHead=false clone -q --depth 1 --branch $(TEMPO_VERSION) https://github.com/grafana/tempo.git "$$tmp"; \
	cd "$$tmp"; \
	git submodule update -q --init --depth 1; \
	mkdir -p pkg/.patched-proto; \
	cp -R opentelemetry-proto/opentelemetry/proto/* pkg/.patched-proto/; \
	find pkg/.patched-proto -name '*.proto' -exec sed -i.bak \
		-e 's+ opentelemetry.proto+ tempopb+g' \
		-e 's+import "opentelemetry/proto/+import "+g' {} \; ; \
	protoc --proto_path . -Ipkg/.patched-proto -Ivendor -Ivendor/github.com/gogo/protobuf \
		--descriptor_set_out="$$out" --include_imports ./pkg/tempopb/tempo.proto; \
	echo "wrote $$out for Tempo $(TEMPO_VERSION)"
