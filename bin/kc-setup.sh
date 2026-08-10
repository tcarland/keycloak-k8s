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
#   ./kc-setup.sh env/prod.env overlays/prod
#
# Environment variables (defaults shown):
#   KEYCLOAK_REALM_NAME=app
#   KEYCLOAK_ADMIN_USER=admin
#   KEYCLOAK_ADMIN_PASSWORD=admin
#   APP_CLIENT_ID=app-client
#   APP_CLIENT_SECRET=app-client-secret
#   KEYCLOAK_DB_URL=jdbc:postgresql://postgres:5432/keycloak
#   KEYCLOAK_DB_USERNAME=keycloak
#   KEYCLOAK_DB_PASSWORD=CHANGE_ME_IN_PRODUCTION
#   KEYCLOAK_DB_NAME=keycloak
#
# Requires: envsubst (gettext)
PNAME=$(basename "$0")
AUTHOR="Timothy C. Arland <tcarland at gmail dot com>"
VERSION="v26.08.10"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"

set -euo pipefail

# --- Load env file  ---------------------------------------------------------

ENV_NAME="$1"

if [ -z "$ENV_NAME" ]; then
    echo "usage: $PNAME <envname>"
fi

ENV_DIR="env/${ENV_NAME}"
ENV_FILE="${ENV_DIR}/${ENV_NAME}.env"

if [[ ! -f $ENV_FILE ]]; then
    echo "$PNAME Error, env file not found for '$ENV_NAME'"
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# --- Defaults (development) -------------------------------------------------

: "${KEYCLOAK_REALM_NAME:=app}"
: "${KEYCLOAK_ADMIN_USER:=admin}"
: "${KEYCLOAK_ADMIN_PASSWORD:=admin}"
: "${APP_CLIENT_ID:=app-client}"
: "${APP_CLIENT_SECRET:=app-client-secret}"
: "${KEYCLOAK_DB_URL:=jdbc:postgresql://postgres:5432/keycloak}"
: "${KEYCLOAK_DB_USERNAME:=keycloak}"
: "${KEYCLOAK_DB_PASSWORD:=CHANGE_ME_IN_PRODUCTION}"
: "${KEYCLOAK_DB_NAME:=keycloak}"

export KEYCLOAK_ADMIN_USER KEYCLOAK_ADMIN_PASSWORD APP_CLIENT_ID APP_CLIENT_SECRET
export KEYCLOAK_DB_URL KEYCLOAK_DB_USERNAME KEYCLOAK_DB_PASSWORD KEYCLOAK_DB_NAME


# --- Check for envsubst -----------------------------------------------------

if ! command -v envsubst >/dev/null 2>&1; then
    echo "Error: envsubst is required but not found." >&2
    echo "  Install gettext:  apt install gettext  |  brew install gettext" >&2
    exit 1
fi

# --- Generate files ---------------------------------------------------------

echo "Generating Keycloak db configuration"
echo "  Admin user:   $KEYCLOAK_ADMIN_USER"
echo "  Realm:        $KEYCLOAK_REALM_NAME"
echo "  Client ID:    $APP_CLIENT_ID"
echo "  DB URL:       $KEYCLOAK_DB_URL"

# Generate postgres.env (always in postgres/, shared by all overlays)
envsubst < "$PROJECT_DIR/postgres/base/postgres.template.env" > "$PROJECT_DIR/postgres/base/postgres.env"
echo "  -> postgres/base/postgres.env"

envsubst < "$PROJECT_DIR/base/secrets.template.env" > "base/secrets.env"
echo "  -> secrets.env"

envsubst < "$PROJECT_DIR/base/realm.template.json" > "base/realm.json"
echo "  -> realm.json"

if [[ ! -d overlays/${ENV_NAME} ]]; then
    echo "Overlay directory not found, creating and using dev as template"
    mkdir -p overlays/${ENV_NAME}
    cp overlays/dev/kustomization.yaml overlays/${ENV_NAME}/
fi
envsubst < "$PROJECT_DIR/base/db.template.env" > "overlays/${ENV_NAME}/db.env"
echo "  -> db.env"


# --- Copy Certificate files --------------------------------------------------

if [ -f ${ENV_DIR}/tls.crt ]; then
    cp ${ENV_DIR}/tls.crt overlays/${ENV_NAME}
    cp ${ENV_DIR}/tls.key overlays/${ENV_NAME}
fi

# --- Ensure namespace exists -------------------------------------------------
# The namespace is created here rather than via kustomize manifests so that
# PostgreSQL can be deployed before Keycloak into the same namespace.
if command -v kubectl >/dev/null 2>&1; then
    kubectl create namespace keycloak --dry-run=client -o yaml 2>/dev/null | \
        kubectl apply -f - >/dev/null 2>&1 && \
        echo "  -> namespace/keycloak ensured" || \
        echo "  -> namespace/keycloak: skipped (kubectl error, create manually)"
else
    echo "  -> namespace/keycloak: skipped (kubectl not found, create manually)"
fi

echo ""
echo "Done. Review the generated files before deploying."
