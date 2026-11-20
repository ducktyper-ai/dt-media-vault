GREEN :=
YELLOW :=
BLUE :=
RED :=
RESET :=

PYTHON_VERSION := 3.12
VENV_NAME := .venv
PYTHON := $(VENV_NAME)/bin/python

# Legacy storage entry points stay disabled pending replacement tools and scope.
.PHONY: nas-disabled
check-volumes analyze-dry analyze migrate verify-migration index-catalog link-project: nas-disabled
nas-disabled: ## Refuse legacy NAS operations unconditionally
	$(error NAS_WORKFLOW_DISABLED: replacement tools and separately approved storage scope required)

.PHONY: help help-all doctor hooks require-build-host lint format-check typecheck test build run release
help: ## Start here: curated guide and five useful commands
	@printf '%s\n' 'Media Vault — offline source and synthetic verifier toolkit' '' \
	  'Start with these five commands:' \
	  '  make help     — this guide; make help-all lists every target' \
	  '  make doctor   — read-only prerequisites and hook diagnostics' \
	  '  make hooks    — install lightweight main-push protection' \
	  '  make setup    — install development tools on an authorized build host' \
	  '  make verify   — full offline gate on an authorized build host' '' \
	  'Use a short-lived branch, review, and the merger; never push main.' \
	  'NAS workflows are disabled. No media root, volume, service, or network is needed by verify.' \
	  'Build/test/gate jobs do not run on the Mac mini. Doctor and hooks run no gate.' \
	  'Setup consumes the universal hash-checked lock with an existing Python 3.12; no interpreter download or source build.'

help-all: ## List every target, including disabled legacy workflows
	@awk 'BEGIN { FS = ":.*## " } /^[a-zA-Z0-9_-]+:.*## / { name = $$1; sub(/^# /, "", name); printf "  %-24s %s\n", name, $$2 }' $(MAKEFILE_LIST)

doctor: ## Diagnose tools, lock identity, environment names, and hooks without changes
	@PYTHONDONTWRITEBYTECODE=1 python3 scripts/devtools.py doctor

hooks: ## Install a main-push refusal, preserving an existing standard pre-push hook
	@PYTHONDONTWRITEBYTECODE=1 python3 scripts/devtools.py hooks

require-build-host: ## Refuse build, setup, and checks on the Mac mini
	@test "$$(uname -s)" != Darwin || { echo 'REFUSED: run this target on an authorized build host, not the Mac mini.' >&2; exit 1; }

format-check: require-build-host ## Check changed-source whitespace without rewriting files
	@git diff --check aeab77f8ca571ddf6a84557f1fa8decccdbe8d01 HEAD

lint: require-build-host ## Run the same fatal Python lint selection as the offline gate
	@ruff check --no-cache --select E9,F63,F7,F82 src tests scripts/devtools.py

typecheck: require-build-host ## Type-check the new typed developer entry point with mypy
	@mypy --follow-imports=skip scripts/devtools.py

test: require-build-host ## Run synthetic verifier and developer-command tests; no media or NAS
	@PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=src python3 -m unittest discover -s tests -v

build: require-build-host ## Build the Python distribution with uv on an authorized host
	@uv build

run: ## Explain why real-media runtime commands are not currently admitted
	$(error NAS_WORKFLOW_DISABLED: replacement tools and separately approved storage scope required)

release: ## Explain the reviewed merger-only release path; never publish implicitly
	$(error RELEASE_NOT_AUTOMATED: use the reviewed PR and authorized merger; no direct main push or package publication)

.PHONY: setup
setup: require-build-host ## Create the existing development environment on an authorized build host
	@echo "$(BLUE)Creating virtual environment...$(RESET)"
	uv venv --no-python-downloads --python $(PYTHON_VERSION)
	uv pip sync --require-hashes --only-binary=:all: --no-build --no-python-downloads \
	  --python $(VENV_NAME)/bin/python requirements-gate-universal.lock
	@echo "$(GREEN)Done! Run: source $(VENV_NAME)/bin/activate$(RESET)"

.PHONY: check-volumes
check-volumes: ## Disabled: real storage access needs replacement tools and separate scope
	$(error NAS_WORKFLOW_DISABLED: replacement tools and separately approved storage scope required)
	@echo "$(BLUE)Checking volumes...$(RESET)"
	@test -d "$(SOURCE_VOLUME)" || (echo "$(RED)Source not found$(RESET)" && exit 1)
	@echo "$(GREEN)Source OK: $(SOURCE_VOLUME)$(RESET)"

.PHONY: analyze-dry
analyze-dry: check-volumes ## Disabled: no archive scan is admitted
	$(error NAS_WORKFLOW_DISABLED: replacement tools and separately approved storage scope required)
	$(PYTHON) -m media_toolkit.analyzer --source $(SOURCE_VOLUME) --output ./analysis_results --dry-run

.PHONY: analyze
analyze: check-volumes ## Disabled: no hashing or archive analysis is admitted
	$(error NAS_WORKFLOW_DISABLED: replacement tools and separately approved storage scope required)
	@echo "$(YELLOW)This takes 4-6 hours. Press Enter to continue...$(RESET)"
	@read dummy
	$(PYTHON) -m media_toolkit.analyzer --source $(SOURCE_VOLUME) --output ./analysis_results

.PHONY: migrate
migrate: ## Disabled: no real-media copy is admitted
	$(error NAS_WORKFLOW_DISABLED: replacement tools and separately approved storage scope required)
	@echo "$(YELLOW)This takes 8-12 hours. Press Enter to continue...$(RESET)"
	@read dummy
	$(PYTHON) -m media_toolkit.migrator --manifest ./analysis_results/migration_manifest.json --target $(TARGET_VOLUME)

.PHONY: verify verify-source verify-migration
# The owning source gate is offline. Never depend on a NAS operation here.
verify: verify-source ## Run the complete offline source gate on an authorized build host

verify-source: ## Run source/history/privacy checks and synthetic safety controls
	bash scripts/verify-source.sh

# This legacy verifier is not an offline quality gate or permission to clean data.
verify-migration: ## Disabled: never verify real NAS content through this target
	$(error NAS_WORKFLOW_DISABLED: replacement tools and separately approved storage scope required)
	$(PYTHON) -m media_toolkit.verifier --manifest ./analysis_results/migration_manifest.json --target $(TARGET_VOLUME)

.PHONY: clean
clean: ## Remove only local tool caches; retain analysis results and media
	rm -rf -- .pytest_cache .mypy_cache .ruff_cache

.PHONY: structure
structure: ## Show project structure
	@echo "${YELLOW}Current Project Structure:${RESET}"
	@echo "${BLUE}"
	@if command -v tree > /dev/null; then \
		tree -a -I '.git|.venv|__pycache__|*.pyc|*.pyo|*.pyd|.pytest_cache|.ruff_cache|.coverage|htmlcov'; \
	else \
		find . -not -path '*/\.*' -not -path '*.pyc' -not -path '*/__pycache__/*' \
			-not -path './.venv/*' -not -path './build/*' -not -path './dist/*' \
			-not -path './*.egg-info/*' \
			| sort | \
			sed -e "s/[^-][^\/]*\// │   /g" -e "s/├── /│── /" -e "s/└── /└── /"; \
	fi
	@echo "${RESET}"

.PHONY: aggregate
aggregate: ## Usage: make aggregate AGGREGATE_TARGET=<directory>
	@echo "${BLUE}Aggregating files from: ${AGGREGATE_TARGET}${RESET}"
	@# Create the aggregate script in memory and execute it
	@echo '#!/bin/bash' > .temp_aggregate.sh
	@echo '# Temporary aggregation script generated by Makefile' >> .temp_aggregate.sh
	@echo 'set -euo pipefail' >> .temp_aggregate.sh
	@echo '' >> .temp_aggregate.sh
	@echo '# Ensure Homebrew coreutils gnubin is on PATH (for grealpath/realpath on macOS)' >> .temp_aggregate.sh
	@echo 'if [ -d "/opt/homebrew/opt/coreutils/libexec/gnubin" ]; then' >> .temp_aggregate.sh
	@echo '  export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:$$PATH"' >> .temp_aggregate.sh
	@echo 'fi' >> .temp_aggregate.sh
	@echo '' >> .temp_aggregate.sh
	@echo 'portable_realpath() {' >> .temp_aggregate.sh
	@echo '  if command -v realpath >/dev/null 2>&1; then' >> .temp_aggregate.sh
	@echo '    realpath "$$1"' >> .temp_aggregate.sh
	@echo '  elif command -v grealpath >/dev/null 2>&1; then' >> .temp_aggregate.sh
	@echo '    grealpath "$$1"' >> .temp_aggregate.sh
	@echo '  elif command -v python3 >/dev/null 2>&1; then' >> .temp_aggregate.sh
	@echo '    python3 -c "import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))" "$$1"' >> .temp_aggregate.sh
	@echo '  else' >> .temp_aggregate.sh
	@echo '    if [ -d "$$1" ]; then (cd "$$1" && pwd -P); else (cd "$$(dirname "$$1")" && printf "%s/%s\n" "$$PWD" "$$(basename "$$1")"); fi' >> .temp_aggregate.sh
	@echo '  fi' >> .temp_aggregate.sh
	@echo '}' >> .temp_aggregate.sh
	@echo '' >> .temp_aggregate.sh
	@echo 'INPUT_ARG="$$1"' >> .temp_aggregate.sh
	@echo 'INPUT_PATH="$$(portable_realpath "$$INPUT_ARG")"' >> .temp_aggregate.sh
	@echo 'if [ ! -d "$$INPUT_PATH" ]; then' >> .temp_aggregate.sh
	@echo '  echo "incorrect path"' >> .temp_aggregate.sh
	@echo '  echo "  pwd       : $$PWD"' >> .temp_aggregate.sh
	@echo '  echo "  input arg : $$INPUT_ARG"' >> .temp_aggregate.sh
	@echo '  echo "  resolved  : $$INPUT_PATH"' >> .temp_aggregate.sh
	@echo '  echo "hint: run from repo root, e.g. make aggregate ./quack-core/src/quack_core/config"' >> .temp_aggregate.sh
	@echo '  exit 1' >> .temp_aggregate.sh
	@echo 'fi' >> .temp_aggregate.sh
	@echo '' >> .temp_aggregate.sh
	@echo 'TRANSIENT_DIR="$$INPUT_PATH/_transient-files"' >> .temp_aggregate.sh
	@echo 'TIMESTAMP="$$(date +%Y-%m-%d)"' >> .temp_aggregate.sh
	@echo 'DIRECTORY_NAME="$$(basename "$$INPUT_PATH")"' >> .temp_aggregate.sh
	@echo 'OUTPUT_FILE="$$TRANSIENT_DIR/$$TIMESTAMP-$$DIRECTORY_NAME.txt"' >> .temp_aggregate.sh
	@echo 'USE_GITIGNORE=false' >> .temp_aggregate.sh
	@echo 'if [ -f "$$INPUT_PATH/.gitignore" ] && command -v git >/dev/null 2>&1; then' >> .temp_aggregate.sh
	@echo '  USE_GITIGNORE=true' >> .temp_aggregate.sh
	@echo 'fi' >> .temp_aggregate.sh
	@echo 'mkdir -p "$$TRANSIENT_DIR"' >> .temp_aggregate.sh
	@echo 'if [ ! -f "$$OUTPUT_FILE" ]; then' >> .temp_aggregate.sh
	@echo '  : > "$$OUTPUT_FILE"' >> .temp_aggregate.sh
	@echo '  echo "Created output file: $$OUTPUT_FILE"' >> .temp_aggregate.sh
	@echo 'else' >> .temp_aggregate.sh
	@echo '  echo "Output file already exists: $$OUTPUT_FILE"' >> .temp_aggregate.sh
	@echo 'fi' >> .temp_aggregate.sh
	@echo '' >> .temp_aggregate.sh
	@echo 'file_already_added() {' >> .temp_aggregate.sh
	@echo '  local file="$$1"' >> .temp_aggregate.sh
	@echo '  grep -q "here is $$file:" "$$OUTPUT_FILE" || return 1' >> .temp_aggregate.sh
	@echo '}' >> .temp_aggregate.sh
	@echo '' >> .temp_aggregate.sh
	@echo 'is_ignored_by_gitignore() {' >> .temp_aggregate.sh
	@echo '  local path="$$1"' >> .temp_aggregate.sh
	@echo '  if $$USE_GITIGNORE; then git -C "$$INPUT_PATH" check-ignore "$$path" >/dev/null 2>&1; return $$?; fi' >> .temp_aggregate.sh
	@echo '  return 1' >> .temp_aggregate.sh
	@echo '}' >> .temp_aggregate.sh
	@echo '' >> .temp_aggregate.sh
	@echo 'FILE_EXTENSIONS=("*.txt" "*.md" "*.py" "*.yaml" "*.template" "*.toml" "Makefile" "*.ts" "*.tsx" "*.mdx" "*.js" "*.jsx")' >> .temp_aggregate.sh
	@echo 'FILES_ADDED=0' >> .temp_aggregate.sh
	@echo 'FILES_PROCESSED=0' >> .temp_aggregate.sh
	@echo 'for EXT in "$${FILE_EXTENSIONS[@]}"; do' >> .temp_aggregate.sh
	@echo '  while IFS= read -r FILE; do' >> .temp_aggregate.sh
	@echo '    FILEPATH="$$(portable_realpath "$$FILE")"' >> .temp_aggregate.sh
	@echo '    if [[ "$$FILEPATH" == "$$TRANSIENT_DIR"* ]] || is_ignored_by_gitignore "$$FILEPATH"; then' >> .temp_aggregate.sh
	@echo '      continue' >> .temp_aggregate.sh
	@echo '    fi' >> .temp_aggregate.sh
	@echo '    FILENAME="$$(basename "$$FILE")"' >> .temp_aggregate.sh
	@echo '    if [[ "$$FILENAME" == deprecated_* ]]; then' >> .temp_aggregate.sh
	@echo '      echo "Skipping deprecated file: $$FILEPATH"' >> .temp_aggregate.sh
	@echo '      continue' >> .temp_aggregate.sh
	@echo '    fi' >> .temp_aggregate.sh
	@echo '    ((FILES_PROCESSED++))' >> .temp_aggregate.sh
	@echo '    if file_already_added "$$FILEPATH"; then' >> .temp_aggregate.sh
	@echo '      echo "Skipping already added file: $$FILEPATH"' >> .temp_aggregate.sh
	@echo '      continue' >> .temp_aggregate.sh
	@echo '    fi' >> .temp_aggregate.sh
	@echo '    echo "Processing: $$FILEPATH"' >> .temp_aggregate.sh
	@echo '    echo "here is $$FILEPATH:" >> "$$OUTPUT_FILE"' >> .temp_aggregate.sh
	@echo '    echo "<$$FILENAME>" >> "$$OUTPUT_FILE"' >> .temp_aggregate.sh
	@echo '    cat "$$FILE" >> "$$OUTPUT_FILE"' >> .temp_aggregate.sh
	@echo '    echo "</$$FILENAME>" >> "$$OUTPUT_FILE"' >> .temp_aggregate.sh
	@echo '    echo "" >> "$$OUTPUT_FILE"' >> .temp_aggregate.sh
	@echo '    ((FILES_ADDED++))' >> .temp_aggregate.sh
	@echo '  done < <(find "$$INPUT_PATH" -type f -name "$$EXT" ! -path "$$TRANSIENT_DIR/*" ! -name ".*")' >> .temp_aggregate.sh
	@echo 'done' >> .temp_aggregate.sh
	@echo '' >> .temp_aggregate.sh
	@echo 'if [ $$FILES_PROCESSED -eq 0 ]; then' >> .temp_aggregate.sh
	@echo '  echo "No files found matching the specified criteria. Exiting."' >> .temp_aggregate.sh
	@echo '  exit 0' >> .temp_aggregate.sh
	@echo 'fi' >> .temp_aggregate.sh
	@echo 'if [ $$FILES_ADDED -eq 0 ]; then' >> .temp_aggregate.sh
	@echo '  echo "No new files to add. Exiting."' >> .temp_aggregate.sh
	@echo '  exit 0' >> .temp_aggregate.sh
	@echo 'else' >> .temp_aggregate.sh
	@echo '  echo "All files aggregated into: $$OUTPUT_FILE"' >> .temp_aggregate.sh
	@echo '  exit 0' >> .temp_aggregate.sh
	@echo 'fi' >> .temp_aggregate.sh
	@chmod +x .temp_aggregate.sh
	@./.temp_aggregate.sh "$(AGGREGATE_TARGET)"
	@rm -f .temp_aggregate.sh
	@echo "${GREEN}✓ File aggregation completed${RESET}"

.PHONY: add-paths
add-paths: ## Add file paths as first-line comments to all Python files
	@echo "${BLUE}Adding file paths as comments to Python files...${RESET}"
	@echo '#!/usr/bin/env python' > add_paths.py
	@echo '# add_paths.py' >> add_paths.py
	@echo '"""' >> add_paths.py
	@echo 'Script to add file paths as first-line comments to Python files.' >> add_paths.py
	@echo '"""' >> add_paths.py
	@echo 'import os' >> add_paths.py
	@echo 'import sys' >> add_paths.py
	@echo 'import traceback' >> add_paths.py
	@echo '' >> add_paths.py
	@echo 'def update_file(filepath):' >> add_paths.py
	@echo '    try:' >> add_paths.py
	@echo '        relpath = os.path.relpath(filepath)' >> add_paths.py
	@echo '        print(f"Processing {relpath}...")' >> add_paths.py
	@echo '' >> add_paths.py
	@echo '        with open(filepath, "r") as f:' >> add_paths.py
	@echo '            content = f.read()' >> add_paths.py
	@echo '' >> add_paths.py
	@echo '        lines = content.split("\\n")' >> add_paths.py
	@echo '        if not lines:' >> add_paths.py
	@echo '            print(f"  Skipping {relpath}: empty file")' >> add_paths.py
	@echo '            return' >> add_paths.py
	@echo '' >> add_paths.py
	@echo '        has_path_comment = False' >> add_paths.py
	@echo '        if lines[0].strip().startswith("#"):' >> add_paths.py
	@echo '            has_path_comment = True' >> add_paths.py
	@echo '            old_line = lines[0]' >> add_paths.py
	@echo '            lines[0] = f"# {relpath}"' >> add_paths.py
	@echo '            print(f"  Replacing comment: {old_line} -> # {relpath}")' >> add_paths.py
	@echo '        else:' >> add_paths.py
	@echo '            lines.insert(0, f"# {relpath}")' >> add_paths.py
	@echo '            print(f"  Adding new comment: # {relpath}")' >> add_paths.py
	@echo '' >> add_paths.py
	@echo '        with open(filepath, "w") as f:' >> add_paths.py
	@echo '            f.write("\\n".join(lines))' >> add_paths.py
	@echo '' >> add_paths.py
	@echo '        print(f"  Updated {relpath}")' >> add_paths.py
	@echo '    except Exception as e:' >> add_paths.py
	@echo '        print(f"  Error processing {filepath}: {str(e)}")' >> add_paths.py
	@echo '        traceback.print_exc()' >> add_paths.py
	@echo '' >> add_paths.py
	@echo 'def main():' >> add_paths.py
	@echo '    try:' >> add_paths.py
	@echo '        count = 0' >> add_paths.py
	@echo '        print("Starting file scan...")' >> add_paths.py
	@echo '        for root, dirs, files in os.walk("."):' >> add_paths.py
	@echo '            # Skip hidden and build directories' >> add_paths.py
	@echo '            if any(x in root for x in [".git", ".venv", "__pycache__", ".mypy_cache",' >> add_paths.py
	@echo '                                      ".pytest_cache", ".ruff_cache", "build", "dist", ".egg-info"]):' >> add_paths.py
	@echo '                continue' >> add_paths.py
	@echo '' >> add_paths.py
	@echo '            for file in files:' >> add_paths.py
	@echo '                if file.endswith(".py"):' >> add_paths.py
	@echo '                    filepath = os.path.join(root, file)' >> add_paths.py
	@echo '                    update_file(filepath)' >> add_paths.py
	@echo '                    count += 1' >> add_paths.py
	@echo '' >> add_paths.py
	@echo '        print(f"Processed {count} Python files")' >> add_paths.py
	@echo '    except Exception as e:' >> add_paths.py
	@echo '        print(f"Fatal error: {str(e)}")' >> add_paths.py
	@echo '        traceback.print_exc()' >> add_paths.py
	@echo '        sys.exit(1)' >> add_paths.py
	@echo '' >> add_paths.py
	@echo 'if __name__ == "__main__":' >> add_paths.py
	@echo '    main()' >> add_paths.py
	@chmod +x add_paths.py
	@$(PYTHON) add_paths.py
	@rm add_paths.py
	@echo "${GREEN}✓ File paths added to all Python files${RESET}"

# Unknown targets deliberately use make's failing default; no catch-all rule.

.PHONY: index-catalog
index-catalog: ## Disabled: no real-media catalog indexing is admitted
	$(error NAS_WORKFLOW_DISABLED: replacement tools and separately approved storage scope required)
	$(PYTHON) -m media_toolkit.catalog index-sidecars \
	  --catalog $(TARGET_VOLUME)/Catalog/catalog.sqlite \
	  --root $(TARGET_VOLUME)

.PHONY: link-project
link-project: ## Disabled: no project/media links are admitted
	$(error NAS_WORKFLOW_DISABLED: replacement tools and separately approved storage scope required)
	$(PYTHON) -m media_toolkit.link_into_project \
	  --root $(TARGET_VOLUME) \
	  --project $(PROJECT) \
	  --shoot $(SHOOT) \
	  --date $(DATE) \
	  $(foreach d,$(DEVICES),--device $(d))


.DEFAULT_GOAL := help
