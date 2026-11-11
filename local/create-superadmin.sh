#!/usr/bin/env bash
#
# Creates the test user "superadmin" in Keycloak realm "cce" (SPEC S0, D5 flow step 1).
# Local only: on other environments a person does this by hand in the Keycloak admin console.
#
# What it does:
#   1. creates user superadmin (email, first and last name are needed by Keycloak and by S2a)
#   2. sets its password from SUPERADMIN_PASSWORD in .env
#   3. gives it the realm role SUPER_ADMIN
#
# Safe to re-run: an existing user is not created again; password and role are set again,
# which changes nothing if they are already the same.
#
# Usage (from the repo root):   ./local/create-superadmin.sh

set -euo pipefail

CONTAINER=cce-admin-keycloak
REALM=cce
USERNAME=superadmin
EMAIL=superadmin@cce.local
FIRST_NAME=Super
LAST_NAME=Admin
ROLE=SUPER_ADMIN

# Run from the repo root, so .env is found wherever the script is called from
cd "$(dirname "$0")/.."

# 1. Read passwords from .env
if [ ! -f .env ]; then
  echo "ERROR: .env not found. Run: cp .env.example .env  and fill in the values." >&2
  exit 1
fi
set -a        # every variable read from .env is exported
. ./.env
set +a

if [ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]; then
  echo "ERROR: KEYCLOAK_ADMIN_PASSWORD is empty in .env" >&2
  exit 1
fi
if [ -z "${SUPERADMIN_PASSWORD:-}" ]; then
  echo "ERROR: SUPERADMIN_PASSWORD is empty in .env" >&2
  exit 1
fi

# 2. Keycloak must be up and healthy
HEALTH=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "not running")
if [ "$HEALTH" != "healthy" ]; then
  echo "ERROR: Keycloak container is '$HEALTH'. Run: docker compose up -d  and wait until it is healthy." >&2
  exit 1
fi

# kcadm.sh runs inside the Keycloak container; it keeps its login in /tmp/kcadm.config there
kcadm() {
  docker exec "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config
}

# 3. Log kcadm in as the Keycloak admin (master realm)
kcadm config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user "$KEYCLOAK_ADMIN_USER" \
  --password "$KEYCLOAK_ADMIN_PASSWORD" > /dev/null

# 4. Create the user only if it does not exist yet (exact username match)
USER_ID=$(kcadm get users -r "$REALM" -q username="$USERNAME" -q exact=true --fields id --format csv --noquotes)

if [ -z "$USER_ID" ]; then
  kcadm create users -r "$REALM" \
    -s username="$USERNAME" \
    -s enabled=true \
    -s email="$EMAIL" \
    -s emailVerified=true \
    -s firstName="$FIRST_NAME" \
    -s lastName="$LAST_NAME" > /dev/null
  echo "Created user $USERNAME"
else
  echo "User $USERNAME already exists (id $USER_ID), not creating it again"
fi

# 5. Set the password (again) from .env; not temporary, so no "change password" prompt at login
kcadm set-password -r "$REALM" --username "$USERNAME" --new-password "$SUPERADMIN_PASSWORD"
echo "Password set from SUPERADMIN_PASSWORD in .env"

# 6. Give the realm role; adding a role the user already has changes nothing
kcadm add-roles -r "$REALM" --uusername "$USERNAME" --rolename "$ROLE"
echo "Realm role $ROLE assigned"

# 7. Show the result
USER_ID=$(kcadm get users -r "$REALM" -q username="$USERNAME" -q exact=true --fields id --format csv --noquotes)
echo ""
echo "Done. User $USERNAME in realm $REALM, Keycloak id: $USER_ID"
