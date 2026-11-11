# cce-admin-service — Developer Setup

How to run the local environment on your machine. The service itself (Java, Maven, Spring Boot)
is added to this guide from sub-task S1 on.

## 1. Prerequisites

| Tool | Version | Check |
|------|---------|-------|
| **Docker** | 24.x+ | `docker --version` |
| **Docker Compose** | 2.x (plugin) | `docker compose version` |
| **curl** | any | `curl --version` |
| **jq** | 1.6+ | `jq --version` |
| **Git** | 2.x+ | `git --version` |

Ports used on your machine: **5434** (Postgres) and **8180** (Keycloak), bound to `127.0.0.1`
only. They avoid 5433 and 8080, used by `extras/cce-local-setup`.

## 2. Clone

```bash
git clone https://github.com/mehul-kunwar-tarento/cce-admin-service-poc.git
cd cce-admin-service-poc
```

## 3. Project Structure

```
cce-admin-service-poc/
├── README.md                     # Quick start
├── ARCHITECTURE.md               # What the service is and why
├── SPEC.md                       # Decisions (D1…) and sub-tasks (S0…)
├── docker-compose.yml            # Local Postgres + Keycloak
├── .env.example                  # Settings template (copy to .env)
├── .gitignore                    # Keeps .env out of git
├── local/
│   ├── keycloak/
│   │   └── cce-realm-local.json  # Realm "cce", imported when Keycloak starts
│   ├── create-superadmin.sh      # Creates the test user superadmin
│   └── get-token.sh              # Prints a token for superadmin
└── docs/                         # This guide and the other design docs
```

## 4. Settings (`.env`)

All passwords live in `.env`, which is in `.gitignore` and never committed.

```bash
cp .env.example .env
```

Fill in every empty value. Any random string works locally; to make one:

```bash
openssl rand -hex 16
```

| Variable | Used by | Meaning |
|---|---|---|
| `POSTGRES_DB` | Postgres | Database name, `admin_service` |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` | Postgres | Database login |
| `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD` | Keycloak | Admin console login (realm `master`) |
| `SUPERADMIN_PASSWORD` | `create-superadmin.sh`, `get-token.sh` | Password of the test user `superadmin` |
| `KEYCLOAK_CLIENT_SECRET` | Keycloak realm import | Secret of client `cce-admin-service` |

## 5. Docker Compose (Local Environment)

### What runs

| Container | Image | Port on your machine | Data kept in volume |
|---|---|---|---|
| `cce-admin-postgres` | `postgres:16` | `127.0.0.1:5434` | `postgres-data` |
| `cce-admin-keycloak` | `quay.io/keycloak/keycloak:26.5.4` (same as `deploy-scripts`) | `127.0.0.1:8180` | `keycloak-data` |

- Postgres holds only the service's database `admin_service`. It is empty until the service's
  Flyway migrations run (S2).
- Keycloak runs in `start-dev` mode and keeps its own data in its built-in database
  (in the `keycloak-data` volume), not in Postgres.
- Both have health checks; `docker compose ps` shows `healthy` when they are ready
  (about 20 seconds).

### Commands

| What | Command | Local data |
|---|---|---|
| Start | `docker compose up -d` | kept |
| Status | `docker compose ps` | — |
| Logs | `docker compose logs -f keycloak` | — |
| Stop | `docker compose down` | kept |
| Reset | `docker compose down -v`, then start again and run `create-superadmin.sh` | **deleted** |

### Connect to the database

```bash
docker compose exec postgres psql -U admin_service -d admin_service
```

With `psql` installed on your machine: `psql -h localhost -p 5434 -U admin_service -d admin_service`
(password: `POSTGRES_PASSWORD` from `.env`).

## 6. Keycloak

Admin console: <http://localhost:8180> — log in with `KEYCLOAK_ADMIN_USER` /
`KEYCLOAK_ADMIN_PASSWORD`, then switch to realm **cce** (top-left).

### Realm `cce` (`local/keycloak/cce-realm-local.json`)

Imported automatically when Keycloak starts, **only if the realm does not exist yet**. After
changing this file, reset (`docker compose down -v`) for the change to take effect.

| Item | Purpose |
|---|---|
| Realm role `SUPER_ADMIN` | Role of the first admin (SPEC D5) |
| Client `cce-admin-service` | Confidential client with a service account. The service uses it to call the Keycloak Admin API. Secret from `.env`. Roles (in `realm-management`, realm `cce` only): `view-users`, `query-users`, `manage-users` |
| Client `cce-admin-local` | Public client for test tokens. Browser login only, redirect `http://localhost:9999/callback`. Adds `cce-admin-service` to the token's `aud`. Local only |

The realm file holds no people and no secrets: `superadmin` comes from the script below, and the
client secret is read from `.env` (`${KEYCLOAK_CLIENT_SECRET}`) during import.

### Test user `superadmin`

```bash
./local/create-superadmin.sh
```

Creates `superadmin` (email `superadmin@cce.local`, name Super Admin), sets its password from
`SUPERADMIN_PASSWORD` and gives it realm role `SUPER_ADMIN`. Safe to run again: an existing
user is not created twice. Run it after every reset.

On other environments a person does this by hand in the Keycloak admin console (SPEC D5).

## 7. Getting a Token

```bash
TOKEN=$(./local/get-token.sh)
```

The script logs in the way a browser does (login page → code → token), because only that kind of
login puts `auth_time` in the token (see Troubleshooting). The token is valid for 5 minutes.

To read what is inside:

```bash
./local/get-token.sh | jq -R 'split(".") | .[1] | gsub("-";"+") | gsub("_";"/") | @base64d | fromjson'
```

Claims to expect:

| Claim | Local value |
|---|---|
| `iss` | `http://localhost:8180/realms/cce` |
| `aud` | `["cce-admin-service", "account"]` |
| `realm_access.roles` | contains `SUPER_ADMIN` |
| `auth_time` | time of login (seconds since 1970, UTC) |
| `sub` | `superadmin`'s Keycloak id (new after every reset) |

## 8. Verifying the Setup

```bash
docker compose ps                                                     # both "healthy"
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8180/realms/cce   # 200
./local/get-token.sh > /dev/null && echo "token OK"
```

## 9. Troubleshooting

| Problem | Cause and fix |
|---|---|
| `port is already allocated` on `up` | Another program uses 5434 or 8180. Find it with `ss -ltnp \| grep -E ':(5434\|8180) '` |
| `set POSTGRES_PASSWORD in .env` (or another variable) on `up` | `.env` is missing or has an empty value. See §4 |
| Keycloak stays `starting` / `unhealthy` | `docker compose logs keycloak`. It needs about 20 seconds; the health check gives it up to 2 minutes |
| Changed `cce-realm-local.json`, nothing changed in Keycloak | The realm is imported only when it does not exist. Reset: `docker compose down -v && docker compose up -d`, then `./local/create-superadmin.sh` |
| `get-token.sh`: `login failed for superadmin` | User missing (e.g. after a reset) or wrong password. Run `./local/create-superadmin.sh` |
| Token has no `auth_time` | It came from a password-grant login. In Keycloak 26.5.4 only a browser-style login sets `auth_time`. Use `get-token.sh` |
| `create-superadmin.sh` prints `Logging into …` and `Created new user with id …` | Info lines from Keycloak's `kcadm` tool, not errors |
