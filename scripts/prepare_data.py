"""Download Firebase events parquet from Google Drive and load into DuckDB."""

import os
import time

import duckdb
import gdown

# Firebase public dataset (Flood It! game), 2018-06-12 to 2018-10-03
GDRIVE_FILE_ID = "1FTZONE_YydmmewPA3wfysVw8MuUTZe7h"
GDRIVE_URL = f"https://drive.google.com/uc?id={GDRIVE_FILE_ID}"

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(BASE_DIR, "data")
PARQUET_PATH = os.path.join(DATA_DIR, "firebase_events.parquet")
DUCKDB_PATH = os.path.join(DATA_DIR, "warehouse.duckdb")


def download_parquet():
    """Download parquet from Google Drive if not already present."""
    if os.path.exists(PARQUET_PATH):
        size_mb = os.path.getsize(PARQUET_PATH) / 1e6
        print(f"Parquet already exists: {PARQUET_PATH} ({size_mb:.0f} MB)")
        return

    os.makedirs(DATA_DIR, exist_ok=True)
    print(f"Downloading Firebase events...")
    print("This may take a few minutes depending on your connection.")

    gdown.download(GDRIVE_URL, PARQUET_PATH, quiet=False)

    size_mb = os.path.getsize(PARQUET_PATH) / 1e6
    print(f"Downloaded: {size_mb:.0f} MB")


def load_to_duckdb():
    """Load parquet into DuckDB as raw.events table."""
    print(f"Loading parquet into DuckDB: {DUCKDB_PATH}")
    start = time.time()

    con = duckdb.connect(DUCKDB_PATH)
    con.execute("CREATE SCHEMA IF NOT EXISTS raw")
    con.execute(f"""
        CREATE OR REPLACE TABLE raw.events AS
        SELECT * FROM read_parquet('{PARQUET_PATH}')
    """)

    count = con.execute("SELECT COUNT(*) FROM raw.events").fetchone()[0]
    elapsed = time.time() - start
    print(f"Loaded {count:,} events into raw.events ({elapsed:.1f}s)")

    con.close()


def main():
    download_parquet()
    load_to_duckdb()
    print("Done. Ready for dbt.")


if __name__ == "__main__":
    main()
