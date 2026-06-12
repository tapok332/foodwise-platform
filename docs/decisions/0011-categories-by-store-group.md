# ADR 0011: Categories partitioned by StoreGroup with backend-owned i18n

**Date:** 2026-05-24

## Context

`/restaurants` (filtered by `type=RESTAURANT`) and `/stores` (no filter) showed
the same 10 cuisine categories (Pizza, Sushi, …) — irrelevant for grocery /
sweets stores. Category `name` was a single non-translated string; UI showed
English regardless of selected locale (`uk` / `en`).

## Decision

1. **`StoreGroup`** — a new enum (`FOOD_SERVICE`, `RETAIL`) owned by `StoreType` via `group()` and `typesIn()`. Mapping:
   - `RESTAURANT`, `CAFE`, `BAKERY` → `FOOD_SERVICE`
   - `GROCERY`, `SWEETS`, `OTHER` → `RETAIL`

2. **Category ↔ StoreType — M:N** via JPA `@ElementCollection<StoreType>` on `CategoryEntity` (backing table `category_store_types`). One category can apply to multiple `StoreType`s (Bakery → RESTAURANT + BAKERY).

3. **i18n — a dedicated table** `category_translations(category_id, locale, name)`. Source of truth lives in the DB; adding a locale is an INSERT, no code change. Resolution chain: requested locale → en fallback → canonical `categories.name`.

4. **`?group=`** on `GET /stores` and `GET /home/categories` — syntactic sugar over `?type=` (mutually exclusive). The page-level partition `/restaurants` ↔ `/stores` lives on the frontend as the literal `'FOOD_SERVICE'` / `'RETAIL'`.

5. **Locale resolution.** A new `RequestLocaleResolver` reads `?locale=` (override) or the `Accept-Language` header, falling back to `en` for unsupported languages. Supported locales: `en` and `uk`. (Named `RequestLocaleResolver` — not `LocaleResolver` — to avoid a clash with the built-in Spring MVC bean.)

## Alternatives rejected

- **Frontend-hardcoded group → multi-value `?type=`.** The group mapping would be duplicated in every client; adding a mobile client duplicates the knowledge again.
- **A parallel `?group=` axis independent of type.** Creates two competing taxonomy axes — confusing URLs.
- **A JSON column `name_i18n`.** Not normalized, awkward fallback queries in SQL, poor fit for an admin UI.
- **Frontend-only i18n (`translations.categories[slug]`).** The source of truth drifts into every client; an admin cannot add a locale without a deploy; a future mobile client duplicates it.

## Consequences

- **Breaking:** `CategoryDto` gains 2 new required fields (`applicableTypes`, `applicableGroups`); existing clients ignore them without errors (JSON additive).
- **Breaking:** `POST /categories` requires `applicableTypes` (non-empty) and `translations.en`. Old admin calls will fail with 400 — intentionally: creating a category without types and without a locale is a bug.
- **Breaking:** the `/stores` page stops being "everything" and becomes RETAIL-only (see spec out-of-scope).
- **Plus:** new languages are added with an INSERT in the seed (or via a future admin UI), no redeploy.
- **Plus:** adding a new `StoreType` (e.g. `BAR`) automatically inherits its `StoreGroup` via the enum constructor.
- **Plus:** the category seed stays idempotent — a repeated boot does not duplicate rows in `category_translations` / `category_store_types`.

## Spec

`docs/superpowers/specs/2026-05-24-categories-by-store-group-design.md`
