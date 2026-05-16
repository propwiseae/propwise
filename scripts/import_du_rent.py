"""
PropWise · DLD Rent Data Import Script
=======================================
Loads DLD rental CSV/Excel exports into the du_rent_info Supabase table.

Usage:
    python import_du_rent.py --file rents-2026-04.csv --period 2026-04
    python import_du_rent.py --file rents-2026-05.xlsx --period 2026-05

Requirements:
    pip install pandas supabase python-dotenv openpyxl tqdm

Environment variables (in .env.local):
    SUPABASE_URL=https://your-project-ref.supabase.co
    SUPABASE_SERVICE_KEY=your-service-role-key
"""

import os
import sys
import argparse
import math
import pandas as pd
from datetime import datetime
from dotenv import load_dotenv
from supabase import create_client, Client
from tqdm import tqdm

# ── Config ───────────────────────────────────────────────────────────────────

BATCH_SIZE = 500       # rows per Supabase upsert call (stay under 6 MB payload)
TABLE      = "du_rent_info"
SOURCE     = "Excel"   # change to "API" if feeding from DLD live API

load_dotenv(".env.local")
SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_KEY = os.environ["SUPABASE_SERVICE_KEY"]   # must be service_role key

# ── Column mapping: CSV column → DB column ───────────────────────────────────

COLUMN_MAP = {
    "REGISTRATION_DATE":  "registration_date",
    "START_DATE":         "start_date",
    "END_DATE":           "end_date",
    "VERSION_EN":         "version_en",
    "AREA_EN":            "area_en",
    "CONTRACT_AMOUNT":    "contract_amount",
    "ANNUAL_AMOUNT":      "annual_amount",
    "IS_FREE_HOLD_EN":    "is_free_hold_en",
    "ACTUAL_AREA":        "actual_area",
    "PROP_TYPE_EN":       "prop_type_en",
    "PROP_SUB_TYPE_EN":   "prop_sub_type_en",
    "ROOMS":              "rooms",
    "USAGE_EN":           "usage_en",
    "NEAREST_METRO_EN":   "nearest_metro_en",
    "NEAREST_MALL_EN":    "nearest_mall_en",
    "NEAREST_LANDMARK_EN":"nearest_landmark_en",
    "PARKING":            "parking",
    "TOTAL_PROPERTIES":   "total_properties",
    "MASTER_PROJECT_EN":  "master_project_en",
    "PROJECT_EN":         "project_en",
}

DATE_COLS = ["registration_date", "start_date", "end_date"]
INT_COLS  = ["rooms", "parking", "total_properties"]

# ── Helpers ───────────────────────────────────────────────────────────────────

def safe_int(val):
    """Convert float/NaN to int or None."""
    if val is None or (isinstance(val, float) and math.isnan(val)):
        return None
    return int(val)

def safe_str(val):
    """Convert NaN/None to None, strip whitespace."""
    if val is None or (isinstance(val, float) and math.isnan(val)):
        return None
    s = str(val).strip()
    return s if s else None

def clean_row(row: dict, source_ref: str, data_period: str) -> dict:
    """Normalise a single row dict for insertion."""
    cleaned = {
        "source":      SOURCE,
        "source_ref":  source_ref,
        "data_period": data_period,
    }
    for csv_col, db_col in COLUMN_MAP.items():
        val = row.get(db_col)   # already renamed via COLUMN_MAP

        if db_col in DATE_COLS:
            if val is None or (isinstance(val, float) and math.isnan(val)):
                cleaned[db_col] = None
            else:
                # Ensure ISO 8601 string for Supabase
                if isinstance(val, pd.Timestamp):
                    cleaned[db_col] = val.isoformat()
                else:
                    cleaned[db_col] = str(val)

        elif db_col in INT_COLS:
            cleaned[db_col] = safe_int(val)

        elif db_col in ("contract_amount", "annual_amount", "actual_area"):
            cleaned[db_col] = None if (val is None or (isinstance(val, float) and math.isnan(val))) else float(val)

        else:
            cleaned[db_col] = safe_str(val)

    return cleaned


def load_file(filepath: str) -> pd.DataFrame:
    """Load CSV or Excel into a DataFrame with normalised column names."""
    ext = os.path.splitext(filepath)[1].lower()
    if ext == ".csv":
        df = pd.read_csv(filepath, parse_dates=["REGISTRATION_DATE", "START_DATE", "END_DATE"])
    elif ext in (".xlsx", ".xls"):
        df = pd.read_excel(filepath, parse_dates=["REGISTRATION_DATE", "START_DATE", "END_DATE"])
    else:
        raise ValueError(f"Unsupported file type: {ext}")

    # Rename to DB column names immediately
    df.rename(columns=COLUMN_MAP, inplace=True)

    # Only keep columns we know about
    known = list(COLUMN_MAP.values())
    df = df[[c for c in known if c in df.columns]]

    return df


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Import DLD rent data into Supabase du_rent_info")
    parser.add_argument("--file",   required=True, help="Path to CSV or Excel file")
    parser.add_argument("--period", required=True, help="Data period e.g. 2026-04")
    parser.add_argument("--dry-run", action="store_true", help="Parse only, don't insert")
    args = parser.parse_args()

    source_ref  = os.path.basename(args.file)
    data_period = args.period

    print(f"\n{'='*60}")
    print(f"  PropWise DLD Rent Import")
    print(f"  File:    {args.file}")
    print(f"  Period:  {data_period}")
    print(f"  Table:   {TABLE}")
    print(f"  Dry run: {args.dry_run}")
    print(f"{'='*60}\n")

    # 1. Load file
    print("📂 Loading file...")
    df = load_file(args.file)
    total_rows = len(df)
    print(f"   ✓ {total_rows:,} rows loaded, {len(df.columns)} columns\n")

    if args.dry_run:
        print("🔍 DRY RUN — sample cleaned rows:")
        sample = df.head(3).to_dict(orient="records")
        for r in sample:
            cleaned = clean_row(r, source_ref, data_period)
            print(cleaned)
        print("\n✅ Dry run complete. No data written.")
        return

    # 2. Connect to Supabase
    print("🔌 Connecting to Supabase...")
    supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)
    print("   ✓ Connected\n")

    # 3. Batch insert
    records = df.to_dict(orient="records")
    total_batches = math.ceil(total_rows / BATCH_SIZE)
    inserted = 0
    errors   = 0

    print(f"⬆️  Inserting {total_rows:,} rows in {total_batches} batches of {BATCH_SIZE}...\n")

    for i in tqdm(range(0, total_rows, BATCH_SIZE), total=total_batches, unit="batch"):
        batch_raw  = records[i : i + BATCH_SIZE]
        batch_clean = [clean_row(r, source_ref, data_period) for r in batch_raw]

        try:
            supabase.table(TABLE).insert(batch_clean).execute()
            inserted += len(batch_clean)
        except Exception as e:
            errors += len(batch_clean)
            print(f"\n❌ Batch {i//BATCH_SIZE + 1} failed: {e}")

    # 4. Summary
    print(f"\n{'='*60}")
    print(f"  Import complete")
    print(f"  Rows inserted : {inserted:,}")
    print(f"  Rows failed   : {errors:,}")
    print(f"  Period        : {data_period}")
    print(f"  Source ref    : {source_ref}")
    print(f"  Timestamp     : {datetime.utcnow().isoformat()}Z")
    print(f"{'='*60}\n")

    if errors:
        sys.exit(1)


if __name__ == "__main__":
    main()
