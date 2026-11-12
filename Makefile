# Ping Identity Platform 8 on Docker Desktop Kubernetes — task runner.
# Run from the project root in WSL:  make help
# Every target wraps a script in src/scripts/ (see docs/running.md) — the scripts stay the
# source of truth; this file only gives them short, ordered names.

SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS   += --no-print-directory

S          := src/scripts
NAMESPACE  := $(or $(shell sed -n 's/^NAMESPACE=//p' .env 2>/dev/null | tr -d '\r'),ping)
FQDN       := $(or $(shell sed -n 's/^FQDN=//p' .env 2>/dev/null | tr -d '\r'),ping-local.test.bbl)
KN         := kubectl --context docker-desktop -n $(NAMESPACE)
TAIL       ?= 100
TOOLS_BIN  ?= /mnt/d/source_code/hobby/tools/_scripts/bin

# component → kubectl object (logs / restart)
LOG_ds      := ds-0
LOG_am      := am-0 -c am
LOG_idm     := deploy/idm -c idm
LOG_ui      := deploy/platform-ui
LOG_gateway := deploy/gateway
LOG_config  := job/platform-config
RES_ds      := statefulset/ds
RES_am      := statefulset/am
RES_idm     := deployment/idm
RES_ui      := deployment/platform-ui
RES_gateway := deployment/gateway
COMPONENTS  := ds am idm ui gateway

.PHONY: help setup setup-wsl env hosts ds-id certs trust preflight build deploy verify up \
        status urls config down purge reset lint docs-check log plan check-gateway diag trust-machine browser regateway recover-env

##@ One-time setup (in this order — or just `make setup`)
setup: setup-wsl env hosts build-ds ds-id certs trust preflight ## All one-time steps below, in order

setup-wsl: ## WSL: packages, kubectl, ~/.kube/config → Windows kubeconfig (asks for sudo)
	bash $(S)/setup-wsl.sh

env: ## Create .env with random secrets (keeps an existing .env)
	bash $(S)/init-env.sh

recover-env: ## Rebuild a lost/overwritten .env from the cluster Secret (NS=ping) — keeps passwords matching the data
	bash $(S)/recover-env.sh $(or $(NS),ping)

hosts: ## Add 127.0.0.1 $FQDN to the Windows hosts file (UAC prompt)
	bash $(S)/add-hosts-entry.sh

ds-id: ## DS deployment ID (→ .env) + DS CA (→ .secrets/ds-ca.pem); needs the ds image
	bash $(S)/ds-deployment-id.sh

certs: ## Local CA + HTTPS certificate for $FQDN (.secrets/)
	bash $(S)/tls.sh

trust: ## Trust the local CA in Windows (security dialog → Yes), then restart the browser
	bash $(S)/tls.sh --trust

trust-machine: ## Trust the local CA for the whole PC (UAC admin prompt) — if policy ignores `make trust`
	bash $(S)/tls.sh --trust-machine

browser: ## Open the platform in a dev browser profile (ignores cert errors, no proxy) — if policy blocks trust
	bash $(S)/open-browser.sh

##@ Build · deploy · verify
preflight: ## Check tools, Docker RAM, cluster, zips, hosts entry, prerequisites
	bash $(S)/preflight.sh

build: ## Build all images from the zips and load them into the cluster
	bash $(S)/build-images.sh

build-%: ## Build one image: build-ds | build-am | build-idm | build-ui | build-config
	bash $(S)/build-images.sh $*

deploy: ## Deploy + configure everything (idempotent; keeps data)
	bash $(S)/deploy.sh

verify: ## End-to-end test through https://$FQDN (connectivity + 17 checks)
	bash $(S)/verify.sh

diag: ## Support bundle: pods, events, endpoints, logs, in-cluster checks → .rendered/diag-*.txt (no secrets)
	@bash $(S)/diag.sh

regateway: ## Recreate the gateway LoadBalancer Service (after freeing port 443/80); clears a stuck finalizer
	@bash -c 'source $(S)/lib.sh && load_env && regateway'

check-gateway: ## Diagnose the path to https://$FQDN only (proxy → DNS → TCP 443 → TLS → Windows side)
	@bash -c 'source $(S)/lib.sh && load_env && diagnose_gateway'

up: build deploy verify ## build + deploy + verify

##@ Daily use
status: ## Pods, services, volumes
	$(KN) get pods,svc,pvc

urls: ## Print the platform URLs
	@echo "Platform admin : https://$(FQDN)/platform        (amadmin / AM_ADMIN_PASSWORD in .env)"
	@echo "End-user portal: https://$(FQDN)/enduser/?realm=alpha"
	@echo "AM console     : https://$(FQDN)/am/ui-admin/"
	@echo "OIDC (alpha)   : https://$(FQDN)/am/oauth2/realms/root/realms/alpha/.well-known/openid-configuration"

logs-%: ## Logs of one component: logs-ds | logs-am | logs-idm | logs-ui | logs-gateway | logs-config  (TAIL=100)
	$(if $(LOG_$*),,$(error unknown component '$*' — use: $(COMPONENTS) config))
	$(KN) logs $(LOG_$*) --tail=$(TAIL)

restart-%: ## Rolling restart of one component: restart-ds | restart-am | restart-idm | restart-ui | restart-gateway
	$(if $(RES_$*),,$(error unknown component '$*' — use: $(COMPONENTS)))
	$(KN) rollout restart $(RES_$*)
	$(KN) rollout status $(RES_$*) --timeout=600s

config: build-config deploy ## Rebuild + re-run the platform configuration Job (after editing src/config/)

##@ Stop · reset
down: ## Remove workloads, KEEP data (bring back with `make deploy`)
	bash $(S)/teardown.sh

purge: ## Delete the namespace incl. ALL data (asks to confirm)
	bash $(S)/teardown.sh --purge

reset: purge deploy verify ## purge (asks) → fresh deploy → verify

##@ Development
lint: ## shellcheck + hadolint (docker images koalaman/shellcheck, hadolint/hadolint)
	docker run --rm -v "$(CURDIR)":/mnt:ro -w /mnt koalaman/shellcheck:v0.10.0 -x \
	  $(S)/*.sh src/config/configure.sh src/docker/*/entrypoint.sh src/docker/idm/platform/patch-conf.sh
	for f in src/docker/*/Dockerfile; do \
	  docker run --rm -i -v "$(CURDIR)/.hadolint.yaml":/cfg.yaml:ro hadolint/hadolint:v2.12.0-alpine \
	    hadolint --config /cfg.yaml - < "$$f" || exit 1; done
	@echo "lint: clean"

docs-check: ## Render every Mermaid diagram in README/docs (mermaid-cli in docker) into .rendered/mermaid/
	@mkdir -p .rendered/mermaid && chmod 777 .rendered/mermaid; rc=0; \
	for f in README.md docs/*.md; do grep -q '```mermaid' "$$f" || continue; \
	  printf '%-28s ' "$$f"; \
	  if docker run --rm -v "$(CURDIR)":/data:ro -v "$(CURDIR)/.rendered/mermaid":/out minlag/mermaid-cli:11.4.2 \
	       -i "/data/$$f" -o "/out/$$(basename $$f)" > .rendered/mermaid/last.log 2>&1; \
	  then echo "ok ($$(grep -c '```mermaid' "$$f") diagrams)"; else echo FAILED; cat .rendered/mermaid/last.log; rc=1; fi; \
	done; exit $$rc

log: ## Add an activity-log entry: make log MSG="[AREA] what — detail — result"
	@test -n "$(MSG)" || { echo 'usage: make log MSG="..."'; exit 1; }
	"$(TOOLS_BIN)/log-activity.sh" "$(MSG)"

plan: ## Create a plan file: make plan TITLE="..."
	@test -n "$(TITLE)" || { echo 'usage: make plan TITLE="..."'; exit 1; }
	"$(TOOLS_BIN)/new-plan.sh" "$(TITLE)"

##@ Help
help: ## Show this list
	@awk 'BEGIN {FS = ":.*## "} \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
	  /^[a-zA-Z0-9_%-]+:.*## / { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo
	@echo "Run in WSL from the project root. Details: docs/running.md, docs/daily-operations.md"
