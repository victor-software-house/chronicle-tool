<!--
  Vendored from gotalab/cc-sdd v3.0.2 (https://github.com/gotalab/cc-sdd.git)
  Source path: tools/cc-sdd/templates/shared/settings/templates/steering-custom/security.md | Materialized: 2026-05-26T19:52:37.629907+00:00
  Do not edit; bump dfetch.yaml and run vendor:materialize.
-->

# Security Standards

[Purpose: define security posture with patterns for validation, authz, secrets, and data]

## Philosophy
- Defense in depth; least privilege; secure by default; fail closed
- Validate at boundaries; sanitize for context; never trust input
- Separate authentication (who) and authorization (what)

## Input & Output
- Validate at API boundaries and UI forms; enforce types and constraints
- Sanitize/escape based on destination (HTML, SQL, shell, logs)
- Prefer allow-lists over block-lists; reject early with minimal detail

## Authentication & Authorization
- Authentication: verify identity; issue short-lived tokens/sessions
- Authorization: check permissions before actions; deny by default
- Centralize policies; avoid duplicating checks across code

Pattern:
```typescript
if (!user.hasPermission('resource:action')) throw ForbiddenError();
```

## Secrets & Configuration
- Never commit secrets; store in secret manager or env
- Rotate regularly; audit access; scope minimal
- Validate required env vars at startup; fail fast on missing

## Sensitive Data
- Minimize collection; mask/redact in logs; encrypt at rest and in transit
- Restrict access by role/need-to-know; track access to sensitive records

## Session/Token Security
- httpOnly + secure cookies where possible; TLS everywhere
- Short expiration; rotate on refresh; revoke on logout/compromise
- Bind tokens to audience/issuer; include minimal claims

## Logging (security-aware)
- Log auth attempts, permission denials, and sensitive operations
- Never log passwords, tokens, secrets, full PII; avoid full bodies
- Include requestId and context to correlate events

## Headers & Transport
- Enforce TLS; HSTS
- Set security headers (CSP, X-Frame-Options, X-Content-Type-Options)
- Prefer modern crypto; disable weak protocols/ciphers

## Vulnerability Posture
- Prefer secure libraries; keep dependencies updated
- Static/dynamic scans in CI; track and remediate
- Educate team on common classes; encode as patterns above

---
_Focus on patterns and principles. Link concrete configs to ops docs._
