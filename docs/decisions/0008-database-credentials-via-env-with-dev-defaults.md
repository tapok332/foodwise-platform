# 0008 — Database credentials via env vars with dev-friendly defaults

* **Status:** Accepted
* **Date:** 2026-05-17
* **Pack:** Portfolio Pack 2 — Secrets discipline

## Context

Per the portfolio audit (2026-05-17), five services were flagged as
having hardcoded `username: tapok332` / `password: admin` literals in
their `application.yml`. **Verification during this pack widened the
scope to seven services** — `cart` and `auth` had the same hardcoded
literals; the audit had marked them clean because `docker-compose.yml`
overrides those values via ENV, but the IDE / `./gradlew bootRun` path
hit the plaintext defaults. The grep that caught it:
`grep -rnE "password:\s*[a-zA-Z]" --include="application.yml"`.

So the final scope is: **`auth`, `profile`, `store`, `surprisebox`,
`cart`, `order`, `payment`** — every service that owns a database.
`gateway` has no datasource and is out of scope. `fw-backend` is a
legacy module (`application-local.yml` only) and was left untouched.

The credentials are local-dev PostgreSQL superuser values created by
`init-databases.sql`, but the literal `password: admin` appearing as
plaintext in source is a textbook secret-discipline failure — both as
a pattern (CWE-798) and as a recruiter-readable signal.

`docker-compose.yml` already wires every service via ENV
(`SPRING_DATASOURCE_USERNAME: ${PROFILE_DB_USER}`,
`SPRING_DATASOURCE_PASSWORD: ${PROFILE_DB_PASSWORD}`, etc.) with
per-service users created by the init script. The `.env` file at the
project root (gitignored) holds the canonical values.

So the gap was inconsistency: containerized runs flowed credentials
through ENV cleanly; running a service from IDE / `./gradlew bootRun`
used the hardcoded superuser literals in YAML. Three problems with the
status quo:

1. **Plaintext "password: admin" in source** is a CWE-798 signal even
   when the password is intentionally weak for local dev. Recruiters
   reviewing the repo will pattern-match on it before reading context.
2. **Docker and local runs use different credentials** — confusing to
   onboard, and the docker-compose path implicitly trains the dev to
   think credentials are externalized when they actually aren't.
3. **No `.env.example`** — no canonical place documenting which
   environment variables a new contributor must populate to run the
   project, so the only path to a working setup was to find the
   hidden `.env` (or guess from `application.yml`).

## Decision

Replace the three datasource literals (and Kafka bootstrap) in each of
the five `application.yml` files with Spring's
`${ENV_NAME:dev-default}` syntax:

```yaml
spring:
  datasource:
    url: ${SPRING_DATASOURCE_URL:jdbc:postgresql://localhost:5432/foodwise_profile}
    username: ${SPRING_DATASOURCE_USERNAME:tapok332}
    password: ${SPRING_DATASOURCE_PASSWORD:admin}
  kafka:
    bootstrap-servers: ${SPRING_KAFKA_BOOTSTRAP_SERVERS:localhost:9092}
```

Both layers are now load-bearing:

* **Docker / prod**: existing `SPRING_DATASOURCE_*` and per-service
  `${PROFILE_DB_USER}`/`${PROFILE_DB_PASSWORD}` env vars override the
  YAML defaults. No change needed in `docker-compose.yml`.
* **Local / IDE**: no env vars set → fallback to the dev superuser
  values (`tapok332` / `admin`) that match what
  `init-databases.sql` creates locally.

Add `.env.example` at the project root as a commit-safe template
documenting every required variable (no real secrets). Audit
`.gitignore` to ensure `.env`, `*.pem`, `*.key`, and credentials JSON
files stay out of the tree.

### Why the dev default is intentional, not lax

The hardcoded defaults `tapok332` / `admin` describe a local PostgreSQL
superuser the developer creates with `init-databases.sql`. The defaults
are not a fallback that gets used in production — production sets every
env var explicitly via `docker-compose.yml`, and there is no
`application-prod.yml` profile that omits this.

The trade-off vs. strict fail-fast is conscious:

| Approach | Local dev cost | Security if env not set in prod |
| --- | --- | --- |
| **`${SPRING_DATASOURCE_PASSWORD:admin}`** (chosen) | Zero — `./gradlew bootRun` just works | Process boots with `admin` against a postgres that doesn't accept it → fails on first query, very obvious |
| `${SPRING_DATASOURCE_PASSWORD}` (no default) | Onboarding requires `.env` setup before first run | Process refuses to start at all — clearer "you forgot to set this" signal |

For a portfolio pet-project where the prod path is explicit (`docker
compose up` always provides the env vars), the local-dev ergonomics
win. The change still removes plaintext-secret-in-source — the
fallback values are not credentials for anything reachable from the
public internet, they're an alias for "I'm running locally."

## Alternatives rejected

### 1. Strict fail-fast (`${SPRING_DATASOURCE_PASSWORD}`)

Closer to what the Pack 2 prompt originally specified. Rejected
because:

* Local dev now requires `cp .env.example .env` *before* the first
  `bootRun` works, breaking the "clone and run" expectation for a pet
  project.
* The default `admin` value is not a real credential — there is no
  production PostgreSQL anywhere accepting it. The fallback is
  effectively a marker for "you didn't override this" rather than a
  leak.

The strict variant remains the right call once a real production
deployment exists. ADR can be revisited then.

### 2. Profile-split (`application-dev.yml` defaults +
   `application-prod.yml` requires)

Cleaner conceptually but doubles the file count and adds an
`-Dspring.profiles.active=` requirement every dev needs to remember.
For five services × two profile files = ten YAML files for a
single-line concern. Not worth the surface area.

### 3. Spring Cloud Config Server / Vault

Production-grade secret store, but for a diploma-scope project this is
operational overhead with no upside — there is no real key rotation
problem, no multi-environment fan-out, no audit-trail requirement.
ADR notes this as the right direction *if* the project ever ships.

### 4. Move to JBang/Testcontainers for all local dev (no real
   PostgreSQL on host)

Would remove the need for dev credentials at all (Testcontainers
generates them per run). Out of scope here — touches every dev's
workflow and many of the existing setup docs.

## Impact

### Files changed

* **7× `application.yml`** in `auth`, `profile`, `store`,
  `surprisebox`, `cart`, `order`, `payment` — datasource block migrated
  to env-vars-with-defaults pattern; same treatment applied to
  `spring.kafka.bootstrap-servers`.
* **`.env.example`** (new) — commit-safe template at project root,
  enumerates every env var the project needs, with placeholders or
  safe defaults.
* **`.gitignore`** (updated) — added `.env.local`, `.env.*.local`,
  `*.pem`, `*.key`, `*.crt`, `service-account*.json`, `gcs-key*.json`,
  `.DS_Store` to the existing root file.
* **`README.md`** (new) — Quick Start covering env setup, secret
  generation, and `docker compose up`.

### Files intentionally not changed

* **`docker-compose.yml`** — already wires every service via ENV with
  per-service users; no edit needed.
* **`gateway`** — no datasource at all (stateless); nothing to migrate.
* **`fw-backend`** — legacy module (`application-local.yml` only),
  not in active deployment; intentionally left untouched.
* **JWT secrets** in `auth-service` — already env-parameterized.
* **Stripe keys in `payment-service`** — already env-parameterized.
* **Per-service `.gitignore`** — not adding these (each service is
  *not* an independent git repo; the root `.gitignore` is the only
  one that matters).
* **No `pre-commit` / `gitleaks` hook** — project is not a git
  repository currently; documenting the hook in ADR as the right
  thing to wire up once VCS is in place.

### Behavior changes for contributors

* **First-time contributor running locally**: behavior is unchanged
  — `./gradlew bootRun` works against a local PostgreSQL with the
  `tapok332`/`admin` superuser. They will see explicit
  `${...:default}` syntax in YAML which is self-documenting.
* **`docker compose up`**: unchanged — ENV vars still override
  defaults exactly as before.
* **Anyone reading the repo**: no longer sees `password: admin` in
  source. The plaintext credential is removed.

## Followups (out of scope for this pack)

* **Rotate the JWT secrets and Stripe webhook secret in `.env`** if
  the project ever moves to a public git history — they are real
  generated values, not placeholders, and committing the wider repo
  with them present would be a leak.
* **`gitleaks` pre-commit hook** — wire this in the moment `git init`
  happens at the project root or per-service.
* **Move to External Secrets Operator / Vault** if production
  deployment ever happens.
* **Consider strict fail-fast** (`${SPRING_DATASOURCE_PASSWORD}` with
  no default) once a real production environment exists where "boot
  fails on missing secret" is the desired prod failure mode.
