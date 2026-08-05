#!/usr/bin/env bash
#
# Generate Keycloak secrets.env, realm.json, and db.env from templates.
#
# Usage:
#   ./kc-setup.sh [env-file] [output-dir]
#
# Examples:
#   # Generate base config with development defaults (admin/admin)
#   ./kc-setup.sh
#
#   # Generate config from env/env.template
#   ./kc-setup.sh env/env
#
#   # Generate production config from an env file
#   ./kc-setup.sh env/env overlays/prod
#
# Environment variables (defaults shown):
#   KEYCLOAK_ADMIN_USER=admin
#   KEYCLOAK_ADMIN_PASSWORD=admin
#   APP_CLIENT_ID=app-client
#   APP_CLIENT_SECRET=app-client-secret
#   KEYCLOAK_DB_URL=jdbc:postgresql://postgres:5432/keycloak
#   KEYCLOAK_DB_USERNAME=keycloak
#   KEYCLOAK_DB_PASSWORD=CHANGE_ME_IN_PRODUCTION
#
# Requires: envsubst (gettext)

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Load env file if provided ----------------------------------------------

ENV_FILE="${1:-}"
if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# --- Defaults (development) -------------------------------------------------

: "${KEYCLOAK_ADMIN_USER:=admin}"
: "${KEYCLOAK_ADMIN_PASSWORD:=admin}"
: "${APP_CLIENT_ID:=app-client}"
: "${APP_CLIENT_SECRET:=app-client-secret}"
: "${KEYCLOAK_DB_URL:=jdbc:postgresql://postgres:5432/keycloak}"
: "${KEYCLOAK_DB_USERNAME:=keycloak}"
: "${KEYCLOAK_DB_PASSWORD:=CHANGE_ME_IN_PRODUCTION}"

export KEYCLOAK_ADMIN_USER KEYCLOAK_ADMIN_PASSWORD APP_CLIENT_ID APP_CLIENT_SECRET
export KEYCLOAK_DB_URL KEYCLOAK_DB_USERNAME KEYCLOAK_DB_PASSWORD

# --- Output directory -------------------------------------------------------

OUTPUT_DIR="${2:-$PROJECT_DIR/base}"
OUTPUT_DIR="$(cd "$PROJECT_DIR" && cd "$OUTPUT_DIR" 2>/dev/null && pwd || echo "$PROJECT_DIR/$OUTPUT_DIR")"

if [[ ! -d "$OUTPUT_DIR" ]]; then
  echo "Error: output directory does not exist: $OUTPUT_DIR" >&2
  exit 1
fi

# --- Check for envsubst -----------------------------------------------------

if ! command -v envsubst >/dev/null 2>&1; then
  echo "Error: envsubst is required but not found." >&2
  echo "  Install gettext:  apt install gettext  |  brew install gettext" >&2
  exit 1
fi

# --- Generate files ---------------------------------------------------------

echo "Generating Keycloak configuration in: $OUTPUT_DIR"
echo "  Admin user:   $KEYCLOAK_ADMIN_USER"
echo "  Realm:        app"
echo "  Client ID:    $APP_CLIENT_ID"
echo "  DB URL:       $KEYCLOAK_DB_URL"

envsubst < "$PROJECT_DIR/base/secrets.template.env" > "$OUTPUT_DIR/secrets.env"
echo "  -> secrets.env"

envsubst < "$PROJECT_DIR/base/realm.template.json" > "$OUTPUT_DIR/realm.json"
echo "  -> realm.json"

envsubst < "$PROJECT_DIR/base/db.template.env" > "$OUTPUT_DIR/db.env"
echo "  -> db.env"

echo ""
echo "Done. Review the generated files before deploying."
