# cce-admin-service — Spec (Decisions + Sub-tasks)

| | |
|---|---|
| **Status** | **v1, frozen 11 Nov 2026.** Every change from here is logged in §9 |
| Service | cce-admin-service (repo `cce-admin-service-poc`) |
| Port | 8085 |
| Tech stack | Java 21, Spring Boot 3.x, Spring Web MVC, Spring Data JPA, Flyway, PostgreSQL, OAuth2 Resource Server (JWKS), keycloak-admin-client, springdoc-openapi, Maven |
| Reference docs | `ARCHITECTURE.md` (this repo) · CCE v2 Admin Module PRD (29 Oct 2026) · `gateway-service/DATABASE_PERMISSIONS_MIGRATION.md` · `gateway-service/.../PermissionSyncController.java` |
| Scope | Backend only. Local only. UI is a separate repo, later. |

How to use this spec: each sub-task is one commit-ready increment, in dependency order. A
sub-task is done only when every acceptance criterion is ticked (with the test that proves it)
and any spec change is logged in §9.

---

## 1. Architecture summary (must understand before reading sub-tasks)

1. A role name never changes. The same string is `roles.name`, the Keycloak realm role and `api_permissions.permission_name` (D9, D11).
2. `api_permissions` has the gateway's shape. We create it only `IF NOT EXISTS` and never alter it; its `id` is BIGSERIAL (D1, D2).
3. `permission_name` means a job role. Rows that aren't ours (e.g. `COLLECTOR_EVENTS_WRITE`) are never read, changed or deleted (D11).
4. Gateway sync creates realm role definitions in Keycloak; this service creates users and assigns roles to them (D4; realm vs client roles is D13, OPEN).
5. Every role always has at least one permission row, `GET /admin/v1/me/menus`, so its realm role exists from the moment it is created (D4, D6).
6. No transaction spans DB + Keycloak/gateway. Keycloak calls run inside the open DB transaction, so a Keycloak failure rolls back → 502. Half-done states → ERROR log + audit row in its own transaction. Only create user is undone; nothing is retried (D3, D8).
7. The service validates the JWT itself and requires a local ACTIVE user. Which role may call which URL is the gateway's job (B-10, B-12, S3).
8. `/me` and `/me/menus` take the caller's roles from the DB, not the token (S12).
9. Role → menu is a soft control (what a console shows); role → permission is a hard control (what the gateway lets through). They are independent.
10. `PUT …/roles|menus|permissions` take the full new set; the service computes the diff. Same set as now = nothing written, no audit.
11. Every change writes exactly one `audit_log` row in the same transaction; failure records use their own transaction (B-50, S4).
12. Deactivation keeps `user_roles`; users are never hard-deleted. System roles can't be changed. A caller can't change their own status or roles (B-34, B-40, S7, S10).
13. First admin: shared Flyway seed for the SUPER_ADMIN role and permissions, plus a startup lookup in Keycloak by `BOOTSTRAP_ADMIN_USERNAME` (D5).
14. Every error uses `{error:{code,message}}`; unplanned errors → 500 with a reference id (D12).
15. `localhost` defaults live only in the `local` profile; no secrets in the repo (B-13).

---

## 2. Decisions

Format for each: **Status** (OPEN / RESOLVED date) · **Question** · **Evidence** · **Decision**
(or working default if open) · **Affects**.

### D1. `api_permissions` primary key type
- **Status:** RESOLVED 2026-11-06 (confirmation asked of lead, Q1 — not blocking)
- **Question:** PRD B-01 says UUID PKs for all 7 tables, including `api_permissions`. The gateway reads `id` as a `Long`. Which wins?
- **Evidence:**
  - PRD B-01 (§7.1): "all seven tables (… api_permissions …) with UUID PKs … per the data dictionary"
  - PRD §5: "Check gateway-service's own migration doc before altering that table; a mismatch breaks a service this team does not own"
  - PRD §12: "api_permissions shape is owned by gateway-service's consumer. Confirm against its migration doc"
  - `gateway-service/.../model/ApiPermission.java`: `@Id private Long id;`
  - `gateway-service/.../repository/ApiPermissionRepository.java`: `ReactiveCrudRepository<ApiPermission, Long>`
  - `gateway-service/DATABASE_PERMISSIONS_MIGRATION.md` and `deploy-scripts/k8s/seeds/api_permissions.sql`: `id` is a number (`BIGSERIAL` / `bigint` + sequence)
  - Data dictionary: not seen
- **Decision:** `api_permissions.id` is `BIGSERIAL` in the DB and `Long` in our JPA entity, matching the gateway. A UUID would break the gateway when it loads permissions (startup and sync). The other 6 tables use UUID as in B-01. No foreign key joins `api_permissions` by id; it is linked to `roles` by name (D11), so mixing types is safe. The PRD contradicts itself here (B-01 vs §5/§12); we follow §5/§12.
- **Affects:** S2 (migration), S11 (entity)

### D2. Who creates the `api_permissions` table
- **Status:** RESOLVED 2026-11-06
- **Question:** The table "already exists" on servers. Does our Flyway also create it?
- **Evidence:**
  - gateway-service only reads the table: no Flyway, no `src/main/resources/db/` folder. Its doc refers to `V1__create_api_permissions_table.sql`, which is not in the repo.
  - On servers it is created **by hand**: `deploy-scripts/k8s/seeds/api_permissions.sql` (`CREATE TABLE IF NOT EXISTS`, run via `docker exec … psql -d ccedb`).
  - On a fresh database nothing creates it, but PRD B-01 requires "Fresh database migrates cleanly".
- **Decision:** Our `V1__schema.sql` creates `api_permissions` with `CREATE TABLE IF NOT EXISTS`, in the gateway's shape (number `id`, per D1). Fresh DB → created; existing table → skipped, nothing changes. Column widths copy the deploy seed, since that is what runs on servers: `permission_name VARCHAR(255)`, `http_method VARCHAR(10)`, `uri_pattern VARCHAR(512)`, `description TEXT`, `resource_category VARCHAR(255)`, `created_at` / `updated_at`.
- **Notes:** The gateway doc and the deploy seed differ (widths 100/255 vs 255/512; only the doc has `UNIQUE (permission_name, http_method, uri_pattern)`). On servers the table is in database `ccedb`; the PRD and this POC use `admin_service`.
- **Affects:** S2

### D3. Gateway sync response handling
- **Status:** RESOLVED 2026-11-06
- **Question:** The PRD says "sync failure → 502 KEYCLOAK_SYNC_FAILED" but never defines what counts as a failure. Which gateway replies are success, which are failure, and how does the caller learn what went wrong?
- **Evidence:**
  - From the PRD:
    - B-42: "gateway sync called automatically afterwards"
    - B-43: "Sync failure → 502 KEYCLOAK_SYNC_FAILED; DB changes remain saved"
    - §10 (B4 notes): "If sync fails, keep the DB change and return 502"
    - Appendix B: 502 = "Keycloak or gateway sync failed; state partially applied"
    - B-03: error body is `{error:{code,message}}`
  - From the gateway code (`PermissionSyncController.syncToKeycloak()`, `PermissionSyncServiceImpl.syncPermissionsToKeycloak()`):
    - **200** `success:true`: all done.
    - **206** `success:false` + `failedRoles`: rules reloaded into gateway memory, but some Keycloak roles failed. Memory is reloaded *before* the Keycloak step.
    - **500** `success:false` + `message`: an exception (DB read or Keycloak).
    - **200** "No permissions found in database": table empty, nothing reloaded. Can't happen while the SUPER_ADMIN seed rows exist (D5).
  - Sync is **global**: it reads all rows (`findAllOrdered()`), so a 206 may come from a different role.
  - The endpoint has **no auth**. The gateway has no Spring Security, and `JwtValidationFilter` is attached only to the `/admin/**` route (`application.yml`).
  - Not in any doc: gateway down or timeout. Every HTTP call must handle these.
- **Decision** (fills a PRD gap):
  - **200 with `success:true`** → success, our service returns 200.
  - **Anything else** (206, 500, any other status, connection refused, timeout) → **502 `KEYCLOAK_SYNC_FAILED`**. The DB change stays saved. The caller retries with `POST /roles/:id/sync`.
  - **Error message is case-specific** and always starts with "Permissions saved." so the caller knows only the sync needs retrying:
    - 206: `Permissions saved. Gateway reloaded its rules, but Keycloak role sync failed for: <failedRoles>. Retry with POST /admin/v1/roles/{id}/sync.`
    - 500 / other status: `Permissions saved. Gateway sync error: <gateway message>. Retry with …/sync.`
    - Unreachable: `Permissions saved. Gateway not reachable at <url>. Retry with …/sync.`
    - Timeout: `Permissions saved. Gateway did not answer within 10s. Retry with …/sync.`
  - **Error body shape unchanged** (`{error:{code,message}}`, B-03). Details go in `message`; no extra `details` field.
  - **Logging:** on every failure, log WARN with role id, URL called, gateway status and the full gateway response body. The root cause of a gateway 500 is in the gateway's own logs.
  - **Timeout:** 10 seconds (our choice).
  - **Gateway address:** config `GATEWAY_BASE_URL`, default `http://localhost:8090` (port from `deploy-scripts/k8s/base/ingress.yaml`). The default lives only in `application-local.yml`; elsewhere the variable is required (B-13; changed 2026-11-11 with the S3 review).
  - **No auth header** on the call, since the endpoint has none.
- **Notes:** Treating 206 as success when our own role isn't in `failedRoles` was considered and rejected; it's extra logic for a rare case. The unauthenticated sync endpoint is a gateway observation, not ours to fix.
- **Affects:** S11

### D4. Every role must always have at least one `api_permissions` row
- **Status:** RESOLVED 2026-11-06
- **Question:** Sync reports `deletedCount`. Can a role with zero permissions lose (or never get) its Keycloak realm role? If so, how do we make sure a role exists in Keycloak before it's assigned to a user?
- **Evidence:**
  - From the gateway code (`KeycloakAdminServiceImpl.syncRolesToKeycloak()` and `deleteRolesNotInDatabase()`), every sync runs two steps:
    1. Create or update a realm role for each distinct `permission_name` in `api_permissions`.
    2. Delete every realm role that is not a `permission_name` in `api_permissions`. Keycloak built-ins are skipped: `default-roles-*`, `offline_*`, `uma_*`.
  - So after every sync, Keycloak realm roles = the distinct `permission_name`s with at least one row, plus the built-ins.
  - PRD §9: "A role's realm role must exist in Keycloak (gateway sync) before it is assigned to any user". The PRD does not say how to guarantee this.
  - Deleting a realm role in Keycloak removes it from every user who held it.
- **What breaks without a rule:**
  1. A role created with no permissions is never in Keycloak. Creating a user with it fails at "assign realm role" → 502 and an orphan Keycloak account (B-32).
  2. Saving an empty permission list deletes the realm role on the next sync. It is silently stripped from all its users in Keycloak while `user_roles` still lists it.
- **Options considered:**
  - A. Every role always has at least one permission row (chosen).
  - B. Check before assigning a role to a user (fixes 1, not 2; needs a new error code).
  - C. Our service creates the realm role directly. Rejected: the PRD makes the gateway the owner, and the next sync would delete a role that has no rows anyway.
- **Decision:**
  - `POST /roles` inserts the role **and** a default row (`<ROLE> GET /admin/v1/me/menus`) in one transaction, then calls gateway sync, so the role exists in Keycloak from the start. Sync failure → 502 per D3; role stays saved; retry with `POST /roles/:id/sync`.
  - `PUT /roles/:id/permissions` with an empty list → 400 `VALIDATION_ERROR`.
  - `DELETE /roles/:id`: details to be decided in D10.
  - Only these three role actions write `api_permissions`. User, menu, role-menu and user-role actions never do.
- **Observation (not ours to fix):** any realm role not in `api_permissions` is deleted on every sync, including roles created by hand in Keycloak or by another app on the same realm.
- **Affects:** S6, S8, S11 · related, still to discuss: D6, D10

### D5. Bootstrap admin
- **Status:** RESOLVED 2026-11-06
- **Question:** The admin APIs need a logged-in, ACTIVE SUPER_ADMIN, so the first one can't be created through the API. How do the first SUPER_ADMIN and its `/admin/v1/**` permission rows get created?
- **What must exist before the first API call:**
  - **Keycloak:** realm, realm role `SUPER_ADMIN`, user `superadmin` with that role, a service-account client for our service (Keycloak Admin API), a client for getting test tokens.
  - **Our DB:** `roles` SUPER_ADMIN (`is_system`), its `api_permissions` rows for `/admin/v1/**`, `users` row with `keycloak_id` = the Keycloak user's id, `user_roles` row. The ids must match or B-12 returns 403.
- **Evidence:**
  - PRD §12 "Bootstrap admin": "Decide how this is seeded per environment"
  - `extras/cce-local-setup`: no Keycloak, no gateway
  - `deploy-scripts/k8s/seeds/cce-realm.json`: realm `cce` with gateway clients, no human users, no SUPER_ADMIN
  - `deploy-scripts/k8s/seeds/api_permissions.sql`: no `/admin/v1/**` rows
- **Options considered:**
  - A. Seed files: Keycloak realm JSON with a fixed user id + Flyway rows with the same id (system data in `V2`, test user in a local-only Flyway folder).
  - B. A bootstrap script using the Keycloak API + `psql`.
  - C. Startup code in the service that creates the admin if `users` is empty.
  - D. Per-environment Flyway seed folders (`db/seed/${APP_ENV}/`) with the admin's Keycloak id pasted into an env var. Considered and replaced the same day: copying the id by hand is error-prone (a typo → 403 for the admin), and every environment needs its own folder.
  - E. Startup lookup by username (chosen).
- **Assumption:** the service will be deployed to dev, and possibly other environments later.
- **Decision: shared seed for the role, startup lookup for the admin user.**

  **Flow (once per environment):**
  ```
  1. Person    → Keycloak admin console: create user "superadmin", give realm role SUPER_ADMIN, set password
  2. Person    → server config: BOOTSTRAP_ADMIN_USERNAME=superadmin
  3. Service starts
       → Flyway V1: 7 tables
       → Flyway V2: 12 menus, SUPER_ADMIN role, its /admin/v1/** rows
       → BootstrapAdminRunner: asks Keycloak "who is superadmin?" → gets id + email
       → inserts users + user_roles + audit row
  4. superadmin logs in → can use the admin API
  ```

  **Part 1: same in every environment (Flyway, `db/migration/V2__seed.sql`)**
  - 12 menus (B-02)
  - `roles`: SUPER_ADMIN, `is_system = true`
  - `api_permissions`: SUPER_ADMIN × GET/POST/PUT/PATCH/DELETE `/admin/v1/**`

  **Part 2: the admin user (Java, `BootstrapAdminRunner`, runs after Flyway on every start)**
  1. `BOOTSTRAP_ADMIN_USERNAME` not set → do nothing.
  2. A `users` row with that username already exists → do nothing (already linked on an earlier start).
  3. Ask Keycloak (Admin API, exact username match) for the user:
     - Keycloak unreachable or user not found → log ERROR (`create <username> in Keycloak first`), do nothing, **keep running**.
     - Found but missing realm role `SUPER_ADMIN` → log ERROR, do nothing, keep running.
     - Found with the role → continue.
  4. In one transaction, insert the `users` row (`keycloak_id` = Keycloak's id, username, email, ACTIVE), its `user_roles` row (→ SUPER_ADMIN) and an audit row (actor `SYSTEM`, action `BOOTSTRAP_ADMIN_LINKED`).
  5. Log INFO `bootstrap admin <username> linked`.

  - **Config:** only `BOOTSTRAP_ADMIN_USERNAME`. No id, email or password in config or in the repo.
  - **On failure, keep running:** one missing admin shouldn't take the service down. The fix is to create the user in Keycloak and restart the service.
  - **Safe to leave set:** after the first successful link, step 2 skips on every later start.
  - **New environment:** repeat steps 1–2 of the flow with that environment's Keycloak. No new files, no code change.
- **Why split this way:** the role and its permissions are the same everywhere, so they belong in the shared Flyway seed. The admin user is different per environment, and Flyway SQL can't call Keycloak to find its id, so it needs a small piece of Java.
- **Affects:** S0, S2, deployment · adds sub-task S2a (BootstrapAdminRunner). S2a builds the `KeycloakClient` with only the two lookups it needs; S8 extends the same client (settled 2026-11-10).

### D6. Permission row for `GET /admin/v1/me/menus`
- **Status:** RESOLVED 2026-11-06
- **Question:** Every console role needs permission to call `GET /admin/v1/me/menus`, or the gateway returns 403 and `cce-insights-ui` can't load its sidebar. Who adds that row, and what if an admin later removes it?
- **Evidence:**
  - PRD §12 "Bootstrap of /me/menus": "Every console user's role needs a permission row for GET /admin/v1/me/menus, or cce-insights-ui cannot load its sidebar"
  - D4 (auto-added on role create) · D5 (SUPER_ADMIN seed rows)
- **Note — permission ≠ menus:** this row only lets a role *ask* `/me/menus`. It grants no screens. Screens come only from `role_menus` (`PUT /roles/:id/menus`).
- **Decision:**

  | Case | Behaviour |
  |---|---|
  | SUPER_ADMIN | Covered by its `GET /admin/v1/**` seed row (D5) |
  | New role | `POST /roles` auto-adds `GET /admin/v1/me/menus` (D4). This is the only default row; `GET /admin/v1/me` is not added (the PRD names only `/me/menus`) |
  | New role, no menus ticked yet | Expected: `/me/menus` returns `200` with `data: []`, so the sidebar is empty. Not an error. Showing a "no access yet" message is the console's job |
  | `PUT /roles/:id/permissions` list without it | **Rejected with 400** (option b). Nothing is changed |

- **Rule for the check (in `PUT /roles/:id/permissions`, after the empty-list check from D4):**
  - The list must contain at least one row with method `GET` whose `uriPattern` matches the path `/admin/v1/me/menus`.
  - Matching uses Ant-style patterns (`AntPathMatcher`), the same way the gateway matches. So `/admin/v1/me/menus`, `/admin/v1/me/*` and `/admin/v1/**` all count.
  - If no row matches, return 400 before touching the DB:
    - no rows deleted or inserted
    - no audit row (nothing changed)
    - no gateway sync

- **Response (body shape per B-03):**
  ```
  HTTP/1.1 400 Bad Request
  Content-Type: application/json

  {
    "error": {
      "code": "VALIDATION_ERROR",
      "message": "Every role must keep GET /admin/v1/me/menus, or its users cannot load their sidebar. Add it back to the list and save again. Nothing was changed."
    }
  }
  ```
- **Options considered:**
  - a. Allow it. Rejected: one forgotten row silently breaks the sidebar for every user of the role.
  - b. Reject with 400. **Chosen.**
  - c. Re-add it silently. Rejected: confusing ("I removed it and it came back").
- **Affects:** S2, S6, S11, S12

### D7. `last_login_at`: taken from the token's `auth_time`
- **Status:** RESOLVED 2026-11-06
- **Question:** `users.last_login_at` should hold when the user last logged in (shown on the Users list, F-10). Login happens in Keycloak, not in our service, so how does the column get filled?
- **Evidence:**
  - PRD §12: "Doc says it is updated by a lightweight callback. The mechanism is not yet specified."
  - PRD F-10: Users list shows "last login"
  - Keycloak tokens carry `auth_time`, the moment the user entered their credentials. To verify in S3 against a real token.
  - Our security filter already loads the local user on every request (B-12, S3).
  - `cce-insights-ui` calls `/me/menus` on every load, so every console user reaches our service after logging in.
- **Options considered:**
  - A. Leave it empty. Rejected: F-10's "last login" column would be useless.
  - **B. Read it from the token. Chosen.**
  - C. Keycloak event-listener plugin that calls us on login. Rejected: Java code deployed inside Keycloak in every environment.
  - D. Ask Keycloak's events/sessions API when listing users. Rejected: one Keycloak call per user per page, and Keycloak must be set to store login events.
- **Decision:**
  - In the security filter (S3), after the user is found and confirmed ACTIVE: if the token's `auth_time` is newer than `users.last_login_at` (or it is null), update `last_login_at` to `auth_time`.
  - **One write per login.** Later requests carry the same `auth_time`, so they only compare and never write.
  - **Never blocks the request:** if the update fails, log WARN and continue with the request.
  - **No audit row:** it is bookkeeping, not an admin change.
  - **If the token has no `auth_time`:** leave `last_login_at` unchanged and log once at startup/first request. Do **not** fall back to `iat`: `iat` changes on every token refresh (every few minutes), so it would record "last activity", not "last login".
- **Known limit:** a user who logs in but never reaches our service (no call to any `/admin/v1/**` endpoint) is not recorded. In practice every console load calls `/me/menus`.
- **Affects:** S3 (filter), S9 (`GET /users` returns `lastLoginAt`)

### D8. Partial failures across Keycloak and the DB: record reliably, undo once for create user
- **Status:** RESOLVED 2026-11-06 (one point asked of lead, Q2 — not blocking)
- **Question:** Some actions change both Keycloak and our DB, with no transaction spanning both. When one side succeeds and the other fails (502 `KEYCLOAK_SYNC_FAILED`), how is it recorded, and who fixes it?
- **Evidence:**
  - PRD B-32: "Returns 502 KEYCLOAK_SYNC_FAILED; keycloak_id recorded in audit_log for manual reconciliation"
  - PRD §9: "partial state is surfaced as 502 and recorded for reconciliation rather than blindly retried"
  - PRD §12: "502 partial states rely on an operator reading audit_log. There is no UI for this in CCE v2."
  - Gap: `audit_log` is in the same DB. If the DB step fails, the main transaction rolls back and takes any audit row in it along, so audit alone can lose the record.
- **Actions that can end half-done:**

  | Action | Sub-task | Half-done result |
  |---|---|---|
  | Create user | S8 | Orphan Keycloak account unknown to our DB |
  | Update profile (added 2026-11-11, S9) | S9 | Keycloak has the new name/email, DB commit failed. Only if the commit fails after Keycloak succeeded: Keycloak is called inside the open DB transaction, so a Keycloak failure rolls the DB back and nothing changes |
  | Change status | S10 | Keycloak enabled/disabled, `users.status` not updated (or the reverse) |
  | Change user's roles | S10 | Some realm roles changed in Keycloak, `user_roles` unchanged |
  | Save permissions | S11 | Not manual: retry with `POST /roles/:id/sync` (D3) |
  | Reset password | S10 | Nothing to reconcile (Keycloak only + audit) |

- **Options considered:**
  - A. PRD as written, made reliable (log + separate-transaction audit).
  - **B. A, plus one undo attempt for create user. Chosen.**
  - C. Background job comparing Keycloak and DB. Rejected: big, out of scope for v2.
- **Decision:**
  1. **Recording (every two-system action above):**
     - **ERROR log, always:** action, target user (id/username), `keycloak_id`, which step failed, the error, and the cleanup result. Written even if the DB is down.
     - **Audit row, best effort, in its own transaction** (`REQUIRES_NEW`), so it survives the main rollback. Actions: `USER_CREATE_FAILED`, `USER_UPDATE_FAILED` (added 2026-11-11, S9), `USER_STATUS_UPDATE_FAILED`, `USER_ROLES_UPDATE_FAILED`. `after` JSON holds `keycloakId`, `failedStep`, `error`, `cleanup`. If this write also fails, the ERROR log is the record.
     - **Response:** 502 `KEYCLOAK_SYNC_FAILED`, message says what is done and what isn't.
  2. **Undo once, for create user only:**
     - If any step after "Keycloak: create account" fails, try **once** to delete the Keycloak account just created.
     - Deleted → nothing left behind; `cleanup: "keycloak user deleted"`.
     - Delete failed → `cleanup: "FAILED — delete keycloak user <id> by hand"`; manual fix needed.
     - **Why only here:** the account is seconds old and unused, so deleting it is safe. Reverting a status or role change could overwrite something that changed meanwhile, so those stay manual.
  3. **Manual fix:** a person finds failures via the ERROR log or `SELECT … FROM audit_log WHERE action LIKE '%_FAILED'`, then fixes Keycloak or the DB by hand. No UI in v2 (PRD §12).
- **Messages (body shape per B-03):**

  | Case | `message` |
  |---|---|
  | Create user, undo worked | `User was not created. The Keycloak account was created but saving the user failed; it has been removed again. Nothing was changed. Try again.` |
  | Create user, undo failed | `User was not created. The Keycloak account <keycloakId> was created but could not be removed. An operator must delete it in Keycloak before retrying with the same username/email.` |
  | Update profile, Keycloak failed (added 2026-11-11) | `Profile not changed. Keycloak error: <reason>. Nothing was changed.` |
  | Update profile, commit failed after Keycloak (added 2026-11-11) | `Profile only partly applied: Keycloak has the new values, the user record does not. An operator must fix it.` |
  | Change status | `Status change only partly applied: <which side succeeded>. Keycloak and the user record now differ; an operator must fix it.` |
  | Change roles | `Role change only partly applied in Keycloak. Keycloak and the user record now differ; an operator must fix it.` |

- **Deviation from PRD:** the undo for create user is not in the PRD. The PRD says "not retried"; undo reverses our own just-made step rather than retrying, but it changes the described behaviour, so it's logged as Q2.
- **Affects:** S4 (audit writer needs a separate-transaction method), S8, S9 (update profile, added 2026-11-11), S10

### D9. Role `name` in `PUT /roles/:id`: same is allowed, different is rejected
- **Status:** RESOLVED 2026-11-06
- **Question:** `PUT /roles/:id` edits only `displayName` and `description`. If the body also contains `name`, do we ignore it or reject it?
- **Evidence:**
  - PRD B-40: "name immutable; only displayName/description editable"; "Modify or delete of an is_system role" → 409 `SYSTEM_ROLE_IMMUTABLE`
  - PRD §4 "One identifier, three systems": `roles.name` = Keycloak realm role = `api_permissions.permission_name`. Renaming only our row would cut the role off from Keycloak and the gateway.
  - PRD Appendix B: no dedicated "rename" error code
- **Options considered:**
  - a. Always ignore `name`. Rejected: a rename attempt returns 200 and the caller wrongly believes it worked.
  - b. Reject whenever `name` is present. Rejected: breaks harmless callers that send the whole role object back.
  - **c. Allow the same name, reject a different one. Chosen.**
- **Decision:**

  | Body | Result |
  |---|---|
  | no `name` | allowed |
  | `name` equal to the current name | allowed (ignored) |
  | `name` different from the current name | 400 `VALIDATION_ERROR` |
  | other unknown fields | ignored (Spring default) |

- **Check order** (first failure stops; nothing is written until all checks pass):
  ```
  0a. Token valid?            no  → 401 UNAUTHENTICATED       (security filter, S3)
  0b. Caller ACTIVE user?     no  → 403 FORBIDDEN             (security filter, S3)
  0c. Body well-formed?       no  → 400 VALIDATION_ERROR      (Spring bean validation)
   1. Role exists?            no  → 404 ROLE_NOT_FOUND
   2. System role?            yes → 409 SYSTEM_ROLE_IMMUTABLE (any change, even displayName)
   3. Name differs?           yes → 400 VALIDATION_ERROR
   4. Save + audit                → 200 with the updated role
  ```
  - **System before name:** a request renaming SUPER_ADMIN gets 409 ("nothing may change"), not a misleading 400 that implies the display name could be edited.
  - **Reads before writes:** steps 1–3 only read. Step 4 updates `roles` and writes an audit row (`ROLE_UPDATED`, before/after) in one transaction. No Keycloak call, no gateway sync: display fields live only in our table.
- **Response for a rename attempt (body shape per B-03):**
  ```
  HTTP/1.1 400 Bad Request
  Content-Type: application/json

  {
    "error": {
      "code": "VALIDATION_ERROR",
      "message": "Role name cannot be changed (it is used in Keycloak and the gateway). Only displayName and description can be edited. To use a different name, create a new role. Nothing was changed."
    }
  }
  ```
- **Affects:** S6

### D10. Deleting a role
- **Status:** RESOLVED 2026-11-06
- **Question:** `DELETE /roles/:id` is allowed only when the role is not in use and not a system role. What happens to the role's `role_menus` and `api_permissions` rows, how does Keycloak get cleaned up, and what if that cleanup fails?
- **Evidence:**
  - PRD B-40: delete blocked with 409 `ROLE_IN_USE` or `SYSTEM_ROLE_IMMUTABLE`, "checked in service layer, not via FK error"
  - PRD B-34: INACTIVE keeps `user_roles` rows so re-activating restores access
  - D4: the gateway creates a realm role for every `permission_name` it finds and deletes realm roles with no rows. Leftover rows would keep the role alive in Keycloak.
  - D3: sync is global; the gateway reloads its memory *before* the Keycloak step
- **Decision — steps:**
  ```
  Checks (read only, first failure stops):
   1. Role exists?                              no  → 404 ROLE_NOT_FOUND
   2. System role?                              yes → 409 SYSTEM_ROLE_IMMUTABLE
   3. Any user_roles rows for this role         yes → 409 ROLE_IN_USE
      (ACTIVE, INACTIVE or LOCKED users)?

  Write (one DB transaction):
   4. delete role_menus      where role_id = :id
   5. delete api_permissions where permission_name = role.name
   6. delete roles           where id = :id
   7. insert audit_log       ROLE_DELETED, before = the role + its menus + its permissions

  After commit:
   8. call gateway sync → gateway finds no rows for the role → deletes the realm role in Keycloak
   9. sync OK → 204 No Content
  ```
- **INACTIVE users count as "in use":** their `user_roles` rows are kept for re-activation (B-34), so deleting the role would silently shrink what they get back. The admin must first remove the role from those users.
- **If the sync in step 8 fails:** return 502 `KEYCLOAK_SYNC_FAILED` (D3); the delete stays committed.
  - The usual retry `POST /roles/:id/sync` can't be used: the role no longer exists (404).
  - Keycloak is cleaned up by the **next successful sync of any role** (sync is global).
  - Message: `Role deleted. Keycloak still has realm role <NAME> until the next successful sync of any role. No user in this service holds it.`
  - Options considered:
    - **a. Wait for the next sync. Chosen.**
    - b. A new `POST /admin/v1/sync` endpoint. Rejected: not in the PRD.
    - c. Undo the delete. Rejected: messy, and the PRD keeps DB changes when sync fails.
- **Edge case (accepted):** step 3 only sees users in our DB. Keycloak-only users (D8 orphans, users created by hand in Keycloak) may still hold the role. If sync failed with 206/500, the gateway has already reloaded without the role's rules, so they get 403. If the gateway was unreachable, it keeps the old rules until its next reload, so such a user keeps the role's access until then. Rare, short-lived, and cleared by the next successful sync. Our own APIs reject them anyway (not in `users`, B-12).
- **Affects:** S6, S11

### D11. Meaning of `permission_name`: job role, not capability
- **Status:** RESOLVED 2026-11-10
- **Question:** The gateway's doc and the server seed use `permission_name` as a capability (`USER_READ`, `COLLECTOR_EVENTS_WRITE`); a holder collects many. The PRD uses it as a job role (`FACILITY_ADMIN`); a person has one or a few. Which do we follow, and how do we live alongside rows of the other kind?
- **Evidence:**
  - `gateway-service/DATABASE_PERMISSIONS_MIGRATION.md`: sample rows `USER_READ`, `USER_CREATE_UPDATE`
  - `deploy-scripts/k8s/seeds/api_permissions.sql` + `README.md`: servers already hold machine capability rows such as `COLLECTOR_EVENTS_WRITE` (used by the OpenHIM adaptor's service account), with no matching role in our `roles` table
  - PRD §4 "One identifier, three systems" and B-42 (`permission_name = roles.name`)
  - PRD F-13/F-14: one Role Detail screen sets a job role's menus and permissions
  - `AuthorizationService.isAuthorized()`: only compares the token's roles with `permission_name`, so the gateway works with either kind
- **Decision:**
  1. **`permission_name = roles.name` (job role).** Our service always takes it from the role in the URL (`/roles/:id/...` → that role's name), never from the request body. If two roles need the same URL, each gets its own row.
  2. **Rows that aren't ours are left alone.** A row whose `permission_name` is not a name in our `roles` table (e.g. `COLLECTOR_EVENTS_WRITE`) is never read, changed or deleted by our service, and is not shown by `GET /roles`. Safe because:
     - `PUT /roles/:id/permissions` and `DELETE /roles/:id` only touch rows `WHERE permission_name = <that role's name>`.
     - Gateway sync keeps every name that has rows (D4).
  3. **No name clashes.** `POST /roles` rejects a name that already appears as a `permission_name` in `api_permissions`, so a new role can't take over and later replace another set's rows. Response (body shape per B-03):
     ```
     HTTP/1.1 409 Conflict
     Content-Type: application/json

     {
       "error": {
         "code": "DUPLICATE_ROLE_NAME",
         "message": "This name is already used by an existing permission set in the gateway. Choose another name."
       }
     }
     ```
- **Affects:** S6 (create-role check), S11

### D12. Unplanned errors: always the PRD envelope, 500 with a reference id
- **Status:** RESOLVED 2026-11-10
- **Question:** PRD Appendix B lists codes for errors we expect (400, 401, 403, 404, 409, 502). What does the caller get for errors nobody planned (DB down, a bug, an unknown URL, broken JSON)?
- **Evidence:**
  - PRD Appendix B: no code for unplanned server errors
  - PRD B-03: every error body is `{error:{code,message}}`
  - Spring's default error body is `{timestamp,status,error,path}`, which breaks B-03 unless we catch it
- **Decision:**
  1. **One global handler** (`@RestControllerAdvice`, S1) catches every exception, including Spring's own, and returns the B-03 envelope. No Spring default error body ever reaches a caller.
  2. **Mapping:**

     | Situation | HTTP | `code` |
     |---|---|---|
     | Broken JSON, wrong field type, failed bean validation | 400 | `VALIDATION_ERROR` |
     | Unknown URL (e.g. `/admin/v1/rolez`) | 404 | `NOT_FOUND` (new) |
     | Wrong method for a URL | 405 | `METHOD_NOT_ALLOWED` (new) |
     | Body is not JSON (`Content-Type`) | 415 | `UNSUPPORTED_MEDIA_TYPE` (new) |
     | Keycloak or gateway call failed, including single-system calls like reset password | 502 | `KEYCLOAK_SYNC_FAILED` (D3, D8) |
     | Anything else (DB down, bug) | 500 | `INTERNAL_ERROR` (new) |

  3. **The real error never goes to the caller.** No exception text, SQL, stack trace, host or class name in `message`. It is logged in full instead.
  4. **Reference id links the two.** For each 500, generate a short random id. Put it in the message and on the ERROR log line with the full exception.
     ```
     HTTP/1.1 500 Internal Server Error
     Content-Type: application/json

     {
       "error": {
         "code": "INTERNAL_ERROR",
         "message": "Something went wrong on our side. The change in this request was not saved. Try again; if it keeps failing, report reference 7f3a9c2e."
       }
     }
     ```
     ```
     ERROR [ref=7f3a9c2e] PUT /admin/v1/roles/r-2/permissions failed
           <full exception and stack trace>
     ```
     The reference goes inside `message`, not in a separate field, so the B-03 shape is unchanged (same choice as D3).
  5. **"Was not saved" holds because:** DB work in each request is one transaction (rolled back on failure), and every step that reaches Keycloak or the gateway is caught as 502 by D3/D8. A 500 only comes from a failure before anything outside the DB changed.
  6. **Expected errors keep their own messages.** Errors we raise on purpose (e.g. D6, D9, D11) already explain the problem in words we control, so they carry no reference id.
- **Deviation from PRD:** four codes not in Appendix B (`NOT_FOUND`, `METHOD_NOT_ALLOWED`, `UNSUPPORTED_MEDIA_TYPE`, `INTERNAL_ERROR`). Added because reusing PRD codes for these would be wrong (e.g. `ROLE_NOT_FOUND` for an unknown URL).
- **Affects:** S1 (global handler), every endpoint sub-task

### D13. Realm roles or client roles
- **Status:** OPEN (Q4 for the lead — blocks nothing now: the dev deploy was dropped on 2026-11-11 and the showcase is local; it matters only when the service goes to a server) · working default below
- **Question:** The PRD and our design use Keycloak **realm** roles (token claim `realm_access.roles`). The deployed gateway reads **client** roles of the `gateway-service` client. Which one does admin-service use on servers?
- **Evidence:**
  - PRD B-11: `JWT_ROLES_CLAIM_PATH` default `realm_access.roles`
  - Gateway sync creates **realm** roles: `gateway-service/.../service/impl/KeycloakAdminServiceImpl.java:135` (`realmResource.roles()`)
  - Gateway default claim path `realm_access.roles`: `gateway-service/src/main/resources/application.yml:54`
  - Deployed gateway: `deploy-scripts/k8s/base/services/gateway-service.yaml:77-78` sets `JWT_ROLES_CLAIM_PATH=resource_access.gateway-service.roles`, and `JWT_AUDIENCE=gateway-service`
  - Server realm `deploy-scripts/k8s/seeds/cce-realm.json`: no custom realm roles; `COLLECTOR_EVENTS_WRITE`, `INSIGHTS_READ`, `COMPLIANCE_READ`, … are client roles of `gateway-service`, used e.g. by the OpenHIM adaptor
- **Problem on dev:** sync creates a realm role and S8 assigns that realm role, but the deployed gateway only reads client roles, so it never sees ours: every user we create gets 403 at the gateway. Switching the deployed gateway to `realm_access.roles` would break other teams' machine clients that rely on client roles. Not ours to decide.
- **Working default:** realm roles, as per the PRD, for everything built and tested locally (S0–S13). `JWT_ROLES_CLAIM_PATH` stays configurable (S3), so only config changes if the answer is "realm roles everywhere".
- **When answered:** update this entry to RESOLVED; if the answer is client roles, the change needs gateway code (sync and role assignment) and gets logged in §9.
- **Affects:** S0 (realm file), S2a (role check), S3 (claim path), S8, S10, any future server deploy

### D14. Data dictionary not available: schema columns and the 12 menus
- **Status:** OPEN (asked of lead, Q3 — not blocking) · working default below
- **Question:** PRD B-01 and B-02 say the tables and the 12-menu seed must match "the data dictionary" exactly. We don't have that document. What do we build from until it arrives?
- **Evidence:**
  - PRD B-01: "with UUID PKs and timestamps per the data dictionary … indexes listed in the data dictionary exist"
  - PRD B-02: "Seed matches the data-dictionary table exactly, including Patients as its own top-level NAV and the two DETAIL entries"
  - PRD §11: "Write V1__schema.sql straight from the data dictionary … Have a reviewer diff your columns against the doc"
  - Not found in the PRD PDF, `~/Downloads`, `cce-admin/` or any repo in `medtronics/` (D1 already notes "Data dictionary: not seen")
  - Column names only: ARCHITECTURE.md §4
  - `cce-insights-ui` (branches `demo-dev`, `demo-tiberbu`): 10 sidebar items in `src/components/layout/Sidebar.tsx:15-24`; drill-down routes in `src/App.tsx:52,54,57` — 3 candidates for the PRD's 2 DETAIL entries
- **Working default:**
  - **Columns:** our own list, written column by column in S2 (names from ARCHITECTURE.md §4; `api_permissions` per D1/D2).
  - **Menus:** 10 NAV from `Sidebar.tsx` (Dashboard `/`, Compliance `/compliance`, Facilities `/facilities`, Practitioners `/practitioners`, Deviations `/deviations`, Patients `/compliance/patients`, Intelligence `/intelligence`, Events `/events`, Ingestion `/ingestion`, Exports `/exports`) + 2 DETAIL = the two `:id` drill-downs: protocol analytics `/compliance/protocols/:id` (parent Compliance) and patient detail `/compliance/patients/:id` (parent Patients). `/events/source-comparison` is not seeded.
- **When the dictionary arrives:** diff it against S2, update S2 (and this entry to RESOLVED), log the change in §9.
- **Affects:** S2; menus also S5, S7, S12

---

## 3. Questions for the lead

Only things I could not work out myself.

| # | Date asked | Question | Blocking? | Answer |
|---|---|---|---|---|
| Q1 | to ask | PRD B-01 says UUID for `api_permissions`, the gateway reads `Long`; I went with `Long` — ok? (D1) | No — proceeding with `Long` | |
| Q2 | to ask | PRD B-32 says record partial user-create failures for manual cleanup. I added one undo attempt (delete the Keycloak account we just created) before falling back to manual — ok? (D8) | No — proceeding with undo | |
| Q3 | to ask | PRD B-01/B-02 say the schema and the 12 menus must match the data dictionary. I don't have that doc. Can you share it? Until then I'm using my own column list and menus taken from the insights-ui code (D14) | No — proceeding with D14 working default | |
| Q4 | to ask (no rush) | Gateway sync creates realm roles and the PRD uses `realm_access.roles`, but the deployed gateway reads `resource_access.gateway-service.roles` (client roles), and the OpenHIM adaptor relies on that. For admin-service on dev: should the gateway switch to realm roles (and the existing client roles move to realm roles), or should we use client roles, which would need a gateway code change? (D13) | No — no dev deploy in this exercise (2026-11-11); building proceeds with realm roles | |

---

## 4. Sub-tasks

Template for each:

```
Depends on: …   Est: …h   PRD: …   Decisions: …
Goal: one sentence
Deliverables: files / endpoints / migrations
Acceptance criteria: [ ] testable statement  (test: …)
Out of scope: what this sub-task deliberately does not do
```

### S0. Local environment
- **Depends on:** — · **Est:** 3h · **PRD:** M0 · **Decisions:** D5
- **Goal:** One command starts a local Postgres (`admin_service`) and Keycloak (realm `cce`) with everything D5 needs before the first API call, and a token for `superadmin` can be fetched.
- **Deliverables:**
  - `docker-compose.yml`: `postgres:16` → host port 5434, DB `admin_service`; Keycloak (pinned version) `start-dev --import-realm` → host port 8180; health checks on both. Ports avoid 5433/8080 used by `extras/cce-local-setup`.
  - `local/keycloak/cce-realm-local.json`: realm `cce`; realm role `SUPER_ADMIN` (realm role per PRD B-11 and gateway default `JWT_ROLES_CLAIM_PATH=realm_access.roles`, `gateway-service/src/main/resources/application.yml:54`; see D13); confidential client `cce-admin-service` with service account and `realm-management` roles `view-users`, `query-users`, `manage-users`; public client `cce-admin-local` for test tokens. No users, no secrets.
  - `local/create-superadmin.sh`: via `kcadm`, creates user `superadmin`, sets the password from `.env`, assigns `SUPER_ADMIN` (local version of D5 flow step 1; other environments do it by hand). Safe to re-run.
  - `local/get-token.sh`: prints an access token for `superadmin`.
  - `.env.example` (committed), `.env` (gitignored), `.gitignore`: DB and Keycloak admin credentials, superadmin password, client secret.
  - README section "Local environment": start, stop, reset, get a token.
- **Acceptance criteria:**
  - [ ] `docker compose up -d` on a clean machine → both containers `healthy` within 2 min (test: …)
  - [ ] `psql -h localhost -p 5434 -d admin_service -c 'select 1'` succeeds; the DB has no tables (Flyway is S2) (test: …)
  - [ ] `GET /admin/realms/cce/roles/SUPER_ADMIN` → 200 (D5 "what must exist") (test: …)
  - [ ] After `create-superadmin.sh`, user `superadmin` exists with realm role `SUPER_ADMIN`; a second run exits 0 and creates no duplicate (D5 flow step 1) (test: …)
  - [ ] Token from `get-token.sh` has `realm_access.roles` ∋ `SUPER_ADMIN` and an `auth_time` claim (D7); its `iss` and `aud` are written in the README as the `JWT_*` values for S3 (test: …)
  - [ ] `cce-admin-service` client_credentials token → `GET /admin/realms/cce/users?username=superadmin&exact=true` → 200 with exactly 1 user (D5 Part 2 step 3) (test: …)
  - [ ] Same token → `GET /admin/realms/master/users` → 403 (least privilege, ARCHITECTURE.md §8) (test: …)
  - [ ] `git ls-files` lists no `.env` and no password or secret value (B-13) (test: …)
  - [ ] `docker compose down -v && docker compose up -d` + `create-superadmin.sh` → every criterion above passes again (test: …)
- **Out of scope:** the Spring app (S1); tables and seed (S2); linking `superadmin` into `users` (S2a); running the gateway locally (optional, ARCHITECTURE.md §9); dev-environment Keycloak (deploy, Fri 20).

### S1. Project skeleton, health, envelope, errors
- **Depends on:** S0 · **Est:** 5h · **PRD:** B-03, B-04, B-05, B-06 · **Decisions:** D12
- **Goal:** A Spring Boot app on 8085 that serves `/health` and Swagger, wraps every response in the B-03 envelope, and turns every error into the D12 mapping.
- **Deliverables:**
  - `pom.xml`: Java 21, Spring Boot 3.x; web, validation, data-jpa, postgresql, springdoc. No security (S3), no Flyway (S2) yet.
  - `application.yml`: `server.port: ${SERVER_PORT:8085}`; DB from `DB_URL` / `DB_USERNAME` / `DB_PASSWORD` with no defaults. Only environment-neutral defaults (port, timeouts, claim path) live here (B-13).
  - `application-local.yml`: every `localhost` default (DB URL and user; later Keycloak, gateway, JWT issuer), used only with `SPRING_PROFILES_ACTIVE=local`. On any other environment a missing variable stops startup instead of silently pointing at localhost (B-13 "local dev defaults never used in shared environments").
  - `api/ApiResponse<T>` (`{data, pagination?}`), `api/Pagination` (`{page, pageSize, total}`), `api/PageParams` (`page` starts at 1; `pageSize` default 20, max 100).
  - `error/ErrorCode` (all PRD Appendix B codes + the 4 from D12), `error/ApiException(status, code, message)`, `error/ErrorResponse` (`{error:{code,message}}`).
  - `error/GlobalExceptionHandler` (`@RestControllerAdvice`): the D12 mapping, 8-character reference id on 500.
  - `health/HealthController`: `GET /admin/v1/health` → `{status, db}`, not wrapped in the envelope.
  - `config/OpenApiConfig`: Swagger UI at `/swagger-ui.html`, spec at `/v3/api-docs`.
  - Test-only controller under `src/test` to exercise the handler and paging before real endpoints exist.
- **Rules filled in here (PRD silent):**
  - Health path is `/admin/v1/health` (PRD API reference: base path `/admin/v1`, "all require a Bearer token except health").
  - Health is not enveloped: B-05 shows the bare `{status:"UP"}`; `db` is added for "best-effort DB status".
  - DB down → health still 200 with `status:"UP"`, `db:"DOWN"`: the app is up, and a 503 would make k8s restart a healthy pod during a DB blip.
  - `page` starts at 1; `pageSize` > 100 → 400, not silently capped.
- **Acceptance criteria:**
  - [ ] With S0 running and `SPRING_PROFILES_ACTIVE=local`, `mvn spring-boot:run` starts on 8085 and `mvn verify` passes (test: …)
  - [ ] Without the `local` profile and without `DB_URL` → app refuses to start, naming `DB_URL` (B-13) (test: …)
  - [ ] `GET /admin/v1/health` without a token → 200 `{"status":"UP","db":"UP"}` (B-05) (test: …)
  - [ ] Postgres stopped → `GET /admin/v1/health` → 200 `{"status":"UP","db":"DOWN"}` within 3s (B-05) (test: …)
  - [ ] `GET /admin/v1/rolez` → 404 `NOT_FOUND` (D12) (test: …)
  - [ ] `DELETE /admin/v1/health` → 405 `METHOD_NOT_ALLOWED` (D12) (test: …)
  - [ ] POST to the test endpoint with `Content-Type: text/plain` → 415 `UNSUPPORTED_MEDIA_TYPE` (D12) (test: …)
  - [ ] Broken JSON → 400 `VALIDATION_ERROR`; failed `@NotBlank` → 400 `VALIDATION_ERROR` with the field name in `message` (D12) (test: …)
  - [ ] Thrown `ApiException(404, ROLE_NOT_FOUND, "x")` → 404 `ROLE_NOT_FOUND`, `message` = `"x"`, no reference id (D12 point 6) (test: …)
  - [ ] Thrown `RuntimeException("secret detail")` → 500 `INTERNAL_ERROR`; `message` has a reference id and no `secret detail` or class name; an ERROR log line carries the same reference id and the stack trace (D12 points 3–4) (test: …)
  - [ ] No error response in the tests above contains Spring's `timestamp` / `status` / `path` keys (D12 point 1) (test: …)
  - [ ] Non-list success → `{data}` with no `pagination` key; list success → `pagination: {page, pageSize, total}` (B-03, B-04) (test: …)
  - [ ] Test endpoint paging: no `pageSize` → 20; `pageSize=100` → 200; `pageSize=101` → 400 `VALIDATION_ERROR`; `page=0` → 400 `VALIDATION_ERROR` (B-04) (test: …)
  - [ ] `GET /swagger-ui.html` → 200; `/v3/api-docs` lists `/admin/v1/health` (B-06; "every endpoint" checked in S13) (test: …)
- **Out of scope:** JWT and the 401/403 bodies (S3; Spring Security answers before the handler runs, so S3 shapes them); Flyway (S2); any real endpoint.

### S2. Flyway schema + seed
- **Depends on:** S1 · **Est:** 4h · **PRD:** B-01, B-02 · **Decisions:** D1, D2, D5, D6, D7, D14
- **Goal:** On a fresh or existing database, Flyway creates the 7 tables and seeds the 12 menus, the SUPER_ADMIN role and its `/admin/v1/**` permission rows.
- **Deliverables:**
  - `db/migration/V1__schema.sql`: `CREATE EXTENSION IF NOT EXISTS pgcrypto`, then the tables below. All UUID PKs default `gen_random_uuid()`; all timestamps `TIMESTAMPTZ`; FKs without cascade (the service deletes child rows itself, D10). Columns are the D14 working default.

    | Table | Columns | Constraints / indexes |
    |---|---|---|
    | `users` | `id` UUID, `keycloak_id` VARCHAR(36), `username` VARCHAR(255), `email` VARCHAR(255), `first_name` / `last_name` VARCHAR(255) null, `status` VARCHAR(20), `facility_scope` TEXT null, `last_login_at` null (D7), `created_at`, `updated_at` | `keycloak_id` unique, `username` unique, unique on `lower(email)`, `status` IN (ACTIVE, INACTIVE, LOCKED) |
    | `roles` | `id` UUID, `name` VARCHAR(100), `display_name` VARCHAR(255), `description` TEXT null, `is_system` BOOLEAN default false, `created_at`, `updated_at` | `name` unique, CHECK `name ~ '^[A-Z][A-Z0-9_]*$'` |
    | `menus` | `id` UUID, `key` VARCHAR(100), `label` VARCHAR(255), `path` VARCHAR(512), `icon` VARCHAR(100) null, `type` VARCHAR(10), `parent_id` UUID null → `menus`, `sort_order` INT, `is_active` BOOLEAN default true, `created_at`, `updated_at` | `key` unique, `type` IN (NAV, DETAIL) |
    | `role_menus` | `role_id` → `roles`, `menu_id` → `menus`, `created_at` | PK (`role_id`, `menu_id`) |
    | `user_roles` | `user_id` → `users`, `role_id` → `roles`, `created_at` | PK (`user_id`, `role_id`), index on `role_id` (D10 `ROLE_IN_USE` check) |
    | `api_permissions` | exactly as D2 (`CREATE TABLE IF NOT EXISTS`, `id` BIGSERIAL per D1) | nothing added |
    | `audit_log` | `id` UUID, `actor_id` UUID null, `actor_username` VARCHAR(255), `action` VARCHAR(50), `entity_type` VARCHAR(50), `entity_id` VARCHAR(64), `before` / `after` JSONB null, `ip_address` VARCHAR(45) null, `created_at` | no FKs; index (`entity_type`, `entity_id`); index `created_at` |

  - `db/migration/V2__seed.sql`: the 12 menus from D14 (`sort_order` 10, 20, …; `icon` = Heroicon name from `Sidebar.tsx`); role `SUPER_ADMIN` (`is_system = true`, no `role_menus`); `api_permissions` SUPER_ADMIN × GET/POST/PUT/PATCH/DELETE `/admin/v1/**` (D5), each inserted with `WHERE NOT EXISTS`.
  - Flyway dependency; `spring.jpa.hibernate.ddl-auto: none` (entities come with each later sub-task).
  - `MigrationTest` on Testcontainers Postgres.
- **Rules filled in here (PRD silent, D14):**
  - Email is unique case-insensitively, so `A@x.com` and `a@x.com` can't both pass `EMAIL_IN_USE`.
  - Role name length 100 fits both `api_permissions` widths seen (100 in the gateway doc, 255 in the server seed; D2 notes).
  - SUPER_ADMIN gets no `role_menus`: it is an admin-console role, and the admin UI sidebar is static (PRD "Role-driven nav in the admin").
  - `audit_log` has no FKs, so D8 failure rows and D5 `SYSTEM` rows never break on a missing user.
  - No index on `api_permissions.permission_name`: it would change the gateway's table on servers (D2).
- **Acceptance criteria:**
  - [ ] Fresh DB → app starts; `flyway_schema_history` shows V1 and V2 succeeded; the 7 tables and the `pgcrypto` extension exist (B-01) (test: …)
  - [ ] Every PK is UUID with default `gen_random_uuid()`, except `api_permissions.id` = bigint (D1) (test: …)
  - [ ] DB pre-loaded with `deploy-scripts/k8s/seeds/api_permissions.sql` → migrate succeeds; its existing rows are unchanged; the 5 SUPER_ADMIN rows are added once (D2) (test: …)
  - [ ] `menus` = 12 rows: 10 NAV with no parent (Patients among them), 2 DETAIL with parents Compliance and Patients (B-02, D14) (test: …)
  - [ ] `roles` = 1 row: `SUPER_ADMIN`, `is_system = true` (B-02) (test: …)
  - [ ] SUPER_ADMIN has exactly 5 `api_permissions` rows, and its GET row matches `/admin/v1/me/menus` with `AntPathMatcher` (D5, D6) (test: …)
  - [ ] `users`, `user_roles`, `role_menus`, `audit_log` are empty after migration (admin user is S2a) (test: …)
  - [ ] DB rejects: status `FOO`; duplicate `roles.name`; role name `facility_admin`; an email differing only in case; duplicate `menus.key`; duplicate (`user_id`, `role_id`) (test: …)
  - [ ] Restarting the app → no new rows, no Flyway error (test: …)
- **Out of scope:** JPA entities and repositories (each sub-task adds its own); linking the admin user (S2a); any change to `api_permissions` shape or indexes; the data-dictionary diff (when D14 resolves).

### S2a. Bootstrap admin on startup
- **Depends on:** S2, S4 · **Est:** 5h · **PRD:** §12 "Bootstrap admin" · **Decisions:** D5
- **Order note:** built after S4 so the audit row goes through `AuditWriter` (no rework). Side effect: until S2a is done, superadmin's valid token gets 403 in S3 (not in `users`), a natural B-12 check.
- **Goal:** On startup, link the Keycloak user named in `BOOTSTRAP_ADMIN_USERNAME` to a local ACTIVE SUPER_ADMIN, or log why not and keep running.
- **Deliverables:**
  - `client/KeycloakClient` (interface) with only what S2a needs: `findUserByUsername(username)` (exact match) and `hasRealmRole(keycloakId, roleName)`. S8 adds the rest to the same interface and class.
  - `client/KeycloakUser` record: id, username, email, firstName, lastName.
  - `client/KeycloakAdminClient`: implementation on `keycloak-admin-client`, client_credentials grant.
  - `config/KeycloakProperties`: `KEYCLOAK_BASE_URL` (no default; `http://localhost:8180` in `application-local.yml` only, B-13), `KEYCLOAK_REALM` (default `cce`), `KEYCLOAK_CLIENT_ID` (default `cce-admin-service`), `KEYCLOAK_CLIENT_SECRET` (no default); timeout 10s.
  - `bootstrap/BootstrapAdminRunner` (`ApplicationRunner`) and `bootstrap/BootstrapAdminService` (one `@Transactional` insert).
- **Rules filled in here (D5 silent):**
  - Keycloak user without an email → treated like the other failures (ERROR, no rows, keep running), since `users.email` is NOT NULL (S2).
  - Role check uses effective realm roles, so SUPER_ADMIN via a composite role or group counts (D13 working default: realm roles).
  - Keycloak timeout 10s, same as the gateway timeout in D3; after it, Keycloak counts as unreachable.
- **Acceptance criteria:**
  - [ ] `BOOTSTRAP_ADMIN_USERNAME` unset → no Keycloak call, no rows, app UP (D5 step 1) (test: …)
  - [ ] A `users` row with that username exists → no Keycloak call, no new rows (D5 step 2) (test: …)
  - [ ] Keycloak unreachable → ERROR log `create <username> in Keycloak first`; no rows; app UP and `GET /admin/v1/health` → 200; startup waits no more than 10s on Keycloak (D5 step 3) (test: …)
  - [ ] User not found → same ERROR, no rows; Keycloak has only `superadmin2` → counts as not found (exact match) (D5 step 3) (test: …)
  - [ ] Found without realm role `SUPER_ADMIN` → ERROR, no rows (D5 step 3) (test: …)
  - [ ] Found without email → ERROR `<username> has no email in Keycloak`, no rows (test: …)
  - [ ] Found with the role → one `users` row (`keycloak_id` = Keycloak id, username, email, names, ACTIVE), one `user_roles` row → SUPER_ADMIN, one audit row (`actor_username` `SYSTEM`, action `BOOTSTRAP_ADMIN_LINKED`, `entity_type` `USER`, `entity_id` = `users.id`); INFO log `bootstrap admin <username> linked` (D5 steps 4–5) (test: …)
  - [ ] `user_roles` insert fails (mocked) → none of the 3 rows saved (D5 step 4, one transaction) (test: …)
  - [ ] Second start → skipped at step 2; still exactly 1 `users` row (D5 "safe to leave set") (test: …)
  - [ ] Real run on S0: after `create-superadmin.sh` and a start, `users.keycloak_id` = the id shown in Keycloak (test: …)
  - [ ] `KEYCLOAK_CLIENT_SECRET` value appears nowhere in `application.yml` or the repo (B-13) (test: …)
- **Out of scope:** creating the user in Keycloak (by hand / S0 script); any other Keycloak operation (S8, S10); re-linking if the Keycloak id later changes.

### S3. Security: JWT, roles claim, local ACTIVE user
- **Depends on:** S2 · **Est:** 6h · **PRD:** B-10, B-11, B-12, B-13 · **Decisions:** D7
- **Goal:** Every non-public request carries a valid JWT and belongs to a local ACTIVE user; otherwise 401 or 403 in the B-03 envelope.
- **Checks per request:**
  ```
  1. Token valid? (signature via JWKS, iss, aud, expiry)   no → 401 UNAUTHENTICATED   (B-10)
  2. Read roles from JWT_ROLES_CLAIM_PATH                                            (B-11)
  3. sub → users row, status ACTIVE?                       no → 403 FORBIDDEN         (B-12)
     + update last_login_at from auth_time if newer                                  (D7)
  ```
  No per-URL role check here: the gateway does that with `api_permissions` (ARCHITECTURE.md §8).
- **Deliverables:**
  - `spring-boot-starter-oauth2-resource-server` dependency.
  - `config/SecurityConfig`: stateless; open paths `/admin/v1/health`, `/swagger-ui/**`, `/v3/api-docs/**`; everything else authenticated.
  - `config/JwtProperties`: `JWT_ISSUER` (required), `JWT_AUDIENCE` (required), `JWT_JWK_SET_URI` (default `${JWT_ISSUER}/protocol/openid-connect/certs`), `JWT_ROLES_CLAIM_PATH` (default `realm_access.roles`). Local values in `application-local.yml` (from S0's README).
  - `security/AudienceValidator` (Spring does not check `aud` by itself).
  - `security/RolesClaimConverter`: reads roles from a dot-notation path.
  - `security/ActiveUserFilter`: looks up `sub`, checks ACTIVE, puts `CurrentUser` (id, username, roles) on the request, does the D7 update.
  - `security/JsonAuthEntryPoint`, `security/JsonAccessDeniedHandler`: 401 / 403 in the B-03 shape (Spring Security answers before the S1 handler).
  - `entity/User`, `repository/UserRepository` (first JPA entity).
  - Protected test endpoint under `src/test`.
- **Rules filled in here:**
  - Swagger UI and `/v3/api-docs` are open without a token (they show the API shape only; calls still need a token).
  - The 401 message is fixed, `Missing or invalid token.`, and does not say which check failed; the reason goes to a DEBUG log.
- **Acceptance criteria:**
  - [ ] No token / bad signature / expired / wrong `iss` / `aud` without `JWT_AUDIENCE` → each 401 `UNAUTHENTICATED`, B-03 body, message `Missing or invalid token.` (B-10) (test: …)
  - [ ] `/admin/v1/health`, `/swagger-ui.html`, `/v3/api-docs` without a token → 200 (B-05, B-06) (test: …)
  - [ ] Valid token, `sub` not in `users` → 403 `FORBIDDEN` (B-12) (test: …)
  - [ ] Valid token, user INACTIVE → 403 `FORBIDDEN`; LOCKED → 403 `FORBIDDEN`; ACTIVE → test endpoint 200 (B-12) (test: …)
  - [ ] Roles read from `realm_access.roles` by default; with `JWT_ROLES_CLAIM_PATH=resource_access.gateway-service.roles` they are read from there (B-11, D13) (test: …)
  - [ ] Claim path missing from the token → empty role list; the request is not rejected for that reason (B-11) (test: …)
  - [ ] `last_login_at` (D7) (test: …):
    - null + `auth_time` T → set to T
    - same T on the next request → no UPDATE issued
    - older `auth_time` → unchanged
    - no `auth_time` → unchanged, logged once
    - the update throws → WARN log, request still 200
    - no audit row in any of these cases
  - [ ] Real run on S0: superadmin's real token → 403 `FORBIDDEN`, since S2a hasn't linked them yet (B-12) (test: …)
  - [ ] Without the `local` profile and without `JWT_ISSUER` or `JWT_AUDIENCE` → app refuses to start, naming the missing variable (B-13) (test: …)
- **Out of scope:** per-URL role checks (gateway, ARCHITECTURE.md §8); `/me` (S12); audit (S4); deciding D13.

### S4. Audit writer
- **Depends on:** S2, S3 · **Est:** 4h · **PRD:** B-50 · **Decisions:** D8, D5
- **Goal:** One `AuditWriter` that appends exactly one `audit_log` row per change inside the caller's transaction, plus a separate-transaction method for D8 failure records.
- **Deliverables:**
  - `entity/AuditLog`; `repository/AuditLogRepository` with insert and read only (no update or delete methods).
  - `audit/AuditAction` enum with the names already fixed by the PRD and decisions: `BOOTSTRAP_ADMIN_LINKED`, `USER_DEACTIVATED`, `USER_ROLES_UPDATED`, `ROLE_UPDATED`, `ROLE_DELETED`, `ROLE_MENUS_UPDATED`, `USER_CREATE_FAILED`, `USER_UPDATE_FAILED`, `USER_STATUS_UPDATE_FAILED`, `USER_ROLES_UPDATE_FAILED`. Each later sub-task adds its own.
  - `audit/AuditWriter`:
    - `record(action, entityType, entityId, before, after)`: `@Transactional(propagation = MANDATORY)`, runs inside the caller's transaction, so a rollback removes it too.
    - `recordFailure(action, entityType, entityId, keycloakId, failedStep, error, cleanup)`: `REQUIRES_NEW`, survives the main rollback, never throws (D8 point 1).
    - Actor = `CurrentUser` (S3); no request (startup) → `SYSTEM` (D5).
    - IP = first entry of `X-Forwarded-For`, else the remote address; null outside a request.
  - Test helper `AuditAssert.exactlyOneRow(action, entityId)` for every later sub-task (B-50 "a test asserts one row per mutation").
- **Rules filled in here:**
  - `MANDATORY` so a missing transaction fails loudly instead of writing a row that can't roll back.
  - IP from `X-Forwarded-For` because behind the gateway the remote address is always the gateway's. Direct callers could fake it, but they still need a valid token (S3).
  - Append-only is enforced in code only (no DB trigger).
  - `before` / `after` never contain passwords or secrets.
- **Acceptance criteria:**
  - [ ] `record()` inside a transaction → exactly 1 row with `actor_id`, `actor_username`, `action`, `entity_type`, `entity_id`, `before`, `after` (JSON), `ip_address`, `created_at` (B-50) (test: …)
  - [ ] `record()` outside a transaction → exception, no row (test: …)
  - [ ] Main transaction rolls back after `record()` → 0 rows (test: …)
  - [ ] `recordFailure()` then main transaction rolls back → 1 row survives; `after` holds `keycloakId`, `failedStep`, `error`, `cleanup` (D8 point 1) (test: …)
  - [ ] `recordFailure()` while the insert throws (DB down) → no exception reaches the caller; ERROR log has action, `keycloakId`, `failedStep`, `error`, `cleanup` (D8 point 1) (test: …)
  - [ ] No current user → `actor_username` = `SYSTEM`, `actor_id` null (D5) (test: …)
  - [ ] `X-Forwarded-For: 1.2.3.4, 10.0.0.1` → `ip_address` = `1.2.3.4`; no header → remote address (B-50) (test: …)
  - [ ] `before` / `after` may be null (create has no before, delete has no after) (test: …)
  - [ ] `AuditLogRepository` exposes no update or delete method (B-50 append-only) (test: …)
- **Out of scope:** an audit read endpoint (PRD: not in v2); calling the writer from endpoints (each sub-task); append-only enforcement in the DB.

### S5. Menus CRUD
- **Depends on:** S4 · **Est:** 6h · **PRD:** B-44 · **Decisions:** D12, D14
- **Goal:** Admins can list the menu catalog as a tree and create, edit, deactivate or delete menus, with one audit row per change.
- **Deliverables:**
  - `entity/Menu`, `entity/RoleMenu`, `repository/MenuRepository`, `repository/RoleMenuRepository`.
  - `controller/MenuController`, `service/MenuService`: `GET /admin/v1/menus`, `POST /admin/v1/menus`, `PUT /admin/v1/menus/{id}`, `DELETE /admin/v1/menus/{id}` (no `GET /menus/{id}`: not in the PRD API table).
  - DTOs `MenuRequest`, `MenuResponse` (tree node with `children`).
  - Audit actions `MENU_CREATED`, `MENU_UPDATED`, `MENU_DELETED`.
- **Rules filled in here (PRD silent):**
  - a. `key` is immutable: same value in `PUT` allowed, different → 400 `VALIDATION_ERROR` (as D9). Consoles map screens by key.
  - b. NAV has no parent; DETAIL must have a NAV parent; no DETAIL under DETAIL (two levels, as B-21 describes).
  - c. Deleting a NAV that still has DETAIL children → 400 `VALIDATION_ERROR` ("delete or move its DETAIL menus first"). No orphans, no silent cascade, no new error code.
  - d. `GET /menus` includes inactive menus (`isActive` flag), sorted by `sortOrder`, not paginated. `/me/menus` (S12) is the one that hides inactive.
  - e. `key` format `^[a-z][a-z0-9-]*$` (e.g. `patient-detail`); the S2 seed keys follow it.
- **Acceptance criteria:**
  - [ ] `GET /admin/v1/menus` → 200: 10 NAV, the 2 DETAIL nested under Compliance and Patients, sorted by `sortOrder`, inactive included (B-44, D14, rule d) (test: …)
  - [ ] `POST` a valid NAV → 201 with the menu; exactly 1 audit row `MENU_CREATED` (B-44, B-50) (test: …)
  - [ ] `POST` with an existing key → 409 `DUPLICATE_MENU_KEY`; no row, no audit (B-44) (test: …)
  - [ ] Two parallel `POST`s with the same new key → one 201, one 409 `DUPLICATE_MENU_KEY` (not 500) (test: …)
  - [ ] `POST` → 400 `VALIDATION_ERROR` for each: missing label, path or type; key `Patient_Detail`; DETAIL without a parent; NAV with a parent; unknown `parentId`; parent that is a DETAIL (rules b, e) (test: …)
  - [ ] `PUT` unknown id → 404 `MENU_NOT_FOUND` (test: …)
  - [ ] `PUT` changing label / path / icon / sortOrder / isActive → 200; 1 audit row `MENU_UPDATED` with before/after (B-50) (test: …)
  - [ ] `PUT` with a different key → 400 `VALIDATION_ERROR`; same key → 200 (rule a) (test: …)
  - [ ] `PUT` turning a NAV with children into a DETAIL, or `parentId` = its own id → 400 `VALIDATION_ERROR` (rule b) (test: …)
  - [ ] `DELETE` a DETAIL → 204; its `role_menus` rows gone; 1 audit row `MENU_DELETED` whose `before` lists the role ids that had it (B-44) (test: …)
  - [ ] `DELETE` a NAV with children → 400 `VALIDATION_ERROR`; nothing deleted, no audit (rule c) (test: …)
  - [ ] `DELETE` unknown id → 404 `MENU_NOT_FOUND` (test: …)
- **Out of scope:** role → menu mapping (S7); `/me/menus` (S12); bulk reordering.

### S6. Roles CRUD + guards
- **Depends on:** S4, S6a · **Est:** 7h · **PRD:** B-40, B-04 · **Decisions:** D4, D6, D9, D10, D11
- **Goal:** Admins can list, view, create, edit and delete roles, with every guard from D4, D9, D10 and D11.
- **Deliverables:**
  - `entity/Role`, `entity/ApiPermission` (`id` Long, D1), `entity/UserRole`; their repositories.
  - `controller/RoleController`, `service/RoleService`: `GET /admin/v1/roles` (paginated, B-04), `GET /admin/v1/roles/{id}`, `POST /admin/v1/roles`, `PUT /admin/v1/roles/{id}`, `DELETE /admin/v1/roles/{id}`.
  - DTOs `CreateRoleRequest`, `UpdateRoleRequest`, `RoleResponse`.
  - Audit actions `ROLE_CREATED` (new), `ROLE_UPDATED`, `ROLE_DELETED`.
- **Behaviour (from decisions):**
  - `POST`: validate name → duplicate checks (`roles.name`, then `api_permissions.permission_name`, D11) → one transaction: role (`is_system = false` always) + default row `GET /admin/v1/me/menus` + audit `ROLE_CREATED` → gateway sync via S6a (D4).
  - `PUT`: the D9 check order exactly; no sync.
  - `DELETE`: D10 steps 1–9 exactly.
- **Rule filled in here:** 502 message for a failed sync after create (D3 covers permissions, D10 covers delete): `Role created. <D3 cause>. Retry with POST /admin/v1/roles/{id}/sync.`, where `<D3 cause>` is the D3 case text (e.g. `Gateway not reachable at <url>`).
- **Acceptance criteria:**
  - [ ] `GET /admin/v1/roles?page=1&pageSize=20` → 200 with `pagination`; a non-role `permission_name` such as `COLLECTOR_EVENTS_WRITE` is not listed (B-04, D11 point 2) (test: …)
  - [ ] `GET /admin/v1/roles/{unknown}` → 404 `ROLE_NOT_FOUND` (test: …)
  - [ ] `POST {name:"FACILITY_ADMIN", displayName:…}` → 201; role row, exactly 1 `api_permissions` row (`FACILITY_ADMIN`, GET, `/admin/v1/me/menus`), 1 audit row `ROLE_CREATED`; sync called once (D4) (test: …)
  - [ ] `POST` with name `facility_admin`, or without `displayName` → 400 `VALIDATION_ERROR`; nothing saved (test: …)
  - [ ] `POST` an existing role name → 409 `DUPLICATE_ROLE_NAME` (B-40) (test: …)
  - [ ] `POST COLLECTOR_EVENTS_WRITE` (exists only in `api_permissions`) → 409 `DUPLICATE_ROLE_NAME` with the D11 message (D11 point 3) (test: …)
  - [ ] `POST` with `isSystem:true` in the body → role saved with `is_system = false` (test: …)
  - [ ] `POST` when sync fails (mocked 206 / 500 / timeout) → 502 `KEYCLOAK_SYNC_FAILED` with the create message above; role, default row and audit stay saved (D4, D3) (test: …)
  - [ ] `PUT`: unknown → 404 `ROLE_NOT_FOUND`; SUPER_ADMIN → 409 `SYSTEM_ROLE_IMMUTABLE` (also for a rename); different name → 400 `VALIDATION_ERROR` with the D9 message; same name or no name → 200 + 1 audit row `ROLE_UPDATED`; sync never called (D9) (test: …)
  - [ ] `DELETE`: unknown → 404 `ROLE_NOT_FOUND`; SUPER_ADMIN → 409 `SYSTEM_ROLE_IMMUTABLE`; role held by an INACTIVE user → 409 `ROLE_IN_USE`; nothing deleted in these cases (D10 steps 1–3) (test: …)
  - [ ] `DELETE` an unused role → 204; its `role_menus` and `api_permissions` rows gone; an unrelated `COLLECTOR_EVENTS_WRITE` row untouched; 1 audit row `ROLE_DELETED` with menus and permissions in `before`; sync called once (D10 steps 4–9, D11) (test: …)
  - [ ] `DELETE` when sync fails → 502 `KEYCLOAK_SYNC_FAILED` with the D10 message; the delete stays committed (D10) (test: …)
- **Out of scope:** `/roles/{id}/menus` (S7); `/roles/{id}/permissions` and `/roles/{id}/sync` (S11); the gateway client itself (S6a).

### S6a. Gateway sync client
- **Depends on:** S1 · **Est:** 3h · **PRD:** B-43 (client side) · **Decisions:** D3
- **Goal:** One client that calls gateway sync and turns every reply into success or a 502 `KEYCLOAK_SYNC_FAILED` reason, exactly as D3 lists.
- **Deliverables:**
  - `client/GatewaySyncClient` (interface): `sync(roleId)`; the role id is used only for logging (D3 logging rule).
  - `client/HttpGatewaySyncClient`: Spring `RestClient`, `POST {GATEWAY_BASE_URL}/api/permissions/sync-to-keycloak`, no auth header, 10s timeout.
  - `config/GatewayProperties`: `GATEWAY_BASE_URL` (required; local default in `application-local.yml`).
  - `client/GatewaySyncException(reason)`: mapped by the S1 handler to 502 `KEYCLOAK_SYNC_FAILED`. The caller puts its own opening in front of the reason: `Role created.` (S6), the D10 delete message (S6), `Permissions saved.` (S11).
  - WireMock test dependency (fake gateway).
- **Rule filled in here:** when the gateway gives no message (e.g. 404), the reason uses `HTTP <status>`.
- **Acceptance criteria:**
  - [ ] 200 + `success:true` → OK, no exception (D3) (test: …)
  - [ ] 200 + `success:false`, or a 200 body that is not JSON → failure (D3 "anything else") (test: …)
  - [ ] 206 + `failedRoles:["A","B"]` → reason `Gateway reloaded its rules, but Keycloak role sync failed for: A, B.` (D3) (test: …)
  - [ ] 500 + `message:"X"` → reason `Gateway sync error: X.`; 404 without a message → `Gateway sync error: HTTP 404.` (D3) (test: …)
  - [ ] Connection refused → `Gateway not reachable at <url>.` (D3) (test: …)
  - [ ] No reply → `Gateway did not answer within 10s.`; the call returns in under 11s (D3) (test: …)
  - [ ] Request is `POST /api/permissions/sync-to-keycloak` with no `Authorization` header (D3) (test: …)
  - [ ] Every failure → exactly 1 WARN log with role id, URL, status and full response body (D3 logging) (test: …)
  - [ ] Never retried: WireMock sees exactly 1 request per `sync()` call (D3) (test: …)
- **Out of scope:** the endpoints that call it (S6, S11); auth on the gateway's sync endpoint (D3 notes: not ours to fix).

### S7. Role → menus
- **Depends on:** S5, S6 · **Est:** 4h · **PRD:** B-41, B-40 · **Decisions:** —
- **Goal:** Admins can read and replace the set of menus a role sees, with a warning when a DETAIL is given without its NAV parent.
- **Deliverables:**
  - `controller/RoleMenuController`, `service/RoleMenuService`: `GET /admin/v1/roles/{id}/menus`, `PUT /admin/v1/roles/{id}/menus` with body `{menuIds:[…]}` (full new set; the service computes the diff).
  - DTOs `RoleMenusRequest`, `RoleMenusResponse` (`menus`, `warnings`).
  - Audit action `ROLE_MENUS_UPDATED`.
  - No Keycloak or gateway call: role → menu is a soft control (ARCHITECTURE.md §3).
- **Rules filled in here (PRD silent):**
  - a. The B-41 warning goes inside `data`: `{data: {menus:[…], warnings:["DETAIL 'patient-detail' given without its parent 'patients'; it will not show in the sidebar."]}}`. The B-03 envelope is unchanged.
  - b. A system role's menus can't be changed → 409 `SYSTEM_ROLE_IMMUTABLE` (B-40 "modify … an is_system role"). The same rule applies to permissions in S11, where removing SUPER_ADMIN's `/admin/v1/**` rows would lock every admin out.
  - c. Unknown menu id in the body → 400 `VALIDATION_ERROR` naming the ids (bad body, not bad URL).
  - d. Duplicate ids are treated as one; an empty list is allowed (empty sidebar is valid, D6).
  - e. Same set as now → 200, no audit row (nothing changed, so not a mutation under B-50).
  - f. Inactive menus can be assigned; `/me/menus` hides them (S12).
- **Acceptance criteria:**
  - [ ] `GET /roles/{id}/menus` → 200, flat list of `{id, key, label, type, parentId}`; unknown role → 404 `ROLE_NOT_FOUND` (B-41) (test: …)
  - [ ] `PUT` `[dashboard, compliance]` on a role that has `[dashboard, exports]` → 200; `role_menus` = exactly those 2; 1 audit row `ROLE_MENUS_UPDATED` with keys in `before` / `after` (B-41, B-50) (test: …)
  - [ ] `PUT` with `patient-detail` but without `patients` → 200, saved, `warnings` has 1 entry naming both (B-41, rule a) (test: …)
  - [ ] `PUT` with both → 200, `warnings` empty (test: …)
  - [ ] `PUT` on SUPER_ADMIN → 409 `SYSTEM_ROLE_IMMUTABLE`; nothing changed (rule b) (test: …)
  - [ ] `PUT` with an unknown menu id → 400 `VALIDATION_ERROR` naming it; nothing changed (rule c) (test: …)
  - [ ] `PUT []` → 200, role has no menus; duplicate ids → saved once (rule d) (test: …)
  - [ ] `PUT` with the current set → 200, 0 audit rows (rule e) (test: …)
  - [ ] `PUT` on an unknown role → 404 `ROLE_NOT_FOUND` (test: …)
  - [ ] No gateway or Keycloak call in any case (test: …)
- **Out of scope:** `/me/menus` (S12); permissions (S11).

### S8. Keycloak client (extend) + create user
- **Depends on:** S6, S2a · **Est:** 7h · **PRD:** B-31, B-32, B-36 · **Decisions:** D4, D8
- **Goal:** One `POST /users` creates the Keycloak account, assigns its realm roles and saves the local user, or cleans up and reports per D8.
- **Flow (B-31, ARCHITECTURE.md Flow A, D8):**
  ```
  0. Checks, DB only: body valid? roles exist? email / username free?   no → 400 / 409, Keycloak not called
  1. Keycloak: create account                                           fails → nothing created (rules c, d)
  2. Keycloak: assign realm roles                                      ─┐ fails → D8: delete the Keycloak
  3. DB, one transaction: users + user_roles + audit USER_CREATED      ─┘ account once, record, 502
  4. 201 Created
  ```
- **Deliverables:**
  - `KeycloakClient` (from S2a) gets `createUser`, `assignRealmRoles`, `deleteUser`.
  - `controller/UserController` (`POST /admin/v1/users`), `service/UserCreateService`.
  - `CreateUserRequest`: `username`, `email`, `firstName`, `lastName`, `facilityScope`, `roleIds`.
  - Audit action `USER_CREATED`; error code `USERNAME_IN_USE` added to `ErrorCode`.
- **Rules filled in here (PRD silent):**
  - a. No password on create: the Keycloak account gets required action `UPDATE_PASSWORD`; the admin sends the link with reset password (S10). B-36 "no password ever passes through the service"; F-11 "create posts once". Sending the email here would add a step that can fail (e.g. no SMTP locally).
  - b. Duplicate username → 409 `USERNAME_IN_USE`. New code, not in PRD Appendix B (same kind of deviation as D12): reusing `EMAIL_IN_USE` for a username would mislead.
  - c. Keycloak create returns 409 → our 409 `EMAIL_IN_USE`, message `Keycloak already has an account with this username or email that this service doesn't know. An operator must remove or link it.` Nothing was created, nothing to undo.
  - d. Keycloak create fails otherwise (down, 500) → 502 `KEYCLOAK_SYNC_FAILED`, message `User was not created. Keycloak could not create the account: <reason>. Nothing was changed. Try again.` No audit row: nothing is half-done, so D8 recording doesn't apply.
  - e. At least one role required; unknown `roleId` → 400 `VALIDATION_ERROR` (PRD scenario S2 "one or more roles"; same as S7 rule c).
  - f. A new user is always `ACTIVE`; status changes are S10.
- **Acceptance criteria:**
  - [ ] Happy path → 201 with `{id, username, email, status:"ACTIVE", roles}`; Keycloak create then assign, in that order; Keycloak user enabled, with `UPDATE_PASSWORD` and no credentials; `users` + `user_roles` rows; exactly 1 audit row `USER_CREATED` (B-31, rule a) (test: …)
  - [ ] Missing username or email, bad email, `roleIds: []`, unknown `roleId` → 400 `VALIDATION_ERROR`; Keycloak never called (rule e) (test: …)
  - [ ] Email already in `users` (different case) → 409 `EMAIL_IN_USE`; Keycloak never called (B-31) (test: …)
  - [ ] Username already in `users` → 409 `USERNAME_IN_USE`; Keycloak never called (rule b) (test: …)
  - [ ] Keycloak create returns 409 → 409 `EMAIL_IN_USE` with the rule c message; no rows, no audit (test: …)
  - [ ] Keycloak create returns 500 / is unreachable → 502 `KEYCLOAK_SYNC_FAILED` with the rule d message; no rows, no audit (test: …)
  - [ ] Assign roles fails, undo works → 502 `KEYCLOAK_SYNC_FAILED` with the D8 "undo worked" message; Keycloak user deleted; no `users` row; 1 audit row `USER_CREATE_FAILED` (`failedStep` = assign realm roles, `cleanup` = keycloak user deleted); ERROR log (D8) (test: …)
  - [ ] DB save fails (mocked) → same as above with `failedStep` = save user (D8) (test: …)
  - [ ] Undo fails → 502 `KEYCLOAK_SYNC_FAILED` with the D8 "undo failed" message containing the `keycloakId`; audit `cleanup` = `FAILED — delete keycloak user <id> by hand` (D8, B-32) (test: …)
  - [ ] Each Keycloak method is called at most once per request (B-32 "not retried") (test: …)
  - [ ] A `password` field in the body is ignored and never sent to Keycloak (B-36) (test: …)
- **Out of scope:** list / get / update users (S9); status, roles, reset password (S10).

### S9. Users list / get / update
- **Depends on:** S8 · **Est:** 7h · **PRD:** B-30, B-33, B-04 · **Decisions:** D7, D8
- **Goal:** Admins can list users with filters and paging, view one user, and edit profile fields, with Keycloak kept in step.
- **Deliverables:**
  - `UserController` gets `GET /admin/v1/users`, `GET /admin/v1/users/{id}`, `PUT /admin/v1/users/{id}`; `service/UserQueryService`, `service/UserUpdateService`.
  - `KeycloakClient` gets `updateUser(keycloakId, email, firstName, lastName)`.
  - DTOs `UserResponse`, `UpdateUserRequest` (`firstName`, `lastName`, `email`, `facilityScope`; B-33).
  - Audit action `USER_UPDATED`.
- **Update order (D8 "Update profile" row):** open DB transaction → update the row (flush, so a duplicate email fails here) → Keycloak `updateUser` → commit. Keycloak fails → rollback, nothing changed. Commit fails after Keycloak succeeded → `recordFailure(USER_UPDATE_FAILED)`, no undo.
- **Rules filled in here (PRD silent):**
  - a. `q` = case-insensitive "contains" on username, firstName, lastName, email (B-30 "name or email").
  - b. Filters `status` (invalid value → 400), `roleId` (users holding that role), `facilityScope` (exact match); combined with AND.
  - c. Sorted by username A→Z; INACTIVE and LOCKED users included unless `status` is given.
  - d. Each user: `id`, `username`, `email`, `firstName`, `lastName`, `status`, `roles` (`[{id, name, displayName}]`), `facilityScope`, `lastLoginAt` (D7), `createdAt` (F-10).
  - e. `username` is immutable: same value allowed, different → 400 `VALIDATION_ERROR` (as D9).
  - f. `facilityScope` lives only in our DB (stored, not enforced); changing only it calls no Keycloak.
- **Acceptance criteria:**
  - [ ] `GET /users?page=1&pageSize=20` → 200 with `pagination.total`; each item has the rule d fields, including `lastLoginAt` (B-30, B-04, D7) (test: …)
  - [ ] `q=ALI` finds users with "ali" in username, first or last name, or email (rule a) (test: …)
  - [ ] `status=INACTIVE&roleId=<r>` → only users matching both; `status=FOO` → 400 `VALIDATION_ERROR` (rule b) (test: …)
  - [ ] `GET /users/{id}` → 200; unknown → 404 `USER_NOT_FOUND` (B-33) (test: …)
  - [ ] `PUT` new email and names → 200; Keycloak updated with the same values; 1 audit row `USER_UPDATED` with before/after (B-33, B-50) (test: …)
  - [ ] `PUT` changing only `facilityScope` → 200; Keycloak not called (rule f) (test: …)
  - [ ] `PUT` with an email used by another user → 409 `EMAIL_IN_USE`; Keycloak not called (test: …)
  - [ ] `PUT` with a different username → 400 `VALIDATION_ERROR`; unknown id → 404 `USER_NOT_FOUND` (rule e, B-33) (test: …)
  - [ ] Keycloak update fails → 502 `KEYCLOAK_SYNC_FAILED` with the D8 "Keycloak failed" message; DB unchanged; no audit row (D8) (test: …)
  - [ ] Commit fails after Keycloak succeeded (mocked) → 502 `KEYCLOAK_SYNC_FAILED` with the D8 "partly applied" message; 1 audit row `USER_UPDATE_FAILED` via `recordFailure`; ERROR log (D8) (test: …)
- **Out of scope:** status, roles, reset password (S10); creating users (S8).

### S10. User status, roles diff, reset password
- **Depends on:** S8 · **Est:** 8h · **PRD:** B-34, B-35, B-36 · **Decisions:** D8
- **Goal:** Admins can change a user's status, replace their role set, and trigger a password-reset email, with Keycloak changed in step and half-done cases recorded per D8.
- **Deliverables:**
  - `UserController` gets `PATCH /admin/v1/users/{id}/status` (`{status}`), `PUT /admin/v1/users/{id}/roles` (`{roleIds:[…]}`, full set), `POST /admin/v1/users/{id}/reset-password`.
  - `service/UserStatusService`, `service/UserRolesService`, `service/PasswordResetService`.
  - `KeycloakClient` gets `setEnabled(keycloakId, enabled)`, `removeRealmRoles(keycloakId, names)`, `sendUpdatePasswordEmail(keycloakId)`.
  - Audit actions `USER_ACTIVATED`, `USER_DEACTIVATED`, `USER_LOCKED`, `USER_ROLES_UPDATED`, `USER_PASSWORD_RESET`.
- **Order for all three (same as S9):** open DB transaction → DB change → Keycloak call(s) → commit. If the first Keycloak call fails, the DB rolls back and nothing changed. A half-done state (D8: `recordFailure`, no undo) happens only when an earlier Keycloak call in the same request already succeeded, or the commit fails after Keycloak.
- **Rules filled in here (PRD silent):**
  - a. LOCKED = Keycloak disabled, same as INACTIVE; only the label differs. Both keep `user_roles` (B-34).
  - b. Audit actions as listed above (`USER_DEACTIVATED` and `USER_ROLES_UPDATED` are from the PRD).
  - c. A caller can't change their own status or roles → 400 `VALIDATION_ERROR`, so the only SUPER_ADMIN can't lock themselves out.
  - d. Role list must have at least one role; unknown `roleId` → 400 `VALIDATION_ERROR` (as S8 rule e).
  - e. Same status or same role set as now → 200, no Keycloak call, no audit row (as S7 rule e).
  - f. First Keycloak call fails → 502 `KEYCLOAK_SYNC_FAILED`, message `<Status|Roles> not changed. Keycloak error: <reason>. Nothing was changed.` (as S9).
  - g. Reset password only for ACTIVE users, otherwise 400 `VALIDATION_ERROR` `Activate the user first.`; success → 204.
  - h. S0's Keycloak has no mail server, so a real local reset returns 502; tests mock Keycloak. Real email delivery is not tested.
- **Acceptance criteria:**
  - Status:
    - [ ] ACTIVE → INACTIVE → 200; Keycloak `enabled=false`; `user_roles` unchanged; 1 audit row `USER_DEACTIVATED`; the user's next request → 403 `FORBIDDEN` (S3) (B-34) (test: …)
    - [ ] INACTIVE → ACTIVE → 200; Keycloak `enabled=true`; same roles as before; 1 audit row `USER_ACTIVATED` (B-34) (test: …)
    - [ ] → LOCKED → 200; Keycloak `enabled=false`; 1 audit row `USER_LOCKED` (rule a) (test: …)
    - [ ] `status:"FOO"` → 400 `VALIDATION_ERROR`; own status → 400 `VALIDATION_ERROR`; unknown user → 404 `USER_NOT_FOUND`; same status → 200, no Keycloak call, no audit (rules c, e) (test: …)
    - [ ] Keycloak fails → 502 `KEYCLOAK_SYNC_FAILED` with the rule f message; DB unchanged; no audit (test: …)
    - [ ] Commit fails after Keycloak (mocked) → 502 `KEYCLOAK_SYNC_FAILED` with the D8 status message; 1 audit row `USER_STATUS_UPDATE_FAILED`; ERROR log (D8) (test: …)
  - Roles:
    - [ ] `[A,B]` → `[B,C]` → 200; Keycloak assigns only C and removes only A, B untouched; `user_roles` = B, C; 1 audit row `USER_ROLES_UPDATED` with role names before/after (B-35) (test: …)
    - [ ] `[]`, unknown `roleId`, or own roles → 400 `VALIDATION_ERROR`; unknown user → 404 `USER_NOT_FOUND`; same set → 200, no Keycloak call, no audit (rules c, d, e) (test: …)
    - [ ] First Keycloak call fails → 502 `KEYCLOAK_SYNC_FAILED` with the rule f message; DB unchanged; no audit (test: …)
    - [ ] Assign succeeds, then remove fails → 502 `KEYCLOAK_SYNC_FAILED` with the D8 roles message; `user_roles` unchanged; 1 audit row `USER_ROLES_UPDATE_FAILED`; ERROR log (D8) (test: …)
  - Reset password:
    - [ ] ACTIVE user → 204; Keycloak execute-actions email with `UPDATE_PASSWORD`; 1 audit row `USER_PASSWORD_RESET`; no password in request, log or audit (B-36) (test: …)
    - [ ] INACTIVE user → 400 `VALIDATION_ERROR`; unknown user → 404 `USER_NOT_FOUND`; Keycloak fails → 502 `KEYCLOAK_SYNC_FAILED`, no audit (rule g, D12) (test: …)
- **Out of scope:** creating users (S8); profile edits (S9); real email delivery; a "last SUPER_ADMIN" check beyond rule c.

### S11. Role → permissions + gateway sync
- **Depends on:** S6, S6a · **Est:** 6h · **PRD:** B-42, B-43 · **Decisions:** D1, D3, D4, D6, D10, D11
- **Goal:** Admins can read and replace a role's API permissions, which are then synced to the gateway, and can re-sync by hand.
- **Deliverables:**
  - `controller/RolePermissionController`, `service/RolePermissionService`: `GET /admin/v1/roles/{id}/permissions`, `PUT /admin/v1/roles/{id}/permissions` (body `{permissions:[{httpMethod, uriPattern, description, resourceCategory}]}`, full set), `POST /admin/v1/roles/{id}/sync`.
  - DTOs `PermissionRow`, `RolePermissionsRequest`.
  - Audit action `ROLE_PERMISSIONS_UPDATED` (PRD).
  - Uses `GatewaySyncClient` (S6a) and `AntPathMatcher` for the D6 check.
- **`PUT` check order (first failure stops; nothing written until step 6):**
  ```
  1. Role exists?                                no  → 404 ROLE_NOT_FOUND
  2. System role?                                yes → 409 SYSTEM_ROLE_IMMUTABLE   (S7 rule b)
  3. Body valid (method, uriPattern)?            no  → 400 VALIDATION_ERROR        (rule a)
  4. List empty?                                 yes → 400 VALIDATION_ERROR        (D4)
  5. No row matching GET /admin/v1/me/menus?     yes → 400 VALIDATION_ERROR, D6 message (D6)
  6. One transaction: delete rows WHERE permission_name = role.name, insert the new rows with
     permission_name = role.name (never from the body), audit ROLE_PERMISSIONS_UPDATED  (D11, B-42)
  7. Gateway sync (S6a) → 200, or 502 KEYCLOAK_SYNC_FAILED "Permissions saved. <D3 cause>. Retry with POST /admin/v1/roles/{id}/sync."  (D3)
  ```
- **Rules filled in here (PRD silent):**
  - a. `httpMethod` ∈ GET, POST, PUT, PATCH, DELETE; `uriPattern` starts with `/`, max 512 characters (D2 width).
  - b. Duplicate (method, uriPattern) pairs in the list → saved once.
  - c. Same list as now → 200, no DB write, no audit, no sync (retry a sync with `/sync`).
  - d. `POST /sync` writes no audit row (it changes nothing in our DB) and works for system roles too (sync is global). Failure → 502 `KEYCLOAK_SYNC_FAILED`, `Sync failed. <D3 cause>. Retry with POST /admin/v1/roles/{id}/sync.`
  - e. Saving = delete all of the role's rows + insert the new ones; row ids change (the gateway doesn't use them). The audit `before` / `after` shows what was added and removed.
- **Acceptance criteria:**
  - [ ] `GET /roles/{id}/permissions` → 200 with the role's rows (`id`, `httpMethod`, `uriPattern`, `description`, `resourceCategory`); unknown role → 404 `ROLE_NOT_FOUND` (B-42) (test: …)
  - [ ] `PUT` 3 valid rows including `GET /admin/v1/me/menus` → 200; exactly those 3 rows with `permission_name` = role name; 1 audit row `ROLE_PERMISSIONS_UPDATED` with before/after; sync called once (B-42, D11) (test: …)
  - [ ] `PUT` with `permissionName:"OTHER"` in a row → stored under the role's own name (D11 point 1) (test: …)
  - [ ] `PUT` leaves unrelated `COLLECTOR_EVENTS_WRITE` rows untouched (D11 point 2) (test: …)
  - [ ] `PUT` on SUPER_ADMIN → 409 `SYSTEM_ROLE_IMMUTABLE`; nothing changed (S7 rule b) (test: …)
  - [ ] `PUT []` → 400 `VALIDATION_ERROR` (D4) (test: …)
  - [ ] `PUT` without a row matching `GET /admin/v1/me/menus` → 400 `VALIDATION_ERROR` with the D6 message; no DB change, no audit, no sync. Rows `GET /admin/v1/me/*` or `GET /admin/v1/**` count as a match (D6) (test: …)
  - [ ] `PUT` with method `FOO` or uriPattern `admin/x` → 400 `VALIDATION_ERROR` (rule a) (test: …)
  - [ ] `PUT` with duplicate pairs → each pair saved once (rule b) (test: …)
  - [ ] `PUT` with the current list → 200, no audit, no sync (rule c) (test: …)
  - [ ] `PUT` and sync gets 206 / 500 / unreachable / timeout → 502 `KEYCLOAK_SYNC_FAILED` with `Permissions saved. <D3 cause>. Retry with POST /admin/v1/roles/{id}/sync.`; rows and audit stay saved (D3, B-43) (test: …)
  - [ ] `POST /roles/{id}/sync` → 200 when sync is OK; 502 `KEYCLOAK_SYNC_FAILED` with the rule d message on failure; unknown role → 404 `ROLE_NOT_FOUND`; 0 audit rows (B-43, rule d) (test: …)
- **Out of scope:** the sync client (S6a); sync on role create / delete (S6); a global permission catalog (PRD: not in v2).

### S12. Current user: `/me`, `/me/menus`
- **Depends on:** S3, S7 · **Est:** 4h · **PRD:** B-20, B-21 · **Decisions:** D6
- **Goal:** A logged-in user can fetch their own profile and the menu tree for their roles.
- **Deliverables:**
  - `controller/MeController`, `service/MeService`: `GET /admin/v1/me`, `GET /admin/v1/me/menus`.
  - DTOs `MeResponse`, `MenuNode`.
- **Roles source (settled 2026-11-11):** the caller's roles come from our DB (`user_roles`), not the token. A role change (S10) shows immediately on the same token, and the result doesn't depend on D13's claim path. This differs from ARCHITECTURE.md Flow C ("roles from token"); the token roles (B-11) stay on `CurrentUser` only.
- **Rules filled in here (PRD silent):**
  - a. `/me` = PRD shape (`id`, `username`, `roles` as names, `facilityScope`) plus `email`, `firstName`, `lastName` (the console header shows a name; PRD "header from GET /me").
  - b. A DETAIL is returned only if its parent NAV is also in the result (matches S7's warning "it will not show in the sidebar").
  - c. An inactive NAV hides its DETAIL children too.
  - d. Each menu item: `id`, `key`, `label`, `path`, `icon`, `type`, `children`.
- **Acceptance criteria:**
  - [ ] `GET /me` → 200 with the rule a fields; `roles` = sorted role names (B-20) (test: …)
  - [ ] After another admin's `PUT /users/{me}/roles`, `/me` and `/me/menus` show the new roles on the same token (roles source) (test: …)
  - [ ] Role A `[dashboard, compliance]` + role B `[compliance, exports]` → `[dashboard, compliance, exports]`, each once, in `sortOrder` (B-21) (test: …)
  - [ ] `compliance` + `protocol-detail` → `protocol-detail` nested in `compliance.children` (B-21) (test: …)
  - [ ] `patient-detail` without `patients` → not returned (rule b) (test: …)
  - [ ] Inactive menu → not returned; inactive NAV → its DETAIL not returned either (B-21, rule c) (test: …)
  - [ ] User whose roles have no menus (e.g. SUPER_ADMIN) → 200 `data: []` (D6) (test: …)
  - [ ] No audit row and no Keycloak call for either endpoint (test: …)
- **Out of scope:** changing `cce-insights-ui` to use this (PRD: separate repo); the gateway permission for `/me/menus` (D6, S11).

### S13. Backend run-through of scenarios S1–S6
- **Depends on:** S0–S12 · **Est:** 6h · **PRD:** scenarios S1–S6 (backend side), B-06 · **Decisions:** —
- **Goal:** Scenarios S1–S6 pass end to end on the local stack through a real gateway, and the spec matches what was built.
- **Setup:** `curl → gateway-service (local, :8095) → cce-admin-service (:8085) → Postgres + Keycloak from S0`. The gateway runs unchanged; everything it needs is an env var (`gateway-service/src/main/resources/application.yml`): `SERVER_PORT=8095` (8090 is the local Protocol service), `DATABASE_URL` (r2dbc, port 5434, `admin_service`), `KEYCLOAK_SERVER_URL`, `KEYCLOAK_TARGET_REALM=cce`, master-realm admin login from S0's `.env`, `JWT_ISSUER`, `ADMIN_SERVICE_URI=http://localhost:8085`.
- **Deliverables:**
  - `local/gateway.env.example`: the variables above, no secrets (real values in the gitignored `.env`).
  - `local/scenarios/s1.sh` … `s6.sh`: curl scripts, one per scenario, printing PASS / FAIL per check.
  - `local/scenarios/README.md`: start order (S0 → service → gateway) and how to run the scripts.
- **Acceptance criteria** (through the gateway on :8095 unless stated):
  - [ ] S1: user with role `FACILITY_ADMIN` (menus dashboard + compliance) → `GET /admin/v1/me/menus` → 200 with exactly those 2 (test: s1.sh)
  - [ ] S2: `POST /users` with 2 roles → 201; Keycloak user exists with both realm roles; `users` row; 1 audit row `USER_CREATED` (test: s2.sh)
  - [ ] S3: `POST /roles` → 201 and the realm role exists in Keycloak straight away (D4); `PUT` menus → 200; `PUT` permissions adding `GET /admin/v1/users` → 200; a token with that role gets 200 on `GET /admin/v1/users` and 403 from the gateway on `POST /admin/v1/roles` (test: s3.sh)
  - [ ] S4: `PUT /users/{id}/roles` → 200; Keycloak role mappings = the new set; 1 audit row `USER_ROLES_UPDATED` (test: s4.sh)
  - [ ] S5: `PATCH` status INACTIVE → 200; Keycloak user disabled; `user_roles` kept; the user's still-valid token → 403 `FORBIDDEN` from our service; a new login is refused by Keycloak (test: s5.sh)
  - [ ] S6: gateway stopped → `PUT` permissions directly on :8085 → 502 `KEYCLOAK_SYNC_FAILED` "Permissions saved. Gateway not reachable…", rows saved; gateway started → `POST /sync` → 200; realm role present in Keycloak (test: s6.sh)
  - [ ] `/v3/api-docs` lists every endpoint in the PRD API table (B-06 "every endpoint") (test: …)
  - [ ] Spec check: every criterion in S0–S12 ticked with its test; §6 matches the code; §9 change log up to date (TIMELINE "backend spec check") (test: manual)
- **Risk:** the local gateway may not start cleanly (e.g. its R2DBC connection or Basic-auth config). Fallback: run S1–S6 on dev on Fri 20 instead, and log it in §9.
- **Out of scope:** running on dev (Fri 20 / Fri 27 per TIMELINE); UI; load testing.

---

## 5. Dependency graph

Draft — confirm on Tue 10.

```
S0 ─► S1 ─┬─► S2 ─► S3 ─► S4 ─┬─► S2a ─────────────────┐
           │                   ├─► S5 ──────┐           │
           │                   │            ├─► S7 ─► S12
           └─► S6a ────────────┴─► S6 ──────┘           │
                                    │                   │
                                    ├─► S11             │
                                    │                   ▼
                                    └─────────────────► S8 ─┬─► S9
                                                            └─► S10
                                  all ─► S13
```

- S2a comes after S4 so its audit row uses `AuditWriter` (settled 2026-11-10).
- S6a (gateway sync client) comes before S6, because `POST` / `DELETE /roles` already call sync (D4, D10); S11 reuses it (settled 2026-11-11).
- S8 needs both S6 (roles exist) and S2a (the `KeycloakClient` it extends).
- **Realm role before user (ARCHITECTURE.md Flow B order rule):** settled by D4. The realm role is created by the sync in `POST /roles` (S6), not by S11, so S8 does not wait for S11. For S8's tests Keycloak and the gateway are mocked. For a **real** local run, sync needs a gateway, which is optional locally (ARCHITECTURE.md §9): either run gateway-service locally, or create the realm role by hand in Keycloak before assigning it.

---

## 6. Traceability (PRD requirement → sub-task)

| PRD ID | Requirement (short) | Sub-task |
|---|---|---|
| B-01 | Flyway, 7 tables | S2 |
| B-02 | Seed 12 menus + SUPER_ADMIN | S2 |
| B-03 | Response envelope + error body | S1 |
| B-04 | Pagination | S1 (model), S6 (first use), S9 |
| B-05 | `/health` unauthenticated | S1 |
| B-06 | OpenAPI + Swagger UI | S1 (set-up), S13 ("every endpoint" check) |
| B-10 | Validate JWT independently | S3 |
| B-11 | Configurable roles claim path | S3 |
| B-12 | Local user exists + ACTIVE | S3 |
| B-13 | No secrets in repo | S0 (`.env`), S1 (`local` profile), S3 (and every sub-task) |
| B-20 | `GET /me` | S12 |
| B-21 | `GET /me/menus` | S12 |
| B-30 | List users with filters | S9 |
| B-31 | Create user with Keycloak | S8 |
| B-32 | Partial failure → 502 + audit | S8 |
| B-33 | Get / update user | S9 (Keycloak kept in step, D8 "Update profile") |
| B-34 | Status, mirrored to Keycloak | S10 |
| B-35 | Replace role set with diff | S10 |
| B-36 | Reset password; no password through the service | S10 (also S8: no password on create) |
| B-40 | Roles CRUD + guards | S6 (also S7, S11: system role can't be changed) |
| B-41 | Role menus | S7 |
| B-42 | Role permissions + auto-sync | S11 |
| B-43 | Manual sync | S11 (endpoint), S6a (client) |
| B-44 | Menus CRUD | S5 |
| B-50 | Audit every mutation | S4 (writer), S2a, S5–S11 (each uses it) |
| §12 | Bootstrap admin (not a B-ID) | S2a |
| Scenarios S1–S6 | End-to-end backend run | S13 |
| F-01…F-15 | Admin UI | Out of scope (separate repo) |

---

## 7. Effort estimate

In build order, 8h per working day. Not working Mon 16 – Wed 18 Nov (leave). No dev deploy: the showcase runs locally (S13) (decided 2026-11-11). Running past 30 Nov is acceptable.

| Sub-task | Est. (h) | Planned day |
|---|---|---|
| S0 Local environment | 3 | Wed 11 (pm) |
| S1 Project skeleton, health, envelope, errors | 5 | Thu 12 |
| S6a Gateway sync client | 3 | Thu 12 |
| S2 Flyway schema + seed | 4 | Fri 13 |
| S3 Security | 6 | Fri 13 – Thu 19 |
| S4 Audit writer | 4 | Thu 19 |
| S2a Bootstrap admin | 5 | Thu 19 – Fri 20 |
| S5 Menus CRUD | 6 | Fri 20 – Mon 23 |
| S6 Roles CRUD + guards | 7 | Mon 23 |
| S7 Role → menus | 4 | Tue 24 |
| S8 Keycloak client (extend) + create user | 7 | Tue 24 – Wed 25 |
| S11 Role → permissions + gateway sync | 6 | Wed 25 – Thu 26 |
| S9 Users list / get / update | 7 | Thu 26 |
| S10 User status, roles diff, reset password | 8 | Fri 27 |
| S12 Current user | 4 | Mon 30 |
| S13 Backend run-through | 6 | Mon 30 – Tue 1 Dec |
| **Total** | **85** (~10.5 days at 8h) | |

Excludes resolving D13 / D14 (waiting on the lead).

---

## 8. Self-review checklist (before freezing v1)

- [ ] Every PRD requirement (B-01…B-50) maps to exactly one sub-task, or is listed as out of scope
- [ ] Every sub-task has deliverables and acceptance criteria I can test (no "works correctly")
- [ ] Every decision is RESOLVED with evidence, or OPEN with a working default
- [ ] The dependency graph has no sub-task that needs something built later
- [ ] Each sub-task fits in one day or less
- [ ] Anything I don't understand is in §3, not guessed silently

---

## 9. Change log

Empty until v1 is frozen. After that, every change to this spec gets a line.

| Date | Section | Change | Why |
|---|---|---|---|
| — | | | |
