# Makefile — raccourcis du lab. Rien ici ne touche à un cluster en route.
#
#   make docs        régénère la documentation HTML bilingue (docs/index.html)
#   make validate    valide Vagrantfile + scripts + config Talos + liens de la doc,
#                    SANS cluster
#
# `docs` a besoin de `uv` (https://docs.astral.sh/uv/) : les dépendances Python
# sont déclarées dans docs/build.py (PEP 723) et installées à la volée.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

DOCS_OUT := docs/index.html

.PHONY: help docs docs-open validate validate-shell validate-vagrant validate-talos \
        validate-docs clean

help: ## Affiche cette aide
	@grep -hE '^[a-z-]+:.*?##' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'

docs: ## Régénère docs/index.html depuis tous les README (EN + miroirs FR)
	@uv run docs/build.py

docs-open: docs ## Régénère puis ouvre la doc dans le navigateur
	@xdg-open $(DOCS_OUT) >/dev/null 2>&1 || open $(DOCS_OUT)

validate: validate-shell validate-vagrant validate-talos validate-docs ## Tout valider (sans cluster)
	@echo "✅ Validation complète OK"

validate-docs: ## Construit la doc dans un fichier jetable et exige des liens valides
	@out="$$(mktemp -d)"; trap 'rm -rf "$$out"' EXIT; \
	uv run docs/build.py --strict --out "$$out/index.html" >/dev/null && echo "✅ docs : liens et ancres OK"

validate-shell: ## Vérifie la syntaxe de tous les scripts shell
	@fail=0; \
	while IFS= read -r f; do \
	  bash -n "$$f" || { echo "❌ $$f"; fail=1; }; \
	done < <(git ls-files '*.sh'); \
	[ $$fail -eq 0 ] && echo "✅ shell : $$(git ls-files '*.sh' | wc -l) scripts OK"

validate-vagrant: ## Valide le Vagrantfile
	@vagrant validate && echo "✅ Vagrantfile OK"

validate-talos: ## Génère la config Talos dans un dossier jetable puis la valide
	@set -eu; \
	. ./lab.env 2>/dev/null || true; \
	cni="$${CNI:-cilium}"; net="$${NETWORK:-192.168.56}"; vip="$${VIP:-$$net.5}"; \
	out="$$(mktemp -d)"; \
	trap 'rm -rf "$$out"' EXIT; \
	talosctl gen config validate-only "https://$$vip:6443" \
	  --install-disk "$${INSTALL_DISK:-/dev/sda}" \
	  --additional-sans "$$vip,$$net.10,$$net.20,$$net.30" \
	  --config-patch               @talos/patch-all.yaml \
	  --config-patch-control-plane @talos/patch-cp.yaml \
	  --config-patch-control-plane "@talos/cni-$$cni.yaml" \
	  --output-dir "$$out" --force >/dev/null 2>&1; \
	talosctl validate --config "$$out/controlplane.yaml" --mode metal; \
	talosctl validate --config "$$out/worker.yaml" --mode metal; \
	echo "   (CNI=$$cni, VIP=$$vip)"

clean: ## Supprime la doc générée
	@rm -f $(DOCS_OUT) && echo "docs/index.html supprimé"
