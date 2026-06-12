# 0003 — Unified `401` response on `/auth/login` for unknown email and wrong password

* **Status:** Accepted
* **Date:** 2026-05-17
* **Pack:** Portfolio Pack 1 — Security baseline (task 1.3)

## Context

`AuthService.login` threw two distinct exceptions:

* Unknown email → `FoodWiseException(USER_NOT_FOUND)` → **HTTP 404**, with
  the submitted email passed as the exception description (later logged via
  `GlobalExceptionHandler.log.error` — a secondary email leak into log
  aggregation).
* Wrong password → `FoodWiseException(UNAUTHORIZED_ERROR)` → **HTTP 401**.

This is the canonical **OWASP A07:2021 — Identification and Authentication
Failures (user enumeration)** signature: any attacker can iterate over a
list of emails and read off which ones are registered by inspecting the
status code. A pinning test (`AuthServiceTest.nonExistentUser_throwsNotFound`)
asserted the wrong behaviour, locking it in against accidental fixes.

The audit (2026-05-17, P0 #4) flagged this as a base security knowledge
gap for an auth service and the highest-ROI auth-side fix.

## Decision

1. **Unified response.** Both branches now throw
   `FoodWiseException(UNAUTHORIZED_ERROR, "Invalid credentials")` →
   **HTTP 401** with a generic body. The description does not mention the
   email.

2. **Timing-equivalent bcrypt verification.** The fix also closes the
   response-time side channel: bcrypt is non-trivially expensive (cost
   factor 10 ≈ 60 ms), and a fast "unknown email" branch that skipped the
   call was distinguishable from "known email, wrong password". The new
   code path always runs `passwordEncoder.matches(request.password(), …)`
   — against the real user hash when the email exists, or against a stable
   sentinel hash (`ENUMERATION_GUARD_HASH`) when it does not.

3. **INFO-level observability without PII leakage.** The audit-log
   requirement from the audit acceptance is met with a single
   `log.info("Failed login attempt (account_exists={})", userOpt.isPresent())`
   call. The email is never written to the log. The `account_exists` flag
   is internal observability only — it is not returned to the caller.

4. **Pinning tests.** `AuthServiceTest.EmailLogin` now contains three tests:
   `success_returnsTokens`, `wrongPassword_throwsUnauthorized`,
   `nonExistentUser_throwsUnauthorized` (renamed and corrected), plus
   `bothBranchesReturnSameErrorMessage_preventingEnumeration` which
   asserts equality of both the message and the HTTP status across both
   branches — a regression on the unification would break it directly.

5. **Dead helper removed.** `AuthService.getUserByEmail(String)` was the
   only USER\_NOT\_FOUND throw site; it had a single caller (`login`) and
   is gone after the inline.

## Alternatives considered

* **Map `USER_NOT_FOUND` to HTTP 401 in `FoodWiseErrorCode` instead of
  unifying the codes.** Half-fix. The error code itself still carries the
  "user not found" semantics and would re-leak through any future
  serialization of the error code symbol (e.g. structured logs, error
  body that includes the code). Unifying at the throw site is the
  cleaner boundary.

* **Skip the timing fix and only unify the response.** Insufficient: the
  bcrypt timing differential alone is enough to enumerate accounts at
  scale, even when the HTTP body looks identical. The two controls go
  together.

* **Apply the same fix to `/auth/register`.** Audit calls this out as a
  P1 follow-up (registration leaks via timing and via the `IllegalArgumentException`
  → 400 path documented in audit P0 #3 for the auth service). Out of
  scope for this pack; tracked for a future security pack.

## Known limitations (not addressed in this pack)

* **`AuthService.register` is still an enumeration oracle.** It throws
  `IllegalArgumentException("User with email already exists")` on
  duplicate email, which `GlobalExceptionHandler.handleIllegalArgument`
  surfaces as `400 INVALID_REQUEST` with the literal message in the
  response body. An attacker can still enumerate registered emails via
  the registration endpoint. Closing this needs the same shape of fix
  (unify error + remove email from message) plus possibly an honeypot
  delay; tracked as future P1 (audit per-service findings flag it as
  the auth P0 #3 follow-up).
* **`GlobalExceptionHandler` logs every `FoodWiseException` at
  `log.error` with a full stack trace** (`fw-common/.../GlobalExceptionHandler.java:22`).
  That defeats the INFO-level audit signal this ADR promises — every
  failed login produces an ERROR-severity stack-trace line in the log
  aggregator. The fix is a one-line severity downgrade for the 4xx
  mapping, but it lives in fw-common and changes every microservice's
  log output, so it belongs to Pack 6 (RFC 9457 error format
  refactor), not this pack. The INFO line from `AuthService.login` is
  the audit signal of record; downstream alerting should consume that
  line, not the ERROR stack from the handler.

## Consequences

* The HTTP status for `/auth/login` with an unknown email changes from
  `404` to `401`. This is a behavioural change visible to existing
  clients. The Next.js frontend currently checks the status code (see
  `src/lib/auth-api.ts`); both branches now look the same, so the UI
  message ("invalid email or password") is correct in both cases — no
  change needed.

* All callers of `AuthService.getUserByEmail` are gone. The private
  helper is removed.

* `GlobalExceptionHandler.handleFoodWiseException` no longer receives an
  exception carrying the email in its description, so the secondary log
  leak is closed by the same change.

* If observability tooling already filters / alerts on
  `FoodWiseErrorCode.USER_NOT_FOUND` from auth, those alerts will go
  silent. Replacement signal: the new
  `log.info("Failed login attempt …")` line — switch monitoring rules to
  count those.

## References

* OWASP A07:2021 — Identification and Authentication Failures
* OWASP ASVS 4.0 — V2.1.12 (no enumeration via login responses)
* Audit `Projects/FoodWise-portfolio-audit-2026-05-17.md` — P0 item #4
* Tests: `fw-auth-service/src/test/java/.../AuthServiceTest.EmailLogin`
