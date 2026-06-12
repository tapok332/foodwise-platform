# 0006 — Programmatic Resilience4j for downstream 4xx → typed `FoodWiseException` mapping

* **Status:** Accepted
* **Date:** 2026-05-17
* **Pack:** Mini-pack after Portfolio Pack 1 — Security baseline

## Context

After Pack 1's `OrderItemRequest` cleanup, `POST /orders` with an unknown
`storeId` returned `500 unknownError` instead of `404 entityNotFound`,
because `StoreServiceClient.getStoreName(...)` let
`HttpClientErrorException.NotFound` propagate as a raw runtime
exception. `GlobalExceptionHandler`'s catch-all bucket then mapped it to
the generic 500. The same shape existed in
`SurpriseBoxServiceClient.getSurpriseBox(...)` — there it was masked by
the Resilience4j `@CircuitBreaker(fallbackMethod=...)`, which silently
turned the 404 into a `null` sentinel that surfaced upstream as the
Pack 1 generic 503 `"Pricing unavailable, please retry"`. `ProfileServiceClient.profileExists(...)`
had a different but related issue: every upstream 404 was counted as a
breaker failure, so legitimate "not yet registered" lookups against
real users could trip the breaker.

Three problems, one shape: **every downstream 4xx must be translated
to a typed `FoodWiseException` so the API consumer gets an accurate
status code, and 4xx must never be counted as a circuit-breaker
failure** because it is a domain answer, not an outage signal.

`PaymentServiceClient` was already correct (it catches
`RestClientResponseException` inside the method and throws typed
`FoodWiseException(PAYMENT_FAILED)`); it is out of scope here.

## Decision

Use **programmatic Resilience4j** (`CircuitBreaker.executeSupplier(...)`)
for the three affected clients instead of the
`@CircuitBreaker(fallbackMethod=...)` annotation. The supplier wraps
only the `RestClient` call; the caller-translation lives in a normal
outer `try/catch` after `executeSupplier`. One linear method, explicit
branches, no fallback inversion.

```java
public InternalSurpriseBoxDto getSurpriseBox(UUID boxId) {
    try {
        ApiResponse<InternalSurpriseBoxDto> response = circuitBreaker.executeSupplier(() ->
                surpriseBoxRestClient.get()
                        .uri("/internal/surprise-boxes/{boxId}", boxId)
                        .retrieve()
                        .body(BOX_RESPONSE)
        );
        return response != null ? response.getData() : null;
    } catch (HttpClientErrorException.NotFound e) {
        throw FoodWiseException.errorWithDescription(
                FoodWiseErrorCode.ENTITY_NOT_FOUND, "Surprise box not found: " + boxId);
    } catch (HttpClientErrorException e) {
        log.warn(...);
        throw FoodWiseException.errorWithDescription(
                FoodWiseErrorCode.SERVICE_UNAVAILABLE,
                "surprise-box-service rejected request: " + e.getStatusCode());
    } catch (CallNotPermittedException e) {
        log.warn("surprise-box circuit breaker open for {}: {}", boxId, e.getMessage());
        return null;
    } catch (RestClientException e) {
        log.warn("surprise-box upstream failure for {}: {}", boxId, e.getMessage());
        return null;
    }
}
```

Four explicit branches, in priority order:

1. **`HttpClientErrorException.NotFound` → `ENTITY_NOT_FOUND`.** Legitimate
   "no such resource" domain answer.
2. **Other `HttpClientErrorException` (4xx) → `SERVICE_UNAVAILABLE`.**
   Malformed request or contract drift from us; not an outage but not
   normal either.
3. **`CallNotPermittedException` (breaker OPEN) → `null`.** Caller
   (`OrderService.createOrder`) sees `null` and reacts with its own
   Pack 1 ADR 0005 path: 503 `"Pricing unavailable, please retry"`.
4. **`RestClientException` (5xx + network failures) → `null`.** Same
   degraded null sentinel; CB also observed the exception (it
   propagated through `executeSupplier` first) and counts it toward
   the open-circuit threshold.

`ProfileServiceClient.profileExists` follows the same shape but returns
`boolean` and degrades to `false` on every failure mode — pessimistic by
design so an outage rejects the order rather than risking creation
against an unverified profile.

`application.yml` declares `ignoreExceptions: HttpClientErrorException`
(and keeps `FoodWiseException` for legacy `PaymentServiceClient`) so
the breaker's failure-rate accounting is not polluted by 4xx. Even
though the outer `try/catch` translates the exception before any
caller sees it, the exception **does** propagate through
`executeSupplier` first, so the breaker sees it and would count it
without the `ignoreExceptions` entry.

## Alternatives considered

* **Annotation + re-throw `FoodWiseException` in the fallback method.**
  First attempt in this mini-pack. Resilience4j invokes the fallback
  on every exception (regardless of `ignoreExceptions` — that list is
  for metrics only, not for fallback gating). To make legit 4xx
  propagate, the fallback must inspect the throwable and re-throw
  `FoodWiseException` while still returning `null` for genuine infra
  failures. This works (issue
  [resilience4j#856](https://github.com/resilience4j/resilience4j/issues/856)
  acknowledges it as the standard workaround) but is two-layer logic —
  the exception-to-domain mapping is split across the main method
  (`catch + throw`) and the fallback (`if (t instanceof FoodWiseException) throw fwe`).
  A future maintainer reading only one of the two will miss half of
  the contract. Rejected for clarity.

* **`Either<Exception, Result>` / Vavr `Try<T>` return type.** Functional,
  no exception flow involved, very clean semantics. Requires
  introducing a new abstraction across the order-service clients and
  changes call sites. Disproportionate for three clients in a
  pet-scope project.

* **Custom Spring AOP aspect to translate `HttpClientErrorException`
  globally.** Hides the translation logic, makes call sites less
  predictable, and adds AOP magic to debug. Not worth it for three
  methods.

* **Keep `@CircuitBreaker` annotation + outer `try/catch` around the
  proxied call.** Would not work — the proxied call already runs the
  fallback inside the AOP advice; the outer `try/catch` only sees what
  the fallback returns, not the original exception.

## Consequences

* `StoreServiceClient`, `ProfileServiceClient`, and
  `SurpriseBoxServiceClient` no longer carry `@CircuitBreaker`
  annotations or `fallbackMethod` helpers. The classes are shorter and
  the flow is linear top-to-bottom.

* Constructor signature changes: each client now takes
  `CircuitBreakerRegistry` and resolves its named breaker once at
  construction time. Existing tests adapted with
  `CircuitBreakerRegistry.ofDefaults()` in `@BeforeEach`.

* `application.yml` simplified to a single `configs.default` block
  inherited by all four breaker instances (Store / Profile / SurpriseBox
  / Payment), with `ignoreExceptions` listing both
  `HttpClientErrorException` (for the new programmatic clients) and
  `FoodWiseException` (kept for the legacy `PaymentServiceClient`
  annotation pattern). Comment in the YAML explains both reasons.

* `OrderService.createOrder` behaviour:
  * Unknown `storeId` → 404 `entityNotFound` (was: **500 unknownError**).
  * Real `storeId` + unknown `surpriseBoxId` → 404 `entityNotFound`
    (was: **503 "Pricing unavailable, please retry"**).
  * `surprise-box-service` 5xx or breaker OPEN → still 503
    `"Pricing unavailable, please retry"` (Pack 1 ADR 0005 holds).
  * Real upstream all 200 → existing happy path unchanged.

* `PaymentServiceClient` is untouched. It uses the annotation pattern
  but its fallback throws `FoodWiseException` (not silent `null`), so
  there is no semantic inversion to fix. Migrating it for consistency
  is a follow-up if the same defect appears there.

* New tests pin the new branches: 4xx → typed exception, 5xx → null,
  404 on profile → false. Existing happy-path tests unchanged.

* The frontend smoke-test against the running cluster confirms the
  end-to-end fix:
  ```
  POST /orders {storeId: 0..099, ...}            → 404 "Store not found: ..."
  POST /orders {storeId: real, boxId: 0..088}    → 404 "Surprise box not found: ..."
  POST /orders {storeId: real, boxId: real, ...} → 200/201 (unchanged)
  ```

## References

* Resilience4j docs — *Annotations vs programmatic API*:
  <https://resilience4j.readme.io/docs/getting-started-3>
* `resilience4j` issue
  [#856](https://github.com/resilience4j/resilience4j/issues/856) —
  fallback invocation semantics
* Sibling pattern: `PaymentServiceClient` (legacy annotation + typed
  exception catch inside method)
* Tests:
  * `fw-order-service/src/test/.../client/StoreServiceClientTest`
    (`getStore_throwsEntityNotFound_whenUpstreamReturns404`,
    `getStore_throwsServiceUnavailable_onOther4xx`,
    `getStore_returnsNull_onUpstream5xx`)
  * `fw-order-service/src/test/.../client/SurpriseBoxServiceClientTest`
    (`getSurpriseBox_throwsEntityNotFound_whenUpstreamReturns404`,
    `getSurpriseBox_returnsNull_onUpstream5xx`)
  * `fw-order-service/src/test/.../client/ProfileServiceClientTest`
    (`profileExists_returnsFalse_whenUpstreamReturns404`,
    `profileExists_returnsFalse_onUpstream5xx`)
