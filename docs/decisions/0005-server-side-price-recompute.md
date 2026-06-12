# 0005 — Resolve order item price and name server-side; reject on upstream fallback

* **Status:** Accepted
* **Date:** 2026-05-17
* **Pack:** Portfolio Pack 1 — Security baseline (task 1.2)

## Context

`OrderItemRequest` carried `String name` and `int price` fields populated
by the client, and `OrderService.createOrder` summed those values directly
into `totalPrice`. The same `totalPrice` was then forwarded to
`payment-service.createStripeIntent(...)` as the Stripe charge amount.

A trivially malicious client sending `{surpriseBoxId: X, price: 1, quantity: 1}`
for an item that actually costs 25 000 kopecks would be billed 1 kopeck.
This is **classic price tampering** — the second-most-common payment
integration bug after missing webhook signature verification — and any
reviewer with payment-systems experience flags it within seconds. Audit
P0 #2.

The fix is straightforward in shape: the authoritative price already lives
in `surprise-box-service`, accessed via the existing
`SurpriseBoxServiceClient.getSurpriseBox(boxId)` (Resilience4j circuit
breaker, typed `InternalSurpriseBoxDto`). The client was wired into the
Spring application context but never injected into `OrderService` — the
fix is to inject it and read prices from its response.

## Decision

1. **Remove `name` and `price` from `OrderItemRequest`.** The wire shape
   becomes `{surpriseBoxId, quantity}` — the client cannot supply either
   field, and Spring's `JsonDeserializer` defaults silently drop any
   field a misbehaving client tries to include.

2. **Resolve `name` (`box.title()`) and `price` from
   `surprise-box-service` per item.** A single de-duplicating pass over
   `request.items()` builds a `LinkedHashMap<UUID, InternalSurpriseBoxDto>`
   so a request with three quantities of the same box hits the upstream
   exactly once. `totalPrice` is then computed exclusively from the
   resolved unit prices.

3. **Reject with HTTP `503 SERVICE_UNAVAILABLE` when the circuit breaker
   fallback fires.** `SurpriseBoxServiceClient.getSurpriseBox(UUID)`
   returns `null` when its fallback runs (downstream unhealthy, timeout,
   etc.). The natural reaction "fall back to a cached/last-known price"
   is rejected here: financial integrity trumps availability. Better to
   tell the customer "try again in a minute" than to bill them based on
   stale or guessed data. The same guard runs for payloads that arrive
   with `null` price or title — surfaced as 503 with a different
   description, because those signal a contract drift in
   surprise-box-service that is operationally indistinguishable from
   an outage.

4. **Externalise currency literals via `OrderProperties`.** The hard-coded
   `"UAH"` (outbox payload) and `"uah"` (Stripe intent) literals are now
   `foodwise.order.currency` and `foodwise.order.stripe-currency`, with
   sensible defaults. The two values are intentionally separate fields
   rather than derived — Stripe's API contract wants lower case, the
   internal contract wants the upper-case ISO-4217 code, and forcing one
   to derive from the other creates a future bug-shaped corner.

5. **Pinning tests.** `OrderServiceTest.CreateOrderPriceRecompute`
   (three new tests):
   * `recomputesPriceFromSurpriseBoxService` — server-side price wins,
     line item DTO carries the upstream price/name.
   * `rejectsWith503_whenSurpriseBoxFallback` — `null` from the client
     (circuit breaker fallback) becomes `SERVICE_UNAVAILABLE`.
   * `rejectsWith503_whenBoxHasMissingPrice` — defence-in-depth for
     malformed upstream payloads.

## Closing the 503 enumeration oracle

The two 503 paths (circuit-breaker fallback vs incomplete payload) used
to surface distinct `description` strings to the caller. With
UUIDv4-keyed surprise boxes the practical attack value of distinguishing
them is small, but the discriminator added nothing useful to the client
either: both mean "retry later". Both branches now return the same
generic `"Pricing unavailable, please retry"` body; the discriminating
cause is recorded server-side via `log.warn` so operators still see
which failure mode triggered the rejection. Same `503` status, same
body, two distinct log lines.

## Alternatives considered

* **Keep `price` in the request, validate it against the upstream
  price, reject on mismatch.** Half-fix that wastes a network round-trip
  to validate against data the server could just use directly. The wire
  contract still tells the client "please send me a price", which is
  exactly the wrong affordance.

* **Use a cached snapshot of the price when the circuit breaker is
  open.** Available paths: in-memory cache in order-service, Redis,
  push-based price events from surprise-box-service. All of them shift
  the trust boundary from "live response from surprise-box-service" to
  "snapshot might be N minutes stale". For Surprise Boxes the price is
  the whole product (the customer is buying a specific window at a
  specific discount); a stale price is a worse user experience than a
  503 retry. Operationally, the surprise-box-service circuit breaker is
  already configured to open on 50% failure rate over 10 calls and
  retry after 10 s — recovery is fast.

* **Retry inside `createOrder` before giving up.** Resilience4j is
  applied at the client method (`@CircuitBreaker`); retries belong
  there, not in the service. Adding application-level retries
  duplicates the concern and confuses operations (which layer's metrics
  matter?). The circuit breaker config is the single retry knob.

* **Hoist currency into a single `Currency` enum.** Premature. Two
  string fields, both with `@NotBlank`, are simpler than introducing a
  full type plus a converter for one field surfaced in one place. If a
  second currency ever ships, the conversion is mechanical.

## Consequences

* The wire contract for `POST /orders` is leaner. Existing clients that
  used to send `name`/`price` will have those fields silently dropped
  by Jackson. Frontend impact: drop those fields from the request
  payload builder. No 4xx on legacy submissions, just dead fields.

* `OrderService` now calls `surprise-box-service` once per distinct
  surprise-box id in the order. With the typical cart shape (1–3
  boxes), this is a 1–3 extra HTTP round-trips on the order-creation
  hot path. Already protected by the circuit breaker so the worst-case
  latency is bounded by `timeLimiter`-style timeouts in the client
  config. Future optimisation if it actually hurts: batch
  endpoint on surprise-box-service (`POST /internal/surprise-boxes:batch`).
  Not needed now.

* `OrderApplication` gained `@ConfigurationPropertiesScan(...)` for the
  new `OrderProperties` record — same idiom as `fw-store-service`.

* `application.yml` exposes `foodwise.order.currency` and
  `foodwise.order.stripe-currency` with `${ENV:default}` syntax. A
  future deploy in a different currency region needs only env vars,
  no code change.

* The existing payment integration is untouched: the `int totalPrice`
  forwarded to `payment-service.createStripeIntent` now reflects the
  recomputed total. Stripe idempotency keying (already in place
  per [[stripe_integration_v1]]) protects against duplicate intent
  creation, so a retried order-creation request never double-charges
  even when our new 503 path triggers a client retry.

## References

* OWASP A04:2021 — Insecure Design (server-side validation of
  business-critical values)
* Audit `Projects/FoodWise-portfolio-audit-2026-05-17.md` — P0 item #2
* Existing pattern: `cart-service` resolves item `price` from
  `store-service` via `InternalMenuItemDto` (Pack 1, ADR 0002 follows
  the same paradigm in the cart domain)
* Tests:
  * `fw-order-service/src/test/.../service/OrderServiceTest.CreateOrderPriceRecompute`
