# 0012. Money serde on Jackson 3 across REST and event path

Date: 2026-06-02
Status: Accepted

## Context

The Money Modeling feature (see `docs/superpowers/specs/2026-06-02-money-modeling-design.md`,
decision #3) requires that minor↔major conversion lives in **exactly one place** — a Jackson
serde for `Money` — applied uniformly to external REST, internal REST, and Kafka.

During Phase 0 implementation we discovered the project runs **two Jackson runtimes**
simultaneously (Spring Boot 4.0.5 / spring-kafka 4):

- **REST** (Spring MVC) auto-configures **Jackson 3** (`tools.jackson`).
- **Event path** is hand-wired on **Jackson 2** (`com.fasterxml.jackson.databind.ObjectMapper`):
  - `OutboxPublisher` serializes the payload to the outbox JSON string with a Jackson 2 mapper
    (`new ObjectMapper().findAndRegisterModules()` bean per service);
  - each service's Kafka `objectMapper` bean (Jackson 2) is also used by consumers for
    `objectMapper.convertValue(event.payload(), ConcreteType.class)`.

`MoneyJacksonModule` was written as a Jackson 3 module (`tools.jackson.databind.module.SimpleModule`,
`ValueSerializer`/`ValueDeserializer`) — confirmed correct against the live classpath
(`tools.jackson.core:jackson-databind:3.x`). A Jackson 3 module does not apply to Jackson 2
mappers, so Money in events would otherwise serialize as the raw record
(`{"amountMinor":30000,"currency":"UAH"}`), reintroducing the minor-unit bug in the event layer.

spring-kafka 4 fact (verified via Context7): Jackson 3 is auto-detected and preferred; Jackson 3
serde counterparts are `JacksonJsonSerializer` / `JacksonJsonDeserializer`
(`new JacksonJsonDeserializer<>(Type.class, false)` to ignore type headers, `.trustedPackages(...)`),
with custom mappers built via `JacksonMapperUtils.enhancedJsonMapper().rebuild().addModule(...).build()`.

## Decision

1. **Standardize the entire Money serialization path on Jackson 3** (Option A, confirmed with the
   user). One `MoneyJacksonModule` (Jackson 3) is the single conversion point for REST + events,
   honoring spec decision #3.

2. **Sequencing — split by when it is needed, to preserve the plan's "Phase 0 is additive" invariant:**
   - **Phase 0 (Task 0.3, now, additive):** register `MoneyJacksonModule` as a
     `tools.jackson.databind.JacksonModule` Spring bean (`MoneyJacksonConfig`). Spring Boot 4
     auto-config adds it to the REST `JsonMapper`. Services already `scanBasePackages` +
     `@EntityScan` `kh.karazin.foodwise.common`, so the bean (and `@Embeddable Money`,
     `@Converter`) load in every service with no per-service change. This is purely additive —
     all builds stay green.
   - **Phase 7 (atomic event flip, when payloads first carry Money):** migrate the event path to
     Jackson 3 — `OutboxPublisher` mapper field → `tools.jackson.databind.ObjectMapper`; each
     service's `objectMapper` bean → a Jackson 3 mapper carrying `MoneyJacksonModule`; consumer
     `convertValue` fields → Jackson 3; `KafkaErrorHandlerConfig` parse-exception type → Jackson 3
     if the Jackson 2 type is no longer resolvable.

3. **The Kafka envelope serializer/deserializer do NOT need to be Money-aware.** The outbox pattern
   converts Money→1b at outbox-write time (Money-aware Jackson 3 mapper) producing a generic
   string map; the wire serde only ever sees the `DomainEvent` envelope with a plain map payload.
   The consumer reconstructs `Money` via the Money-aware `convertValue` mapper. This keeps the
   Phase 7 change contained to the `objectMapper` beans + `OutboxPublisher`, avoiding subclassing
   the Kafka serializers and the type-header/trusted-package subtleties.

## Addendum (2026-06-02): interim Internal*Dto money convention

`fw-common` `Internal*Dto` monetary fields (`InternalMenuItemDto.price` Integer,
`InternalStoreDto.deliveryFee`/`minOrderAmount` BigDecimal, `InternalSurpriseBoxDto.price`, …)
are shared contracts that flip to `Money` atomically in **Phase 7.2**. During the migration
window (Phases 2–6) producing services keep these fields in their existing
Integer/BigDecimal types but populate them with **MINOR units** (via `money.amountMinor()`),
NOT major units. Rationale: lossless (no scale/rounding fragility), one-line bridge, and a
trivial flip to `Money.ofMinor(...)`/`Money` in Phase 7.2. As each consumer service migrates
(cart Phase 3, order Phase 4, surprisebox Phase 5) it interprets these fields via
`Money.ofMinor(value, currency)`. This replaces the historical major-unit (whole-hryvnia)
semantics of those fields. Cross-service runtime correctness is validated only at the Phase 10
e2e (dev big-bang, wipe & reseed) — no incremental deployment in between.

## Addendum 2 (2026-06-02): RestClient must use the auto-configured builder

Services that send or receive `Money` over `RestClient` MUST build their `RestClient` beans
from the **Spring-injected, auto-configured `RestClient.Builder`** (which carries the
Jackson 3 `JsonMapper` with `MoneyJacksonModule` via `JacksonAutoConfiguration`), then
`.clone()`/customize per downstream. Using the static `RestClient.builder()` factory creates a
builder with default message converters that do NOT know `MoneyJacksonModule`, so a `Money` in a
request body serializes as a raw record (`{"amountMinor":...,"currency":{...}}`) and a `Money` in
a response fails to deserialize — silently breaking internal contracts. This was caught in
order-service (`RestClientConfig`) on the order→payment path and fixed. Every service whose
`RestClient` will carry `Money` (order→payment now; cart→store, order→store/surprisebox,
surprisebox→store once Internal*Dto flip to Money in Phase 7.2) must use the injected builder.
Mocked client unit tests do NOT catch this — verify with a real-serialization test
(MockRestServiceServer / WireMock) asserting the `{amount,currency}` wire shape.

## Consequences

- Phase 0 stays additive; the event-path Jackson 3 migration is folded into the already-breaking
  Phase 7, where Money enters event payloads.
- fw-common base `KafkaConsumerConfig` / `KafkaProducerConfig` abstract classes are not extended by
  any service (services define their own `KafkaConfig`); they are effectively dead code on the
  Jackson 2 serde and are left untouched (candidate for later cleanup).
- Annotation imports `com.fasterxml.jackson.annotation.*` (`@JsonInclude`, `@JsonIgnoreProperties`)
  remain valid — the annotations package is shared across Jackson 2 and 3.
