# 0013. Refresh token in httpOnly cookie, access token in memory only

Date: 2026-06-12

## Status

Accepted

## Context

Both JWTs (access, 15 min TTL; refresh, 30 days TTL) were returned in the JSON
body of every token-issuing endpoint and persisted by fw-client-ui in
`localStorage`. Any XSS payload could exfiltrate the long-lived refresh token
and hold the account indefinitely. This was a top-3 finding of the 2026-05-17
portfolio security audit. A side effect of the old flow: the frontend logout
never called the backend, so refresh tokens were never revoked server-side.

## Decision

Split the token pair across two transports:

- **Access token** — JSON body only (`AuthTokenResponse`), held by the frontend
  exclusively in module-level memory (`fw-client-ui/src/lib/auth-api.ts`), sent
  as `Authorization: Bearer`. Never written to localStorage/sessionStorage.
- **Refresh token** — `Set-Cookie: refreshToken=…; HttpOnly; Secure;
  SameSite=Strict; Path=/auth; Max-Age=<remaining TTL>` issued by
  fw-auth-service (`RefreshTokenCookieFactory`). `/auth/refresh-token` and
  `/auth/logout` read it via `@CookieValue`; the request body variant was
  removed (`RefreshTokenRequest` deleted). Logout always answers 204 and clears
  the cookie with `Max-Age=0`.

Session recovery after a page reload is a silent `POST /auth/refresh-token`
gated by a non-secret `localStorage["fw.auth.session-hint"]` flag so anonymous
visitors never fire the call. `auth:session-expired` (redirect to /login) is
dispatched only when an access token existed in memory — a failed bootstrap
refresh stays silent.

CSRF: business endpoints authenticate via the Authorization header (immune to
cookie-based CSRF). The cookie itself is confined by `Path=/auth` +
`SameSite=Strict`, which blocks cross-site delivery entirely; no CSRF token
machinery is required. `Secure` is configurable (`AUTH_COOKIE_SECURE`,
default `false`) because local dev runs plain http://localhost.

The gateway needed no changes: `Set-Cookie` passes through untouched and CORS
already ran with `allowCredentials: true` for `http://localhost:3000`.

## Consequences

- XSS can no longer steal the refresh token; a stolen in-memory access token
  expires within 15 minutes.
- Logout now revokes the refresh token server-side (closes a pre-existing gap).
- `JwtResponse` (fw-common) is demoted to an internal carrier — never
  serialized to clients.
- Accepted limitation: two tabs refreshing simultaneously can race the
  rotation; the loser gets 401 and re-logins. Mitigation (Web Locks /
  BroadcastChannel) deferred until it hurts.
- Accepted limitation: a stale hint (cookie expired while away) costs one
  failed refresh call on the next visit, then cleans itself up.
- fw-backend (legacy monolith) still uses the old body-based contract and is
  intentionally out of scope.

## Alternatives rejected

- **Both tokens in cookies** — requires the gateway JWT filter to read cookies
  and full CSRF-token machinery on every state-changing endpoint.
- **BFF via Next.js API routes** — the UI is fully client-side (`"use client"`
  everywhere); proxying every call through Next would be a rewrite
  disproportionate to the threat model.
