#!/usr/bin/env python3
"""
Build Lift's bundled reference databases.

Produces TWO separate SQLite files, deliberately never joined:

  food.db       USDA FoodData Central (public domain) + Open Food Facts (ODbL)
                -> distribute under ODbL, with attribution

  exercises.db  free-exercise-db (public domain) + wger (CC-BY-SA 3.0)
                -> distribute under CC-BY-SA 3.0, with attribution

ODbL and CC-BY-SA 3.0 are both share-alike and are NOT compatible with each
other. Keeping the sources in separate files makes this a "Collective
Database" rather than a "Derivative Database", so each share-alike obligation
stays scoped to its own file. Do not merge these into one file, and do not
write a query that joins across them.

Usage:
    python3 build_reference.py --sources ./sources --out ./out

Expected layout under --sources:
    fdc/food.csv                    from FoodData Central full download
    fdc/food_nutrient.csv
    fdc/branded_food.csv            (optional)
    off/en.openfoodfacts.org.products.csv    tab-delimited export
    exercises/free-exercise-db.json          combined JSON array
    exercises/wger-exercises.json            (optional) from the wger API
"""

from __future__ import annotations

import argparse
import csv
import json
import sqlite3
import sys
from pathlib import Path

csv.field_size_limit(sys.maxsize)

# FoodData Central nutrient IDs. Verify against nutrient.csv in your release —
# these have been stable for years but the dataset does change.
FDC_NUTRIENTS = {
    1008: "calories",   # Energy (kcal)
    1003: "protein",
    1005: "carbs",      # Carbohydrate, by difference
    1004: "fat",        # Total lipid (fat)
    1079: "fiber",      # Fiber, total dietary
    2000: "sugar",      # Total Sugars
    1093: "sodium",     # Sodium, Na (mg)
}

# Only keep these FDC data types. Branded is ~1.9M rows and mostly duplicates
# what Open Food Facts already covers, so it is excluded by default.
FDC_KEEP_TYPES = {"foundation_food", "sr_legacy_food", "survey_fndds_food"}

# Open Food Facts is global and enormous. Restrict to markets you serve.
OFF_COUNTRIES = {"united-states", "canada", "united-kingdom"}

FOOD_SCHEMA = """
CREATE TABLE foods (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  brand         TEXT,
  barcode       TEXT,
  servingGrams  REAL,
  servingLabel  TEXT,
  caloriesPer100g REAL NOT NULL,
  proteinPer100g  REAL NOT NULL,
  carbsPer100g    REAL NOT NULL,
  fatPer100g      REAL NOT NULL,
  fiberPer100g    REAL,
  sugarPer100g    REAL,
  sodiumPer100g   REAL,
  source        TEXT NOT NULL
);
CREATE INDEX idx_foods_barcode ON foods(barcode);
CREATE VIRTUAL TABLE foods_fts USING fts5(
  name, brand, content='foods', content_rowid='rowid',
  tokenize='porter unicode61'
);
"""

EXERCISE_SCHEMA = """
CREATE TABLE exercises (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  primaryMuscle TEXT,
  equipment     TEXT,
  category      TEXT,
  mechanic      TEXT,
  level         TEXT,
  instructions  TEXT,
  source        TEXT NOT NULL
);
CREATE VIRTUAL TABLE exercises_fts USING fts5(
  name, primaryMuscle, content='exercises', content_rowid='rowid',
  tokenize='porter unicode61'
);
"""


def fresh_db(path: Path, schema: str) -> sqlite3.Connection:
    path.unlink(missing_ok=True)
    conn = sqlite3.connect(path)
    conn.executescript(schema)
    conn.execute("PRAGMA journal_mode = OFF")
    conn.execute("PRAGMA synchronous = OFF")
    return conn


def to_float(value: str | None) -> float | None:
    if value is None or value == "":
        return None
    try:
        result = float(value)
    except ValueError:
        return None
    # Guard against the malformed rows that are common in crowd-sourced data.
    if result != result or result < 0:
        return None
    return result


# ----------------------------------------------------------------- USDA

def load_usda(conn: sqlite3.Connection, root: Path) -> int:
    food_csv = root / "fdc" / "food.csv"
    nutrient_csv = root / "fdc" / "food_nutrient.csv"
    if not food_csv.exists():
        print("  fdc/food.csv not found — skipping USDA")
        return 0

    keep: dict[str, str] = {}
    with food_csv.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            if row.get("data_type") in FDC_KEEP_TYPES:
                keep[row["fdc_id"]] = row["description"]
    print(f"  {len(keep):,} USDA foods of interest")

    # food_nutrient.csv is several GB. Stream it, keeping only wanted pairs.
    nutrients: dict[str, dict[str, float]] = {}
    with nutrient_csv.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            fdc_id = row["fdc_id"]
            if fdc_id not in keep:
                continue
            try:
                nutrient_id = int(row["nutrient_id"])
            except ValueError:
                continue
            field = FDC_NUTRIENTS.get(nutrient_id)
            if field is None:
                continue
            amount = to_float(row.get("amount"))
            if amount is not None:
                nutrients.setdefault(fdc_id, {})[field] = amount

    rows = []
    for fdc_id, name in keep.items():
        values = nutrients.get(fdc_id)
        # Require the four macros; an entry without them is useless for logging.
        if not values or "calories" not in values:
            continue
        rows.append((
            f"usda:{fdc_id}", name, None, None, None, None,
            values.get("calories", 0.0),
            values.get("protein", 0.0),
            values.get("carbs", 0.0),
            values.get("fat", 0.0),
            values.get("fiber"),
            values.get("sugar"),
            values.get("sodium"),
            "usda",
        ))

    conn.executemany("INSERT OR IGNORE INTO foods VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
    conn.commit()
    return len(rows)


# ------------------------------------------------------- Open Food Facts

def load_off(conn: sqlite3.Connection, root: Path) -> int:
    path = root / "off" / "en.openfoodfacts.org.products.csv"
    if not path.exists():
        print("  off/...products.csv not found — skipping Open Food Facts")
        return 0

    inserted = 0
    batch: list[tuple] = []

    with path.open(newline="", encoding="utf-8", errors="replace") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            code = (row.get("code") or "").strip()
            name = (row.get("product_name") or "").strip()
            if not code or not name or len(name) > 200:
                continue

            countries = (row.get("countries_tags") or "")
            if OFF_COUNTRIES and not any(c in countries for c in OFF_COUNTRIES):
                continue

            calories = to_float(row.get("energy-kcal_100g"))
            protein = to_float(row.get("proteins_100g"))
            carbs = to_float(row.get("carbohydrates_100g"))
            fat = to_float(row.get("fat_100g"))

            # Drop products with no usable nutrition — a large share of OFF.
            if calories is None or calories > 900:
                continue
            if protein is None and carbs is None and fat is None:
                continue

            sodium = to_float(row.get("sodium_100g"))
            batch.append((
                f"off:{code}", name,
                (row.get("brands") or "").strip() or None,
                code,
                to_float(row.get("serving_quantity")),
                (row.get("serving_size") or "").strip() or None,
                calories, protein or 0.0, carbs or 0.0, fat or 0.0,
                to_float(row.get("fiber_100g")),
                to_float(row.get("sugars_100g")),
                sodium * 1000 if sodium is not None else None,  # g -> mg
                "openfoodfacts",
            ))

            if len(batch) >= 50_000:
                conn.executemany(
                    "INSERT OR IGNORE INTO foods VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", batch)
                inserted += len(batch)
                batch.clear()
                print(f"    {inserted:,} products...", end="\r")

    if batch:
        conn.executemany("INSERT OR IGNORE INTO foods VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", batch)
        inserted += len(batch)

    conn.commit()
    return inserted


# -------------------------------------------------------------- exercises

def load_exercises(conn: sqlite3.Connection, root: Path) -> int:
    rows: list[tuple] = []

    free_path = root / "exercises" / "free-exercise-db.json"
    if free_path.exists():
        for item in json.loads(free_path.read_text(encoding="utf-8")):
            muscles = item.get("primaryMuscles") or []
            rows.append((
                f"fedb:{item['id']}",
                item.get("name", ""),
                muscles[0] if muscles else None,
                item.get("equipment"),
                item.get("category"),
                item.get("mechanic"),
                item.get("level"),
                "\n".join(item.get("instructions") or []) or None,
                "free-exercise-db",
            ))
    else:
        print("  free-exercise-db.json not found — skipping")

    wger_path = root / "exercises" / "wger-exercises.json"
    if wger_path.exists():
        payload = json.loads(wger_path.read_text(encoding="utf-8"))
        for item in payload.get("results", payload if isinstance(payload, list) else []):
            name = (item.get("name") or "").strip()
            if not name:
                continue
            rows.append((
                f"wger:{item.get('id')}", name,
                (item.get("category") or {}).get("name") if isinstance(item.get("category"), dict) else None,
                None,
                "strength",
                None,
                None,
                (item.get("description") or "").strip() or None,
                "wger",
            ))

    conn.executemany("INSERT OR IGNORE INTO exercises VALUES (?,?,?,?,?,?,?,?,?)", rows)
    conn.commit()
    return len(rows)


# ------------------------------------------------------------------ main

def finalise(conn: sqlite3.Connection, table: str) -> None:
    conn.execute(
        f"INSERT INTO {table}_fts({table}_fts) VALUES('rebuild')")
    conn.commit()
    conn.execute("VACUUM")
    conn.commit()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sources", type=Path, default=Path("sources"))
    parser.add_argument("--out", type=Path, default=Path("out"))
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    print("Building food.db  (USDA public domain + Open Food Facts ODbL)")
    food_path = args.out / "food.db"
    food = fresh_db(food_path, FOOD_SCHEMA)
    usda_count = load_usda(food, args.sources)
    print(f"  USDA:            {usda_count:,}")
    off_count = load_off(food, args.sources)
    print(f"  Open Food Facts: {off_count:,}")
    finalise(food, "foods")
    food.close()
    if usda_count + off_count == 0:
        food_path.unlink()
        print("  no food data — food.db not written\n")
    else:
        print(f"  -> {food_path} ({food_path.stat().st_size / 1e6:.0f} MB)\n")

    print("Building exercises.db  (free-exercise-db public domain + wger CC-BY-SA 3.0)")
    ex_path = args.out / "exercises.db"
    exercises = fresh_db(ex_path, EXERCISE_SCHEMA)
    ex_count = load_exercises(exercises, args.sources)
    print(f"  exercises:       {ex_count:,}")
    finalise(exercises, "exercises")
    exercises.close()
    print(f"  -> {ex_path} ({ex_path.stat().st_size / 1e6:.1f} MB)\n")

    print("Reminder: ship ATTRIBUTION.md, and publish food.db under ODbL.")


if __name__ == "__main__":
    main()
