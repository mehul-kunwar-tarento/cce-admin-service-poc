# cce-admin-service — Basic Architecture

Written 5 Nov 2026 from the CCE v2 Admin Module PRD (29 Oct 2026). The team's design docs
(data dictionary, flow diagrams, API reference) win over this file where they disagree.

> **Repo:** `cce-admin-service-poc` is a standalone learning build. It is **not** the
> `openphc/cce-admin-service` repo and is not linked to it. Inside this doc the service is still
> called `cce-admin-service`, the name the PRD uses.
>
> **Scope:** the **backend service only**. The admin UI (`cce-admin-ui`) is a separate repo and
> comes later; until then the service is driven through Swagger UI and curl. This is a learning
> exercise in spec-driven development. It is built and tested locally and **designed to be
> deployed to dev** (and other environments later); nothing goes to prod as part of this
> exercise. The decisions and sub-tasks are in `SPEC.md`.

---

## 1. What the service does and why

**Problem today.** `cce-insights-ui` shows the same sidebar to every logged-in user. The gateway
can already block APIs per role, but nobody can manage *who has which role*, *which screens a
role sees*, or *which APIs a role can call* without hand-editing Keycloak and a database table.

**What cce-admin-service is.** A Spring Boot backend that:
- owns users, roles, menus and API permissions,
- creates and updates user accounts in Keycloak, and keeps the DB and Keycloak in step,
- tells any console which menus the logged-in user may see (`GET /me/menus`),
- writes an audit row for every change.

**Goals.**
1. A console can ask "which menus may this user see?" and get the right answer for their roles.
2. API permissions per role are managed through this service's API, not by hand in SQL.
3. Every change is in `audit_log`: who gave this user access, and when.
4. Users, roles and role assignments stay consistent between the DB and Keycloak. When they
   can't, the caller gets a clear error, never a silent half-done change.

---

## 2. Where the service sits

| Component | Status | Relationship to the service |
|---|---|---|
| Keycloak | Exists | Issues the tokens the service checks. The service calls its **Admin API** to create users, assign roles, enable/disable, reset passwords |
| gateway-service | Exists, **not changed** | Sits in front: checks the JWT and `api_permissions`, then forwards `/admin/**`. The service calls back into it to sync realm roles |
| PostgreSQL, DB `admin_service` | Exists, gateway already reads it | The service's own database. Shared with the gateway for `api_permissions` |
| **cce-admin-service** (:8085) | **New — this repo** | |
| Callers | — | Later: `cce-admin-ui` and `cce-insights-ui`. Now: Swagger UI / curl |

```
                                                          Keycloak
                                                             ▲
                                                             │ Keycloak Admin API
                                                             │ (create user, assign roles,
  caller (Swagger / curl,                                    │  enable/disable, reset pwd)
  later the UIs)                                             │
     │ Bearer token, /admin/v1/**                            │
     ▼                                                       │
  gateway-service ──────────── proxy ──────────► cce-admin-service (:8085)
     │ JWT check                                   │       │
     │ + api_permissions check                     │ JPA   │ POST /api/permissions/sync-to-keycloak
     │ (R2DBC read)                                ▼       │   (gateway then creates realm roles
     └──────────────────────────────────►  PostgreSQL ◄────┘    in Keycloak)
                                           admin_service
```

Rules:
- The service is never internet-facing. It still checks the JWT itself (defense in depth, §8).
- The **gateway** creates realm role *definitions* in Keycloak. The **service** creates *users*
  and *assigns* roles to them.

---

## 3. Key ideas (read these first)

| Term | Meaning |
|---|---|
| User | A person who can log in. 1:1 with a Keycloak user, joined by `keycloak_id = JWT sub`. No passwords stored locally. |
| Role | A named bundle of access, e.g. `FACILITY_ADMIN`. UPPER_SNAKE_CASE. **Name can never change.** |
| Menu | One screen of `cce-insights-ui`. `NAV` = sidebar item. `DETAIL` = drill-down page under a NAV. |
| Permission | One `(HTTP method, URI pattern)` a role may call. Stored in `api_permissions`, enforced by the gateway. |

**One name, three places.** `roles.name` = Keycloak realm role name = `api_permissions.permission_name`.
That is why a role name is permanent.

**Two separate controls.**
- Role → Menu is a **soft** control. It only changes what a console shows. Wrong setup looks odd but is not a security problem.
- Role → Permission is a **hard** control. It decides what the gateway lets through. Wrong setup **is** a security problem.

Giving a role the Compliance menu does **not** give it the compliance APIs, and the other way round.

---

## 4. Data model (schema `admin_service`)

Seven tables, created by Flyway. Exact columns come from the data dictionary.

| Table | Holds | Notes |
|---|---|---|
| `users` | Local copy of each person | `keycloak_id`, username, email, names, `status` (ACTIVE / INACTIVE / LOCKED), `facility_scope` (stored only, not enforced), `last_login_at` |
| `roles` | Role definitions | `name` (unique, immutable), `display_name`, `description`, `is_system` |
| `menus` | The 12 insights-ui screens | `key` (unique), label, path, icon, `type` NAV/DETAIL, `parent_id`, `sort_order`, `is_active` |
| `role_menus` | Which role sees which menu | Many-to-many |
| `user_roles` | Which user has which role | Kept when a user is deactivated, so re-activating restores access |
| `api_permissions` | Which role may call which API | **Shape is owned by the gateway. Do not change it.** |
| `audit_log` | Append-only history | actor, action, entity type/id, before/after JSON, IP |

Seed data: the 12 `cce-insights-ui` menus and one `SUPER_ADMIN` system role.

**`api_permissions` as the gateway defines it today** (`gateway-service/DATABASE_PERMISSIONS_MIGRATION.md`):

```sql
id BIGSERIAL PRIMARY KEY,
permission_name VARCHAR(100) NOT NULL,     -- = roles.name
http_method VARCHAR(10) NOT NULL,
uri_pattern VARCHAR(255) NOT NULL,
description TEXT,
resource_category VARCHAR(50),
created_at, updated_at TIMESTAMP,
UNIQUE (permission_name, http_method, uri_pattern)
```

Note: the PRD says "UUID PKs" for all tables, but this table uses `BIGSERIAL`. The gateway's
shape wins (see §10).

---

## 5. API (base path `/admin/v1`)

All endpoints need a Bearer token except `/health`.

| Method | Path | Purpose |
|---|---|---|
| GET | `/me` | Caller's profile and role names |
| GET | `/me/menus` | Menu tree for the caller's roles (used by consoles to build their sidebar) |
| GET / POST | `/users` | List (filter + paginate) / create with Keycloak account |
| GET / PUT | `/users/:id` | Get / update profile |
| PATCH | `/users/:id/status` | ACTIVE / INACTIVE / LOCKED, mirrored to Keycloak |
| PUT | `/users/:id/roles` | Replace the user's full role set |
| POST | `/users/:id/reset-password` | Trigger Keycloak reset email |
| GET / POST | `/roles` | List / create |
| GET / PUT / DELETE | `/roles/:id` | Get / edit display fields / delete (guarded) |
| GET / PUT | `/roles/:id/menus` | Read / replace menu set |
| GET / PUT | `/roles/:id/permissions` | Read / replace permissions (then auto-sync) |
| POST | `/roles/:id/sync` | Manual re-sync to gateway |
| GET / POST | `/menus` | Menu tree / create |
| PUT / DELETE | `/menus/:id` | Update / delete (also removes `role_menus`) |
| GET | `/health` | `{status:"UP"}` |

**Response shape.** Success: `{ data, pagination? }`. Error: `{ error: { code, message } }`.
Lists: `page`, `pageSize` (default 20, max 100).

**"Replace" semantics.** `PUT .../roles`, `.../menus`, `.../permissions` always receive the
**full** new set. The service works out what was added and removed.

**Error codes.**

| HTTP | Code | When |
|---|---|---|
| 400 | VALIDATION_ERROR | Bad body or query |
| 401 | UNAUTHENTICATED | Missing, invalid or expired token |
| 403 | FORBIDDEN | Role not allowed, or local user not ACTIVE |
| 404 | USER_ / ROLE_ / MENU_NOT_FOUND | Unknown id |
| 409 | DUPLICATE_ROLE_NAME, DUPLICATE_MENU_KEY, EMAIL_IN_USE | Already exists |
| 409 | ROLE_IN_USE | Deleting a role still assigned to users |
| 409 | SYSTEM_ROLE_IMMUTABLE | Changing or deleting a system role |
| 502 | KEYCLOAK_SYNC_FAILED | Keycloak or gateway call failed, change only partly applied |

---

## 6. Main flows

### Flow A — Create a user (scenario S2)
```
caller ──POST /admin/v1/users──► gateway (JWT + permission) ──► admin-service
admin-service:
  1. check JWT, check caller is a local ACTIVE user
  2. Keycloak: create account          ─┐ if any step fails after Keycloak succeeded:
  3. Keycloak: assign realm roles       │   return 502 KEYCLOAK_SYNC_FAILED and write
  4. DB: insert users + user_roles      │   keycloak_id into audit_log so an operator
  5. DB: insert audit_log               ─┘   can clean up by hand. No automatic retry.
  6. return 201
```

### Flow B — Save a role's permissions (S3, S6)
```
admin-service:
  1. DB (one transaction): delete old api_permissions rows for this role, insert new ones, audit
  2. call gateway POST /api/permissions/sync-to-keycloak
       └► gateway reads api_permissions and creates/updates realm roles in Keycloak
  3. sync OK      → 200
     sync failed  → 502 KEYCLOAK_SYNC_FAILED, DB change stays saved;
                    caller retries with POST /roles/:id/sync
```
**Order rule.** A role's realm role must exist in Keycloak (step 2) before any user gets that role.

### Flow C — A console asks for the user's menus (S1)
```
console ──GET /admin/v1/me/menus──► gateway ──► admin-service
admin-service: roles from token → union of active menus across all roles
               → DETAIL items nested under their NAV parent → sorted by sort_order
```

### Flow D — Change roles / deactivate (S4, S5)
- **Change roles:** full new set in, service diffs it, assigns/removes only the changed realm
  roles in Keycloak, updates `user_roles`, writes audit `USER_ROLES_UPDATED`.
- **Deactivate:** disable the Keycloak account, set status INACTIVE, **keep** `user_roles`, audit
  `USER_DEACTIVATED`. No hard delete, ever.

---

## 7. Inside the service

**Stack:** Java 21, Spring Boot 3, Spring Web MVC (blocking; it's low-traffic CRUD), Spring Data
JPA + Flyway, OAuth2 Resource Server (JWKS), `keycloak-admin-client`, springdoc-openapi, Maven.

**Layers** (one request goes top to bottom):

```
security/    JWT filter → read roles from JWT_ROLES_CLAIM_PATH → find local user by sub → must be ACTIVE
controller/  HTTP only: parse request, call service, wrap response in the envelope
service/     the rules: ordering, diffs, guards (ROLE_IN_USE, SYSTEM_ROLE_IMMUTABLE), transactions
client/      KeycloakClient (wraps keycloak-admin-client), GatewaySyncClient (calls the gateway)
repository/  Spring Data JPA repositories
entity/      JPA entities for the 7 tables
audit/       AuditWriter: one append-only row per change
config/      security, OpenAPI, client beans
+ one @RestControllerAdvice that turns exceptions into the error codes above
```

Why `client/` is an interface: service tests can swap in a fake Keycloak and a fake gateway, so
we can test "Keycloak worked, DB failed" without a real Keycloak.

**Testing.** Service-layer tests with Keycloak and gateway clients mocked. Every mutating
endpoint has a test that asserts exactly one `audit_log` row.

---

## 8. Security

| Check | Where |
|---|---|
| JWT signature, issuer, audience, expiry | gateway **and** admin-service |
| Caller's role allowed for this method + URI | gateway (`api_permissions`) |
| Caller is a local user with status ACTIVE | admin-service only (catches deactivated users whose token hasn't expired) |
| Secrets | env vars only; nothing in the repo |
| Keycloak service account | least privilege: manage users + role mappings in one realm only |

`JWT_ISSUER`, `JWT_AUDIENCE`, `JWT_ROLES_CLAIM_PATH` must match the gateway's values for the same realm.

### Q&A: why does admin-service validate the JWT again?

Q: The gateway already validates the JWT, and the service isn't internet-facing. Why check it
again?

A: Because "the gateway already checked" only holds if every request goes through the gateway
and the gateway is configured correctly. There are four reasons to check again:

1. **Requests can bypass the gateway.** Anything else on the cluster network can call `:8085`
   directly: another pod, a compromised service, a `kubectl port-forward`, or a misrouted
   ingress. Without its own check, the service would accept anyone.
2. **A gateway misconfiguration fails open.** One wrong `api_permissions` row or a route added
   without auth would expose every admin endpoint. A second check limits the damage.
3. **The service needs an identity it can trust.** It uses `sub` to find the local user, run
   the ACTIVE check, and record the actor in `audit_log`. If the token isn't verified, anyone can
   forge a `sub` and then act as, or frame, any admin in the audit trail. On a compliance
   platform that is a correctness failure.
4. **The gateway can't see local status.** A user deactivated in admin-service still holds a
   valid token until it expires, and the gateway would let it through. The service's
   "local user exists and is ACTIVE" check (B-12) is what blocks them straight away.

---

## 9. Running it

### Locally (building and testing)

| Item | Value |
|---|---|
| Postgres + Keycloak | Local, via docker-compose (or reuse `extras/cce-local-setup`) |
| Service | `mvn spring-boot:run` on port 8085 |
| Trying it out | Swagger UI at `http://localhost:8085/swagger-ui.html`, or curl with a token from Keycloak |
| Keycloak realm | confidential service-account client for the service; a client to get test tokens from; one test SUPER_ADMIN |
| Gateway | Optional locally. Call the service directly. `GatewaySyncClient` can be a stub, or point at a local gateway-service to test the real sync |

### Deployed (dev first, other environments later)

| Item | Value |
|---|---|
| Image | Docker image of the service, port 8085 |
| k8s | Deployment + ClusterIP Service in `deploy-scripts` (not exposed directly; reached only through the gateway) |
| Gateway route | `/admin/**` → admin-service (already in the gateway's `application.yml` as `ADMIN_SERVICE_URI`) plus an ingress path so `/admin` reaches the gateway |
| Keycloak (per env) | Service-account client for the service; SUPER_ADMIN realm role + first admin user created by hand once |
| Config | DB, Keycloak, `JWT_*`, `GATEWAY_BASE_URL`, `BOOTSTRAP_ADMIN_USERNAME` from env vars / secrets; nothing env-specific in the repo |

### Seeding (SPEC D5)

| What | How |
|---|---|
| 12 menus, SUPER_ADMIN role, its `/admin/v1/**` rows | `db/migration/V2__seed.sql`, same in every environment |
| First admin user (`users` + `user_roles`) | Created by hand in that environment's Keycloak; on startup `BootstrapAdminRunner` looks it up by `BOOTSTRAP_ADMIN_USERNAME` and inserts the rows |

Not in this exercise: prod deployment, Jenkins pipeline.

---

## 10. Open questions and risks

Each of these becomes a decision (D1, D2, …) in `SPEC.md`, with a date and the evidence used.

| # | Item | Proposed answer / action |
|---|---|---|
| 1 | `api_permissions.id` is `BIGSERIAL` in the gateway, PRD says UUID PKs everywhere | Keep the gateway's shape exactly. |
| 2 | Who creates `api_permissions` — the gateway's own `V1__create_api_permissions_table.sql` or our Flyway? | Need one owner, otherwise two migrations fight over the same table. Decide before the schema sub-task. |
| 3 | Gateway sync returns **206** on partial failure (some roles failed), not only 500 | Treat anything except 200 as `KEYCLOAK_SYNC_FAILED`. |
| 4 | Gateway sync reports `deletedCount`: it may delete realm roles that have no `api_permissions` rows | A new role with zero permissions might never get (or might lose) its realm role. Check in `PermissionSyncService` before the permissions sub-task. |
| 5 | Bootstrap: first SUPER_ADMIN + its permission rows | Shared Flyway seed for the role; startup lookup in Keycloak for the admin user (see §9 and SPEC D5). |
| 6 | Every console role needs a permission row for `GET /admin/v1/me/menus` | Add it to the seed and to the role-create default. |
| 7 | `last_login_at` "updated by a callback" — not specified | Leave the column, don't fill it in v2 unless defined. |
| 8 | 502 cleanup is manual: an operator reads `audit_log` | Accepted. Covered by a test that asserts the audit row. |

---

## 11. Out of scope

- The admin UI (`cce-admin-ui`): separate repo, later
- Prod deployment and a Jenkins pipeline
- Changing `cce-insights-ui` to build its sidebar from `/me/menus`
- From the PRD, not in v2: audit log read endpoint · global permission catalog · enforcing
  `facility_scope` · deriving permissions from menus · hard delete of users
