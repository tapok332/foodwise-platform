# 0002 — Resolve cart-item storeId server-side, not from client request

* **Status:** Accepted
* **Date:** 2026-05-17
* **Pack:** Portfolio Pack 1 — Security baseline (task 1.5)

## Context

The `POST /cart/items` endpoint accepted an `AddToCartRequest` containing
`{itemId, storeId, quantity}`. `CartService.addToCart` then wrote the
client-supplied `storeId` directly onto the persisted `CartItemEntity`,
even though the authoritative store ownership of the menu item was already
known: the service fetched `InternalMenuItemDto` from store-service in the
same method and the DTO carries `storeId()` for exactly this reason.

Consequences of trusting the client value:

* **Cross-store cart.** A client could submit `{itemId: A, storeId: B}`
  where `A` actually belongs to store `X ≠ B`, mixing items from different
  merchants in one cart. Downstream, order-service enforces store-scoped
  validation (single delivery address per store, single pickup window),
  so the malformed cart breaks order creation in non-obvious ways at
  checkout time — turning a silent contract violation into a user-facing
  500 long after the offending request.
* **Mass-assignment smell.** Audit cross-cutting theme #1 calls out this
  exact pattern across four services: request and response DTOs sharing
  fields the server should own. Cart was the most direct exploit path.

## Decision

1. **Remove `storeId` from `AddToCartRequest`.** The client now sends only
   `{itemId, quantity}`. The `UUID storeId` field is gone, along with its
   `@NotNull` validator and the now-unused `java.util.UUID` import.

2. **Resolve `storeId` from `menuItem.storeId()` in `CartService.addToCart`.**
   The store-service round-trip already happens in the same method to
   resolve `name` and `price`; reading `storeId()` from the same payload is
   free.

3. **Defence-in-depth null guard.** If store-service returns a menu item
   with a null `storeId` (data corruption or contract drift), `addToCart`
   throws `FoodWiseException(SERVICE_UNAVAILABLE)` instead of persisting a
   cart item with a null `store_id` column. The existing null check for
   `name`/`price` is extended.

4. **Test pinning.** `CartServiceTest.StoreIdResolution` covers both
   behaviours: (a) the resolved storeId on the cart item equals
   `menuItem.storeId()` regardless of caller state; (b) the missing-storeId
   path rejects with `FoodWiseException`.

## Alternatives considered

* **Keep `storeId` in the request, override server-side anyway.** Half-fix.
  The field would remain a public contract that does nothing — a confusing
  trap for future API consumers and a tempting future re-introduction of
  the bug. Removing the field makes the protection irreversible at the
  schema level.

* **Validate that client `storeId` matches `menuItem.storeId()` and reject
  on mismatch (400).** More information for the client, but ergonomically
  pointless: legitimate clients have no business knowing the storeId at
  submit time (they call store-service's menu listings themselves and know
  the items, not the storeId mapping). And it does not remove the
  mass-assignment surface.

* **Spring Security `@PreFilter` / SpEL ownership check.** Wrong layer.
  This is request shape, not authorisation. SpEL adds runtime ceremony
  without addressing the underlying contract bug.

## Consequences

* The wire contract for `POST /cart/items` changes: `storeId` is no longer
  accepted. Existing clients that include the field will continue to work —
  Spring's JSON deserializer ignores unknown fields by default. Removing
  the field is a soft contract change, not a breaking one.

* `CartController.addToCart` itself is untouched: it forwards the request
  unchanged.

* The frontend is currently not using `/cart` at all (see audit P0 #11 and
  the dedicated cart-service "integrate, not delete" verdict). When Pack 8
  wires the UI through `/cart`, the new contract is what the frontend
  binds against from the start.

* The frontend impact is bounded to whichever future TanStack Query call
  builds the request — drop the `storeId` field from the payload.

## References

* Audit `Projects/FoodWise-portfolio-audit-2026-05-17.md` — fw-cart P0 #3,
  cross-cutting theme #1 (Boundary thinking / mass assignment)
* `~/.claude/rules/security.md` — *Mass Assignment* anti-pattern
* Test: `fw-cart-service/src/test/java/.../CartServiceTest.StoreIdResolution`
