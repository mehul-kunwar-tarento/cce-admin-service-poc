#!/usr/bin/env bash
#
# Prints an access token for the test user "superadmin" (SPEC S0).
# Logs in the way a browser does (authorization code flow) through the public client
# "cce-admin-local", so the token has auth_time (SPEC D7). In Keycloak 26.5.4 a
# password-grant token has no auth_time.
# Local only. The token is valid for 5 minutes; run again for a new one.
#
# The four steps, as a browser does them:
#   1. open Keycloak's login page
#   2. submit username and password in its form
#   3. Keycloak redirects to REDIRECT_URI with a one-time "code"
#      (nothing listens there; the script only reads the code from the redirect address)
#   4. swap the code for a token
#
# Usage (from the repo root):
#   ./local/get-token.sh                 # prints the token
#   TOKEN=$(./local/get-token.sh)        # keeps it in a variable for curl
#
# Only the token goes to stdout; every error goes to stderr.

set -euo pipefail

KEYCLOAK_URL=http://localhost:8180
REALM=cce
CLIENT_ID=cce-admin-local
USERNAME=superadmin
REDIRECT_URI=http://localhost:9999/callback

# Run from the repo root, so .env is found wherever the script is called from
cd "$(dirname "$0")/.."

# Read the superadmin password from .env
if [ ! -f .env ]; then
  echo "ERROR: .env not found. Run: cp .env.example .env  and fill in the values." >&2
  exit 1
fi
set -a        # every variable read from .env is exported
. ./.env
set +a

if [ -z "${SUPERADMIN_PASSWORD:-}" ]; then
  echo "ERROR: SUPERADMIN_PASSWORD is empty in .env" >&2
  exit 1
fi

# Keycloak remembers the login between steps 1 and 2 with a cookie, like a browser.
# The cookie file is temporary and deleted when the script ends (trap … EXIT).
COOKIES=$(mktemp)
trap 'rm -f "$COOKIES"' EXIT

# 1. Open the login page
AUTH_URL="$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/auth?client_id=$CLIENT_ID&response_type=code&scope=openid&redirect_uri=$REDIRECT_URI"

if ! LOGIN_PAGE=$(curl -s -c "$COOKIES" -b "$COOKIES" "$AUTH_URL"); then
  echo "ERROR: Keycloak not reachable at $KEYCLOAK_URL. Run: docker compose up -d" >&2
  exit 1
fi

# The page has <form … action="ADDRESS">; take ADDRESS. In HTML "&amp;" means "&".
FORM_URL=$(echo "$LOGIN_PAGE" | grep -o 'action="[^"]*"' | head -1 | sed 's/^action="//; s/"$//; s/&amp;/\&/g' || true)

if [ -z "$FORM_URL" ]; then
  echo "ERROR: no login form from Keycloak. Is realm $REALM imported and browser login on for $CLIENT_ID?" >&2
  exit 1
fi

# 2. Submit username and password; do not follow the redirect, only read where it points
REDIRECT=$(curl -s -c "$COOKIES" -b "$COOKIES" -o /dev/null -w '%{redirect_url}' -X POST "$FORM_URL" \
  -d username="$USERNAME" \
  --data-urlencode password="$SUPERADMIN_PASSWORD")

# 3. Take the code from the redirect address: …/callback?…&code=CODE&…
CODE=$(echo "$REDIRECT" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')

if [ -z "$CODE" ]; then
  echo "ERROR: login failed for $USERNAME (wrong password, or user missing)." >&2
  echo "Run ./local/create-superadmin.sh and check SUPERADMIN_PASSWORD in .env" >&2
  exit 1
fi

# 4. Swap the code for a token
RESPONSE=$(curl -s -X POST "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" \
  -d grant_type=authorization_code \
  -d client_id="$CLIENT_ID" \
  -d code="$CODE" \
  -d redirect_uri="$REDIRECT_URI")

TOKEN=$(echo "$RESPONSE" | jq -r '.access_token // empty')

if [ -z "$TOKEN" ]; then
  echo "ERROR: no token from Keycloak. Its answer was:" >&2
  echo "$RESPONSE" >&2
  exit 1
fi

echo "$TOKEN"
