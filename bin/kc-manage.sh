#!/bin/bash
#
# keycloak-manage.sh - Manage Keycloak realm users and clients
#
# Usage:
#   ./scripts/keycloak-manage.sh <command> [args]
#
# Commands:
#   add-user <username> <password> <role>   Add a user to the realm
#   remove-user <username>                  Remove a user from the realm
#   add-client <client-id> <secret>         Add a client to the realm
#   remove-client <client-id>               Remove a client from the realm
#   add-user-role <username> <role>         Assign a realm role to a user
#   remove-user-role <username> <role>      Remove a realm role from a user
#   add-role <role-name> [description]      Add a realm role
#   remove-role <role-name>                 Remove a realm role
#   list-users                              List all users in the realm
#   list-clients                            List all clients in the realm
#   backup                                  Backup current realm config
#   restore <backup-file>                   Restore realm config from backup
#   show                                    Show current realm config
#
# Environment:
#   KUBECONFIG           - Kubernetes config (default: ~/.kube/config)
#   KEYCLOAK_NAMESPACE   - Kubernetes namespace (default: keycloak)
#   KEYCLOAK_SECRET_NAME - Secret name (default: keycloak-realm)
#
set -e

VERSION="v26.08.09"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$PROJECT_ROOT/.backups"

# Defaults
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
KEYCLOAK_SECRET_NAME="${KEYCLOAK_SECRET_NAME:-keycloak-realm}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'


info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
die()   { error "$1"; exit 1; }


# Check dependencies
check_deps() {
    for cmd in kubectl jq base64; do
        if ! command -v "$cmd" &> /dev/null; then
            die "Required command not found: $cmd"
        fi
    done
}


# Get current realm config from secret
get_realm_config() {
    kubectl get secret "$KEYCLOAK_SECRET_NAME" -n "$KEYCLOAK_NAMESPACE" \
        -o jsonpath='{.data.realm\.json}' 2>/dev/null | base64 -d
}


# Update realm config in secret
update_realm_config() {
    local config="$1"
    local encoded
    encoded=$(echo -n "$config" | base64 -w0)
    
    kubectl patch secret "$KEYCLOAK_SECRET_NAME" -n "$KEYCLOAK_NAMESPACE" \
        --type='json' \
        -p="[{\"op\": \"replace\", \"path\": \"/data/realm.json\", \"value\": \"$encoded\"}]"
}


# Add a user to the realm
add_user() {
    local username="$1"
    local password="$2"
    local role="${3:-catalog-reader}"
    
    [[ -z "$username" ]] && die "Usage: add-user <username> <password> [role]"
    [[ -z "$password" ]] && die "Usage: add-user <username> <password> [role]"
    
    local config
    config=$(get_realm_config)
    [[ -z "$config" ]] && die "Could not retrieve realm config from secret"
    
    # Check if user already exists
    if echo "$config" | jq -e ".users[] | select(.username == \"$username\")" > /dev/null 2>&1; then
        die "User already exists: $username"
    fi
    
    # Create user JSON
    local user_json
    user_json=$(cat <<EOF
{
  "username": "$username",
  "email": "${username}@cluster.local",
  "enabled": true,
  "firstName": "$username",
  "lastName": "User",
  "credentials": [
    {
      "type": "password",
      "value": "$password",
      "temporary": false
    }
  ],
  "realmRoles": ["$role"]
}
EOF
)
    
    # Add user to config
    local new_config
    new_config=$(echo "$config" | jq --argjson user "$user_json" '.users += [$user]')
    
    # Update secret
    update_realm_config "$new_config"
    
    info "Added user: $username with role: $role"
    warn "Restart Keycloak to apply changes: kubectl rollout restart deployment/keycloak -n $KEYCLOAK_NAMESPACE"
}


# Remove a user from the realm
remove_user() {
    local username="$1"
    
    [[ -z "$username" ]] && die "Usage: remove-user <username>"
    
    local config
    config=$(get_realm_config)
    [[ -z "$config" ]] && die "Could not retrieve realm config from secret"
    
    # Check if user exists
    if ! echo "$config" | jq -e ".users[] | select(.username == \"$username\")" > /dev/null 2>&1; then
        die "User not found: $username"
    fi
    
    # Remove user from config
    local new_config
    new_config=$(echo "$config" | jq "del(.users[] | select(.username == \"$username\"))")
    
    # Update secret
    update_realm_config "$new_config"
    
    info "User removed: $username"
    warn "Restart Keycloak to apply changes: kubectl rollout restart deployment/keycloak -n $KEYCLOAK_NAMESPACE"
}


# Add a client to the realm
add_client() {
    local client_id="$1"
    local secret="$2"
    
    [[ -z "$client_id" ]] && die "Usage: add-client <client-id> <secret>"
    [[ -z "$secret" ]] && die "Usage: add-client <client-id> <secret>"
    
    local config
    config=$(get_realm_config)
    [[ -z "$config" ]] && die "Could not retrieve realm config from secret"
    
    # Check if client already exists
    if echo "$config" | jq -e ".clients[] | select(.clientId == \"$client_id\")" > /dev/null 2>&1; then
        die "Client already exists: $client_id"
    fi
    
    # Create client JSON
    local client_json
    client_json=$(cat <<EOF
{
  "clientId": "$client_id",
  "name": "$client_id",
  "enabled": true,
  "publicClient": false,
  "secret": "$secret",
  "directAccessGrantsEnabled": true,
  "serviceAccountsEnabled": true,
  "standardFlowEnabled": false,
  "protocol": "openid-connect",
  "defaultClientScopes": ["openid", "profile", "roles"]
}
EOF
)
    # Add client to config
    local new_config
    new_config=$(echo "$config" | jq --argjson client "$client_json" '.clients += [$client]')
    
    # Update secret
    update_realm_config "$new_config"
    
    info "Client added: $client_id"
    warn "Restart Keycloak to apply changes: kubectl rollout restart deployment/keycloak -n $KEYCLOAK_NAMESPACE"
}


# Remove a client from the realm
remove_client() {
    local client_id="$1"
    
    [[ -z "$client_id" ]] && die "Usage: remove-client <client-id>"
    
    local config
    config=$(get_realm_config)
    [[ -z "$config" ]] && die "Could not retrieve realm config from secret"
    
    # Check if client exists
    if ! echo "$config" | jq -e ".clients[] | select(.clientId == \"$client_id\")" > /dev/null 2>&1; then
        die "Client not found: $client_id"
    fi
    
    # Remove client from config
    local new_config
    new_config=$(echo "$config" | jq "del(.clients[] | select(.clientId == \"$client_id\"))")
    
    # Update secret
    update_realm_config "$new_config"
    
    info "Client removed: $client_id"
    warn "Restart Keycloak to apply changes: kubectl rollout restart deployment/keycloak -n $KEYCLOAK_NAMESPACE"
}


add_user_role() {
    local username="$1"
    local role="$2"

    [[ -z "$username" ]] && die "Usage: add-user-role <username> <role>"
    [[ -z "$role" ]] && die "Usage: add-user-role <username> <role>"

    local config
    config=$(get_realm_config)
    [[ -z "$config" ]] && die "Could not retrieve realm config from secret"

    # Check if user exists
    if ! echo "$config" | jq -e ".users[] | select(.username == \"$username\")" > /dev/null 2>&1; then
        die "User not found: $username"
    fi

    # Check if role exists
    if ! echo "$config" | jq -e ".roles.realm[] | select(.name == \"$role\")" > /dev/null 2>&1; then
        die "Role not found: $role"
    fi

    # Add role to user's realmRoles
    local new_config
    new_config=$(echo "$config" | jq --arg u "$username" --arg r "$role" '
        .users |= map(if .username == $u then .realmRoles += [$r] else . end)
    ')

    # Update secret
    update_realm_config "$new_config"

    info "Role '$role' assigned to user '$username'"
    warn "Restart Keycloak to apply changes: kubectl rollout restart deployment/keycloak -n $KEYCLOAK_NAMESPACE"
}


remove_user_role() {
    local username="$1"
    local role="$2"

    [[ -z "$username" ]] && die "Usage: remove-user-role <username> <role>"
    [[ -z "$role" ]] && die "Usage: remove-user-role <username> <role>"

    local config
    config=$(get_realm_config)
    [[ -z "$config" ]] && die "Could not retrieve realm config from secret"

    # Check if user exists
    if ! echo "$config" | jq -e ".users[] | select(.username == \"$username\")" > /dev/null 2>&1; then
        die "User not found: $username"
    fi

    # Check if role exists
    if ! echo "$config" | jq -e ".roles.realm[] | select(.name == \"$role\")" > /dev/null 2>&1; then
        die "Role not found: $role"
    fi

    # Remove role from user's realmRoles
    local new_config
    new_config=$(echo "$config" | jq --arg u "$username" --arg r "$role" '
        .users |= map(if .username == $u then .realmRoles |= map(select(. != $r)) else . end)
    ')

    # Update secret
    update_realm_config "$new_config"

    info "Role '$role' removed from user '$username'"
    warn "Restart Keycloak to apply changes: kubectl rollout restart deployment/keycloak -n $KEYCLOAK_NAMESPACE"
}


# Add a realm role
add_role() {
    local role_name="$1"
    local description="${2:-}"

    [[ -z "$role_name" ]] && die "Usage: add-role <role-name> [description]"

    local config
    config=$(get_realm_config)
    [[ -z "$config" ]] && die "Could not retrieve realm config from secret"

    # Check if role already exists
    if echo "$config" | jq -e ".roles.realm[] | select(.name == \"$role_name\")" > /dev/null 2>&1; then
        die "Role already exists: $role_name"
    fi

    # Create role JSON
    local role_json
    role_json=$(cat <<EOF
{
  "name": "$role_name",
  "description": "$description"
}
EOF
)

    # Add role to config
    local new_config
    new_config=$(echo "$config" | jq --argjson role "$role_json" '.roles.realm += [$role]')

    # Update secret
    update_realm_config "$new_config"

    info "Role added: $role_name"
    warn "Restart Keycloak to apply changes: kubectl rollout restart deployment/keycloak -n $KEYCLOAK_NAMESPACE"
}


# Remove a realm role
remove_role() {
    local role_name="$1"

    [[ -z "$role_name" ]] && die "Usage: remove-role <role-name>"

    local config
    config=$(get_realm_config)
    [[ -z "$config" ]] && die "Could not retrieve realm config from secret"

    # Check if role exists
    if ! echo "$config" | jq -e ".roles.realm[] | select(.name == \"$role_name\")" > /dev/null 2>&1; then
        die "Role not found: $role_name"
    fi

    # Remove role from config and strip it from any users' realmRoles
    local new_config
    new_config=$(echo "$config" | jq --arg r "$role_name" '
        del(.roles.realm[] | select(.name == $r))
        | .users |= map(if has("realmRoles") then .realmRoles |= map(select(. != $r)) else . end)
    ')

    # Update secret
    update_realm_config "$new_config"

    info "Role removed: $role_name (also stripped from users' realmRoles)"
    warn "Restart Keycloak to apply changes: kubectl rollout restart deployment/keycloak -n $KEYCLOAK_NAMESPACE"
}


# List users in the realm
list_users() {
    info "Users in realm:"
    echo ""
    
    local config
    config=$(get_realm_config)
    [[ -z "$config" ]] && die "Could not retrieve realm config from secret"
    
    echo "$config" | jq -r '.users[] | "  \(.username)\t\(.realmRoles | join(", "))"' | column -t -s $'\t'
}


# List clients in the realm
list_clients() {
    info "Clients in realm:"
    echo ""
    
    local config
    config=$(get_realm_config)
    [[ -z "$config" ]] && die "Could not retrieve realm config from secret"
    
    echo "$config" | jq -r '.clients[] | "  \(.clientId)\t\(.name // "-")"' | column -t -s $'\t'
}


# Backup current realm config
backup() {
    mkdir -p "$BACKUP_DIR"
    
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="$BACKUP_DIR/keycloak-realm-$timestamp.json"
    
    local config
    config=$(get_realm_config)
    [[ -z "$config" ]] && die "Could not retrieve realm config from secret"
    
    echo "$config" | jq '.' > "$backup_file"
    
    info "Realm config backup saved: $backup_file"
}


# Restore realm config from backup
restore() {
    local backup_file="$1"
    
    [[ -z "$backup_file" ]] && die "Usage: restore <backup-file>"
    [[ ! -f "$backup_file" ]] && die "Backup file not found: $backup_file"
    
    info "Restoring realm config from: $backup_file"
    
    local config
    config=$(cat "$backup_file")
    
    # Validate JSON
    if ! echo "$config" | jq empty 2>/dev/null; then
        die "Invalid JSON in backup file"
    fi
    
    # Confirm
    warn "This will replace the current realm configuration."
    read -p "Continue? (y/N) " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Aborted"
        return
    fi
    
    # Update secret
    update_realm_config "$config"
    
    info "Realm config restored"
    warn "Restart Keycloak to apply changes: kubectl rollout restart deployment/keycloak -n $NAMESPACE"
}


# Show current realm config
show() {
    local config
    config=$(get_realm_config)
    [[ -z "$config" ]] && die "Could not retrieve realm config from secret"
    
    echo "$config" | jq '.'
}


# Show usage
usage() {
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  add-user <username> <password> [role]  Add a user (default role: catalog-reader)"
    echo "  remove-user <username>                 Remove a user"
    echo "  add-client <client-id> <secret>        Add a client"
    echo "  remove-client <client-id>              Remove a client"
    echo "  add-user-role <username> <role>        Assign a realm role to a user"
    echo "  remove-user-role <username> <role>     Remove a realm role from a user"
    echo "  add-role <role-name> [description]     Add a realm role"
    echo "  remove-role <role-name>                Remove a realm role"
    echo "  list-users                             List all users"
    echo "  list-clients                           List all clients"
    echo "  backup                                 Backup current realm config"
    echo "  restore <backup-file>                  Restore from backup"
    echo "  show                                   Show current realm config"
    echo ""
    echo "Roles: managed via add-role / remove-role (default: admin, user)"
    echo ""
    echo "Environment:"
    echo "  KEYCLOAK_NAMESPACE    - Kubernetes namespace (default: keycloak)"
    echo "  KEYCLOAK_SECRET_NAME  - Secret name (default: keycloak-realm)"
    echo ""
    echo "Examples:"
    echo "  $0 add-user alice secret123 catalog-writer"
    echo "  $0 add-client trino-client trino-secret"
    echo "  $0 add-role catalog-reader 'Read access to catalog'"
    echo "  $0 list-users"
    echo "  $0 backup"
}


# Main
main() {
    check_deps
    
    case "${1:-}" in
        add-user)
            add_user "$2" "$3" "$4"
            ;;
        remove-user)
            remove_user "$2"
            ;;
        add-client)
            add_client "$2" "$3"
            ;;
        remove-client)
            remove_client "$2"
            ;;
        add-user-role)
            add_user_role "$2" "$3"
            ;;
        remove-user-role)
            remove_user_role "$2" "$3"
            ;;
        add-role)
            add_role "$2" "$3"
            ;;
        remove-role)
            remove_role "$2"
            ;;
        list-users)
            list_users
            ;;
        list-clients)
            list_clients
            ;;
        backup)
            backup
            ;;
        restore)
            restore "$2"
            ;;
        show)
            show
            ;;
        -h|--help|help|"")
            usage
            ;;
        *)
            error "Unknown command: $1"
            echo ""
            usage
            exit 1
            ;;
    esac
}

main "$@"
