# 0009 — Shared library boundary policy (fw-common)

* **Status:** Accepted
* **Date:** 2026-05-17
* **Pack:** Portfolio Pack 4 — Internal contracts

## Context

`fw-common` is a Gradle library module consumed by all eight first-party
services (`auth`, `profile`, `store`, `surprisebox`, `cart`, `order`,
`payment`, `gateway`). Over the lifetime of Epic A the module grew
opportunistically — anything plausibly "shared" landed there. The
portfolio audit (2026-05-17, item #10) flagged this as a classic
distributed-monolith smell: changes in one bounded context propagate
to every other consumer through a single library coordinate. A senior
reviewer will ask "why is `OrderCreatedPayload` defined in shared
library code?" within the first thirty seconds of opening `fw-common`.

A full inventory of `fw-common` at the start of this pack:

| Category | Classes | Used by |
| --- | --- | --- |
| Cross-cutting infrastructure | `XUserHeadersAuthFilter`, `InternalAuthFilter`, `RequestIdFilter`, `GlobalExceptionHandler`, `KafkaConsumerConfig`, `KafkaProducerConfig`, `KafkaErrorHandlerConfig` | all 8 services (one per cross-cut concern) |
| Protocol envelopes | `ApiResponse<T>`, `PagingResponse`, `DomainEvent<T>`, `EventTopics` | all 8 services |
| Internal inter-service DTOs | `InternalStoreDto`, `InternalLocationDto`, `InternalMenuItemDto`, `InternalProfileDto`, `InternalSurpriseBoxDto`, `InternalPaymentIntentDto`, `InternalUserInfoDto` (added in this pack) | producer + consumer of each pair |
| Domain event payloads | 12 records in `event/payload/*` (`OrderCreatedPayload`, `PaymentCompletedPayload`, `BoxReservedPayload`, …) | 4-6 services per payload |
| Error semantics | `ErrorCode` interface, `FoodWiseErrorCode` (12 values, 8 generic + 4 domain-specific), `FoodWiseException`, `ErrorDetails`, `ErrorResponse` | all 8 services |
| Validation | `@SafeUrl`, `SafeUrlValidator` | 2-3 services |
| Idempotency / outbox infra | `IdempotentConsumer`, `ProcessedEvent` `@Entity`, `ProcessedEventRepository`, `OutboxEvent` `@Entity`, `OutboxEventRepository`, `OutboxPublisher` | 3-4 services with outbox |
| JWT (auth-service local concern) | `JwtProvider`, `JwtFilter`, `JwtAuthentication`, `JwtUtils`, `Authorities`, `Role`, `TokenModel`, `JwtResponse` | `fw-auth-service` only |

Three problems with the status quo:

1. **Domain knowledge in shared library** — 12 event payload records
   describe schemas owned by individual bounded contexts. Touching
   `OrderCreatedPayload` to add a field forces recompile of all
   consumers even when only `order-service` and `payment-service` are
   semantically involved. Pact-style consumer-driven contract tests
   would isolate this, but they aren't wired today.
2. **Domain-specific error codes leak** — `USER_NOT_FOUND`,
   `USER_ALREADY_EXISTS`, `PAYMENT_FAILED`, `FILE_UPLOAD_FAILED` are
   shaped by their owning service's vocabulary but live in a shared
   enum. The `ErrorCode` interface was added precisely to enable
   per-service enums (one of them already exists for the store-search
   pack), but the migration is unfinished.
3. **`@Entity` types in a library module** — `OutboxEvent` and
   `ProcessedEvent` ship as JPA entities. Every consumer that imports
   `fw-common` must either provide the matching schema or explicitly
   exclude these from entity scanning. That's a latent infrastructure
   dependency hidden in a "utility" library.

The architectural question for this pack: **what should live in
`fw-common`, what should not, and what do we do about the gap?**

## Decision

**Adopt status quo + documented trade-off + migration path (Option A).**

Specifically:

1. Keep the current `fw-common` content. Do not migrate event payloads
   out in this pack.
2. Adopt a written policy (this ADR) describing the four categories of
   content that are *acceptable* for `fw-common` and the categories
   that are *not*. Future changes must justify themselves against this
   policy in PR description or per-feature ADR.
3. Document the migration path to Option B (per-service payloads) so
   the cost is known when project scale eventually justifies it.

### What MAY live in `fw-common` (acceptable)

| Allowed | Rationale |
| --- | --- |
| Cross-cutting infrastructure (security filters, MDC tracing, exception handling, Kafka producer/consumer/error-handler configs) | Identical implementation required in every service. Duplication = drift risk + 7× maintenance burden. |
| Protocol envelopes (`ApiResponse`, `PagingResponse`, `DomainEvent`, `EventTopics`) | Wire-format contract surface. Splitting these is the textbook split-brain failure. |
| Generic error codes (`UNKNOWN_ERROR`, `INVALID_REQUEST`, `ENTITY_NOT_FOUND`, `UNAUTHORIZED_ERROR`, `FORBIDDEN`, `SERVICE_UNAVAILABLE`, `DUPLICATE_REQUEST`, `RESOURCE_UNAVAILABLE`) + `ErrorCode` interface | Universal HTTP status semantics. Per-service additions extend `ErrorCode`, not the shared enum. |
| Internal inter-service wire DTOs (`Internal*Dto` family) | Producer and consumer agree on a shape; centralizing the record avoids accidental drift. Reviewed in ADR 0010. |
| Stateless validation utilities (`@SafeUrl`) | Pure functions, no domain coupling. |
| Reusable infrastructure primitives (`IdempotentConsumer` API, `OutboxPublisher` base) | Pattern code. Acceptable, but with the caveat below about JPA leakage. |

### What MUST NOT live in `fw-common` (going forward)

| Forbidden | Reason |
| --- | --- |
| Domain entities or domain services | Bounded-context content. Owns its schema, lifecycle, and validation in the producer service. |
| Domain-specific exception types | Semantics tied to one context. Extend `ErrorCode` interface inside the owning service instead. |
| Public user-facing DTOs (`StoreDto`, `ProfileDto`, …) | These belong on the producer's API surface. `Internal*Dto` is the supported cross-service contract. |
| Business validation rules (`@StoreOpenForPickup`, `@MinOrderAmountValid`, …) | Domain logic. Owning service implements its own validator + annotation. |
| New JPA `@Entity` classes | Leaks schema management into every consumer. Existing outbox/idempotency entities are grandfathered with documented warning. |

### Distributed-monolith debt we explicitly accept for diploma scope

| Issue | Why we don't fix now | Future trigger to fix |
| --- | --- | --- |
| 12 event payload records in `event/payload/*` | Migrating would create 12 records × 4-6 consumers ≈ 50 sync touch-points + require contract-test wiring (Pact or Spring Cloud Contract). Estimate: +3-4 working days. Out of pack scope. | Two unrelated bounded contexts need to evolve the same payload independently, or schema-evolution velocity exceeds 1 change/week. |
| 4 domain-specific values in `FoodWiseErrorCode` (`USER_NOT_FOUND`, `USER_ALREADY_EXISTS`, `PAYMENT_FAILED`, `FILE_UPLOAD_FAILED`) | The `ErrorCode` interface already supports per-service enums (store-search pack used it). The cleanup is mechanical but adds noise to PRs that aren't otherwise touching error handling. | Any of these four codes acquires meaning that differs between services (already a smell), or `FoodWiseErrorCode` grows past ~20 values. |
| JWT cluster (`JwtProvider`, `JwtFilter`, etc.) used only by `fw-auth-service` | Moving these requires changing one service's imports for zero observable benefit while the seven other services don't even reference them. Net negative. | A second service needs to mint JWTs (e.g., system-to-system tokens), at which point shared placement becomes legitimate; *or* `fw-auth-service` is the only consumer indefinitely, in which case the code should move to `fw-auth-service` for locality. |
| JPA `@Entity` types in `fw-common` (`OutboxEvent`, `ProcessedEvent`) | Out-of-pack scope. They work today; flagged for cleanup when the entity-scanning leak causes a concrete bug. | A consumer service needs to add its own `outbox_events` table with different columns, or `fw-common` ships a breaking JPA upgrade. |

## Migration path to Option B (per-service payloads) — recorded for the future

Sketch of the steps when project scale justifies the work:

1. Per-service `<ServiceName>EventPayloads` module created inside each
   producer. Records move into the owning context.
2. Consumers redefine a local `record` matching the wire shape they
   actually read (Jackson tolerates additive changes; consumers ignore
   unknown fields by default in this project).
3. Pact (consumer-driven) or Spring Cloud Contract verification added
   to the producer's CI to keep wire formats in sync. Each consumer
   publishes its expected schema; producer's build fails when the
   expected wire shape is no longer producible.
4. `fw-common/event/payload/*` becomes empty; package removed.

Estimated effort: 3-4 working days for migration + 1-2 days for
contract-test pipeline plumbing. Pre-requisites: at least one breaking
schema evolution would have to have happened in production to justify
the up-front investment.

## Alternatives rejected

### Option B: Migrate payloads out now

The "architecturally pure" answer. Rejected for this pack because:

* +1-2 working days on top of the typed-controllers work this pack
  already targets.
* Without contract tests, the migration trades one risk (shared-library
  drift) for another (consumer-producer wire-format divergence with no
  automated detection).
* For a diploma project where the topology is unlikely to fork into
  multiple owners of the same event, the consumer-driven contract
  infrastructure investment isn't payback-positive.

### Option C: Strip `fw-common` to infrastructure only

Move `GlobalExceptionHandler` mappings, `RequestIdFilter`,
`KafkaConsumerConfig` defaults, and `Internal*Dto` records into each
service. Rejected because:

* `GlobalExceptionHandler` is ~200 LOC of error-mapping rules; copying
  to 8 services produces ~1.6 kLOC of identical code that *will* drift
  over the lifetime of the project. We already saw this exact pattern
  in Pack 7 (Kafka error handling) — the `KafkaErrorHandlerConfig`
  consolidation closed an inconsistency that had crept in across four
  services running near-identical-but-not-quite handlers.
* The trade-off (drift risk on copies) is strictly worse than the
  trade-off being optimized (distributed-monolith feel on a shared
  library).

### Option D: Adopt Confluent Schema Registry with Avro/Protobuf

Production-grade evolution with strong backward/forward compatibility
guarantees. Rejected for diploma scope because:

* Adds a Confluent Schema Registry container (and Kafka topic) to the
  stack with associated lifecycle.
* Per-service Avro deserializer config replaces the lightweight
  `ObjectMapper.convertValue(...)` approach.
* Without multiple teams or production SLAs, ROI is negative.

Recorded as the right direction *if* the project ever ships to
production with real consumer teams.

## Impact

### Files changed

* **`fw-common`** — no structural changes in this pack. `InternalUserInfoDto`
  added per ADR 0010; otherwise the policy applies to future PRs.

### Behavior changes for contributors

* Future PRs adding code to `fw-common` must justify the addition
  against the categorization tables above (in PR description or per-
  feature ADR). Reviewers can point at this ADR to push back on
  domain code leaking into the shared module.
* The four pieces of debt (event payloads, domain error codes, JWT
  cluster locality, `@Entity` in library) remain on the radar with
  documented triggers for revisiting.

## Followups (out of scope for this pack)

* When a payload change forces a re-deployment fan-out beyond its
  bounded context, migrate it to the producer service and add the
  consumer-driven contract test. Don't migrate all 12 at once.
* `FoodWiseErrorCode` cleanup: move the 4 domain-specific values to
  per-service enums implementing `ErrorCode`. Mechanical, ~1 hour per
  service, doable as a Pack 4.5 mini-PR.
* `OutboxEvent` / `ProcessedEvent` — consider moving to a separate
  `fw-outbox-starter` module that's an opt-in dependency rather than
  bundled with `fw-common`. Defers the entity-scanning leak only when
  the consumer actually needs outbox.
