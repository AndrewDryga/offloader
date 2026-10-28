# Offloader — V1 gate targets. Keep these boring and explicit.
#
#   check         fast local gate: run every component check that exists. Stays green on
#                 the bare scaffold; each component task fills in its own sub-target.
#   e2e           manifest -> materialize -> HTTP smoke. Fails until the server runs (G01, E02).
#   deploy-check  build + boot the production image locally. Fails until it exists (I01, I04).
#   doctor        report the required toolchain.
#
# Component tasks REPLACE the stub sub-target body with a real check (e.g. G01 makes
# server-check run the mix gate). Until then a stub prints "skip …" and exits 0, so the
# fast gate is green on an empty scaffold. e2e and deploy-check fail loudly on purpose:
# there is nothing to smoke yet.
.DEFAULT_GOAL := help

check: server-check tools-check docs-check ## Fast local gate: every component check that exists

server-check: ## Server (Elixir/Phoenix) gate: deps, compile (warnings-as-errors), format, test
	cd server && mix deps.get && mix compile --warnings-as-errors && mix format --check-formatted && mix test

tools-check: ## Helper tooling (Go) gate: gofmt, vet, tidy, race tests
	@test -z "$$(gofmt -l -s tools/)" || { echo "gofmt: run 'gofmt -s -w tools/'"; gofmt -l -s tools/; exit 1; }
	cd tools && go vet ./...
	cd tools && go mod tidy
	git diff --exit-code -- tools/go.mod tools/go.sum
	cd tools && go test -race -count=1 ./...

docs-check: dev/docs-site/node_modules ## Docs gate: no overclaims; generated docs and sitemap match their sources
	./dev/scripts/docs-check.sh
	npm run check --prefix dev/docs-site

# Install the docs renderer's pinned dependencies on first use, as server-check does with mix deps.get.
dev/docs-site/node_modules: dev/docs-site/package-lock.json
	npm ci --prefix dev/docs-site
	@touch $@

e2e: ## End-to-end manifest -> materialize -> HTTP smoke against the example
	./dev/scripts/e2e.sh

deploy-check: ## Build + boot the production image locally and verify it before rollout
	./dev/scripts/deploy-check.sh

doctor: ## Print required toolchain checks
	@missing=0; \
	for t in go gofmt elixir mix docker node npm; do \
	  command -v $$t >/dev/null 2>&1 && echo "  ok       $$t" || { echo "  MISSING  $$t"; missing=1; }; \
	done; \
	[ $$missing -eq 0 ] && echo "doctor: all good" || { echo "doctor: install the missing tools above"; exit 1; }

help: ## List targets
	@grep -hE '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*## / - /' | sort

.PHONY: check server-check tools-check docs-check e2e deploy-check doctor help
