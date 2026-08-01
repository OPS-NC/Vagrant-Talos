# Makefile — lab shortcuts. Nothing here touches a running cluster.
#
#   make docs        regenerates the bilingual HTML documentation (docs/index.html)
#   make validate    validates Vagrantfile + scripts + YAML + Talos config + doc
#                    links, WITHOUT a cluster
#
# `docs` needs `uv` (https://docs.astral.sh/uv/): the Python dependencies are
# declared in docs/build.py (PEP 723) and installed on the fly.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

DOCS_OUT := docs/index.html

# PyYAML is not guaranteed to be present (neither locally nor on a runner): we go through
# uv, already required by `make docs`. `--no-project`: do not look for a non-existent
# pyproject.toml.
YAML_PY := uv run --quiet --with pyyaml --no-project python
# Flags added to `vagrant validate` (see validate-vagrant).
VAGRANT_VALIDATE_FLAGS ?=

.PHONY: help docs docs-open validate validate-shell validate-yaml validate-vagrant \
        validate-talos validate-submodule validate-docs k8s-update clean

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?##' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'

docs: ## Regenerate docs/index.html from every README (EN + FR mirrors)
	@uv run docs/build.py

docs-open: docs ## Regenerate then open the documentation in the browser
	@xdg-open $(DOCS_OUT) >/dev/null 2>&1 || open $(DOCS_OUT)

validate: validate-shell validate-yaml validate-vagrant validate-talos validate-submodule validate-docs ## Validate everything (without a cluster)
	@echo "✅ Full validation OK"

# `_k8s/` is a submodule (k8s-playground, shared with the kubeadm lab). Two ways to break
# a fresh clone without noticing from YOUR own copy, where everything works:
#   1. pinning a never-pushed commit — `git clone --recurse-submodules` then fails
#      for everyone but you;
#   2. declaring a `git@github.com:` URL — the clone fails for anyone without a GitHub
#      SSH key, on a repo that is public and invites cloning.
# Both are invisible locally: this test makes them visible.
validate-submodule: ## Check the _k8s submodule is declared, public and fetchable
	@url="$$(git config -f .gitmodules submodule._k8s.url)"; \
	case "$$url" in \
	  https://*) ;; \
	  *) echo "❌ submodule _k8s: URL '$$url' — expected https:// (a public clone cannot use SSH)"; exit 1 ;; \
	esac; \
	sha="$$(git ls-files -s _k8s | awk '{print $$2}')"; \
	[ -n "$$sha" ] || { echo "❌ _k8s is not registered as a submodule"; exit 1; }; \
	tmp="$$(mktemp -d)"; trap 'rm -rf "$$tmp"' EXIT; \
	git -C "$$tmp" init -q .; \
	if git -C "$$tmp" fetch -q --depth 1 "$$url" "$$sha" 2>/dev/null; then \
	  echo "✅ submodule: _k8s -> $$url @ $$(echo "$$sha" | cut -c1-7) (publicly fetchable)"; \
	else \
	  echo "❌ submodule: commit $$(echo "$$sha" | cut -c1-7) not found on $$url"; \
	  echo "   -> it has most likely never been pushed. A clone --recurse-submodules would fail."; \
	  exit 1; \
	fi

validate-docs: ## Build the docs into a throwaway file and require valid links
	@out="$$(mktemp -d)"; trap 'rm -rf "$$out"' EXIT; \
	uv run docs/build.py --strict --out "$$out/index.html" >/dev/null && echo "✅ docs: links and anchors OK"

validate-shell: ## Check the syntax of every shell script
	@fail=0; \
	while IFS= read -r f; do \
	  bash -n "$$f" || { echo "❌ $$f"; fail=1; }; \
	done < <(git ls-files '*.sh'); \
	[ $$fail -eq 0 ] && echo "✅ shell: $$(git ls-files '*.sh' | wc -l) scripts OK"

validate-yaml: ## Check that every YAML in the repo parses
	@git ls-files -z '*.yaml' '*.yml' | xargs -0 $(YAML_PY) -c 'import sys, yaml; [list(yaml.safe_load_all(open(f, encoding="utf-8"))) for f in sys.argv[1:]]' \
	  && echo "✅ yaml: $$(git ls-files '*.yaml' '*.yml' | wc -l) files OK"

# --ignore-provider: indispensable in CI, where no VirtualBox is installed (the job
# would fail on the provider before even looking at the Vagrantfile). Locally, without the
# flag, the validation ALSO covers the provider config — so we do not force it here.
validate-vagrant: ## Validate the Vagrantfile (VAGRANT_VALIDATE_FLAGS=--ignore-provider in CI)
	@vagrant validate $(VAGRANT_VALIDATE_FLAGS) && echo "✅ Vagrantfile OK"

# ⚠️ `lab.env` is PARSED, never SOURCED. A `. ./lab.env` had two flaws:
#   1. it INVERTS the documented precedence (real env var > lab.env > default):
#      `CNI=flannel make validate-talos` used to validate the cilium patch and announce
#      it as such. A target that validates something other than what you asked for is
#      worse than no target at all;
#   2. it executes the file — a hand-mangled lab.env must not be able to run code.
# `lab_get` reproduces the extraction of `lire_lab_env` (_k8s/lib/common.sh): optional
# `export`, trailing comment preceded by a space. The `|| true` is mandatory:
# .SHELLFLAGS carries `pipefail`, and sed exits 2 when lab.env does not exist.
validate-talos: ## Generate the Talos config in a throwaway directory then validate it
	@set -eu; \
	lab_get() { sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$$1=//p" lab.env 2>/dev/null \
	              | head -n1 | sed 's/[[:space:]][[:space:]]*#.*$$//' | tr -d " \"'" || true; }; \
	cni="$${CNI:-$$(lab_get CNI)}"                   ; cni="$${cni:-cilium}"; \
	net="$${NETWORK:-$$(lab_get NETWORK)}"           ; net="$${net:-192.168.56}"; \
	vip="$${VIP:-$$(lab_get VIP)}"                   ; vip="$${vip:-$$net.5}"; \
	disk="$${INSTALL_DISK:-$$(lab_get INSTALL_DISK)}"; disk="$${disk:-/dev/sda}"; \
	kver="$${KUBERNETES_VERSION:-$$(lab_get KUBERNETES_VERSION)}"; \
	[ -f "talos/cni-$$cni.yaml" ] || { echo "❌ unknown CNI '$$cni' (talos/cni-$$cni.yaml missing)"; exit 1; }; \
	out="$$(mktemp -d)"; \
	trap 'rm -rf "$$out"' EXIT; \
	kargs=(); [ -z "$$kver" ] || kargs=(--kubernetes-version "$${kver#v}"); \
	talosctl gen config validate-only "https://$$vip:6443" \
	  --install-disk "$$disk" \
	  --additional-sans "$$vip,$$net.10,$$net.20,$$net.30" \
	  "$${kargs[@]}" \
	  --config-patch               @talos/patch-all.yaml \
	  --config-patch-control-plane @talos/patch-cp.yaml \
	  --config-patch-control-plane "@talos/cni-$$cni.yaml" \
	  --output-dir "$$out" --force >/dev/null 2>&1 \
	  || { echo "❌ gen config failed (invalid KUBERNETES_VERSION='$$kver'?)"; exit 1; }; \
	talosctl validate --config "$$out/controlplane.yaml" --mode metal; \
	talosctl validate --config "$$out/worker.yaml" --mode metal; \
	echo "   (CNI=$$cni, VIP=$$vip, Kubernetes=$${kver:-talosctl default})"

# A submodule ALWAYS records a precise commit in the parent repo — that is how git
# guarantees a clone gives exactly the same tree. "Follow main" is therefore declared
# in .gitmodules (`branch = main`) and materialised by `--remote`, which fetches the tip
# of that branch and updates the recorded pointer.
k8s-update: ## Align the _k8s submodule on the tip of main (then commit the pointer)
	@git submodule update --remote --init _k8s
	@if git diff --quiet -- _k8s; then \
	  echo "✅ _k8s already on the tip of main ($$(git -C _k8s rev-parse --short HEAD))"; \
	else \
	  echo "⬆️  _k8s -> $$(git -C _k8s rev-parse --short HEAD)"; \
	  git -C _k8s log --oneline -5; \
	  echo; echo "   Pointer updated in the working tree. To freeze it:"; \
	  echo "     git add _k8s && git commit -m '[Claude] chore: bump _k8s'"; \
	fi

clean: ## Remove the generated documentation
	@rm -f $(DOCS_OUT) && echo "docs/index.html removed"
