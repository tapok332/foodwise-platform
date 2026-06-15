# 0015 — Reserve-then-order saga (order-linked surprise-box reservations)

* **Status:** Accepted
* **Date:** 2026-06-15
* **Scope:** fw-surprisebox-service, fw-order-service, fw-common (internal DTOs)
* **Supersedes (partial):** the dead `POST /internal/surprise-boxes/{id}/decrement-stock` endpoint

## Context

The `surprise-box.reserved` and `reservation.expired` events were scaffolded
with an `orderId` field, but the single producer
(`SurpriseBoxEventPublisherAdapter`) hard-coded `orderId = null`: there was no
link between a reservation and the order that caused it. The
`surprise_box_reservations` table had no `order_id` column and the
`Reservation` aggregate carried no order reference.

As a result:

* order-service had to null-guard both consumers (an `orderId`-bearing
  `new OrderId(null)` would NPE → DLT), so the saga
  (`OrderSagaService.onReservationExpired` → `Order.expireReservation()`) was
  dormant — a reservation expiring never cancelled the order that owned it.
* The **order-first flow does not touch stock at all.** `OrderService.placeOrder`
  only resolves price via `SurpriseBoxGateway.resolve()`; it never reserves and
  never decrements. The frontend places orders directly and never calls the
  profile-scoped standalone `POST /surprise-boxes/{id}/reserve`.
* The internal `POST /internal/surprise-boxes/{id}/decrement-stock` endpoint has
  **zero callers** anywhere in the platform — dead since the order path stopped
  calling it.

Two flows were possible:

* **(A) Order-creates-reservation** — `POST /orders` creates an order-linked
  reservation that holds stock; if payment is not secured within the reservation
  window the reservation expires and cancels the order.
* **(B) Reserve-then-checkout (TooGoodToGo)** — the user reserves a box first,
  then checks out against that reservation, stamping `orderId` at checkout.

## Decision

**Adopt Flow A, scoped to STRIPE orders.**

* **A, not B.** The frontend is order-first and never reserves; B needs a new
  checkout-against-reservation contract plus a frontend rework, both excluded by
  the "do not break existing contracts" constraint. A reuses the existing
  `POST /orders` and the already-scaffolded saga, which was built for
  order-linked reservations.
* **STRIPE-only.** Only STRIPE orders are *awaiting asynchronous payment* — the
  exact scenario the saga compensates ("payment not completed within the
  window → release the order"). CASH orders are confirmed at placement and have
  no expiry concept; they are left unchanged (no reservation, no stock hold —
  status quo, see Consequences).

### Reservation ⇄ order link

* `surprise_box_reservations.order_id UUID NULL` (Flyway `V2`, additive — old
  rows and standalone reservations stay valid with `NULL`).
* `Reservation` carries a nullable `OrderId`. `open(box, profile)` keeps the
  standalone semantics (`orderId = null`); `openForOrder(box, profile, orderId)`
  mints an order-linked ACTIVE reservation. The publisher emits the reservation's
  real `orderId` (or `null` for standalone).

### Placement

`OrderService.placeOrder`, for STRIPE orders: save order (mint `orderId`) →
**reserve the box(es)** via `SurpriseBoxGateway.reserve(box, orderId, profile)`
→ create the Stripe intent → publish `order.created`. Reserve runs before the
intent so an out-of-stock box rejects the order before any charge. A box with no
stock surfaces as a typed rejection (the atomic conditional decrement returns
false → `409` → order rolled back); a genuinely unknown box stays `404`; a
downstream outage collapses to "Reservation unavailable, please retry" (`503`),
mirroring the existing `resolve()` fail-closed contract (ADR 0006).

### Stock is single-sourced through the reservation

A reservation **holds** stock while `ACTIVE` or `COMPLETED` and **releases** it
exactly once when it transitions to `EXPIRED` or `CANCELLED`:

* **Scheduler expiry** (`ReservationLifecycleService.expireOverdueReservations`,
  unchanged): `ACTIVE → EXPIRED`, restore stock, emit `reservation.expired` —
  now carrying the real `orderId`.
* **`order.cancelled` consumer becomes order-scoped.** It looks the reservation
  up by `orderId` (was: restock by `items` + cancel by `profileId`) and restores
  stock only if the reservation still *holds* it. An already-`EXPIRED`
  reservation is a no-op, so the expiry → order cancel → `order.cancelled` loop
  cannot double-restore. This also removes a pre-existing phantom-inflation bug:
  the old items-based restock added stock that the order-first flow never
  decremented.
* **`order.completed`** marks the order's `ACTIVE` reservation `COMPLETED`
  (existing profile-scoped behaviour, unchanged) so a paid box never expires.

### Saga reactions (order-service)

* The null-guard **stays** — standalone `/reserve` still emits `orderId = null`
  and must be skipped. Order-linked events now carry `orderId` and flow through.
* `onReservationExpired` cancels the order; `Order.expireReservation()` gains a
  guard so a `PAID` order is never cancelled by a stale expiry (protects the
  narrow race between `payment.completed` and `order.completed`).
* `onSurpriseBoxReserved` stays a no-op log — placement reserved synchronously,
  so the event is informational.

### Orphan safety

Placement is a choreographed saga across two transactions. If the order
transaction rolls back after a successful reserve (e.g. the Stripe intent
fails), the surprise-box reservation is orphaned but self-heals via the 15-minute
expiry (restoring stock) — the same accepted trade-off the codebase already makes
for orphaned Stripe intents on rollback.

## Alternatives considered

* **Flow B (reserve-then-checkout).** Rejected: builds an unused path
  (frontend never reserves) and changes the public contract.
* **Keep `order.cancelled` profile/items-scoped, gate restock elsewhere.**
  Rejected: profile-scoped restock is the source of both the double-restore and
  the phantom-inflation bug; order-scoping fixes both at the root.
* **Reserve for CASH too (COMPLETED reservation, permanent hold).** Deferred:
  needs an `awaitingPayment` flag threaded into surprisebox and a
  COMPLETED-can-be-cancelled stock path; out of scope for the payment-timeout
  saga. CASH stock handling is tracked as a follow-up.

## Consequences

* `reservation.expired` for a STRIPE order now cancels that order; the
  payment-timeout compensation path is live end to end.
* Stock for STRIPE surprise-box orders is held from placement and restored
  exactly once on release — no double-count, no phantom inflation.
* CASH surprise-box orders still do not hold stock (pre-existing oversell gap,
  unchanged). Documented follow-up, not a regression.
* The dead `decrement-stock` internal endpoint, its use-case method and slice
  test are removed; a typed internal `reserve` endpoint replaces it.
* New shared contract in fw-common: `InternalReserveBoxRequest`,
  `InternalReservationDto` (ADR 0010 internal-DTO policy).

## References

* ADR 0005 — server-side price recompute (placement still resolves price server-side)
* ADR 0006 — programmatic circuit breaker / 4xx mapping (reserve reuses the fail-closed contract)
* ADR 0007 — Kafka DLT error handling (consumers retry → DLT on failure)
* ADR 0010 — internal DTO contracts (reserve request/response in fw-common)
* ADR 0014 — hexagonal service architecture (invariants in aggregates, ports & adapters)
