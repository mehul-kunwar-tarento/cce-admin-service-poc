# cce-admin-service-poc

Backend for the CCE v2 Admin Module: users, roles, menus and API permissions, kept in step
with Keycloak. A spec-driven learning build, run locally.

- What and why: [ARCHITECTURE.md](ARCHITECTURE.md)
- Decisions and sub-tasks: [SPEC.md](SPEC.md)
- Full setup guide: [docs/developer-setup.md](docs/developer-setup.md)

## Local environment

Postgres (database `admin_service`, port 5434) and Keycloak (realm `cce`, port 8180) in Docker.
Needs Docker with Compose, `curl` and `jq`.

### Start

```bash
cp .env.example .env              # first time only, then fill in the empty values
docker compose up -d              # check with: docker compose ps  (both "healthy")
./local/create-superadmin.sh      # first time, and after every reset
```

### Stop

```bash
docker compose down               # local data is kept
```

### Reset (deletes all local data)

```bash
docker compose down -v
docker compose up -d
./local/create-superadmin.sh
```

### Get a token

```bash
TOKEN=$(./local/get-token.sh)     # superadmin, valid for 5 minutes
```

### Token values for the service (S3)

Read from a real token on 2026-11-12:

| Variable | Local value | Token claim |
|---|---|---|
| `JWT_ISSUER` | `http://localhost:8180/realms/cce` | `iss` |
| `JWT_AUDIENCE` | `cce-admin-service` | `aud` (`["cce-admin-service", "account"]`) |
| `JWT_ROLES_CLAIM_PATH` | `realm_access.roles` | holds `SUPER_ADMIN` |
