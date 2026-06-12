# 0010 — Internal DTO contracts (typed, no envelope)

* **Status:** Accepted
* **Date:** 2026-05-17
* **Pack:** Portfolio Pack 4 — Internal contracts

## Context

Per the portfolio audit (items #9, #10, #11), four internal endpoints
were returning either public user-facing DTOs (with fields that
downstream consumers neither needed nor should be coupled to) or an
untyped `Map<String, Object>`:

| Endpoint | Return type before this pack | Consumers |
| --- | --- | --- |
| `GET /internal/stores/{id}` (store-service) | `ApiResponse<StoreDto>` — 21 fields incl. `menuItems`, `combos`, `distance` | `order-service`, `surprisebox-service` |
| `GET /internal/menu-items/{id}` (store-service) | `ApiResponse<StoreMenuItemDto>` | `cart-service` |
| `GET /internal/profiles/{userId}` (profile-service) | `ProfileDto` — includes `stats`, `referral`, `avatar` | `order-service` |
| `GET /internal/users/{userId}` (auth-service) | `Map<String, Object>` with `id`, `email`, `isActive` keys | none today |
| `GET /internal/surprise-boxes/{id}` (surprisebox-service) | `ApiResponse<SurpriseBoxDto>` — 17 fields incl. `pickup`, `description`, `rating` | `order-service` |

Two distinct contract-design problems:

1. **Type/shape leak.** Returning the public user-facing DTO means every
   field added to a public response (e.g., a new `loyaltyTier` field on
   `ProfileDto` for the user-facing API) is silently broadcast to every
   internal consumer. Internal consumers then either depend on it
   (creating coupling that nobody approved) or carry dead weight on the
   wire. Audit item #9 calls this out for store-service; the same
   pattern existed for profile and surprisebox.
2. **Envelope inconsistency.** Three of the five endpoints wrapped the
   payload in `ApiResponse<T>` (`{"success":true,"data":{...},"error":null}`),
   two returned the payload directly. Consumer clients had to know per
   endpoint whether to unwrap or not. The audit (item #15) calls out the
   same inconsistency on the public lane; it shouldn't have spread to
   internal lane in the first place.

Compounding the second problem: every consumer client wrapped its
deserialization in
`ParameterizedTypeReference<ApiResponse<InternalStoreDto>>` and
manually called `.getData()` with a null check. That's eight lines of
ceremony per call, repeated across four clients, for a contract whose
error semantics are already conveyed by HTTP status (which the
`RestClient` programmatic handler from ADR 0006 already maps to a
typed `FoodWiseException`).

There was also a non-obvious gap: `Internal*Dto` records *already
existed* in `fw-common/dto/internal/` (added during Epic A). The
producer controllers simply weren't using them — they kept returning
the public DTOs. The consumer clients meanwhile *did* deserialize into
the `Internal*Dto` records, relying on Jackson's `failOnUnknownProperties=false`
behaviour to tolerate the mismatch silently. The contract was "this
works today" rather than "this is enforced."

## Decision

Adopt three rules for internal-lane endpoints:

1. **Internal endpoints return typed `Internal<Aggregate>Dto` records
   defined in `fw-common/dto/internal/`.** Never the public user-facing
   DTO, never `Map<String, Object>`. If the right `Internal*Dto`
   doesn't exist, create it before the controller change — it's part of
   the same atomic work.
2. **Internal endpoints return the DTO directly, not wrapped in
   `ApiResponse<T>`.** Errors propagate as HTTP 4xx/5xx and are mapped
   to a typed `FoodWiseException` on the consumer side via the
   programmatic `RestClient` handler installed in Pack 1.5 (ADR 0006).
   Consumers call
   `restClient.get().uri(...).retrieve().body(InternalStoreDto.class)`
   and either get the record or a typed exception.
3. **Each internal controller has a `@WebMvcTest` slice test** that
   asserts (a) the response shape contains the required fields, (b)
   forbidden public-DTO fields (`menuItems`, `combos`, `stats`,
   `referral`, …) are absent, and (c) no `data`/`success`/`error`
   envelope wrappers are present. The negative assertions are the
   important ones — they're what locks future PRs out of accidentally
   reintroducing the leak.

Implementation contract:

| Controller | Endpoint | Returns |
| --- | --- | --- |
| `InternalAuthController` | `GET /internal/users/{id}` | `InternalUserInfoDto(UUID id, String email, Boolean isActive)` (new in this pack) |
| `InternalProfileController` | `GET /internal/profiles/{userId}` | `InternalProfileDto(UUID id, UUID userId, String name, String email)` |
| `InternalStoreController` | `GET /internal/stores/{id}` | `InternalStoreDto(UUID id, String name, String imageUrl, InternalLocationDto location, BigDecimal deliveryFee, BigDecimal minOrderAmount)` |
| `InternalStoreController` | `GET /internal/menu-items/{id}` | `InternalMenuItemDto(UUID id, String name, Integer price, String imageUrl, UUID storeId, Boolean available)` |
| `InternalSurpriseBoxController` | `GET /internal/surprise-boxes/{id}` | `InternalSurpriseBoxDto(UUID id, String title, Integer price, Integer stock, String imageUrl, StoreRef store, InternalLocationDto location)` |
| `InternalSurpriseBoxController` | `POST /internal/surprise-boxes/{id}/decrement-stock` | `ResponseEntity<Void>` (204 No Content) |

Mapping happens in the producer service: `StoreMapper.toInternalDto`,
`ProfileEntity::toInternalDto`, `AuthService.getUserInfo`,
`SurpriseBoxMapper.toInternalDto`. Mappers stay in the producer — the
records in `fw-common` are pure wire records with no mapping logic.

### Performance side-effect: `getStoreForInternal`

`StoreService.getStoreById` (used by the public-API path) issues three
SQL queries (`store + menuItems + combos`) to build the rich
`StoreDto`. The internal endpoint historically reused this method to
return a payload from which the only consumed field was `store.name()`.
Adding a separate `StoreService.getStoreForInternal(UUID)` that issues
a single `findById` removes two unnecessary JOINs on every order
checkout. Pure side-effect of the typing work but it's the right cleanup.

### Why no envelope on internal lane

The envelope `{"success":true,"data":{...},"error":null}` exists to give
*frontend* a uniform error/success branching shape. The internal lane has
neither of the two reasons that justify it:

* **No untyped HTTP client.** Producer-to-consumer calls go through
  `RestClient` with the programmatic Resilience4j handler from ADR
  0006. 4xx responses are already mapped to a typed `FoodWiseException`
  with the producer's error code carried in headers / problem detail.
  The consumer either gets the record or catches a typed exception —
  the `{success, error}` fields would be checked nowhere and add only
  defensive null-checks at the call sites.
* **No browser/CORS surface.** Internal endpoints are gated by
  `InternalAuthFilter` (shared `X-Internal-Token` header) and not
  exposed via the gateway. The "uniform handling for the JS client"
  consideration doesn't apply.

Audit item #15 flags the same inconsistency on the *public* lane. That
fix is a separate piece of work (Pack 6) — this ADR scopes the policy
to internal-lane only.

### Why omit roles from `InternalUserInfoDto`

Three reasons:

1. The pre-pack controller didn't return roles. Adding the field would
   be a contract change with no requesting consumer.
2. There are no downstream consumers of `GET /internal/users/{id}`
   today (verified via grep across all 8 services). Adding fields for
   hypothetical future consumers is YAGNI.
3. Adding a field later is a non-breaking change: existing consumers
   ignore unknown fields by default (project-wide Jackson default), so
   the cost of waiting is zero.

If a downstream service later needs roles for authorization decisions
(e.g., a future internal admin tool), add `Set<String> roles` to
`InternalUserInfoDto`, populate it from `UserEntity.authorities.roles`,
and ship the additive change.

## Alternatives rejected

### 1. Keep `ApiResponse` envelope on internal lane "for consistency with public lane"

Tempting because it would avoid the four consumer-client changes. But:

* The public lane itself is *not* consistent (audit #15 — success vs.
  error shapes differ already). Anchoring to it locks in known debt.
* `ApiResponse` adds value when error handling is by-payload — it's
  vestigial when error handling is by HTTP status + typed exception.
* The consumer-client change is ~5 lines per file, ~20 lines total.
  Affordable in the same pack.

### 2. Keep returning the public DTOs, just document the contract

Lowest-effort. Rejected because:

* Doesn't close the leak — any future field added to `ProfileDto` (say
  a sensitive customer-LTV field) ships to every internal consumer
  silently.
* Doesn't fix the perf side-effect (`getStoreById`'s 3 SQL queries).
* Doesn't make the contract testable — slice tests against
  `Internal*Dto` are the mechanism that locks future PRs into the
  policy.

### 3. Define `Internal*Dto` records per-service instead of in `fw-common`

Aligns with ADR 0009's "don't put domain content in shared library"
spirit. Rejected because:

* `Internal*Dto` is *contract* content, not domain content. It defines
  the wire format that two services agree on. ADR 0009 lists "internal
  inter-service wire DTOs" explicitly in the allowed-categories table.
* Defining the same record in two places (producer + consumer)
  guarantees drift unless contract tests are wired (not in scope).

## Impact

### Files changed

#### New files
* `fw-common/.../dto/internal/InternalUserInfoDto.java`
* 4 slice tests, one per typed controller:
  * `fw-store-service/.../InternalStoreControllerTest.java`
  * `fw-profile-service/.../InternalProfileControllerTest.java`
  * `fw-auth-service/.../InternalAuthControllerTest.java`
  * `fw-surprisebox-service/.../InternalSurpriseBoxControllerTest.java`

#### Modified — producer side
* `fw-store-service`: `InternalStoreController.java`, `StoreService.java`
  (new `getStoreForInternal`), `StoreMenuItemService.java` (new
  `getMenuItemForInternal`), `StoreMapper.java` (new `toInternalDto`,
  `toInternalMenuItemDto`).
* `fw-profile-service`: `InternalProfileController.java`,
  `ProfileEntity.java` (new `toInternalDto()`),
  `InternalProfileLookupService.java` or
  `ProfileService.getProfileForInternal(UUID)`.
* `fw-auth-service`: `InternalAuthController.java`, `AuthService.java`
  (new `getUserInfo(UUID)`).
* `fw-surprisebox-service`: `InternalSurpriseBoxController.java`,
  `SurpriseBoxMapper.java` (new `toInternalDto`),
  `SurpriseBoxService.java` (new `getSurpriseBoxForInternal`).

#### Modified — consumer side (envelope removal)
* `fw-order-service/.../client/StoreServiceClient.java` + test
* `fw-order-service/.../client/SurpriseBoxServiceClient.java` + test
* `fw-surprisebox-service/.../client/StoreServiceClient.java` + test
* `fw-cart-service/.../service/StoreServiceClient.java` + test

### Behavior changes for contributors

* Adding a new field to a public DTO (e.g., `ProfileDto`) no longer
  propagates to internal lane unless the corresponding `Internal*Dto`
  is also updated. The asymmetry is intentional — internal consumers
  opt in to fields explicitly.
* Adding a new internal endpoint must follow the three rules above:
  return a typed `Internal*Dto`, no envelope, slice test with negative
  assertions.
* Consumer clients use `.body(InternalStoreDto.class)` directly. No
  more `ParameterizedTypeReference<ApiResponse<...>>` ceremony.

### Anti-regression test (the slice tests)

The slice tests assert *absence* of forbidden fields:

```java
.andExpect(jsonPath("$.menuItems").doesNotExist())
.andExpect(jsonPath("$.combos").doesNotExist())
.andExpect(jsonPath("$.stats").doesNotExist())
.andExpect(jsonPath("$.referral").doesNotExist())
.andExpect(jsonPath("$.data").doesNotExist())
.andExpect(jsonPath("$.success").doesNotExist())
```

A future PR that "fixes" the internal endpoint to return the rich
public DTO will fail these tests instead of silently regressing the
contract.

## Followups (out of scope for this pack)

* **Apply ADR 0006 (programmatic Resilience4j) to `cart-service` and
  `surprisebox-service` clients.** Pack 4 envelope removal in
  `fw-cart-service/.../StoreServiceClient` and
  `fw-surprisebox-service/.../client/StoreServiceClient` preserved the
  existing `@CircuitBreaker` annotation + `fallbackMethod` pattern from
  before Pack 1.5. That pattern conflates a legitimate 404 (entity
  doesn't exist) with infra outage (downstream unhealthy) — both fall
  into the fallback returning `null`. Order-service was migrated to
  programmatic Resilience4j in Pack 1.5; the remaining two clients
  should follow. Estimate: ~30 min per client. Tracked as a [SHOULD-FIX]
  from the Pack 4 code review.
* **Audit item #15** — apply the same "no envelope" rule to public-lane
  endpoints in Pack 6 (Observability + RFC 9457). Public lane will move
  to RFC 9457 `application/problem+json` for errors and plain JSON for
  success, eliminating the envelope distinction.
* **`InternalProfileDto.email`** — currently always `null` on the wire
  because profile-service does not store the email (auth-service does).
  Decision: leave the field for consumer record-binding compatibility,
  remove in a follow-up only if no consumer reads it (today: order-service
  doesn't). Documented in the record's Javadoc.
* **Contract tests** — Pact-style consumer-driven verification on
  `Internal*Dto` shapes if/when the project grows multiple consumer
  teams. Today the slice-test + Jackson tolerance combination is
  enough; consumer-driven contracts become a payoff only when consumer
  evolution velocity matters.
* **`Internal*Dto` field minimization** — current records keep the
  shape they had under Epic A. A separate audit could verify each field
  is actually read by a consumer (e.g., `InternalStoreDto.imageUrl` may
  be dead) and trim accordingly. Not done now — stability of the
  contract is more valuable than -200 bytes per response for
  diploma-scope traffic.
