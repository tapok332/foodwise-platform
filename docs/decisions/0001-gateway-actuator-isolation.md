# 0001 — Isolate gateway actuator endpoints to a dedicated management port

* **Status:** Accepted
* **Date:** 2026-05-17
* **Pack:** Portfolio Pack 1 — Security baseline (task 1.4)

## Context

`fw-gateway` exposed Spring Boot Actuator on the main public port `8080`
(`management.endpoints.web.exposure.include: health,info,gateway`) and listed
`/actuator` in the `PUBLIC_PATHS` allow-list of `JwtAuthenticationFilter`.
The combination made `/actuator/gateway/routes`, `/actuator/gateway/filters`
and `/actuator/gateway/globalfilters` reachable by anonymous callers from the
public internet. Those endpoints return the complete routing table including
downstream service URIs, predicate definitions and per-route filter chains —
high-value reconnaissance data for an attacker mapping the topology of the
microservice fleet before targeting individual services.

This matches **OWASP A05:2021 — Security Misconfiguration** and the
"Cryptographic & misconfiguration leaks of routing metadata" pattern flagged
during the 2026-05-17 portfolio audit (P0 item #5).

## Decision

Two complementary changes, applied together:

1. **Move actuator to a dedicated port.** `application.yml` now sets
   `management.server.port: 8081`. Docker-compose publishes only `8080:8080`
   for the gateway service, so port `8081` is reachable only from inside the
   Docker network. Probes, Prometheus scraping and future ops tooling stay on
   `8081` over the internal bridge.

2. **Tighten the actuator exposure list.** `gateway` is removed from
   `management.endpoints.web.exposure.include`, leaving `health,info`. Even on
   the management port the routes/filters introspection surface is no longer
   served.

3. **Remove `/actuator` from `JwtAuthenticationFilter.PUBLIC_PATHS`.** Any
   request for `/actuator/**` that still lands on the main `8080` port is now
   subject to the same `Bearer` token requirement as `/orders`, `/payments` and
   the rest of the protected catalogue. The filter rejects unauthenticated
   actuator probes with `401 Unauthorized` instead of forwarding them.

## Alternatives considered

* **Keep actuator on `8080`, just remove `gateway` from `include`.** Minimum
  fix per the audit's "fallback" recommendation. Rejected because it leaves
  the network-layer attack surface in place: any future addition to the
  include list (`prometheus`, `env`, `loggers`) would re-introduce the leak,
  and a misconfiguration of `PUBLIC_PATHS` would expose it again.
  Defence-in-depth requires both controls.

* **Spring Security on the gateway, with explicit actuator role check.**
  Heavier dependency, double-evaluation risk with the existing global
  `JwtAuthenticationFilter` (the audit explicitly flags this as a pitfall),
  and does not reduce the attack surface at the network layer.

## Consequences

* `/actuator/gateway/routes` is no longer reachable from the host, period.
  Anyone needing to inspect routes must `docker exec` into the container or
  port-forward `8081` deliberately.

* If a future operator wants Prometheus scraping or external health probes,
  the docker-compose / k8s manifests must expose `8081` on a private network
  segment (not the public ingress). This is intentional friction.

* `JwtAuthenticationFilterTest.ActuatorPaths` (added as part of this change)
  pins the new behaviour: `/actuator/gateway/routes`, `/actuator/health` and
  arbitrary `/actuator/*` requests on the main port return `401` without a
  bearer token. Any regression that adds `/actuator` back into `PUBLIC_PATHS`
  will break these three tests.

* `docker-compose.yml` is not modified by this ADR — `8081` is deliberately
  left unpublished. If healthchecks for the gateway service are added in a
  future pack, they should call `http://gateway:8081/actuator/health` from
  inside the network.

## References

* OWASP A05:2021 — Security Misconfiguration
* `~/.claude/rules/kubernetes.md` — *Actuator endpoint port* section (probes
  on `8081`, traffic on `8080`)
* Audit `Projects/FoodWise-portfolio-audit-2026-05-17.md` — P0 item #5
* Test: `fw-gateway/src/test/java/.../JwtAuthenticationFilterTest.ActuatorPaths`
