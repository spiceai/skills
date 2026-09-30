.PHONY: eval eval-skill eval-no-grade grade package check check-versions test-distribution release-preview release-assets clean help

SKILL ?=

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-15s %s\n", $$1, $$2}'

eval: ## Run evals for all skills (or SKILL=name for one)
ifdef SKILL
	python3 scripts/run_evals.py $(SKILL) --grade
else
	python3 scripts/run_evals.py --grade
endif

eval-no-grade: ## Run evals without grading
ifdef SKILL
	python3 scripts/run_evals.py $(SKILL)
else
	python3 scripts/run_evals.py
endif

grade: ## Grade existing eval results for a skill (requires SKILL=name)
ifndef SKILL
	$(error SKILL is required, e.g. make grade SKILL=setup)
endif
	python3 grade_eval.py $(SKILL)-workspace/iteration-1

package: ## Package the plugin as ZIP and tar.gz archives in dist/
	./scripts/package_plugin.sh

check: check-versions ## Validate names, catalogs, resources, and private-skill boundaries
	python3 scripts/validate_plugin.py

test-distribution: ## Test release safeguards without API keys or network calls
	python3 -m unittest discover -s tests -p 'test_distribution.py' -v

release-preview: ## Build a local marketplace handoff (not suitable for submission)
	python3 scripts/prepare_release.py --preview --output-dir dist/preview

release-assets: ## Build submission assets from a clean release tag (TAG=vX.Y.Z)
ifndef TAG
	$(error TAG is required, e.g. make release-assets TAG=v2.3.2)
endif
	python3 scripts/prepare_release.py --tag "$(TAG)"

check-versions: ## Check manifests and skills target the same Spice release line
	bash scripts/check_versions.sh

clean: ## Remove workspace dirs and dist/
	rm -rf *-workspace/ dist/
