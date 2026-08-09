# Data attribution

Lift bundles two independent reference databases. They are distributed together
but are **not merged** — each remains under its own license.

---

## food.db

Contains data from two sources:

### USDA FoodData Central
U.S. Department of Agriculture, Agricultural Research Service.
Work of the U.S. federal government — **public domain**.
https://fdc.nal.usda.gov

### Open Food Facts
© Open Food Facts contributors.
Licensed under the **Open Database License (ODbL) v1.0**.
https://openfoodfacts.org · https://opendatacommons.org/licenses/odbl/

The portion of `food.db` derived from Open Food Facts is made available under
the same ODbL terms. A machine-readable copy of the adapted database is
available free of charge at:

**https://dugcanlift.com/data/food.db**  ← publish this before release

Individual database contents are available under the Database Contents License.

---

## exercises.db

### free-exercise-db
By yuhonas. **Public domain.**
https://github.com/yuhonas/free-exercise-db

### wger
Exercise data © wger contributors, licensed under
**Creative Commons Attribution-ShareAlike 3.0 (CC-BY-SA 3.0)**.
https://wger.de · https://creativecommons.org/licenses/by-sa/3.0/

`exercises.db` is made available under CC-BY-SA 3.0.

---

## Why two files

ODbL and CC-BY-SA 3.0 both carry share-alike obligations, and they are not
compatible with one another. Merging Open Food Facts and wger data into a
single database would mean each license required the combined result be
released under itself — which cannot be satisfied simultaneously.

Distributing them as separate, independent databases makes this a **Collective
Database** rather than a **Derivative Database**, so each share-alike
obligation stays scoped to its own file.

This is why `ReferenceDatabase` opens two `DatabaseQueue`s and why no query
spans both. Do not merge these files, and do not add a table that joins food
records to exercise records.

---

## Release checklist

- [ ] Surface these notices in the app (Settings → About → Data sources)
- [ ] Publish `food.db` under ODbL at a stable public URL
- [ ] Publish `exercises.db` under CC-BY-SA 3.0
- [ ] Re-publish both whenever the bundled databases are updated
- [ ] Have a lawyer confirm before App Store submission

*Not legal advice — this reflects the licenses as published by each project.*
