# 0007 — Kafka error handling: shared `DefaultErrorHandler` with Dead Letter Topic

* **Status:** Accepted
* **Date:** 2026-05-17
* **Pack:** Portfolio Pack 3 — Kafka reliability

## Context

Four of seven Kafka consumer services (`cart`, `order`, `payment`,
`surprisebox`) shared a copy-pasted anti-pattern:

```java
try {
    idempotentConsumer.processIfNew(event.eventId(), event.eventType(), () -> { /* business */ });
} catch (Exception e) {
    log.error("...", e);
} finally {
    ack.acknowledge();
}
```

The `finally`-ack commits the Kafka offset **regardless of outcome**.
Any transient failure (DB unavailable, network blip, NPE in business
code) silently loses the message — there is no retry, no Dead Letter
Topic, no visibility. The exception is logged and forgotten.

For a financial path like `payment-service` consuming `order.created`
this is a correctness liability: a DB flap during `PaymentService.processPayment`
means **the payment is never created but the order is marked as paid
downstream** because the event was acknowledged. The same pattern hits
inventory restoration in `surprisebox-service` (`order.cancelled` →
restore stock) and cart cache invalidation (`menu-item.updated`).

`fw-common` already exposed an abstract `KafkaConsumerConfig` base
class — but only `profile-service` extended it; the four problem
services duplicated their own consumer factory + container factory and
all of them lacked any `CommonErrorHandler`. There was zero retry
infrastructure shared across the services.

## Decision

Introduce a **non-invasive `KafkaErrorHandlerConfig`** as an
opt-in `@Configuration` in `fw-common` that exposes one bean:

```java
@Bean
public DefaultErrorHandler kafkaErrorHandler(KafkaTemplate<String, Object> template)
```

Each of the four problem services adds `@Import(KafkaErrorHandlerConfig.class)`
to its existing `KafkaConfig`, injects the `DefaultErrorHandler`, and
calls `factory.setCommonErrorHandler(kafkaErrorHandler)` on its
`ConcurrentKafkaListenerContainerFactory`. The consumers move
`ack.acknowledge()` out of `finally` into the success path of the
`try` block and **rethrow** on exception so the container's error
handler can take over.

### Retry policy

* **3 attempts** with `ExponentialBackOffWithMaxRetries`
* Backoff: initial 1s, multiplier 2.0, max interval 10s
* After exhaustion → `DeadLetterPublishingRecoverer` publishes to
  `<topic>.DLT` (Spring Kafka default naming)

### Non-retryable exception list

These bypass retries and go straight to DLT:

* `DeserializationException` — bad payload, will never succeed
* `IllegalArgumentException` — programming error / contract violation
* `ValidationException` — invalid input, will never succeed
* `JsonParseException` — malformed JSON, permanent
* `NullPointerException` — defensive bug catch, not transient

**Not on the list:** `FoodWiseException` — some `FoodWiseException`
causes are transient (downstream service 5xx, DB pool exhausted), so a
blanket non-retryable rule would lose legitimate retries.

### Logging

* WARN on every retry attempt (via `RetryListener`)
* ERROR + stacktrace on send-to-DLT (default `DeadLetterPublishingRecoverer`
  behavior — surfaces in standard logs)

## Alternatives rejected

### 1. Spring Kafka `@RetryableTopic`

Creates N intermediate retry topics per consumer (`topic-retry-1`,
`topic-retry-2`, ...). For a pet-scope portfolio with ~4 consumer
topics across 4 services the topic explosion (and DLT-management
tooling burden) is not justified. `DefaultErrorHandler` + one DLT per
topic gives the same correctness guarantee with a tenth of the
operational surface.

### 2. Modify the abstract `KafkaConsumerConfig` base class

Would require either (a) breaking change to the base class signature
that forces `profile-service` to be modified in lock-step, or (b)
introducing an `Optional<CommonErrorHandler>` hook that the four
services would have to override anyway. A separate `@Configuration`
with `@Import` is opt-in, requires no refactor of the abstract class,
and leaves `profile-service` (which already extends the base) free to
opt in later as a separate concern.

### 3. Include `FoodWiseException` in non-retryable list

Tempting because `FoodWiseException` looks like a domain-level "this
is a business error, don't retry" signal. In practice, several
`ErrorCode` values inside `FoodWiseException` originate from transient
downstream conditions (a 5xx from `store-service`, a DB pool timeout
re-thrown by the `IdempotentConsumer.tryMarkProcessed`). Blocklisting
the entire class would silently lose events that would succeed on
retry. Future work could introduce a marker sub-class
(`PermanentFoodWiseException`) but that is overscope here.

### 4. Custom DLT topic resolver

Default Spring Kafka behavior is `<originalTopic>.DLT`. We considered
prefixing per-service (`payment.DLT.order.created`) for ownership
clarity but the default convention is universally understood and any
observability tooling (`kafkaui`, AKHQ) already groups DLT siblings.

### 5. DLT consumer / automated reprocess UI

Out of scope. Documented in README as a manual operation
(`kafka-console-consumer --topic <name>.DLT --from-beginning`) and
recorded as future work. Building an automated reprocess UI now would
balloon the pack.

### 6. Transactional DLT publication

The `order-service` and `payment-service` `ProducerFactory` instances
have `setTransactionIdPrefix("order-tx-"/"payment-tx-")` set, but
business events are published through the `OutboxPublisher` which
**does not** use transactional Kafka semantics — the `outbox` table is
the source of truth. DLT publishing therefore uses the existing
(transactional) `KafkaTemplate` without entering a transaction. This
works because `DefaultErrorHandler` runs DLT publication after the
consumer's transaction has rolled back; the DLT send is a separate
producer flow.

## Impact

### Files changed

* **fw-common** — added `KafkaErrorHandlerConfig.java`
* **fw-surprisebox-service** — `KafkaConfig` imports + applies error
  handler; `SurpriseBoxEventConsumer` re-throws on failure; added
  `KafkaDltIT` integration test
* **fw-cart-service** — `KafkaConfig` imports + applies error handler;
  `CartEventConsumer` re-throws on failure
* **fw-order-service** — `KafkaConfig` imports + applies error
  handler; `OrderKafkaConsumer` (4 listeners) re-throws on failure
* **fw-payment-service** — `KafkaConfig` imports + applies error
  handler; `PaymentEventConsumer` re-throws on failure

### Topics

Auto-created in dev (`spring.kafka.admin.auto-create=true` default).
In production these would be created explicitly:

* `order.completed.DLT`, `order.cancelled.DLT` (surprisebox + payment)
* `order.created.DLT` (payment)
* `menu-item.updated.DLT`, `surprise-box.stock-updated.DLT` (cart)
* `payment.completed.DLT`, `payment.failed.DLT`,
  `surprise-box.reserved.DLT`, `reservation.expired.DLT` (order)

### Observability

DLT messages surface via standard Kafka tooling. Operations are
documented in each service's `README.md` under "Monitoring DLT".

## Verification

* Integration test `KafkaDltIT` in `surprisebox-service` (using
  `@EmbeddedKafka`) publishes a payload that forces a controlled
  exception in the consumer, then asserts the message appears on
  `<topic>.DLT` after the retry window. Representative for the
  pattern across all four services.
* All four service builds pass with no regression.

## Followups

* `profile-service` should adopt `KafkaErrorHandlerConfig` (low
  priority — `UserCreatedConsumer` does not exhibit the
  `finally`-ack anti-pattern, so the gap is consistency, not
  correctness).
* DLT consumer + dashboard / Slack alert wiring — separate concern.
* Move `groupId` from `@KafkaListener` annotation literal to
  `${spring.kafka.consumer.group-id}` property in `order-service`
  (audit `[SHOULD-FIX]`, not blocking this pack).
