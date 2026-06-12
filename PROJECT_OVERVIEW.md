# FoodWise — Software Engineering Overview

> **Purpose of this document.** A detailed overview of the FoodWise project from a software engineering perspective: what it is, why it exists, its architecture, key technical decisions, the trade-offs made, and where the line runs between "thesis / pet project" and "production-ready".
>
> **Audience.** Portfolio reviewer, a new developer joining the project, yourself six months from now.
>
> **Snapshot date.** 2026-05-24. Specific numbers (ADR count, Spring Boot state, etc.) are accurate as of this date; if reading later, verify against the code.

---

## 1. What this project is

**FoodWise** is a study/portfolio project by a Karazin University student (`group = kh.karazin`). Delivery format: thesis + public portfolio.

**The domain model is a hybrid of two product ideas:**

1. **Food ordering / delivery marketplace.** The user browses a catalog of venues (shops, cafes, restaurants), picks dishes from a menu, adds them to a cart, places an order, and pays.
2. **"Surprise boxes" / magic bags.** Venues pack end-of-day food leftovers and sell them at a discount (the Too Good To Go pattern). The user reserves a box and picks it up during a pickup window.

These two domains live in one system and intertwine at the cart and order level.

**Technical posture.** The project is deliberately **over-engineered for its size** — it is a vehicle for demonstrating competencies (microservices, Spring Cloud Gateway, Kafka, Outbox, Saga, PostGIS, Stripe integration). This is stated explicitly in `README.md` and in the portfolio self-assessment. See also the portfolio audit from 2026-05-17 (memory `portfolio_audit_2026_05_17`): current portfolio-readiness ~70%, ceiling ~85% — anything beyond that is over-engineering for pet scope.

---

## 2. System topology

### 2.1 Services and ports

```
client-ui (Next.js, :3000 / dev :9002)
        │
        ▼
gateway (:8080) ── Spring Cloud Gateway WebFlux
        │           JWT validation, CORS, Redis rate-limit, header strip,
        │           circuit-breaker per route, fallback controller
        │
        ├── auth-service        (:8081) — users, registration, login,
        │                                 refresh tokens, JWT issuance
        ├── profile-service     (:8082) — user profiles, addresses
        ├── store-service       (:8083) — stores, categories,
        │                                 menu sections / items, combos,
        │                                 promos, reviews, PostGIS geo
        ├── surprisebox-service (:8084) — surprise box inventory,
        │                                 reservations, expiration
        ├── cart-service        (:8085) — per-user cart (single-store),
        │                                 price sync via Kafka
        ├── order-service       (:8086) — checkout, order saga,
        │                                 status flow, ownership enforcement
        └── payment-service     (:8087) — Stripe Payment Intents,
                                          webhooks, refunds, payment methods
```

### 2.2 Infrastructure

| Component    | Version           | Purpose                                                               |
|--------------|-------------------|---------------------------------------------------------------------|
| PostgreSQL   | 16 + PostGIS 3.4  | Single DB instance, **schema-per-service** (`foodwise_auth`, `foodwise_stores`, …). PostGIS is used in store for geo queries (`ST_DWithin`, `ST_Distance`). |
| Apache Kafka | 3.9.0 (KRaft)     | Inter-service communication. 12 topics (see `EventTopics.java`). `AUTO_CREATE_TOPICS_ENABLE=true` — dev-only. |
| Redis        | 7.4-alpine        | Used only by the gateway — Spring Cloud Gateway `RequestRateLimiter`. |

Everything is orchestrated via `docker-compose.yml` at the repo root. Healthchecks are configured: the gateway depends on `auth-service` + `store-service` (by `service_started`) and `redis` (by `service_healthy`); each business service waits for `postgres` + `kafka` by `service_healthy`.

### 2.3 What exists in the repo but is **not used**

- `fw-backend/` — legacy monolith. Kept for diff-observing the architectural evolution; it is not in `docker-compose` and should **not be touched**.
- `fw-frontend/` — old client on Vite 6 + React 19. Also legacy, no Dockerfile, not in compose.

The active frontend is **`fw-client-ui/`** (Next.js 15.5.14, App Router, React 18).

---

## 3. Technology stack

### 3.1 Backend

| Layer             | Technology / version                             |
|-------------------|--------------------------------------------------|
| Language          | **Java 25** (toolchain pin)                      |
| Framework         | **Spring Boot 4.0.5**                            |
| Web stack         | Spring Web MVC (servlet) for business services, Spring Cloud Gateway **WebFlux** for the gateway |
| Security          | Spring Security 7, JJWT 0.12.6 for JWT signing/verification |
| Persistence       | Spring Data JPA + Hibernate 7, PostGIS (`hibernate-spatial`, `jts-core 1.20`) |
| Migrations        | **Flyway** (`flyway-core` + `flyway-database-postgresql`). Hibernate `ddl-auto=validate`. |
| Messaging         | Spring Kafka, `JsonSerializer`/`JsonDeserializer` with `setUseTypeHeaders(false)` |
| Resilience        | Resilience4j (gateway: circuit breakers per route; clients: 4xx mapping — see ADR 0006) |
| HTTP client       | Spring `RestClient` (Spring 6.1+) for inter-service calls — **no RestTemplate anywhere** |
| Build             | **Gradle 8.x** (per-service `build.gradle`, no multi-module — each service is self-contained) |
| OpenAPI           | springdoc-openapi 2.8.6                          |
| Mappers           | **Handcrafted** (no MapStruct, no ModelMapper)   |
| Lombok            | Used (`@RequiredArgsConstructor`, `@Slf4j`, `@Builder`, `@Getter/@Setter`) |
| Testing           | JUnit 5 + Mockito, **Testcontainers** for integration tests, no H2 |

### 3.2 Frontend

| Layer             | Technology                                       |
|-------------------|--------------------------------------------------|
| Framework         | **Next.js 15.5.14** (App Router) on React 18     |
| Server-side       | Only client-side storage is used (see below regarding JWT in localStorage — a known [SHOULD-FIX] from the audit) |
| State             | React Context for AuthContext / CartContext. **Zustand is not used** (although it is on the migration roadmap). |
| Data fetching     | TanStack Query 5.66 (`@tanstack/react-query`) — installed but **not used everywhere**. Some APIs are called directly via `lib/api.ts` + `useEffect` (tech debt, see portfolio audit Pack 5) |
| Forms             | React Hook Form 7 + `@hookform/resolvers` + Zod (with `class-variance-authority` for variants) |
| UI                | **Radix UI** primitives + Tailwind CSS 4 + custom shadcn-style components. Design tokens: `shadow-soft*` (green-tinted soft shadows), `rounded-3xl` for a biophilic feel. |
| Payments          | `@stripe/stripe-js` + `@stripe/react-stripe-js` |
| Maps              | `@vis.gl/react-google-maps` + `@googlemaps/markerclusterer` (geo maps of venues) |
| AI                | `@genkit-ai/googleai` + `@genkit-ai/next` (an attempt at AI features — recommendation generation) |
| Other             | `firebase`, `canvas-confetti`, `date-fns`, `@zxcvbn-ts/core` (password strength) |

### 3.3 Tests

- ~120 unit tests in the backend (see memory `epic_a_status`). Build is green across all 9 modules.
- **No integration tests on the frontend** (see portfolio audit Pack 5 — major gap).
- Testcontainers is actively used for repository tests with Spring Boot 4 (important: `TestRestTemplate` was removed in Boot 4 → use `HttpClient` or `MockMvc`; see memory `spring_boot_4_test_apis`).

---

## 4. Architectural principles

### 4.1 Where things live: package-by-feature within a service

Each service follows a **feature-oriented structure**, not the classic layer-based one:

```
fw-{service}/src/main/java/kh/karazin/foodwise/{service}/
├── {service}Application.java        # @SpringBootApplication, main
├── config/                          # SecurityConfig, KafkaConfig, RestClientConfig…
├── controller/                      # @RestController public + InternalController for /internal/**
├── service/                         # @Service — use-cases
├── repository/                      # Spring Data JPA
├── entity/                          # @Entity (JPA-annotated)
├── dto/                             # Request/Response records
├── mapper/                          # handcrafted entity ↔ DTO
└── kafka/                           # @KafkaListener consumers, producers
```

This is **not strict hexagonal architecture** — full ports-and-adapters would be over-engineering for a project of this size. The domain layer is not separated from Spring/JPA (`@Entity` lives directly in `entity/`). This is a **deliberate trade-off** in the spirit of KISS.

### 4.2 fw-common — shared library

`fw-common/` is built as a plain jar (`bootJar.enabled = false`, `jar.enabled = true`) and pulled in by each service via `implementation files('../fw-common/build/libs/fw-common-0.0.1-SNAPSHOT-plain.jar')`.

**Contents:**

| Package                                 | What's inside                                                 |
|----------------------------------------|--------------------------------------------------------------|
| `common.dto`                           | `ApiResponse<T>` (envelope for the public API), `ErrorInfo`  |
| `common.dto.internal`                  | Typed DTOs for `/internal/**` (`InternalStoreDto`, `InternalMenuItemDto`, `InternalUserInfoDto`, `InternalSurpriseBoxDto`, `InternalProfileDto`). **No envelope** — see ADR 0010. |
| `common.event` + `common.event.payload` | `DomainEvent<T>` envelope (eventId, eventType, occurredAt, payload), `EventTopics` constants, 12 payload records |
| `common.exception`                     | `GlobalExceptionHandler` (`@RestControllerAdvice`), mapping `AuthorizationDeniedException → 403`, `AuthenticationException → 401`, in-house `FoodWiseException` |
| `common.idempotency`                   | `IdempotentConsumer` — processed-events table for exactly-once semantics |
| `common.jwt`                           | `JwtProvider`, claims (including `jti: UUID` for refresh-token uniqueness) |
| `common.kafka`                         | `KafkaConsumerConfig` (abstract base class), **`KafkaErrorHandlerConfig`** — shared DLT handler |
| `common.outbox`                        | `OutboxEvent` entity, `OutboxEventRepository`, **`OutboxPublisher`** (`@Scheduled(fixedDelay = 500)`) |
| `common.response`                      | `ApiResponse` envelope                                        |
| `common.security`                      | `XUserHeadersAuthFilter`, `InternalAuthFilter`                |
| `common.tracing`                       | `RequestIdFilter` (generates/forwards `X-Request-Id`), MDC `requestId` + `userId` |
| `common.validation`                    | `@SafeUrl` Bean Validation (whitelist `https?://`, blacklist `javascript:` / `data:` / `file:`). 48 unit tests. |

**The fw-common boundary** is fixed in ADR 0009 ("shared library boundary policy"). The rule: only code that **touches 2+ services** and **carries no domain-specific business logic** goes into fw-common. This prevents fw-common from turning into a god-jar.

### 4.3 Auth flow — JWT through the gateway

The full request authorization path:

1. **Frontend → `POST /auth/login`** via gateway → auth-service issues a `{accessToken, refreshToken}` pair.
2. **Frontend → `Authorization: Bearer <jwt>`** on any protected endpoint.
3. **Gateway `JwtAuthenticationFilter`** parses the JWT, extracts `sub` (UUID) and `roles` (CSV), and sets downstream headers:
   - `X-User-Id: <uuid>`
   - `X-User-Roles: ADMIN,CLIENT` (without the `ROLE_` prefix)
4. **Gateway header-stripping**: incoming `X-User-Id` / `X-User-Roles` from the client are **dropped** before routing — otherwise a client could impersonate any user. See ADR 0001 (gateway actuator isolation — a related pattern).
5. **Downstream `XUserHeadersAuthFilter`** (fw-common) parses these headers and creates a `PreAuthenticatedAuthenticationToken` with a UUID principal + `List<GrantedAuthority>` (with the `ROLE_` prefix). The filter **skips `/internal/**` and `/actuator/**`**.
6. **`@PreAuthorize("hasRole('ADMIN')")` / `("isAuthenticated()")`** on controllers enforce authorization.
7. **Inter-service calls**: `/internal/**` endpoints are protected by `InternalAuthFilter`, which checks the `X-Internal-Token` header against the shared secret `INTERNAL_SERVICE_SECRET`. Each RestClient automatically adds this header via `defaultHeader(...)` in `RestClientConfig`.

**The gateway also parses the JWT on public routes** (if the Authorization header is present) — so that admin endpoints like `POST /categories` (sitting on a "public" route) can receive `X-User-Id` + `X-User-Roles` and pass `@PreAuthorize('hasRole(ADMIN)')` downstream.

### 4.4 Inter-service communication

Two patterns:

**A. Synchronous HTTP via `/internal/**`** — when service A needs to ask service B a fact right now (e.g., order-service asks store-service about the menu, prices, and availability during checkout).

- Contract: a typed `InternalXxxDto` from `fw-common.dto.internal`.
- **No envelope** (`ApiResponse<T>`) — see ADR 0010. The public API has an envelope for frontend compatibility and graceful error semantics; internal contracts are bare records for discipline.
- Resilience4j `CircuitBreaker` + 4xx mapping into a typed `FoodWiseException` (ADR 0006). Previously an unknown storeId yielded a 500; now correct 404 / 4xx codes propagate between services.

**B. Asynchronous events via Kafka** — when service A wants to notify "someone else" without blocking.

12 topics, registry in `EventTopics.java`:

```
user.created                       (auth → profile)
order.created                      (order → payment, surprisebox, cart)
order.completed
order.cancelled                    (order → surprisebox to restore stock)
order.status-changed
payment.completed                  (payment → order)
payment.failed                     (payment → order)
surprise-box.reserved              (surprisebox → order)
surprise-box.stock-updated
reservation.expired                (surprisebox → order)
store.updated                      (store → cart for invalidation)
menu-item.updated                  (store → cart for price resync)
```

**Each event's envelope** is `DomainEvent<T>` with fields `eventId: UUID`, `eventType: String`, `occurredAt: Instant`, `payload: T`. Consumers use `IdempotentConsumer` (which keeps a `processed_events` table with `eventId` as PK) for exactly-once semantics on top of Kafka at-least-once.

### 4.5 Outbox pattern

Producers use a **Transactional Outbox**, not a direct `KafkaTemplate.send` from the business transaction:

1. Within the same JPA transaction as the business write (`order.save()`), a record is saved to `outbox_events` (type, topic, key, payload as JSON, correlationId).
2. `OutboxPublisher.publishPending()` (`@Scheduled(fixedDelay = 500)`) picks up unpublished records, sends them to Kafka, and marks `publishedAt = Instant.now()`.

**Guarantee:** if the business transaction rolls back, the event never reaches Kafka. If Kafka is unavailable, the event is not lost at business-operation time — it goes out on the publisher's next poll.

Debezium (CDC from the WAL) was not used — polling every 500ms is sufficient for pet scope.

### 4.6 Saga (orchestration / choreography hybrid)

The order saga on checkout:

```
POST /orders
  └─ order.created → payment-service (init Payment Intent / charge)
                    └─ payment.completed → order-service.onPaymentCompleted
                                            └─ if a surprise box is present:
                                              surprise-box.reserved → order-service.onSurpriseBoxReserved
                                            └─ order.status = CONFIRMED
                    └─ payment.failed → order-service.onPaymentFailed
                                          └─ order.status = CANCELLED
                                          └─ order.cancelled → surprisebox to restore stock
                    └─ reservation.expired (on surprisebox timeout) → order-service.onReservationExpired
                                                                       └─ rollback of the whole chain
```

This is **choreography** (no central orchestrator; each service listens and reacts). See `OrderKafkaConsumer.java` in fw-order-service. For longer chains and compliance work this would be Temporal/Camunda; for pet scope choreography is sufficient.

### 4.7 Kafka error handling — shared DLT

ADR 0007 closed the "silent ack-on-error" anti-pattern (where `ack.acknowledge()` sits in `finally` and swallows errors). The solution:

- fw-common gained **`KafkaErrorHandlerConfig`** — configures a `DefaultErrorHandler` with:
  - **Retry policy:** 3 attempts with exponential backoff 1s → 2s → 4s (cap 10s).
  - **Non-retryable** (straight to DLT): `DeserializationException`, `IllegalArgumentException`, `ValidationException`, `JsonParseException`, `NullPointerException`.
  - **Retryable** (with retry): `FoodWiseException` and others — may be transient (5xx from downstream, exhausted DB pool).
  - **DLT routing:** `DeadLetterPublishingRecoverer` → `<originalTopic>.DLT`.
- Services opt in via `@Import(KafkaErrorHandlerConfig.class)` + `factory.setCommonErrorHandler(handler)`.
- Consumers must **move `ack.acknowledge()` out of `finally` into the success branch of the try block**.

This affected 4 services (cart, order, payment, surprisebox).

---

## 5. Security posture

This is the most polished discipline in the project — thanks to the portfolio audit it received 10 ADRs.

### 5.1 What is closed (P0 security baseline — Pack 1)

| ADR  | Fix                                                                            |
|------|--------------------------------------------------------------------------------|
| 0001 | Gateway does not proxy `/actuator/**` downstream — each service's actuator is reachable only intra-network, not from outside |
| 0002 | Cart cross-store prevention: a cart is pinned to a single `storeId`; adding an item from another store → 409 |
| 0003 | Unified login error — no user enumeration (identical response for unknown email and wrong password) |
| 0004 | **Order ownership enforcement (IDOR fix)** — `GET /orders/{id}` checks `order.profileId` against `X-User-Id`, 403 on mismatch. `OrderService.getOrderById(UUID)` is now internal-only; the public path goes through `getOrderByIdForUser(orderId, profileId)`. |
| 0005 | **Server-side price recompute** — the client no longer sends `OrderItemRequest.price`; the price is recomputed on the backend from store-service data by `menuItemId`. |
| 0006 | Programmatic Resilience4j circuit breaker — 4xx from downstream is correctly mapped into a typed `FoodWiseException` instead of becoming a 500. |
| 0007 | Kafka DLT (see 4.7) |
| 0008 | Database credentials via `${SPRING_DATASOURCE_*:dev-default}` env vars in `application.yml` — the secret is not in git. Local dev works with defaults (`tapok332/admin` via `init-databases.sql`); Docker compose pulls from `.env`. |
| 0009 | fw-common boundary policy (see 4.2) |
| 0010 | Internal DTO contracts (see 4.4) |

### 5.2 What is closed at the fw-common level

- `XUserHeadersAuthFilter` (see 4.3)
- `InternalAuthFilter` for `/internal/**` (skips `/actuator/**`)
- `@SafeUrl` Bean Validation (whitelist `https?://`, blacklist `javascript:` / `data:` / `file:`)
- `RequestIdFilter` + MDC tracing
- `JwtProvider` with a `jti: UUID` claim (prevents refresh-token collision on rapid re-login)
- `GlobalExceptionHandler` — `AuthorizationDeniedException → 403` (not 500), `AuthenticationException → 401`

### 5.3 What is **not closed** (known SHOULD-FIX)

See memory `open_should_fix` and `portfolio_audit_2026_05_17`:

- **JWT in localStorage** on the frontend — an XSS steal vector. Roadmap: migrate to memory + httpOnly cookie for refresh.
- `LocalDateTime` against `TIMESTAMPTZ` in 3 services — timezone bugs under load.
- TanStack Query is installed but not used everywhere — some APIs are called via `useEffect` + `fetch`.
- Frontend has no tests at all.
- No OWASP Dep Check / Snyk configured in CI (there is no CI as such — pet project).

### 5.4 OAuth (stub)

`auth-service` has `OAUTH_GOOGLE_CLIENT_ID`, `OAUTH_APPLE_CLIENT_ID` env vars (see `docker-compose.yml`). The implementation is stubbed; the audit marks it as future work.

---

## 6. Frontend architecture

### 6.1 Structure

```
fw-client-ui/src/
├── ai/                  # Genkit AI flows (integration attempt)
├── app/                 # Next.js App Router
│   ├── (auth pages)/    # login/, register/, activate-code/
│   ├── (main pages)/    # page.tsx (home), restaurants/, category/,
│   │                    # cart/, checkout/, orders/, profile/, ...
│   ├── layout.tsx
│   ├── providers.tsx    # TanStack QueryClient, AuthContext, CartContext
│   └── globals.css      # Tailwind base + design tokens (shadow-soft*)
├── components/          # presentational + smart components
├── contexts/            # AuthContext, CartContext (React Context, not Zustand)
├── hooks/               # use{Stores,Cart,...}
├── lib/
│   ├── api.ts           # central HTTP client + backend→frontend mappers
│   └── ...
├── providers/
├── services/
├── styles/
├── types/               # frontend domain types
└── utils/
```

### 6.2 Routing and API layer

The backend returns a paginated envelope `{success, data: {content: [...], totalPages, ...}}` for collections. The frontend `lib/api.ts` normalizes both shapes (paginated and flat array) — there was a known bug with `stores.getAll`, which expected a flat array (see epic_a_status, root cause found via Playwright MCP).

### 6.3 Backend→Frontend mappers

Backend and frontend use **different field names** for the same entity (e.g., surprise box: backend `title/imageUrl/discountPercentage/location.{lat,lng}` → frontend `name/image/discount/{latitude,longitude}`). A `mapXxxFields` layer in `lib/api.ts` translates. This is a [SHOULD-FIX] — better to synchronize the contract.

### 6.4 Design

- **Soft shadow paradigm**: green-tinted `hsl(140 35% 18%)`, 3-layer blur stacks → biophilic feel. Tokens `shadow-soft`, `shadow-soft-md`, `shadow-soft-lg` in `globals.css`.
- **Rounded geometry**: `rounded-3xl` (24px) on cards instead of `rounded-2xl`.
- **Scroll containers**: explicit `py-8 -my-4 px-2 -mx-2` so shadows are not clipped by the BFC of `overflow-x-auto`.

### 6.5 Stripe integration (frontend)

`@stripe/react-stripe-js` + `Elements` provider. The PaymentElement renders after receiving a `clientSecret` from `POST /orders` (variant A flow, see memory `stripe_integration_v2_variant_a`). `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY` is exposed in the bundle (a publishable key — this is fine, not a secret).

---

## 7. Database

### 7.1 Per-service schema

```
foodwise_auth          → fw-auth-service
foodwise_profile       → fw-profile-service
foodwise_stores        → fw-store-service (PostGIS Point on stores.location)
foodwise_surprisebox   → fw-surprisebox-service
foodwise_cart          → fw-cart-service
foodwise_order         → fw-order-service
foodwise_payment       → fw-payment-service
```

One Postgres instance, separate databases. Each service owns its schema entirely — **no shared tables** between services. Inter-service queries go through REST or Kafka, not SQL joins.

`init-databases.sql` creates the databases on the Postgres container's first start.

### 7.2 Migrations (Flyway)

Each service carries its own `src/main/resources/db/migration/V*__*.sql`. Hibernate `ddl-auto=validate` — production discipline. Example from store-service:

```
V1__create_store_tables.sql
V2__create_content_tables.sql
V3__add_store_type_and_category_slug.sql
V4__add_category_store_types_translations_and_seed.sql
```

V4 is the current work in progress: adds an M:N category↔store-type relation + localized category names (see plan `docs/superpowers/plans/2026-05-24-categories-by-store-group.md`).

### 7.3 PostGIS

`store-service` uses Hibernate Spatial. `StoreEntity.location` is an `org.locationtech.jts.geom.Point`. Queries like "stores within X meters of a point" are done via `ST_DWithin` / `ST_Distance`. Coordinates are in SRID 4326 (WGS-84).

### 7.4 Idempotency table

Each consumer service has a `processed_events (event_id UUID PRIMARY KEY, event_type TEXT, processed_at TIMESTAMPTZ)` table. `IdempotentConsumer.processIfNew(eventId, eventType, runnable)` writes to it; a repeated event with the same `eventId` is skipped.

### 7.5 Outbox table

`outbox_events (id UUID, event_type, topic, event_key, payload JSONB, correlation_id, created_at, published_at)`. `published_at IS NULL` → not yet sent.

---

## 8. Build and dev workflow

### 8.1 Docker-compose as the primary dev environment

```bash
cp .env.example .env
# fill in secrets (see README §1)
docker compose up -d
```

Each service is built via its own `Dockerfile` with `additional_contexts: fw-common: ./fw-common, service: ./fw-xxx`. Multi-stage: Gradle build → Eclipse Temurin JRE 25.

### 8.2 Without Docker (local dev)

`./gradlew bootRun` in any service directory works out of the box — `application.yml` has dev defaults:

```yaml
spring:
  datasource:
    url: jdbc:postgresql://localhost:5432/foodwise_xxx
    username: ${SPRING_DATASOURCE_USERNAME:tapok332}
    password: ${SPRING_DATASOURCE_PASSWORD:admin}
```

Required: JDK 25, Postgres 16 + PostGIS on :5432 (with schemas from `init-databases.sql`), Kafka 3.x on :9092, Redis 7.x on :6379.

### 8.3 fw-common rebuild order

`fw-common` is not a Spring Boot app but a plain jar. Services pull it in via `files('../fw-common/build/libs/fw-common-0.0.1-SNAPSHOT-plain.jar')`. After changing fw-common:

```bash
cd fw-common && ./gradlew jar
cd ../fw-xxx-service && ./gradlew bootJar
```

This is **tech debt** — the proper approach would be a settings.gradle multi-module setup or Maven publish. It is done this way for historical reasons (see ADR 0009 → "shared library boundary policy").

### 8.4 Smoke

```bash
curl -i http://localhost:8080/actuator/health
# {"status":"UP"}
```

**Important** (memory `feedback_use_gateway_not_direct_ports`): smoke tests go through the gateway at `:8080`, not the services' direct ports. The direct ports (8081…8087) are not exposed outside the compose network in docker-compose (except for some `ports:` mappings left over from early iterations — keep an eye on those).

---

## 9. ADRs (Architecture Decision Records)

All important decisions are recorded in `docs/decisions/` in the Michael Nygard format. As of 2026-05-24 there are 10:

| #     | Topic                                                      |
|-------|-----------------------------------------------------------|
| 0001  | Gateway actuator isolation                                |
| 0002  | Cart cross-store prevention                               |
| 0003  | Unified login error (no user enumeration)                 |
| 0004  | Per-profile ownership check on GET /orders/{id}           |
| 0005  | Server-side price recompute                               |
| 0006  | Programmatic Resilience4j circuit breaker for 4xx mapping |
| 0007  | Kafka DLT with a shared `DefaultErrorHandler`             |
| 0008  | DB credentials via env + dev defaults                     |
| 0009  | Shared library boundary policy (fw-common)                |
| 0010  | Internal DTO contracts (no-envelope rule)                 |

Each ADR describes context, decision, and consequences. This is **the key portfolio artifact** for a reviewer — it shows not only the final code but the thinking process.

---

## 10. What is deliberately **over-engineered** (and why that's OK)

A reviewer should understand this; the README and the audit state it explicitly:

| What                                 | Why (from a portfolio perspective)                            |
|-------------------------------------|---------------------------------------------------------------|
| 7 microservices instead of a modular monolith | Demonstrates the Spring ecosystem (Cloud Gateway, Kafka, Resilience4j, fw-common shared library) |
| Outbox pattern                       | Reliable event publishing — production discipline             |
| Saga (choreography)                  | Distributed transaction reasoning                             |
| PostGIS                              | Showcase of advanced Postgres + Hibernate Spatial             |
| Stripe Payment Intents end-to-end    | Textbook payment integration (HMAC webhook, idempotency, PCI SAQ-A via Stripe Elements) |
| Per-service schema                   | Database-per-service discipline                               |
| 10 ADRs                              | Architecture documentation as a first-class artifact          |

---

## 11. What is **deliberately simpler** (anti-over-engineering)

| What was not done                           | Why                                                               |
|--------------------------------------------|-------------------------------------------------------------------|
| No hexagonal architecture (domain not separated from Spring/JPA) | Full ports-and-adapters would be ceremony with no benefit at pet scope |
| No MapStruct, no ModelMapper                | Handcrafted mappers are more readable and don't rely on reflection |
| No Spring Cloud Eureka                      | Service discovery via docker-compose service names              |
| No Spring Cloud Config / Vault              | Env vars + dev defaults in `application.yml` (ADR 0008)          |
| No Debezium for the outbox                  | `@Scheduled(fixedDelay = 500)` polling is sufficient             |
| No Temporal for the saga                    | Choreography over 4 events covers the current use cases          |
| No CQRS / Event Sourcing                    | Plain CRUD + ad-hoc events                                       |
| No gRPC for internal calls                  | REST with typed `InternalXxxDto` + circuit breaker               |
| No ELK / OTel                               | Plain JSON logs with structured `[service, requestId, userId]` MDC |
| No Prometheus / Grafana                     | Roadmap (portfolio Pack 6)                                       |
| No Kubernetes in prod                       | A `k8s/` directory exists with experimental manifests, but prod deployment is not a goal |
| No CI/CD                                    | Pet scope; builds run manually or via the IDE                    |

---

## 12. Where the **tech debt** is (current backlog)

Source: portfolio audit from 2026-05-17 (memory `portfolio_audit_2026_05_17`) + `open_should_fix.md`.

**P0 — closed (Packs 1, 2, 3, 4 done).**

**P1 / P2 (open):**

- **Pack 5: Frontend foundation** — migrate everything to TanStack Query, move JWT from localStorage → memory + httpOnly cookie, add Vitest + RTL + Playwright tests. 3-5 days.
- **Pack 6: Observability** — RFC 9457 `application/problem+json` responses, structured JSON logs, Prometheus endpoint, OpenTelemetry traces. 2-3 days.
- **Pack 7: Data discipline** — `@Version` for optimistic locking, `LocalDateTime` → `Instant`, missing FK indexes, dead code cleanup. 2-3 days.
- **Pack 8: Cart integrate** — cart-service is not yet integrated with the frontend (the frontend uses local state). 1.5-2 days.

**Backend-specific** (flagged by the audit):
- Placeholder image 404s on `/images/*-placeholder.jpg` (minor).
- `/home/boxes` returns 0 elements (separate issue, unclear which service).
- Frontend store fields beyond `logoUrl/heroUrl` are not mapped into the Store frontend type.

**Notification service** (Epic B) — a separate future-work service for push + email + Kafka events (see memory `epic_b_planned`).

**Current work as of 2026-05-24** — plan `docs/superpowers/plans/2026-05-24-categories-by-store-group.md`: adding a `StoreType` enum + localized category names + an M:N category↔store-type relation. Task 1 (StoreType enum) and Task 2 (V4 migration) are already done.

---

## 13. How to read the repo for the first time

**Recommended order:**

1. `README.md` — introduction, quick start.
2. `docs/decisions/0001…0010-*.md` — key architectural decisions. The most valuable reading for a reviewer.
3. `docker-compose.yml` — network topology, environment variables, healthchecks.
4. `fw-gateway/src/main/resources/application.yml` — all routes, which path goes where.
5. `fw-common/src/main/java/.../security/XUserHeadersAuthFilter.java` — the auth contract between the gateway and services.
6. `fw-common/src/main/java/.../event/EventTopics.java` + `event/payload/*.java` — the registry of all Kafka events.
7. `fw-order-service/src/main/java/.../kafka/OrderKafkaConsumer.java` + `service/OrderSagaHandler.java` — the saga by example.
8. Any `controller/` + `service/` + `repository/` of any service — the structure is uniform everywhere.

For the frontend: `fw-client-ui/src/lib/api.ts` (central API client + mappers), `src/app/page.tsx` (homepage), `src/contexts/AuthContext.tsx`.

---

## 14. Project metrics (snapshot 2026-05-24)

| Metric                                        | Value                   |
|----------------------------------------------|-------------------------|
| Active Spring services                        | 8 (including gateway)   |
| Shared libraries                              | 1 (fw-common)           |
| Kafka topics                                  | 12                      |
| ADRs                                          | 10                      |
| Backend unit tests                            | ~120                    |
| Frontend tests                                | 0 (known gap)           |
| Databases (per-service)                       | 7                       |
| Flyway migrations (cumulative)                | ~15-20 (varies by service) |
| Lines of Java code (rough)                    | ~15-20K                 |
| Lines of TypeScript code (rough)              | ~10-12K                 |
| Portfolio-readiness (per audit)               | ~70% (ceiling ~85%)     |

---

## 15. Resume contract for a future session

If you return to the project after a month or half a year:

1. **Read this file in full** — 15 minutes gives a complete recap.
2. **Read `memory/MEMORY.md`** in `~/.claude/projects/-Users-tapok332-Documents-fw-project-dyplom/memory/` — it holds the actual state of work and known issues.
3. **Check the dates** — specific numbers (ADR count, Spring Boot version) may have changed. The source of truth is `build.gradle` and `docs/decisions/`.
4. **Check `docs/superpowers/plans/`** — in-progress plans live there (as of 2026-05-24 it's categories-by-store-group).
5. **Run `docker compose up -d`** and `curl localhost:8080/actuator/health` — health check.
6. **`git log --oneline -20`** — what was done last.

---

*This document was created on 2026-05-24 as the single-source-of-truth project overview. On significant architecture changes, update the relevant source section rather than appending after-the-fact comments.*
