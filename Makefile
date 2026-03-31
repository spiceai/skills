.PHONY: eval eval-skill grade package clean help

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
	$(error SKILL is required, e.g. make grade SKILL=spice-setup)
endif
	python3 grade_eval.py $(SKILL)-workspace/iteration-1

package: ## Package the plugin into dist/
	./scripts/package_plugin.sh

clean: ## Remove workspace dirs and dist/
	rm -rf *-workspace/ dist/
