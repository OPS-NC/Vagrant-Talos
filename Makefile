# Makefile — raccourcis du lab. Rien ici ne touche à un cluster en route.
#
#   make docs        régénère la documentation HTML bilingue (docs/index.html)
#   make validate    valide Vagrantfile + scripts + YAML + config Talos + liens de la
#                    doc, SANS cluster
#
# `docs` a besoin de `uv` (https://docs.astral.sh/uv/) : les dépendances Python
# sont déclarées dans docs/build.py (PEP 723) et installées à la volée.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

DOCS_OUT := docs/index.html

# PyYAML n'est pas garanti présent (ni en local, ni sur un runner) : on passe par uv, déjà
# exigé par `make docs`. `--no-project` : ne pas chercher un pyproject.toml inexistant.
YAML_PY := uv run --quiet --with pyyaml --no-project python
# Drapeaux ajoutés à `vagrant validate` (cf. validate-vagrant).
VAGRANT_VALIDATE_FLAGS ?=

.PHONY: help docs docs-open validate validate-shell validate-yaml validate-vagrant \
        validate-talos validate-submodule validate-docs k8s-update clean

help: ## Affiche cette aide
	@grep -hE '^[a-z-]+:.*?##' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'

docs: ## Régénère docs/index.html depuis tous les README (EN + miroirs FR)
	@uv run docs/build.py

docs-open: docs ## Régénère puis ouvre la doc dans le navigateur
	@xdg-open $(DOCS_OUT) >/dev/null 2>&1 || open $(DOCS_OUT)

validate: validate-shell validate-yaml validate-vagrant validate-talos validate-submodule validate-docs ## Tout valider (sans cluster)
	@echo "✅ Validation complète OK"

# `_k8s/` est un sous-module (k8s-playground, partagé avec le lab kubeadm). Deux façons
# de casser un clone neuf sans s'en rendre compte depuis SA copie locale, où tout marche :
#   1. épingler un commit jamais poussé — `git clone --recurse-submodules` échoue alors
#      pour tout le monde sauf soi ;
#   2. déclarer une URL en `git@github.com:` — le clone échoue pour quiconque n'a pas de
#      clé SSH GitHub, alors que ce dépôt est public et invite au clone.
# Les deux sont invisibles en local : ce test les rend visibles.
validate-submodule: ## Vérifie que le sous-module _k8s est déclaré, public et récupérable
	@url="$$(git config -f .gitmodules submodule._k8s.url)"; \
	case "$$url" in \
	  https://*) ;; \
	  *) echo "❌ sous-module _k8s : URL '$$url' — attendu https:// (un clone public ne peut pas utiliser SSH)"; exit 1 ;; \
	esac; \
	sha="$$(git ls-files -s _k8s | awk '{print $$2}')"; \
	[ -n "$$sha" ] || { echo "❌ _k8s n'est pas enregistré comme sous-module"; exit 1; }; \
	tmp="$$(mktemp -d)"; trap 'rm -rf "$$tmp"' EXIT; \
	git -C "$$tmp" init -q .; \
	if git -C "$$tmp" fetch -q --depth 1 "$$url" "$$sha" 2>/dev/null; then \
	  echo "✅ sous-module : _k8s -> $$url @ $$(echo "$$sha" | cut -c1-7) (récupérable publiquement)"; \
	else \
	  echo "❌ sous-module : le commit $$(echo "$$sha" | cut -c1-7) est introuvable sur $$url"; \
	  echo "   -> il n'a probablement jamais été poussé. Un clone --recurse-submodules échouerait."; \
	  exit 1; \
	fi

validate-docs: ## Construit la doc dans un fichier jetable et exige des liens valides
	@out="$$(mktemp -d)"; trap 'rm -rf "$$out"' EXIT; \
	uv run docs/build.py --strict --out "$$out/index.html" >/dev/null && echo "✅ docs : liens et ancres OK"

validate-shell: ## Vérifie la syntaxe de tous les scripts shell
	@fail=0; \
	while IFS= read -r f; do \
	  bash -n "$$f" || { echo "❌ $$f"; fail=1; }; \
	done < <(git ls-files '*.sh'); \
	[ $$fail -eq 0 ] && echo "✅ shell : $$(git ls-files '*.sh' | wc -l) scripts OK"

validate-yaml: ## Vérifie que tous les YAML du dépôt parsent
	@git ls-files -z '*.yaml' '*.yml' | xargs -0 $(YAML_PY) -c 'import sys, yaml; [list(yaml.safe_load_all(open(f, encoding="utf-8"))) for f in sys.argv[1:]]' \
	  && echo "✅ yaml : $$(git ls-files '*.yaml' '*.yml' | wc -l) fichiers OK"

# --ignore-provider : indispensable en CI, où aucun VirtualBox n'est installé (le job
# échouerait sur le provider avant même de regarder le Vagrantfile). En local, sans le
# flag, la validation couvre EN PLUS la config provider — donc on ne l'impose pas ici.
validate-vagrant: ## Valide le Vagrantfile (VAGRANT_VALIDATE_FLAGS=--ignore-provider en CI)
	@vagrant validate $(VAGRANT_VALIDATE_FLAGS) && echo "✅ Vagrantfile OK"

# ⚠️ `lab.env` est PARSÉ, jamais SOURCÉ. Un `. ./lab.env` avait deux défauts :
#   1. il INVERSE la précédence documentée (variable d'env réelle > lab.env > défaut) :
#      `CNI=flannel make validate-talos` validait le patch cilium et l'annonçait comme
#      tel. Une cible qui valide autre chose que ce qu'on lui demande est pire que pas
#      de cible du tout ;
#   2. il exécute le fichier — un lab.env bricolé ne doit pas pouvoir lancer du code.
# `lab_get` reproduit l'extraction de `lire_lab_env` (_k8s/lib/common.sh) : `export`
# optionnel, commentaire de fin de ligne précédé d'une espace. `|| true` obligatoire :
# .SHELLFLAGS porte `pipefail`, et sed sort en 2 si lab.env n'existe pas.
validate-talos: ## Génère la config Talos dans un dossier jetable puis la valide
	@set -eu; \
	lab_get() { sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$$1=//p" lab.env 2>/dev/null \
	              | head -n1 | sed 's/[[:space:]][[:space:]]*#.*$$//' | tr -d " \"'" || true; }; \
	cni="$${CNI:-$$(lab_get CNI)}"                   ; cni="$${cni:-cilium}"; \
	net="$${NETWORK:-$$(lab_get NETWORK)}"           ; net="$${net:-192.168.56}"; \
	vip="$${VIP:-$$(lab_get VIP)}"                   ; vip="$${vip:-$$net.5}"; \
	disk="$${INSTALL_DISK:-$$(lab_get INSTALL_DISK)}"; disk="$${disk:-/dev/sda}"; \
	[ -f "talos/cni-$$cni.yaml" ] || { echo "❌ CNI '$$cni' inconnu (talos/cni-$$cni.yaml absent)"; exit 1; }; \
	out="$$(mktemp -d)"; \
	trap 'rm -rf "$$out"' EXIT; \
	talosctl gen config validate-only "https://$$vip:6443" \
	  --install-disk "$$disk" \
	  --additional-sans "$$vip,$$net.10,$$net.20,$$net.30" \
	  --config-patch               @talos/patch-all.yaml \
	  --config-patch-control-plane @talos/patch-cp.yaml \
	  --config-patch-control-plane "@talos/cni-$$cni.yaml" \
	  --output-dir "$$out" --force >/dev/null 2>&1; \
	talosctl validate --config "$$out/controlplane.yaml" --mode metal; \
	talosctl validate --config "$$out/worker.yaml" --mode metal; \
	echo "   (CNI=$$cni, VIP=$$vip)"

# Un sous-module enregistre TOUJOURS un commit précis dans le dépôt parent — c'est ainsi
# que git garantit qu'un clone donne exactement le même arbre. « Suivre main » se déclare
# donc dans .gitmodules (`branch = main`) et se matérialise par `--remote`, qui va chercher
# la pointe de cette branche et met à jour le pointeur enregistré.
k8s-update: ## Aligne le sous-module _k8s sur la pointe de main (puis committer le pointeur)
	@git submodule update --remote --init _k8s
	@if git diff --quiet -- _k8s; then \
	  echo "✅ _k8s déjà sur la pointe de main ($$(git -C _k8s rev-parse --short HEAD))"; \
	else \
	  echo "⬆️  _k8s -> $$(git -C _k8s rev-parse --short HEAD)"; \
	  git -C _k8s log --oneline -5; \
	  echo; echo "   Pointeur mis à jour dans l'arbre de travail. Pour le figer :"; \
	  echo "     git add _k8s && git commit -m '[Claude] chore: bump _k8s'"; \
	fi

clean: ## Supprime la doc générée
	@rm -f $(DOCS_OUT) && echo "docs/index.html supprimé"
