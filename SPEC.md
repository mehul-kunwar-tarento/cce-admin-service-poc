# cce-admin-service — Spec (Decisions + Sub-tasks)

| | |
|---|---|
| **Status** | DRAFT — to be self-reviewed and frozen as v1 on Wed 11 Nov 2026 |
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

<!-- 10–15 short bullets. Draft list to refine on Mon 9: -->

- TODO: role name is immutable; same string in `roles.name`, the Keycloak realm role and `api_permissions.permission_name`
- TODO: `api_permissions` shape is owned by the gateway; do not change it
- TODO: gateway creates realm role definitions; this service creates users and assigns roles
- TODO: no transaction spans DB + Keycloak; fixed step order, on failure return 502 + audit row, no retry
- TODO: service re-validates the JWT and checks local user is ACTIVE (defense in depth)
- TODO: role → menu is a soft control, role → permission is a hard control; independent
- TODO: replace semantics on `PUT .../roles|menus|permissions`; service computes the diff
- TODO: every mutation writes exactly one `audit_log` row
- TODO: deactivation is terminal-safe: INACTIVE keeps `user_roles`, no hard delete

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
  - **Gateway address:** config `GATEWAY_BASE_URL`, default `http://localhost:8090` (port from `deploy-scripts/k8s/base/ingress.yaml`).
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
- **Affects:** S0, S2, S3 (needs the Keycloak client from S8 earlier, or its own minimal lookup), deployment · adds sub-task S2a (BootstrapAdminRunner)

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
     - **Audit row, best effort, in its own transaction** (`REQUIRES_NEW`), so it survives the main rollback. Actions: `USER_CREATE_FAILED`, `USER_STATUS_UPDATE_FAILED`, `USER_ROLES_UPDATE_FAILED`. `after` JSON holds `keycloakId`, `failedStep`, `error`, `cleanup`. If this write also fails, the ERROR log is the record.
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
  | Change status | `Status change only partly applied: <which side succeeded>. Keycloak and the user record now differ; an operator must fix it.` |
  | Change roles | `Role change only partly applied in Keycloak. Keycloak and the user record now differ; an operator must fix it.` |

- **Deviation from PRD:** the undo for create user is not in the PRD. The PRD says "not retried"; undo reverses our own just-made step rather than retrying, but it changes the described behaviour, so it's logged as Q2.
- **Affects:** S4 (audit writer needs a separate-transaction method), S8, S10

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

---

## 3. Questions for the lead

Only things I could not work out myself.

| # | Date asked | Question | Blocking? | Answer |
|---|---|---|---|---|
| Q1 | to ask | PRD B-01 says UUID for `api_permissions`, the gateway reads `Long`; I went with `Long` — ok? (D1) | No — proceeding with `Long` | |
| Q2 | to ask | PRD B-32 says record partial user-create failures for manual cleanup. I added one undo attempt (delete the Keycloak account we just created) before falling back to manual — ok? (D8) | No — proceeding with undo | |

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
- **Depends on:** — · **Est:** TODO · **PRD:** M0 · **Decisions:** D5
- **Goal:** TODO
- **Deliverables:** TODO
- **Acceptance criteria:**
  - [ ] TODO
- **Out of scope:** TODO

### S1. Project skeleton, health, envelope, errors
- **Depends on:** S0 · **Est:** TODO · **PRD:** B-03, B-04, B-05, B-06 · **Decisions:** D12
- **Goal:** TODO
- **Deliverables:** TODO
- **Acceptance criteria:**
  - [ ] TODO
- **Out of scope:** TODO

### S2. Flyway schema + seed
- **Depends on:** S1 · **Est:** TODO · **PRD:** B-01, B-02 · **Decisions:** D1, D2, D5, D6, D7
- **Goal:** TODO
- **Deliverables:** TODO
- **Acceptance criteria:**
  - [ ] TODO
- **Out of scope:** TODO

### S2a. Bootstrap admin on startup
- **Depends on:** S2 · **Est:** TODO · **PRD:** §12 "Bootstrap admin" · **Decisions:** D5
- **Goal:** TODO
- **Deliverables:** TODO
- **Acceptance criteria:**
  - [ ] TODO
- **Out of scope:** TODO

### S3. Security: JWT, roles claim, local ACTIVE user
- **Depends on:** S2 · **Est:** TODO · **PRD:** B-10, B-11, B-12, B-13 · **Decisions:** D7
- **Goal:** TODO
- **Deliverables:** TODO
- **Acceptance criteria:**
  - [ ] TODO
- **Out of scope:** TODO

### S4. Audit writer
- **Depends on:** S2, S3 · **Est:** TODO · **PRD:** B-50 · **Decisions:** D8
- **Goal:** TODO
- **Deliverables:** TODO
- **Acceptance criteria:**
  - [ ] TODO
- **Out of scope:** TODO

### S5. Menus CRUD
- **Depends on:** S4 · **Est:** TODO · **PRD:** B-44 · **Decisions:** —
- **Goal:** TODO
- **Deliverables:** TODO
- **Acceptance criteria:**
  - [ ] TODO
- **Out of scope:** TODO

### S6. Roles CRUD + guards
- **Depends on:** S4 · **Est:** TODO · **PRD:** B-40 · **Decisions:** D4, D6, D9, D10, D11
- **Goal:** TODO
- **Deliverables:** TODO
- **Acceptance criteria:**
  - [ ] TODO
- **Out of scope:** TODO

### S7. Role → menus
- **Depends on:** S5, S6 · **Est:** TODO · **PRD:** B-41 · **Decisions:** —
- **Goal:** TODO
- **Deliverables:** TODO
- **Acceptance criteria:**
  - [ ] TODO
- **Out of scope:** TODO

### S8. Keycloak client + create user
- **Depends on:** S6 · **Est:** TODO · **PRD:** B-31, B-32 · **Decisions:** D4, D8
- **Goal:** TODO
- **Deliverables:** TODO
- **Acceptance criteria:**
  - [ ] TODO
- **Out of scope:** TODO

### S9. Users list / get / update
- **Depends on:** S8 · **Est:** TODO · **PRD:** B-30, B-33 · **Decisions:** D7
- **Goal:** TODO
- **Deliverables:** TODO
- **Acceptance criteria:**
  - [ ] TODO
- **Out of scope:** TODO

### S10. User status, roles diff, reset password
- **Depends on:** S8 · **Est:** TODO · **PRD:** B-34, B-35, B-36 · **Decisions:** D8
- **Goal:** TODO
- **Deliverables:** TODO
- **Acceptance criteria:**
  - [ ] TODO
- **Out of scope:** TODO

### S11. Role → permissions + gateway sync
- **Depends on:** S6 · **Est:** TODO · **PRD:** B-42, B-43 · **Decisions:** D1, D3, D4, D10, D11
- **Goal:** TODO
- **Deliverables:** TODO
- **Acceptance criteria:**
  - [ ] TODO
- **Out of scope:** TODO

### S12. Current user: `/me`, `/me/menus`
- **Depends on:** S3, S7 · **Est:** TODO · **PRD:** B-20, B-21 · **Decisions:** D6
- **Goal:** TODO
- **Deliverables:** TODO
- **Acceptance criteria:**
  - [ ] TODO
- **Out of scope:** TODO

### S13. Backend run-through of scenarios S1–S6
- **Depends on:** S0–S12 · **Est:** TODO · **PRD:** scenarios S1–S6 (backend side) · **Decisions:** —
- **Goal:** TODO
- **Deliverables:** TODO
- **Acceptance criteria:**
  - [ ] TODO
- **Out of scope:** TODO

---

## 5. Dependency graph

Draft — confirm on Tue 10.

```
S0 ─► S1 ─► S2 ─► S2a ─► S3 ─► S4 ─┬─► S5 ──────┐
                                   │            ├─► S7 ─► S12
                                   └─► S6 ──────┤
                                        │       │
                                        ├─► S11 │
                                        │       │
                                        └─► S8 ─┬─► S9
                                                └─► S10
                                      all ─► S13
```

TODO: the order rule says a role's realm role must exist in Keycloak (S11 sync) before a user
gets that role (S8). With a mocked Keycloak this doesn't block S8's tests, but a real run does.
Decide: build S11 before S8, or create the realm role by hand for S8's real run.

---

## 6. Traceability (PRD requirement → sub-task)

| PRD ID | Requirement (short) | Sub-task |
|---|---|---|
| B-01 | Flyway, 7 tables | S2 |
| B-02 | Seed 12 menus + SUPER_ADMIN | S2 |
| B-03 | Response envelope + error body | S1 |
| B-04 | Pagination | S1 (model), S9 (first use) |
| B-05 | `/health` unauthenticated | S1 |
| B-06 | OpenAPI + Swagger UI | S1 |
| B-10 | Validate JWT independently | S3 |
| B-11 | Configurable roles claim path | S3 |
| B-12 | Local user exists + ACTIVE | S3 |
| B-13 | No secrets in repo | S3 (and every sub-task) |
| B-20 | `GET /me` | S12 |
| B-21 | `GET /me/menus` | S12 |
| B-30 | List users with filters | S9 |
| B-31 | Create user with Keycloak | S8 |
| B-32 | Partial failure → 502 + audit | S8 |
| B-33 | Get / update user | S9 |
| B-34 | Status, mirrored to Keycloak | S10 |
| B-35 | Replace role set with diff | S10 |
| B-36 | Reset password | S10 |
| B-40 | Roles CRUD + guards | S6 |
| B-41 | Role menus | S7 |
| B-42 | Role permissions + auto-sync | S11 |
| B-43 | Manual sync | S11 |
| B-44 | Menus CRUD | S5 |
| B-50 | Audit every mutation | S4 (writer), S5–S11 (each uses it) |
| §12 | Bootstrap admin (not a B-ID) | S2a |
| F-01…F-15 | Admin UI | Out of scope (separate repo) |

---

## 7. Effort estimate

| Sub-task | Est. (h) | Planned day |
|---|---|---|
| S0 | TODO | Wed 11 (pm) |
| S1–S13 | TODO | Thu 12 – Thu 19 |
| **Total** | TODO | |

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
