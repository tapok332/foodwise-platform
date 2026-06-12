# Stores API — Contract (Phase 2 frontend brief)

> **What this is.** The `fw-store-service` contract after the 2026-05-17 backend phase (`StoreType` + `Category.slug` + sort whitelist + readable seed). A document for the frontend agent: what to send, what you get back, what to migrate to, which fallbacks to keep.
>
> **Base URL.** Always through the gateway: `http://localhost:8080` (env `API_BASE_URL`). Never the direct microservice ports.
>
> **Auth.** The endpoints below are public (via the gateway's `PUBLIC_PATHS`). `POST /categories`, `POST /stores` — `@PreAuthorize("hasRole('ADMIN')")`, require `Authorization: Bearer <JWT>`. In general the frontend only calls the GET endpoints in this document.
>
> **Response envelope.** Every 2xx response is wrapped in `ApiResponse<T>`:
> ```json
> { "success": true, "data": <T>, "error": null }
> ```
> Errors:
> ```json
> { "success": false, "data": null, "error": { "code": "BAD_REQUEST", "message": "Unknown sort: password" } }
> ```

---

## 1. What changed vs the previous version

| Area | Before | Now |
|---|---|---|
| **Categories** | free-form `name`, `Asian-1777468007` (timestamp suffix), 80 duplicates | 10 canonical, `{id, slug, name, iconName}`. Seeded idempotently from the backend |
| **Category identifier in frontend URLs** | hardcode / slug-with-timestamp | `slug` ∈ {`pizza`, `sushi`, `bakery`, `asian`, `burgers`, `coffee`, `dessert`, `vegan`, `pastry`, `greek`} |
| **Venue type** | absent; everything was a "category" | new `StoreType` field (macro classification) |
| **Store DTO** | `categoryName: string` | `category: CategoryDto`. The `categoryName` field is kept **deprecated** (mirror of `category.name`), to be removed in 1 sprint |
| **`GET /stores` params** | most were silently ignored | the full contract works (see §3) |
| **Invalid sort** | silently ignored (default order by id) | `400 Bad Request` with a clear message |
| **`GET /categories/{slug}`** | did not exist | new endpoint |

---

## 2. Entities

### `StoreType` (enum)

```ts
type StoreType = "RESTAURANT" | "GROCERY" | "BAKERY" | "CAFE" | "SWEETS" | "OTHER";
```

Serialized as a string in JSON. Accepted as a string in query params. Default on creation — `RESTAURANT`.

### `CategoryDto`

```ts
interface CategoryDto {
  id: string;
  slug: string;
  name: string;                      // localized via Accept-Language / ?locale=
  iconName: string | null;
  applicableTypes: StoreType[];      // NEW
  applicableGroups: StoreGroup[];    // NEW (derived)
}

type StoreGroup = "FOOD_SERVICE" | "RETAIL";
```

### `StoreDto`

```ts
interface StoreDto {
  id: string;
  name: string;
  type: StoreType;                    // NEW
  category: CategoryDto | null;       // NEW — replaces categoryName
  description: string | null;
  imageUrl: string | null;
  heroImageUrl: string | null;
  address: string | null;
  location: { latitude: number; longitude: number } | null;
  rating: number | null;              // 0.0..5.0, 1 decimal place
  opensAt: string | null;             // "HH:mm:ss"
  closesAt: string | null;
  phone: string | null;
  website: string | null;
  deliveryFee: number | null;
  minOrderAmount: number | null;
  priceLevel: number | null;          // 1..4
  currentlyOpen: boolean;             // computed in the service timezone (Europe/Kyiv)
  menuItems: MenuItemDto[];           // empty for search
  combos: ComboDto[];                 // empty for search
  distance: number | null;            // meters; null for search results, populated only in GET /stores/{id}?latitude&longitude

  /** @deprecated mirror of category.name, remove once all readers have migrated */
  categoryName: string | null;
}
```

---

## 3. `GET /stores`

### Query parameters (all optional except `page`/`limit`, which have defaults)

| Parameter | Type | Default | Semantics |
|---|---|---|---|
| `search` | string | — | LIKE `%search%` on `name` OR `description` (case-insensitive) |
| `type` | `StoreType` | — | exact match on `store.type` |
| `group` | `StoreGroup` | — | mutually exclusive with `type`; translates to `WHERE type IN (typesIn(group))`. **400** if both set. |
| `categoryId` | UUID | — | exact match on `store.category.id`. **Takes priority over `categorySlug` if both are passed** |
| `categorySlug` | string `^[a-z0-9-]+$` | — | exact match on `store.category.slug` |
| `latitude` | number (-90..90) | — | user latitude (WGS84). Sent together with `longitude` |
| `longitude` | number (-180..180) | — | user longitude |
| `minRating` | number 0..5 | — | `store.rating >= minRating` (inclusive) |
| `maxDistance` | number > 0 | — | in **kilometers**. Applied only if `latitude` + `longitude` are provided. PostGIS `ST_DWithin` |
| `openNow` | boolean | `false` | `true` → only venues whose `opensAt..closesAt` window contains the current time in `Europe/Kyiv`. Overnight windows supported (22:00–02:00) |
| `priceLevel` | `int[]` (multi-value) | — | `store.priceLevel IN (...)`. **Multi-value**: `?priceLevel=1&priceLevel=2` |
| `sort` | string | `relevance` | whitelist: `distance` \| `rating` \| `priceAsc` \| `priceDesc` \| `relevance`. A direction suffix is allowed (`rating,desc`) but ignored — the direction is intrinsic to the enum. Unknown value → **400** |
| `page` | int | `0` | 0-based |
| `limit` | int 1..100 | `20` | hard cap 100, values below 1 are coerced to 20 |

### Sort semantics

| `sort=` | Behavior |
|---|---|
| `distance` | ASC by `ST_Distance` from (`latitude`, `longitude`). Without coordinates — falls back to `relevance` |
| `rating` | DESC by `rating` |
| `priceAsc` | ASC by `priceLevel` |
| `priceDesc` | DESC by `priceLevel` |
| `relevance` / empty | no explicit ordering (PK) |

### Response

`ApiResponse<Page<StoreDto>>`. `data` is a standard Spring `Page`:

```json
{
  "success": true,
  "data": {
    "content": [ /* StoreDto[] */ ],
    "totalElements": 10,
    "totalPages": 1,
    "size": 20,
    "number": 0,
    "first": true,
    "last": true,
    "empty": false,
    "numberOfElements": 10,
    "pageable": { "pageNumber": 0, "pageSize": 20, "offset": 0, ... },
    "sort": { "sorted": true, "unsorted": false, "empty": false }
  },
  "error": null
}
```

### Examples

```bash
# All stores, sorted by rating
GET /stores?sort=rating

# Pizzerias within 1 km of the user
GET /stores?categorySlug=pizza&latitude=50.45&longitude=30.52&maxDistance=1

# Type RESTAURANT + minimum rating 4.0, multi-value price levels
GET /stores?type=RESTAURANT&minRating=4.0&priceLevel=1&priceLevel=2

# Open right now
GET /stores?openNow=true&latitude=50.45&longitude=30.52
```

### Edge cases / guarantees

- **If a parameter is empty/null** — the filter is not applied (no `WHERE x IS NULL`).
- **`maxDistance` without coordinates** — ignored (no reference point).
- **`sort=distance` without coordinates** — falls back to `relevance`, not 400.
- **Multi-value `priceLevel`** requires repeating the key: `?priceLevel=1&priceLevel=2`. A comma (`?priceLevel=1,2`) **does not work** — Spring parses it as a single element `"1,2"` and fails int parsing → 400.
- **`limit > 100`** is silently coerced to 100.
- **`page < 0` / `limit < 1`** silently coerced to `0` / `20`.
- **Unknown `type`** (e.g. `?type=FOO`) → 400 (Spring enum binding).
- **Unknown `sort`** → 400 with message `Unknown sort: <value>`.
- **`categoryId` + `categorySlug`** together — `categoryId` wins.

---

## 4. `GET /stores/{id}`

| Parameter | Type | Default | Semantics |
|---|---|---|---|
| `latitude` | number | — | if both are provided — populates `distance` in the response (meters) |
| `longitude` | number | — | same |

Response: `ApiResponse<StoreDto>`. Here `menuItems` and `combos` are populated with real data (unlike search).

**404** if the store does not exist.

---

## 5. `GET /home/categories`

Returns all 10 canonical categories.

Response:
```json
{
  "success": true,
  "data": [
    {"id": "...", "slug": "pizza",   "name": "Pizza",   "iconName": "pizza"},
    {"id": "...", "slug": "sushi",   "name": "Sushi",   "iconName": "fish"},
    {"id": "...", "slug": "bakery",  "name": "Bakery",  "iconName": "croissant"},
    {"id": "...", "slug": "asian",   "name": "Asian",   "iconName": "noodles"},
    {"id": "...", "slug": "burgers", "name": "Burgers", "iconName": "burger"},
    {"id": "...", "slug": "coffee",  "name": "Coffee",  "iconName": "coffee"},
    {"id": "...", "slug": "dessert", "name": "Dessert", "iconName": "cake"},
    {"id": "...", "slug": "vegan",   "name": "Vegan",   "iconName": "leaf"},
    {"id": "...", "slug": "pastry",  "name": "Pastry",  "iconName": "cookie"},
    {"id": "...", "slug": "greek",   "name": "Greek",   "iconName": "olive"}
  ],
  "error": null
}
```

Cached on the backend (`@Cacheable`). The frontend can safely cache it for the session.

### 5.1 Localization & filters

`GET /home/categories` now accepts:

| Param | Type | Behavior |
|---|---|---|
| `group` | `FOOD_SERVICE\|RETAIL` | return categories where `applicableTypes ∩ typesIn(group) ≠ ∅` |
| `type` | `StoreType` (multi-value) | `?type=BAKERY&type=CAFE` — categories applicable to any of these types |
| `locale` | `uk\|en` | overrides `Accept-Language` |

`group` and `type` are mutually exclusive — **400** if both are set. `Accept-Language: uk` (or `?locale=uk`) → `name` comes back in Ukrainian, fallback `en`, fallback canonical code.

---

## 6. `GET /categories/{slug}` (new)

Resolves a single category by slug. Useful for the category page header (display name from the URL parameter).

```bash
GET /categories/pizza
```

Response:
```json
{
  "success": true,
  "data": {"id": "2b9a04dc-...", "slug": "pizza", "name": "Pizza", "iconName": "pizza"},
  "error": null
}
```

**404** if the slug is not found.

---

## 7. `GET /home/featured-stores`, `/home/stores/nearby`, `/home/boxes`

Unchanged. Same URLs/params/shape as before. Just note that `Store.categoryName` is now a deprecated computed field (see §2).

---

## 8. Frontend migration guide

### 8.1. TypeScript types

```ts
// types/index.ts

export type StoreType = "RESTAURANT" | "GROCERY" | "BAKERY" | "CAFE" | "SWEETS" | "OTHER";

export interface Category {
  id: string;
  slug: string;
  name: string;
  iconName: string | null;
}

export interface Store {
  id: string;
  name: string;
  type: StoreType;
  category: Category | null;
  description: string | null;
  imageUrl: string | null;
  heroImageUrl: string | null;
  // ... the rest of the fields unchanged
  
  /** @deprecated use `category.name`. Will be removed in the next sprint. */
  categoryName?: string | null;
}

export interface StoreSearchParams {
  search?: string;
  type?: StoreType;
  categoryId?: string;
  categorySlug?: string;
  latitude?: number;
  longitude?: number;
  minRating?: number;
  maxDistance?: number;     // in km
  openNow?: boolean;
  priceLevel?: number[];
  sort?: "distance" | "rating" | "priceAsc" | "priceDesc" | "relevance";
  page?: number;
  limit?: number;
}
```

### 8.2. Routes

- `/category/[slug]` — the route parameter is the **slug** (e.g. `/category/pizza`). NOT the category name, NOT a UUID. Resolve the display name via `GET /categories/{slug}` or by looking it up in the cached `/home/categories`.
- New route `/restaurants` — a list of all `?type=RESTAURANT`. Pass `type=RESTAURANT` to `GET /stores`. Same approach for other types if needed (`/groceries`, `/cafes`, …).

### 8.3. API client

`api.stores.getByCategory` currently accepts `categoryId: string` (UUID). After migration — accept a `slug` and send `?categorySlug=`. Example query builder using `URLSearchParams`:

```ts
function buildStoresQuery(params: StoreSearchParams): string {
  const qs = new URLSearchParams();
  if (params.search) qs.set("search", params.search);
  if (params.type) qs.set("type", params.type);
  if (params.categoryId) qs.set("categoryId", params.categoryId);
  if (params.categorySlug) qs.set("categorySlug", params.categorySlug);
  if (params.latitude !== undefined) qs.set("latitude", String(params.latitude));
  if (params.longitude !== undefined) qs.set("longitude", String(params.longitude));
  if (params.minRating !== undefined) qs.set("minRating", String(params.minRating));
  if (params.maxDistance !== undefined) qs.set("maxDistance", String(params.maxDistance));
  if (params.openNow !== undefined) qs.set("openNow", String(params.openNow));
  if (params.sort) qs.set("sort", params.sort);
  if (params.page !== undefined) qs.set("page", String(params.page));
  if (params.limit !== undefined) qs.set("limit", String(params.limit));
  // multi-value!
  (params.priceLevel ?? []).forEach(level => qs.append("priceLevel", String(level)));
  return qs.toString();
}
```

### 8.4. Reading `category` in the UI

```tsx
// BEFORE
<span>{store.categoryName}</span>

// AFTER
<span>{store.category?.name ?? "—"}</span>

// For URL links — slug, not name
<Link href={`/category/${store.category?.slug}`}>{store.category?.name}</Link>
```

### 8.5. What to drop

- Any "parse slug = `name-timestamp`" logic — no longer needed; the slug in the URL == the slug in the DB.
- Any client-side category filtering after fetch — it existed because the backend ignored the parameter; filtering is now server-side.
- The hardcoded `restaurant` as a "category" — that is a `type`, not a category.

---

## 9. Sort handling in the UI

Sort options on the frontend:

```ts
const SORT_OPTIONS = [
  { value: "rating",    label: "Rating (high → low)" },
  { value: "distance",  label: "Distance" },        // show only when geolocation is available
  { value: "priceAsc",  label: "Price (low → high)" },
  { value: "priceDesc", label: "Price (high → low)" },
] as const;
```

Send `sort=distance` only when `latitude`+`longitude` are available (otherwise the backend falls back to relevance — not an error, just useless).

---

## 10. Open-now indicator

`StoreDto.currentlyOpen` is already computed on the backend (timezone `Europe/Kyiv`, supports overnight windows). Do NOT compute it on the frontend — the frontend and server may disagree on the client timezone.

For the "open now" filter, send `?openNow=true` (a server-side filter); do not filter `content.filter(s => s.currentlyOpen)` after loading — that breaks `totalElements` and pagination.

---

## 11. Distance

- In search responses (`GET /stores?...`): `distance: null` always. If you need to show km — compute it yourself with haversine on the frontend (`store.location.latitude/longitude` + the user's position are available). This is **intentional** — server-side sorting by distance works, but the backend does not yet return the exact distance in every store search result.
- In a single-store response (`GET /stores/{id}?latitude&longitude`): `distance` in **meters** (PostGIS `ST_Distance` on the geography type).

---

## 12. Error handling

| HTTP | When |
|---|---|
| **400** | malformed/unknown param (`type=FOO`, `sort=password`, `priceLevel=abc`) |
| **404** | `GET /stores/{id}` or `GET /categories/{slug}` — not found |
| **5xx** | server error; frontend retries with backoff (see the existing `fetchAPI` wrapper) |

The 4xx body is the same `ApiResponse` envelope with `success:false` + `error.code` + `error.message`. Show `error.message` to the user (it is already in Russian/English depending on backend configuration) or map `error.code` to your own localized text.

---

## 13. Canonical slug list

Do **not** hardcode it on the frontend — there are now 18 categories (10 cuisine + 8 retail) and the list will
grow. Use `GET /home/categories` (cached). For an unknown slug in `/category/[slug]` —
show an empty state, do not hit the API.

---

## 14. Don't forget

1. **Remove** all reads of `store.categoryName` after migrating to `store.category?.name`. The frontend bundle will stop compiling once the deprecated field is removed from the backend in 1 sprint.
2. **Remove** any/all client-side filtering that existed as a workaround for broken server-side filtering.
3. **Do not pass** a category UUID where a slug is now expected (URL routes).
4. **Pass** `priceLevel` as an array via `?priceLevel=1&priceLevel=2`, not CSV.
5. **Do not compute** `currentlyOpen` on the client.
6. **Do not drop** the existing `categoryName` immediately — keep a transitional read until it is removed from the backend.
