# Rebuilding the reference databases

`food.db` and `exercises.db` no longer live in this repository. They ship in
LiftKit's `LiftReference` product, and so does the script that builds them:

    dugcanlift-kit/Tools/build_reference.py

This repository used to carry its own copy of that script, and the two drifted
the first time the food data changed: LiftKit 1.9.0 added saturated fat (USDA
nutrient 1258) to the kit's copy. The copy here was deleted on 2026-09-16 so
there is one script to change. Its header describes the sources, the phases
(USDA now, Open Food Facts later) and how to rebuild.

The raw sources are still untracked under `data/` in this checkout (`data/` is
gitignored): `data/fdc/food.csv`, `data/fdc/food_nutrient.csv` and
`data/exercises/`. From the kit's root, with this repository checked out beside
it:

```bash
python3 Tools/build_reference.py \
    --sources ../lift-ios/data --out Sources/LiftReference/Resources
```

A new `food.db` reaches this app as a LiftKit release: tag the kit, then bump
`exactVersion` in `project.yml`. If the release changes a `@Model` type, or a
struct one stores, read `Sources/Shared/LiftSchemaVersions.swift` first.

## Licensing

`food.db` is USDA FoodData Central (public domain) today. If Open Food Facts
data (ODbL, share-alike) is ever added, see the script's header and
`ATTRIBUTION.md` for the attribution to ship with it.
