export DBT_PROFILES_DIR := .

.PHONY: setup build docs clean

setup: ## Install dependencies and prepare data
	pip install -r requirements.txt
	python scripts/prepare_data.py

build: ## Run dbt build
	dbt build

docs: ## Generate and serve dbt docs
	dbt docs generate
	dbt docs serve

clean: ## Remove build artifacts and data
	rm -rf target/ dbt_packages/ logs/
	rm -f data/*.duckdb data/*.duckdb.wal data/*.parquet
