export DBT_PROFILES_DIR := .

.PHONY: setup build build-small docs clean

setup: ## Install dependencies and prepare data
	pip install -r requirements.txt
	python scripts/prepare_data.py

build: ## Run dbt build (full pipeline; requires ≥16 GB RAM)
	dbt build

build-small: ## Cold-rebuild path for ≤8 GB sandboxes (chunked stg_events + dbt build of the rest)
	python scripts/build_stg_batched.py
	dbt build --exclude stg_events

docs: ## Generate and serve dbt docs
	dbt docs generate
	dbt docs serve

clean: ## Remove build artifacts and data
	rm -rf target/ dbt_packages/ logs/
	rm -f data/*.duckdb data/*.duckdb.wal data/*.parquet
