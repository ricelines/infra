# shellcheck shell=sh

# Defaults for Hetzner resources.
: "${HCLOUD_SERVER_NAME:=tuwunel-matrix}"
: "${HCLOUD_SERVER_TYPE:=cx23}"
: "${HCLOUD_SERVER_IMAGE:=debian-12}"
# nbg1 is in Germany and part of Hetzner's eu-central network zone.
: "${HCLOUD_SERVER_LOCATION:=nbg1}"
# Additional Germany locations to try if capacity is temporarily unavailable.
: "${HCLOUD_SERVER_LOCATION_FALLBACKS:=fsn1}"

# Optional management resources.
: "${HCLOUD_FIREWALL_ENABLE:=true}"
: "${HCLOUD_FIREWALL_NAME:=$HCLOUD_SERVER_NAME-fw}"
: "${HCLOUD_HTTP_ALLOW_CLOUDFLARE_ONLY:=true}"
: "${HCLOUD_SSH_ALLOWED_NETS:=0.0.0.0/0}"

: "${HCLOUD_SSH_KEY_NAME:=$HCLOUD_SERVER_NAME-key}"
: "${HCLOUD_SSH_PUBLIC_KEY_PATH:=$HOME/.ssh/id_ed25519.pub}"
: "${HCLOUD_SSH_PRIVATE_KEY_PATH:=}"
: "${HCLOUD_SSH_KNOWN_HOSTS_FILE:=$SCRIPT_DIR/.known_hosts}"
: "${HCLOUD_SSH_USER:=root}"
: "${HCLOUD_SSH_PORT:=22}"
: "${HCLOUD_SSH_CONNECT_TIMEOUT_SECONDS:=10}"
: "${HCLOUD_SSH_READY_TIMEOUT_SECONDS:=90}"

# Labels make ownership explicit and simplify future filtering.
: "${HCLOUD_LABEL_MANAGED_BY_KEY:=managed-by}"
: "${HCLOUD_LABEL_MANAGED_BY_VALUE:=nq}"
: "${HCLOUD_LABEL_STACK_KEY:=stack}"
: "${HCLOUD_LABEL_STACK_VALUE:=matrix-tuwunel}"

# Cloudflare + DNS.
: "${CLOUDFLARE_MANAGE_DNS:=true}"
: "${CLOUDFLARE_API_TOKEN:=}"
: "${CLOUDFLARE_ZONE_NAME:=}"
: "${CLOUDFLARE_ZONE_ID:=}"
: "${CLOUDFLARE_DNS_PROXIED:=true}"
: "${CLOUDFLARE_DNS_TTL:=1}"

# Matrix + Traefik deployment settings.
: "${MATRIX_BASE_URL:=}"
: "${MATRIX_SERVER_NAME:=}"

: "${MATRIX_ALLOW_REGISTRATION:=true}"
: "${MATRIX_ALLOW_OPEN_REGISTRATION:=false}"
: "${MATRIX_REGISTRATION_TOKEN:=}"
: "${MATRIX_ALLOW_GUEST_REGISTRATION:=false}"
: "${MATRIX_ALLOW_FEDERATION:=false}"
: "${MATRIX_FEDERATE_CREATED_ROOMS:=false}"
: "${MATRIX_ALLOW_ENCRYPTION:=true}"
: "${MATRIX_ENCRYPTION_DEFAULT_ROOM_TYPE:=all}"
: "${MATRIX_GRANT_ADMIN_TO_FIRST_USER:=true}"
: "${MATRIX_CREATE_ADMIN_ROOM:=true}"
: "${MATRIX_FEDERATE_ADMIN_ROOM:=false}"
: "${MATRIX_EMERGENCY_PASSWORD:=}"

: "${TRAEFIK_IMAGE:=traefik:v3}"
: "${TUWUNEL_IMAGE:=ghcr.io/matrix-construct/tuwunel:latest}"
: "${MATRIX_DATA_ROOT:=/srv/matrix}"

: "${MATRIX_WELL_KNOWN_CLIENT_URL:=}"
: "${MATRIX_WELL_KNOWN_SERVER:=}"

normalize_bool_var() {
  name=$1
  value=$(eval "printf '%s' \"\${$name}\"")
  case "$value" in
    true|TRUE|True|1|yes|YES|Yes|on|ON|On)
      eval "$name=true"
      ;;
    false|FALSE|False|0|no|NO|No|off|OFF|Off|'')
      eval "$name=false"
      ;;
    *)
      die "invalid boolean for $name: $value"
      ;;
  esac
}

require_nonempty() {
  name=$1
  value=$(eval "printf '%s' \"\${$name:-}\"")
  [ -n "$value" ] || die "$name is required"
}

require_file() {
  path=$1
  [ -f "$path" ] || die "required file does not exist: $path"
}

url_host_from_https() {
  url=$1
  case "$url" in
    https://*)
      without_scheme=${url#https://}
      host_with_port=${without_scheme%%/*}
      host=${host_with_port%%:*}
      [ -n "$host" ] || return 1
      printf '%s\n' "$host"
      ;;
    *)
      return 1
      ;;
  esac
}

derive_ssh_config() {
  if [ -z "$HCLOUD_SSH_PRIVATE_KEY_PATH" ]; then
    case "$HCLOUD_SSH_PUBLIC_KEY_PATH" in
      *.pub)
        candidate=${HCLOUD_SSH_PUBLIC_KEY_PATH%.pub}
        [ -f "$candidate" ] || die "HCLOUD_SSH_PRIVATE_KEY_PATH is unset and matching private key does not exist: $candidate"
        HCLOUD_SSH_PRIVATE_KEY_PATH=$candidate
        ;;
      *)
        die "HCLOUD_SSH_PRIVATE_KEY_PATH is required when HCLOUD_SSH_PUBLIC_KEY_PATH does not end in .pub"
        ;;
    esac
  fi
}

derive_matrix_config() {
  require_nonempty MATRIX_BASE_URL
  MATRIX_BASE_HOST=$(url_host_from_https "$MATRIX_BASE_URL") || die "MATRIX_BASE_URL must be a valid https:// URL"
  MATRIX_BASE_HOST_NO_DOT=${MATRIX_BASE_HOST%.}

  if [ -z "$CLOUDFLARE_ZONE_NAME" ]; then
    CLOUDFLARE_ZONE_NAME=$MATRIX_SERVER_NAME
  fi

  if [ -z "$MATRIX_WELL_KNOWN_CLIENT_URL" ]; then
    MATRIX_WELL_KNOWN_CLIENT_URL=$MATRIX_BASE_URL
  fi
  if [ -z "$MATRIX_WELL_KNOWN_SERVER" ]; then
    MATRIX_WELL_KNOWN_SERVER=$MATRIX_BASE_HOST_NO_DOT:443
  fi
}

validate_apply_config() {
  normalize_bool_var HCLOUD_FIREWALL_ENABLE
  normalize_bool_var HCLOUD_HTTP_ALLOW_CLOUDFLARE_ONLY
  normalize_bool_var CLOUDFLARE_MANAGE_DNS
  normalize_bool_var CLOUDFLARE_DNS_PROXIED
  normalize_bool_var MATRIX_ALLOW_REGISTRATION
  normalize_bool_var MATRIX_ALLOW_OPEN_REGISTRATION
  normalize_bool_var MATRIX_ALLOW_GUEST_REGISTRATION
  normalize_bool_var MATRIX_ALLOW_FEDERATION
  normalize_bool_var MATRIX_FEDERATE_CREATED_ROOMS
  normalize_bool_var MATRIX_ALLOW_ENCRYPTION
  normalize_bool_var MATRIX_GRANT_ADMIN_TO_FIRST_USER
  normalize_bool_var MATRIX_CREATE_ADMIN_ROOM
  normalize_bool_var MATRIX_FEDERATE_ADMIN_ROOM

  require_nonempty MATRIX_SERVER_NAME
  derive_matrix_config
  derive_ssh_config
  # shellcheck disable=SC2034
  MATRIX_LETSENCRYPT_EMAIL="letsencrypt@$MATRIX_SERVER_NAME"

  require_nonempty CLOUDFLARE_API_TOKEN

  require_nonempty HCLOUD_SSH_KEY_NAME
  require_file "$HCLOUD_SSH_PUBLIC_KEY_PATH"
  require_file "$HCLOUD_SSH_PRIVATE_KEY_PATH"

  if [ "$MATRIX_ALLOW_REGISTRATION" = "true" ] && [ "$MATRIX_ALLOW_OPEN_REGISTRATION" != "true" ] && [ -z "$MATRIX_REGISTRATION_TOKEN" ]; then
    die "MATRIX_REGISTRATION_TOKEN is required when MATRIX_ALLOW_REGISTRATION=true and MATRIX_ALLOW_OPEN_REGISTRATION=false"
  fi
}

validate_destroy_config() {
  normalize_bool_var HCLOUD_FIREWALL_ENABLE
  normalize_bool_var HCLOUD_HTTP_ALLOW_CLOUDFLARE_ONLY
  normalize_bool_var CLOUDFLARE_MANAGE_DNS

  if [ "$CLOUDFLARE_MANAGE_DNS" = "true" ]; then
    require_nonempty MATRIX_SERVER_NAME
    require_nonempty MATRIX_BASE_URL
    derive_matrix_config
    require_nonempty CLOUDFLARE_API_TOKEN
  fi
}

validate_verify_config() {
  normalize_bool_var MATRIX_ALLOW_REGISTRATION
  normalize_bool_var MATRIX_ALLOW_OPEN_REGISTRATION

  require_nonempty MATRIX_SERVER_NAME
  derive_matrix_config
  derive_ssh_config

  if [ "$MATRIX_ALLOW_REGISTRATION" = "true" ] && [ "$MATRIX_ALLOW_OPEN_REGISTRATION" != "true" ] && [ -z "$MATRIX_REGISTRATION_TOKEN" ]; then
    die "MATRIX_REGISTRATION_TOKEN is required when MATRIX_ALLOW_REGISTRATION=true and MATRIX_ALLOW_OPEN_REGISTRATION=false"
  fi
}
