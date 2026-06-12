# 0004 — Per-profile ownership check on `GET /orders/{orderId}`

* **Status:** Accepted
* **Date:** 2026-05-17
* **Pack:** Portfolio Pack 1 — Security baseline (task 1.1)

## Context

`OrderController.getOrderById(@PathVariable UUID orderId)` accepted any
authenticated caller and returned the full `OrderDto` — including
`deliveryAddress`, `pickupCode`, `totalPrice`, line items, profile id and
store id — to whoever asked. The lookup was unscoped: the controller
called `OrderService.getOrderById(UUID)` which simply fetched by primary
key.

This is **OWASP A01:2021 — Broken Access Control (IDOR)** in its textbook
form. Any authenticated user who guessed, scraped or coincidentally
received another customer's order id (referer leaks, browser history,
support tickets pasted into chat) could read the full order. The audit
flagged it as P0 #1, the single highest-ROI fix in the entire portfolio
audit — a five-minute read for any security-aware reviewer.

The same service already had the right pattern in `cancelOrder`
(`OrderController.java:69–77` → `OrderService.cancelOrder` at lines
206–214): the controller forwards `X-User-Id`, the service compares
`order.profileId` and throws `FORBIDDEN` on mismatch. The fix is the
same idiom, applied to `getOrderById`.

## Decision

1. **Split the service method.** `OrderService.getOrderById(UUID)` keeps
   its unscoped semantics but is documented as **internal-only**: the only
   caller from now on is `InternalOrderController` which sits behind the
   `X-Internal-Token` guard and is not reachable from the public gateway.
   A new method,
   `OrderService.getOrderByIdForUser(UUID orderId, UUID profileId)`,
   loads the entity, compares `profileId`, and throws
   `FoodWiseException(FORBIDDEN)` on mismatch — same idiom as
   `cancelOrder`.

2. **Wire the public controller through the scoped method.**
   `OrderController.getOrderById` now declares
   `@RequestHeader("X-User-Id") String userId`, parses it via the
   existing `parseUserId` helper (consistent with sibling endpoints), and
   delegates to `getOrderByIdForUser`.

3. **No admin override now.** The audit acceptance criterion offered two
   admin override paths (separate `/internal/orders/{id}` endpoint, or
   `hasRole('ADMIN')` bypass). Neither is implemented in this pack —
   there is no admin UI consuming such an endpoint today, and
   `InternalOrderController` already serves the legitimate inter-service
   read path. When a future admin pack needs cross-user order viewing,
   the natural addition is a role check inside `getOrderByIdForUser`:
   ```java
   if (!order.getProfileId().equals(profileId) && !callerHasAdminRole) {
       throw FORBIDDEN;
   }
   ```
   using the `X-User-Roles` header already populated by the gateway's
   `JwtAuthenticationFilter`. Spring Security ACL is explicitly off the
   table — the audit's anti-pattern list calls it out as "too much
   ceremony for pet-scope".

4. **403 vs 404.** Mismatch returns `403 Forbidden`, not `404 Not Found`.
   Returning 404 would have the side benefit of hiding existence (mild
   enumeration protection), but it would also be semantically wrong (the
   order does exist) and inconsistent with `cancelOrder`, which already
   uses 403. Consistency wins for the pet-scope; the enumeration vector
   for orders is much less interesting than for users (orders are
   UUIDv4 — unguessable in practice).

5. **Tests pin the new behaviour.**
   * `OrderServiceTest.GetOrderByIdForUser` (new) — unit tests for the
     three branches: owner hit, mismatch → `FORBIDDEN`, missing → `ENTITY_NOT_FOUND`.
   * `OrderControllerSecurityTest.getOrderById_returns403_whenCallerIsNotOrderOwner`
     (new) — MockMvc slice test that asserts the HTTP layer surfaces
     `FORBIDDEN` as a `403`, including the `X-User-Id` header flow.

## Alternatives considered

* **Change `OrderService.getOrderById(UUID)` signature in place.** Would
  break the `InternalOrderController` inter-service contract (it has no
  user id to pass). Adding a sentinel "system" profile id would be a
  smell. Two methods, one for trusted callers and one scoped to the
  caller, is cleaner.

* **Spring Security ACL (`@PostAuthorize("returnObject.profileId == authentication.name")`).**
  Rejected per the audit anti-patterns list: heavy machinery, hard to
  unit-test, easy to misconfigure, and adds runtime SpEL evaluation
  costs to every read. Inline check in the service is two lines and
  trivial to reason about.

* **Filter-level enforcement in fw-common.** Would require knowing which
  paths are user-scoped and the URL → owner mapping — a global rule
  that does not generalise.

## Consequences

* `OrderService` now exposes two methods that look similar but differ
  fundamentally in trust assumptions. Both methods carry javadoc
  spelling out the intended caller — future contributors must read
  before picking. The pattern is bounded (just orders), so the
  duplication risk is acceptable.

* `InternalOrderController` is unchanged. The internal contract for
  order lookups across service boundaries is preserved.

* `OrderControllerSecurityTest` had to import `GlobalExceptionHandler`
  explicitly (`@Import({SecurityConfig.class, GlobalExceptionHandler.class})`)
  because the WebMvc slice's component scan is narrowed to
  `OrderController`. Without the advice, `FoodWiseException` propagates
  as `ServletException` instead of being mapped to 403 by the advice.
  This is a generic test-slice gotcha, documented here so the next
  controller test in this service knows the pattern.

* The frontend `src/lib/api.ts` already forwards the `Authorization`
  header on every request, and the gateway strips and re-injects
  `X-User-Id` from the validated JWT (Pack 1, ADR 0001 confirms the
  filter ordering). So the end-to-end flow works without any frontend
  change: a logged-in user retrieving their own order still gets a
  `200`; an attacker probing another user's order now gets a `403`
  instead of a `200`.

## References

* OWASP A01:2021 — Broken Access Control (IDOR sub-category)
* OWASP ASVS 4.0 — V4.2.1 (object-level authorization on every
  authenticated request)
* Audit `Projects/FoodWise-portfolio-audit-2026-05-17.md` — P0 item #1
* Sibling pattern: `OrderService.cancelOrder` (already correct)
* Tests:
  * `fw-order-service/src/test/.../service/OrderServiceTest.GetOrderByIdForUser`
  * `fw-order-service/src/test/.../controller/OrderControllerSecurityTest.getOrderById_returns403_whenCallerIsNotOrderOwner`
