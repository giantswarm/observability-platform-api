##@ Testing

TEMPO_VERSION ?= v2.10.7

.PHONY: dex-token
dex-token: ## Print a Dex ID token from the device-code flow (needs BASE_URL).
	@./hack/dex-token.sh

.PHONY: test-tempo
test-tempo: ## Run the Tempo end-to-end test (needs BASE_URL; gets TOKEN from Dex when unset).
	@TOKEN="$${TOKEN:-$$(./hack/dex-token.sh)}" ./hack/test-tempo.sh

.PHONY: update-tempo-protoset
update-tempo-protoset: ## Regenerate hack/tempo.protoset for TEMPO_VERSION (needs git, protoc).
	@TEMPO_VERSION=$(TEMPO_VERSION) ./hack/update-tempo-protoset.sh
