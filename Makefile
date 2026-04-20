# NixOS Homelab - K3s homelab on NixOS
# Wraps nixos-k8s upstream tooling with homelab-specific glue (--impure,
# marker cleanup, on-server backup commands). Upstream scripts are invoked
# through flake apps (`nix run .#install` etc.), no sibling checkout needed.

FLAKE    := .
NIX_EVAL := nix eval --raw --impure
NIX_RUN  := PROJECT_DIR=$(CURDIR) nix run $(FLAKE)

ADMIN = $(shell $(NIX_EVAL) --expr '(import ./config.nix).adminUser')

# Get a node's IP: $(call node-ip,imre)
node-ip = $(shell $(NIX_EVAL) --expr '(import ./config.nix).nodes.$(1).ip')

# Bootstrap node name (the one with bootstrap=true)
bootstrap-node = $(shell $(NIX_EVAL) --expr 'let c = import ./config.nix; in builtins.head (builtins.filter (n: c.nodes.$${n}.bootstrap or false) (builtins.attrNames c.nodes))')

.PHONY: help setup add-node install deploy deploy-all bootstrap ssh logs status \
        unlock enroll-tpm reinstall check fmt shell clean \
        backup-now backup-status backup-restore

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

setup: ## Run interactive setup wizard (generates config.nix + secrets)
	@./scripts/setup.sh

add-node: config.nix ## Add a new node to config.nix: make add-node [NAME=x] [IP=x.x.x.x] [ROLE=agent]
	@$(NIX_RUN)#add-node -- $(NAME) $(IP) $(ROLE)

install: config.nix ## Install a node: make install NODE=imre [IP=<live-ip>]
	@[ -n "$(NODE)" ] || { echo "Usage: make install NODE=<name> [IP=<live-usb-ip>]"; exit 1; }
	@NODE_IP=$${IP:-$(call node-ip,$(NODE))}; \
	echo "Target: $$NODE_IP (node: $(NODE))"; \
	$(NIX_RUN)#install -- $(NODE) $$NODE_IP

deploy: config.nix ## Deploy to a node: make deploy [NODE=imre]
	@_NODE=$${NODE:-$(bootstrap-node)}; \
	NODE_IP=$$($(NIX_EVAL) --expr "(import ./config.nix).nodes.$$_NODE.ip"); \
	echo "=== Deploying $$_NODE ($$NODE_IP) ==="; \
	echo "Updating flake.lock..."; \
	nix flake update; \
	echo "Cleaning service markers..."; \
	ssh $(ADMIN)@$$NODE_IP 'for f in /var/lib/*-setup-done /var/lib/*-config-done; do [ -e "$$f" ] && sudo rm -f "$$f"; done' 2>/dev/null || true; \
	set +e; \
	nixos-rebuild switch --flake $(FLAKE)#$$_NODE \
		--target-host $(ADMIN)@$$NODE_IP --sudo --ask-sudo-password --impure; \
	RC=$$?; \
	set -e; \
	if [ $$RC -ne 0 ] && [ $$RC -ne 4 ]; then exit $$RC; fi; \
	echo "Deploy OK"

deploy-all: config.nix ## Deploy to all nodes
	@for node in $$(nix eval --json --impure --expr 'builtins.attrNames (import ./config.nix).nodes' | jq -r '.[]'); do \
		$(MAKE) deploy NODE=$$node; \
	done

bootstrap: config.nix ## Bootstrap cluster: deploy bootstrap node, wait, then all
	@BOOT=$(bootstrap-node); \
	echo "=== Bootstrapping from $$BOOT ==="; \
	$(MAKE) deploy NODE=$$BOOT; \
	echo "Waiting 60s for infrastructure..."; \
	sleep 60; \
	$(MAKE) deploy-all

ssh: config.nix ## SSH into a node: make ssh [NODE=imre]
	@_NODE=$${NODE:-$(bootstrap-node)}; \
	ssh $(ADMIN)@$$($(NIX_EVAL) --expr "(import ./config.nix).nodes.$$_NODE.ip")

status: config.nix ## Show cluster status
	@BOOT=$(bootstrap-node); \
	ssh $(ADMIN)@$$($(NIX_EVAL) --expr "(import ./config.nix).nodes.$$BOOT.ip") \
		'sudo kubectl get nodes -o wide && echo "" && sudo kubectl get pods -A'

logs: config.nix ## Show K3s logs: make logs [NODE=imre]
	@_NODE=$${NODE:-$(bootstrap-node)}; \
	ssh $(ADMIN)@$$($(NIX_EVAL) --expr "(import ./config.nix).nodes.$$_NODE.ip") \
		'journalctl -u "k3s*" --no-pager -n 50'

unlock: config.nix ## SSH-unlock a node's LUKS disk: make unlock NODE=imre
	@[ -n "$(NODE)" ] || { echo "Usage: make unlock NODE=<name>"; exit 1; }
	@$(NIX_RUN)#unlock -- $(NODE)

enroll-tpm: config.nix ## Enroll TPM2 for auto-unlock: make enroll-tpm NODE=imre
	@[ -n "$(NODE)" ] || { echo "Usage: make enroll-tpm NODE=<name>"; exit 1; }
	@$(NIX_RUN)#enroll-tpm -- $(NODE)

reinstall: config.nix ## Force reinstall a service: make reinstall SVC=jellyfin [NODE=imre]
	@[ -n "$(SVC)" ] || { echo "Usage: make reinstall SVC=<name> [NODE=<name>]"; exit 1; }
	@_NODE=$${NODE:-$(bootstrap-node)}; \
	NODE_IP=$$($(NIX_EVAL) --expr "(import ./config.nix).nodes.$$_NODE.ip"); \
	echo "=== Reinstalling $(SVC) on $$_NODE ($$NODE_IP) ==="; \
	ssh $(ADMIN)@$$NODE_IP "sudo rm -f /var/lib/$(SVC)-setup-done && sudo systemctl restart $(SVC)-setup.service"

backup-now: config.nix ## Trigger a backup on the bootstrap node
	@BOOT=$(bootstrap-node); \
	ssh -t $(ADMIN)@$$($(NIX_EVAL) --expr "(import ./config.nix).nodes.$$BOOT.ip") "sudo backup-now"

backup-status: config.nix ## Show backup status
	@BOOT=$(bootstrap-node); \
	ssh $(ADMIN)@$$($(NIX_EVAL) --expr "(import ./config.nix).nodes.$$BOOT.ip") "sudo backup-status"

backup-restore: config.nix ## Restore from backup (interactive)
	@BOOT=$(bootstrap-node); \
	ssh -t $(ADMIN)@$$($(NIX_EVAL) --expr "(import ./config.nix).nodes.$$BOOT.ip") "sudo backup-restore"

check: config.nix ## Build all node configs without deploying
	@for node in $$(nix eval --json --impure --expr 'builtins.attrNames (import ./config.nix).nodes' | jq -r '.[]'); do \
		echo "Checking $$node..."; \
		nixos-rebuild build --flake $(FLAKE)#$$node --impure || exit 1; \
	done
	@echo "All nodes OK"

fmt: ## Format all .nix files
	nix fmt

shell: ## Enter nix dev shell
	nix develop

clean: ## Remove build artifacts
	rm -rf result result-*
