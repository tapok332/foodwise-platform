# 0014 — Hexagonal (ports & adapters) architecture for business services

* **Status:** Accepted
* **Date:** 2026-06-12
* **Scope:** all 8 business services; piloted on fw-cart-service

## Context

Every business service grew up with flat technical layering
(`controller/service/repository/entity/dto`). That shape served the early
epics, but it has accumulated friction:

* **Anemic domain.** Business invariants live in `@Service` methods and even
  in JPA entities (`CartEntity.getTotalPrice()` computed a domain total
  inside a persistence class). There is no single place that *owns* a rule
  like "cart line storeId is server-resolved" — it is scattered across
  service methods and guarded only by tests.
* **Framework coupling.** Domain logic is welded to Spring, JPA and Jackson
  annotations, so it cannot be unit-tested or reasoned about without the
  framework context, and persistence concerns leak into business code.
* **No enforced boundaries.** Nothing stops a controller from calling a
  repository directly or an entity from acquiring REST concerns; layering is
  convention-only and erodes one PR at a time.

`~/.claude/rules/spring-boot.md` mandates hexagonal + package-by-feature for
microservices. The portfolio goal adds a second motive: the services should
demonstrate the canonical ports-and-adapters shape consistently.

## Decision

Adopt **full hexagonal architecture** in every business service, with a
**separate domain model** (no shared classes between domain and JPA), rolled
out in waves with fw-cart-service as the calibration pilot:

```
kh.karazin.foodwise.<svc>/
├── domain/              # pure Java: aggregates with behavior, VO records, domain errors
├── application/
│   ├── port/in/         # use-case interfaces, one per business operation group
│   ├── port/out/        # outbound interfaces: repositories, gateways, event publishers
│   └── usecase/         # @Service implementations; @Transactional lives here
└── adapter/
    ├── in/rest/         # controllers, wire DTOs, REST mappers (contracts unchanged)
    ├── in/kafka/        # event consumers
    ├── in/internal/     # internal API controllers (ADR 0010 DTOs)
    └── out/
        ├── persistence/ # JPA entities + Spring Data repos + port adapter
        ├── client/      # REST clients to other services
        └── messaging/   # outbox publisher adapters
```

Conventions fixed during the pilot:

1. **Rich domain.** Invariants move into aggregate methods; use cases
   orchestrate, the domain decides. In cart: `Cart.addItem()` owns line
   merging and accepts data only through a server-resolved
   `MenuItemSnapshot` (ADR 0002/0005 invariants), `Cart.totalPrice()` owns
   the single-currency total.
2. **Separate persistence model.** JPA entities are dumb mappings; a
   persistence adapter reconciles the aggregate onto managed entities
   (update in place, orphan-delete removed lines, append new ones) and maps
   back, so generated ids surface on the returned aggregate.
3. **Explicit mapping** via constructors/factories — no MapStruct, no
   reflection mappers.
4. **IDs as VO records** (`CartId`, `CartItemId`, `ProfileId`, `StoreId`,
   …) inside the domain; adapters convert at boundaries.
5. **Package-private by default**; `public` only where a type crosses a
   layer boundary or a framework requires it (entities, wire DTOs).
6. **Domain exceptions, translated at the application layer.** The domain
   throws its own errors (e.g. `CartItemNotFoundException`); use cases
   translate them into `FoodWiseException` with the exact pre-refactor
   error codes and descriptions, keeping the wire contract byte-identical.
7. **Guards live where their error contract lives.** Example: the cart's
   incomplete-payload guard sits in `StoreCatalogAdapter` *outside* the
   circuit breaker, because anything thrown inside a
   `@CircuitBreaker`-wrapped method is rewritten by its fallback message.
8. **Sanctioned pragmatic exception:** `Money` from fw-common is used
   inside the domain as-is. Its `@Embeddable` annotation is a dependency of
   Money itself, not of domain classes; the ArchUnit rule checks direct
   dependencies only, so the domain stays clean while the platform keeps a
   single money type (ADR 0012).

### Enforcement

One ArchUnit test class per service (template:
`fw-cart-service/src/test/java/.../architecture/HexagonalArchitectureTest.java`):

* `..domain..` does not depend on Spring / `jakarta.persistence` / Jackson
  (2.x and 3.x) / `..application..` / `..adapter..` / `..config..`
* `..application..` does not depend on `..adapter..` / `..config..`
* `@RestController` classes only under `adapter.in.rest`, `@KafkaListener`
  methods only under `adapter.in.kafka`, `@Entity` classes only under
  `adapter.out.persistence`

The rules run in plain `gradlew test`, so the published CI enforces them on
every push/PR.

### Behavior preservation

The migration is a pure refactor: wire DTO JSON, error bodies, status
codes, Flyway migrations, DB schema and Kafka topics/payloads stay
unchanged. Existing tests move to matching packages and must stay green;
new unit tests pin the domain methods that gained behavior.

One sanctioned value-level drift: the denormalized `carts.total_price_*`
columns are now also refreshed when Kafka-driven syncs modify cart lines
(previously they went stale; reads always recomputed the total, so no wire
response ever changes).

## Alternatives considered

* **Keep flat layering, add ArchUnit only.** Cheapest, but it freezes the
  anemic-domain problem instead of fixing it, and there is no domain layer
  to protect — the rules would enforce nothing meaningful.
* **Hexagonal with shared model (JPA entities as domain).** Fewer classes,
  but entities stay framework-bound, invariants keep leaking into
  persistence, and the ArchUnit purity rule becomes impossible. Rejected by
  explicit user choice of "full hexagonal everywhere" for portfolio
  consistency, accepting the model-doubling cost in thin services.
* **Spring Modulith instead of hexagonal packages.** Solves module
  boundaries, not the domain-purity problem; the services are already
  separate deployables, so module extraction adds little here.

## Consequences

* Domain logic is unit-testable without Spring (`CartTest` runs in
  milliseconds, no context).
* Class count roughly doubles in thin services (domain + entity pairs,
  port + adapter pairs) — accepted cost.
* The persistence adapter's load-reconcile-save pattern issues the same SQL
  as the old managed-entity flow within one transaction (the reload hits
  the Hibernate L1 cache), so no measurable overhead.
* Wave rollout: 0 cart (pilot, this ADR) → 1 order → 2 payment +
  surprisebox → 3 store → 4 auth + profile + favorites. Each wave gates on
  green tests + ArchUnit + docker e2e smoke through the gateway.

## References

* `~/.claude/rules/spring-boot.md` — hexagonal package structure mandate
* ADR 0002 — cart cross-store prevention (invariant now in `Cart.addItem`)
* ADR 0005 — server-side price recompute (now `Cart.totalPrice`)
* ADR 0010 — internal DTO contracts (internal controllers land in `adapter/in/internal`)
* Tom Hombergs, *Get Your Hands Dirty on Clean Architecture*
