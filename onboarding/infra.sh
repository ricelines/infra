#!/bin/sh
set -eu

SCRIPT_DIR=$(
  CDPATH='' cd -- "$(dirname -- "$0")" && pwd
)
REPO_ROOT=$(
  CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd
)

BASE_ENV_FILE=${ONBOARDING_MATRIX_ENV_FILE:-$SCRIPT_DIR/../matrix/.env}
if [ -f "$BASE_ENV_FILE" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$BASE_ENV_FILE"
  set +a
fi

ENV_FILE=${ONBOARDING_ENV_FILE:-$SCRIPT_DIR/.env}
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
fi

# shellcheck source=infra/matrix/lib/log.sh
. "$SCRIPT_DIR/../matrix/lib/log.sh"
# shellcheck source=infra/matrix/lib/config.sh
. "$SCRIPT_DIR/../matrix/lib/config.sh"
# shellcheck source=infra/matrix/lib/hcloud.sh
. "$SCRIPT_DIR/../matrix/lib/hcloud.sh"
# shellcheck source=infra/matrix/lib/ssh.sh
. "$SCRIPT_DIR/../matrix/lib/ssh.sh"

: "${ONBOARDING_MANAGER_TUNNEL_PORT:=54100}"

: "${ONBOARDING_BOOTSTRAP_OPERATOR_USERNAME:=$MATRIX_ADMIN_USERNAME}"
: "${ONBOARDING_BOOTSTRAP_ONBOARDING_BOT_USERNAME:=onboarding}"
: "${ONBOARDING_BOOTSTRAP_WELCOME_ROOM_ALIAS_LOCALPART:=welcome}"
: "${ONBOARDING_MATRIX_BINDABLE_SERVICE_NAME:=matrix}"
: "${ONBOARDING_MANAGER_BINDABLE_SERVICE_NAME:=amber-manager-api}"
: "${ONBOARDING_SHARED_RESPONSES_BINDABLE_SERVICE_NAME:=responses-api}"

: "${ONBOARDING_ONBOARDING_MODEL:=gpt-5.4-mini}"
: "${ONBOARDING_ONBOARDING_MODEL_REASONING_EFFORT:=medium}"
: "${ONBOARDING_DEFAULT_AGENT_MODEL:=gpt-5.4-mini}"
: "${ONBOARDING_DEFAULT_AGENT_MODEL_REASONING_EFFORT:=medium}"

: "${ONBOARDING_DEFAULT_AGENT_SOURCE_URL:=https://raw.githubusercontent.com/ricelines/scenarios/refs/heads/main/amber/user-agent.json5}"
: "${ONBOARDING_AUTH_PROXY_SOURCE_URL:=https://raw.githubusercontent.com/ricelines/codex-a2a/refs/heads/main/amber/codex-auth-proxy.json5}"
: "${ONBOARDING_SHARED_RESPONSES_BINDABLE_SERVICE_ID:=}"
: "${ONBOARDING_CODEX_AUTH_JSON_PATH:=$MATRIX_DATA_ROOT/onboarding-codex/.codex/auth.json}"
: "${ONBOARDING_DESTROY_CONFIRM:=}"
: "${ONBOARDING_DESTROY_INCLUDE_USER_AGENTS:=false}"

: "${ONBOARDING_PROVISIONER_MANIFEST_PATH:=$REPO_ROOT/onboarding/amber/agent-provisioner.json5}"
: "${ONBOARDING_ONBOARDING_MANIFEST_PATH:=$REPO_ROOT/onboarding/amber/onboarding-agent.json5}"
: "${ONBOARDING_ONBOARDING_DEVELOPER_INSTRUCTIONS_PATH:=$REPO_ROOT/onboarding/prompts/onboarding-developer-instructions.md}"
: "${ONBOARDING_ONBOARDING_AGENTS_MD_PATH:=$REPO_ROOT/onboarding/agents/onboarding-agent.md}"
: "${ONBOARDING_ONBOARDING_WORKSPACE_AGENTS_MD_PATH:=}"
: "${ONBOARDING_DEFAULT_AGENT_DEVELOPER_INSTRUCTIONS_PATH:=$REPO_ROOT/onboarding/prompts/default-user-agent-developer-instructions.md}"
: "${ONBOARDING_DEFAULT_AGENT_AGENTS_MD_PATH:=$REPO_ROOT/onboarding/agents/default-user-agent.md}"
: "${ONBOARDING_DEFAULT_AGENT_WORKSPACE_AGENTS_MD_PATH:=}"
: "${ONBOARDING_CODEX_CONFIG_TOML_PATH:=}"

REMOTE_MANAGER_SOURCE_DIR_SUFFIX=amber-manager/data/bootstrap-sources
REMOTE_MANAGER_SOURCE_URL_PREFIX=file:///var/lib/amber-manager/bootstrap-sources

PROVISIONER_SOURCE_URL=
ONBOARDING_SOURCE_URL=
DEFAULT_AGENT_SOURCE_URL=
AUTH_PROXY_SOURCE_URL=
BOOTSTRAP_CODEX_AUTH_JSON_PATH=

ONBOARDING_METADATA_KIND_AUTH_PROXY=onboarding-auth-proxy
ONBOARDING_METADATA_KIND_PROVISIONER=onboarding-provisioner
ONBOARDING_METADATA_KIND_ONBOARDING=onboarding-agent
ONBOARDING_MANAGED_ROOM_EVENT_TYPE=com.ricelines.onboarding.managed
ONBOARDING_MANAGED_ROOM_KIND_WELCOME=welcome-room

CURRENT_ONBOARDING_BOT_USER_ID=
CURRENT_WELCOME_ROOM_ID=
CURRENT_SHARED_RESPONSES_BINDABLE_SERVICE_ID=
CURRENT_AUTH_PROXY_SCENARIO_ID=
CURRENT_PROVISIONER_SCENARIO_ID=
CURRENT_ONBOARDING_SCENARIO_ID=
CURRENT_BOOTSTRAP_ADMIN_USER_ID=
CURRENT_ROOM_JOIN_RULE=
CURRENT_ROOM_DIRECTORY_VISIBILITY=
CURRENT_ROOM_MESSAGE_POWER_LEVEL=
CURRENT_ROOM_USERS_DEFAULT=
CURRENT_ROOM_ADMIN_POWER_LEVEL=
CURRENT_ROOM_ONBOARDING_BOT_POWER_LEVEL=
ONBOARDING_BOT_PASSWORD=

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  apply    Deploy the onboarding product on top of an existing infra/matrix stack
  verify   Validate the onboarding control plane on top of an existing infra/matrix stack
  destroy  Remove the onboarding control plane from an existing infra/matrix stack

Config files:
  ONBOARDING_MATRIX_ENV_FILE  default: $SCRIPT_DIR/../matrix/.env
  ONBOARDING_ENV_FILE         default: $SCRIPT_DIR/.env

This layer assumes infra/matrix is already applied and reuses its SSH/host settings.

One of:
  ONBOARDING_SHARED_RESPONSES_BINDABLE_SERVICE_ID
  ONBOARDING_AUTH_PROXY_SOURCE_URL

Important notes:
  - apply manages the internal onboarding-bot Matrix password on the target host
    under \$MATRIX_DATA_ROOT/secrets/onboarding/. verify reuses that host-side secret
    and does not read it from onboarding config.
  - ONBOARDING_CODEX_AUTH_JSON_PATH is a path on the target host where this script keeps
    the VM's dedicated Codex auth.json. apply installs Codex there with npm if needed,
    runs device auth there when auth proxy bootstrap needs it, then uses that file for
    the auth-proxy root config.
  - apply temporarily allowlists bootstrap-only scenario sources in amber-manager,
    reconciles the onboarding control plane, then leaves only the default agent source
    allowlisted for future provisioning.
  - verify checks onboarding control-plane scenarios; it does not create a sample end user.
  - destroy is guarded. Set ONBOARDING_DESTROY_CONFIRM=$MATRIX_SERVER_NAME to enable it.
EOF
}

cleanup_tmpdir() {
  if [ -n "${tmpdir:-}" ] && [ -d "$tmpdir" ]; then
    rm -rf "$tmpdir"
  fi
}

cleanup_tunnel() {
  if [ -n "${tunnel_pid:-}" ]; then
    kill "$tunnel_pid" >/dev/null 2>&1 || true
    wait "$tunnel_pid" >/dev/null 2>&1 || true
    tunnel_pid=
  fi
}

handle_interrupt() {
  trap - INT TERM EXIT
  cleanup_tunnel
  cleanup_tmpdir
  exit 130
}

local_abs_path() {
  target=$1
  dir=$(CDPATH='' cd -- "$(dirname -- "$target")" && pwd)
  base=$(basename -- "$target")
  printf '%s/%s\n' "$dir" "$base"
}

require_local_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found. Install it and retry."
}

require_local_prereqs() {
  require_local_command jq
  require_local_command curl
  require_local_command base64
  hcloud_require_cli
  hcloud_require_auth
  ssh_require_cli
}

validate_common_config() {
  normalize_bool_var MATRIX_ALLOW_REGISTRATION
  normalize_bool_var MATRIX_ALLOW_OPEN_REGISTRATION

  require_nonempty MATRIX_BASE_URL
  require_nonempty MATRIX_SERVER_NAME
  derive_matrix_config
  derive_ssh_config

  if [ "$MATRIX_ALLOW_REGISTRATION" = "true" ] && [ "$MATRIX_ALLOW_OPEN_REGISTRATION" != "true" ] && [ -z "$MATRIX_REGISTRATION_TOKEN" ]; then
    die "MATRIX_REGISTRATION_TOKEN is required when MATRIX_ALLOW_REGISTRATION=true and MATRIX_ALLOW_OPEN_REGISTRATION=false"
  fi
}

validate_apply_config() {
  validate_common_config
  require_local_prereqs

  require_nonempty ONBOARDING_DEFAULT_AGENT_SOURCE_URL
  require_nonempty ONBOARDING_ONBOARDING_MODEL
  require_nonempty ONBOARDING_DEFAULT_AGENT_MODEL
  require_nonempty MATRIX_ADMIN_USERNAME
  require_nonempty MATRIX_ADMIN_PASSWORD
  if [ "$ONBOARDING_BOOTSTRAP_OPERATOR_USERNAME" != "$MATRIX_ADMIN_USERNAME" ]; then
    die "onboarding: ONBOARDING_BOOTSTRAP_OPERATOR_USERNAME must equal MATRIX_ADMIN_USERNAME; provisioning must use the server admin account"
  fi

  require_file "$(local_abs_path "$ONBOARDING_PROVISIONER_MANIFEST_PATH")"
  require_file "$(local_abs_path "$ONBOARDING_ONBOARDING_MANIFEST_PATH")"
  require_file "$(local_abs_path "$ONBOARDING_ONBOARDING_DEVELOPER_INSTRUCTIONS_PATH")"
  require_file "$(local_abs_path "$ONBOARDING_ONBOARDING_AGENTS_MD_PATH")"
  if [ -n "$ONBOARDING_ONBOARDING_WORKSPACE_AGENTS_MD_PATH" ]; then
    require_file "$(local_abs_path "$ONBOARDING_ONBOARDING_WORKSPACE_AGENTS_MD_PATH")"
  fi
  require_file "$(local_abs_path "$ONBOARDING_DEFAULT_AGENT_DEVELOPER_INSTRUCTIONS_PATH")"
  require_file "$(local_abs_path "$ONBOARDING_DEFAULT_AGENT_AGENTS_MD_PATH")"
  if [ -n "$ONBOARDING_DEFAULT_AGENT_WORKSPACE_AGENTS_MD_PATH" ]; then
    require_file "$(local_abs_path "$ONBOARDING_DEFAULT_AGENT_WORKSPACE_AGENTS_MD_PATH")"
  fi

  if [ -n "$ONBOARDING_CODEX_CONFIG_TOML_PATH" ]; then
    require_file "$(local_abs_path "$ONBOARDING_CODEX_CONFIG_TOML_PATH")"
  fi

  if [ -z "$ONBOARDING_SHARED_RESPONSES_BINDABLE_SERVICE_ID" ]; then
    require_nonempty ONBOARDING_AUTH_PROXY_SOURCE_URL
    require_nonempty ONBOARDING_CODEX_AUTH_JSON_PATH
    if [ "$(basename -- "$ONBOARDING_CODEX_AUTH_JSON_PATH")" != "auth.json" ]; then
      die "ONBOARDING_CODEX_AUTH_JSON_PATH must end in auth.json because Codex writes to \$CODEX_HOME/auth.json on the target host"
    fi
  fi
}

validate_verify_config() {
  validate_common_config
  require_local_prereqs
  require_nonempty ONBOARDING_DEFAULT_AGENT_SOURCE_URL
  require_nonempty MATRIX_ADMIN_USERNAME
  require_nonempty MATRIX_ADMIN_PASSWORD
  if [ "$ONBOARDING_BOOTSTRAP_OPERATOR_USERNAME" != "$MATRIX_ADMIN_USERNAME" ]; then
    die "onboarding: ONBOARDING_BOOTSTRAP_OPERATOR_USERNAME must equal MATRIX_ADMIN_USERNAME; provisioning must use the server admin account"
  fi
}

validate_destroy_config() {
  validate_common_config
  require_local_prereqs
  normalize_bool_var ONBOARDING_DESTROY_INCLUDE_USER_AGENTS

  if [ "$ONBOARDING_DESTROY_CONFIRM" != "$MATRIX_SERVER_NAME" ]; then
    die "onboarding: destroy is guarded; set ONBOARDING_DESTROY_CONFIRM=$MATRIX_SERVER_NAME to proceed"
  fi
}

manager_source_url() {
  bundle_dir=$1
  input=$2
  staged_name=$3

  case "$input" in
    http://*|https://*)
      printf '%s\n' "$input"
      ;;
    file://*)
      source_path=${input#file://}
      source_abs=$(local_abs_path "$source_path")
      require_file "$source_abs"
      if [ -n "$bundle_dir" ]; then
        cp "$source_abs" "$bundle_dir/manager-sources/$staged_name"
      fi
      printf '%s/%s\n' "$REMOTE_MANAGER_SOURCE_URL_PREFIX" "$staged_name"
      ;;
    *)
      source_abs=$(local_abs_path "$input")
      require_file "$source_abs"
      if [ -n "$bundle_dir" ]; then
        cp "$source_abs" "$bundle_dir/manager-sources/$staged_name"
      fi
      printf '%s/%s\n' "$REMOTE_MANAGER_SOURCE_URL_PREFIX" "$staged_name"
      ;;
  esac
}

resolve_source_urls() {
  bundle_dir=${1:-}

  PROVISIONER_SOURCE_URL=$REMOTE_MANAGER_SOURCE_URL_PREFIX/agent-provisioner.json5
  ONBOARDING_SOURCE_URL=$REMOTE_MANAGER_SOURCE_URL_PREFIX/onboarding-agent.json5
  DEFAULT_AGENT_SOURCE_URL=$(manager_source_url "$bundle_dir" "$ONBOARDING_DEFAULT_AGENT_SOURCE_URL" default-agent.json5)

  AUTH_PROXY_SOURCE_URL=
  if [ -n "$ONBOARDING_AUTH_PROXY_SOURCE_URL" ]; then
    AUTH_PROXY_SOURCE_URL=$(manager_source_url "$bundle_dir" "$ONBOARDING_AUTH_PROXY_SOURCE_URL" auth-proxy.json5)
  fi
}

render_bundle() {
  bundle_dir=$1

  mkdir -p "$bundle_dir/manager-sources"
  cp "$(local_abs_path "$ONBOARDING_PROVISIONER_MANIFEST_PATH")" "$bundle_dir/manager-sources/agent-provisioner.json5"
  cp "$(local_abs_path "$ONBOARDING_ONBOARDING_MANIFEST_PATH")" "$bundle_dir/manager-sources/onboarding-agent.json5"

  resolve_source_urls "$bundle_dir"
}

deploy_bundle() {
  host_ip=$1
  bundle_dir=$2
  stage_dir="/tmp/nq-onboarding-deploy-$HCLOUD_SERVER_NAME"

  ssh_push_dir "$host_ip" "$bundle_dir" "$stage_dir"
  ssh_exec "$host_ip" "MATRIX_DATA_ROOT='$MATRIX_DATA_ROOT' REMOTE_SUFFIX='$REMOTE_MANAGER_SOURCE_DIR_SUFFIX' STAGE_DIR='$stage_dir' sh -s" <<'EOF'
set -eu
target="$MATRIX_DATA_ROOT/$REMOTE_SUFFIX"
rm -rf "$target"
install -d -m 755 "$target"
if [ -d "$STAGE_DIR/manager-sources" ]; then
  find "$STAGE_DIR/manager-sources" -mindepth 1 -maxdepth 1 -type f -exec install -m 644 {} "$target/" \;
fi
rm -rf "$STAGE_DIR"
EOF
}

wait_for_remote_manager_ready() {
  host_ip=$1
  attempts=${2:-90}
  count=0

  while [ "$count" -lt "$attempts" ]; do
    if ssh_exec "$host_ip" "curl -fsS 'http://127.0.0.1:4100/readyz' >/dev/null 2>&1"; then
      return 0
    fi

    count=$((count + 1))
    if [ $((count % 10)) -eq 0 ] || [ "$count" -eq "$attempts" ]; then
      log "onboarding: waiting for amber-manager readiness at http://127.0.0.1:4100/readyz ($count/$attempts)"
    fi
    sleep 2
  done

  return 1
}

wait_for_remote_matrix_ready() {
  host_ip=$1
  attempts=${2:-120}
  count=0

  while [ "$count" -lt "$attempts" ]; do
    if ssh_exec "$host_ip" "curl -fsS 'http://127.0.0.1:8008/_matrix/client/versions' >/dev/null 2>&1"; then
      return 0
    fi

    count=$((count + 1))
    if [ $((count % 10)) -eq 0 ] || [ "$count" -eq "$attempts" ]; then
      log "onboarding: waiting for Matrix readiness at http://127.0.0.1:8008/_matrix/client/versions ($count/$attempts)"
    fi
    sleep 2
  done

  return 1
}

wait_for_room_alias_absent() {
  room_alias=$1
  access_token=$2
  attempts=${3:-60}
  count=0

  while [ "$count" -lt "$attempts" ]; do
    if ! resolve_room_alias "$room_alias" "$access_token"; then
      return 0
    fi

    count=$((count + 1))
    sleep 1
  done

  return 1
}

render_allowlist_json() {
  output_path=$1
  shift
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique' >"$output_path"
}

set_remote_manager_allowlist() {
  host_ip=$1
  allowlist_json_path=$2
  current_config_path="$tmpdir/manager-config.current.json"
  next_config_path="$tmpdir/manager-config.next.json"

  ssh_exec "$host_ip" "MATRIX_DATA_ROOT='$MATRIX_DATA_ROOT' sh -s" <<'EOF' >"$current_config_path"
set -eu
cat "$MATRIX_DATA_ROOT/amber-manager/config/manager-config.json"
EOF

  jq --argjson allowlist "$(cat "$allowlist_json_path")" '
    del(.scenario_source_allowlist)
    | if ($allowlist | length) > 0 then
        .scenario_source_allowlist = $allowlist
      else
        .
      end
  ' "$current_config_path" >"$next_config_path"

  config_b64=$(base64 <"$next_config_path" | tr -d '\n')

  ssh_exec "$host_ip" \
    "MATRIX_DATA_ROOT='$MATRIX_DATA_ROOT' CONFIG_B64='$config_b64' sh -s" <<'EOF'
set -eu

tmp=$(mktemp)
printf '%s' "$CONFIG_B64" | base64 -d >"$tmp"
install -m 644 "$tmp" "$MATRIX_DATA_ROOT/amber-manager/config/manager-config.json"
rm -f "$tmp"

docker compose --env-file "$MATRIX_DATA_ROOT/.env" -f "$MATRIX_DATA_ROOT/docker-compose.yml" up -d --force-recreate --no-deps amber-manager
EOF

  if ! wait_for_remote_manager_ready "$host_ip" 120; then
    die "onboarding: amber-manager did not become ready after reconciling allowlist"
  fi
}

start_manager_tunnel() {
  host_ip=$1

  cleanup_tunnel

  ssh \
    -i "$HCLOUD_SSH_PRIVATE_KEY_PATH" \
    -p "$HCLOUD_SSH_PORT" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout="$HCLOUD_SSH_CONNECT_TIMEOUT_SECONDS" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$HCLOUD_SSH_KNOWN_HOSTS_FILE" \
    -N \
    -L "127.0.0.1:$ONBOARDING_MANAGER_TUNNEL_PORT:127.0.0.1:4100" \
    "$(ssh_target "$host_ip")" \
    >/dev/null 2>&1 &
  tunnel_pid=$!
}

wait_for_local_manager_ready() {
  attempts=${1:-60}
  count=0
  url="http://127.0.0.1:$ONBOARDING_MANAGER_TUNNEL_PORT/readyz"

  while [ "$count" -lt "$attempts" ]; do
    if curl -fsS "$url" | jq -e '.ready == true' >/dev/null 2>&1; then
      return 0
    fi
    if [ -n "${tunnel_pid:-}" ] && ! kill -0 "$tunnel_pid" >/dev/null 2>&1; then
      die "onboarding: SSH tunnel to amber-manager exited before becoming ready"
    fi
    count=$((count + 1))
    sleep 1
  done

  return 1
}

ensure_local_manager_tunnel_healthy() {
  host_ip=$1
  url="http://127.0.0.1:$ONBOARDING_MANAGER_TUNNEL_PORT/readyz"

  if [ -n "${tunnel_pid:-}" ] \
    && kill -0 "$tunnel_pid" >/dev/null 2>&1 \
    && curl -fsS "$url" | jq -e '.ready == true' >/dev/null 2>&1; then
    return 0
  fi

  log "onboarding: restarting local manager tunnel"
  start_manager_tunnel "$host_ip"
  if ! wait_for_local_manager_ready 60; then
    die "onboarding: local manager tunnel did not become ready after restart"
  fi
}

prepare_codex_config() {
  tmpdir_path=$1

  if [ -n "$ONBOARDING_CODEX_CONFIG_TOML_PATH" ]; then
    CODEX_CONFIG_PATH=$(local_abs_path "$ONBOARDING_CODEX_CONFIG_TOML_PATH")
    require_file "$CODEX_CONFIG_PATH"
    return 0
  fi

  CODEX_CONFIG_PATH="$tmpdir_path/codex-config.toml"
  cat >"$CODEX_CONFIG_PATH" <<'EOF'
[features]
child_agents_md = true
EOF
}

remote_onboarding_secret_dir() {
  printf '%s\n' "$MATRIX_DATA_ROOT/secrets/onboarding"
}

remote_admin_matrix_password_path() {
  printf '%s/bootstrap-operator-matrix-password\n' "$(remote_onboarding_secret_dir)"
}

remote_onboarding_bot_password_path() {
  printf '%s/onboarding-bot-matrix-password\n' "$(remote_onboarding_secret_dir)"
}

remote_secret_file_exists() {
  host_ip=$1
  secret_path=$2

  ssh_exec "$host_ip" "SECRET_PATH='$secret_path' sh -s" <<'EOF'
set -eu
[ -s "$SECRET_PATH" ]
EOF
}

ensure_remote_generated_secret_file() {
  host_ip=$1
  secret_path=$2
  secret_label=$3

  ssh_exec "$host_ip" "SECRET_PATH='$secret_path' SECRET_LABEL='$secret_label' sh -s" <<'EOF'
set -eu

secret_dir=$(dirname -- "$SECRET_PATH")
mkdir -p "$secret_dir"
chmod 700 "$secret_dir"

if [ -s "$SECRET_PATH" ]; then
  chmod 600 "$SECRET_PATH"
  exit 0
fi

tmp=$(mktemp "$secret_dir/.secret.XXXXXX")
trap 'rm -f "$tmp"' EXIT

echo "onboarding: generating $SECRET_LABEL on target host" >&2
umask 077
LC_ALL=C tr -dc 'A-Za-z0-9._-' </dev/urandom | head -c 48 >"$tmp"
bytes=$(wc -c <"$tmp" | tr -d '[:space:]')
[ "$bytes" = "48" ] || {
  echo "onboarding: failed to generate $SECRET_LABEL" >&2
  exit 1
}

mv "$tmp" "$SECRET_PATH"
chmod 600 "$SECRET_PATH"
EOF
}

fetch_remote_secret_file() {
  host_ip=$1
  secret_path=$2
  local_path=$3

  old_umask=$(umask)
  umask 077
  ssh_exec "$host_ip" "SECRET_PATH='$secret_path' sh -s" <<'EOF' >"$local_path"
set -eu
[ -s "$SECRET_PATH" ] || {
  echo "onboarding: expected non-empty remote secret file at $SECRET_PATH" >&2
  exit 1
}
cat "$SECRET_PATH"
EOF
  umask "$old_umask"
  chmod 600 "$local_path"
}

load_local_secret_into_var() {
  secret_path=$1
  result_var=$2

  secret_value=$(cat "$secret_path")
  [ -n "$secret_value" ] || die "onboarding: local secret file $secret_path was empty"
  eval "$result_var=\$secret_value"
}

ensure_onboarding_passwords() {
  host_ip=$1
  mode=$2
  onboarding_bot_password_remote_path=$(remote_onboarding_bot_password_path)

  case "$mode" in
    apply)
      ensure_remote_generated_secret_file "$host_ip" "$onboarding_bot_password_remote_path" "onboarding bot Matrix password"
      ;;
    verify)
      remote_secret_file_exists "$host_ip" "$onboarding_bot_password_remote_path" || die "onboarding: expected host-managed onboarding bot password at $onboarding_bot_password_remote_path; run apply to reconcile onboarding secrets"
      ;;
    *)
      die "onboarding: unsupported onboarding password mode $mode"
      ;;
  esac

  onboarding_bot_password_local_path=$(mktemp "$tmpdir/onboarding-bot-password.XXXXXX")

  fetch_remote_secret_file "$host_ip" "$onboarding_bot_password_remote_path" "$onboarding_bot_password_local_path"
  load_local_secret_into_var "$onboarding_bot_password_local_path" ONBOARDING_BOT_PASSWORD
}

remote_codex_home_path() {
  dirname -- "$ONBOARDING_CODEX_AUTH_JSON_PATH"
}

remote_codex_base_home_path() {
  dirname -- "$(remote_codex_home_path)"
}

remote_codex_auth_exists() {
  host_ip=$1
  ssh_exec "$host_ip" "ONBOARDING_CODEX_AUTH_JSON_PATH='$ONBOARDING_CODEX_AUTH_JSON_PATH' sh -s" <<'EOF'
set -eu
[ -f "$ONBOARDING_CODEX_AUTH_JSON_PATH" ]
EOF
}

ensure_remote_codex_cli() {
  host_ip=$1
  remote_codex_home=$(remote_codex_home_path)
  remote_codex_base_home=$(remote_codex_base_home_path)

  ssh_exec "$host_ip" "ONBOARDING_CODEX_AUTH_JSON_PATH='$ONBOARDING_CODEX_AUTH_JSON_PATH' REMOTE_CODEX_HOME='$remote_codex_home' REMOTE_CODEX_BASE_HOME='$remote_codex_base_home' sh -s" <<'EOF'
set -eu

mkdir -p "$REMOTE_CODEX_BASE_HOME" "$REMOTE_CODEX_HOME"
chmod 700 "$REMOTE_CODEX_BASE_HOME" "$REMOTE_CODEX_HOME"

if command -v codex >/dev/null 2>&1; then
  exit 0
fi

if ! command -v npm >/dev/null 2>&1; then
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "onboarding: remote host is missing both codex and npm, and no supported package manager is available to install npm" >&2
    exit 1
  fi

  export DEBIAN_FRONTEND=noninteractive
  echo "onboarding: installing nodejs and npm on target host" >&2
  apt-get update
  apt-get install -y nodejs npm
fi

npm_bin_dir=$(npm prefix -g)/bin
PATH="$npm_bin_dir:$PATH"
export PATH

if command -v codex >/dev/null 2>&1; then
  exit 0
fi

echo "onboarding: installing @openai/codex on target host" >&2
npm install -g @openai/codex

if ! command -v codex >/dev/null 2>&1; then
  echo "onboarding: codex is still not on PATH after npm install -g @openai/codex" >&2
  exit 1
fi
EOF
}

run_remote_codex_device_auth() {
  host_ip=$1
  remote_codex_home=$(remote_codex_home_path)
  remote_codex_base_home=$(remote_codex_base_home_path)

  ssh_exec "$host_ip" "REMOTE_CODEX_HOME='$remote_codex_home' REMOTE_CODEX_BASE_HOME='$remote_codex_base_home' sh -s" <<'EOF'
set -eu

if command -v npm >/dev/null 2>&1; then
  npm_bin_dir=$(npm prefix -g)/bin
  PATH="$npm_bin_dir:$PATH"
  export PATH
fi

command -v codex >/dev/null 2>&1 || {
  echo "onboarding: codex is not available on the target host" >&2
  exit 1
}

mkdir -p "$REMOTE_CODEX_BASE_HOME" "$REMOTE_CODEX_HOME"
chmod 700 "$REMOTE_CODEX_BASE_HOME" "$REMOTE_CODEX_HOME"

export HOME="$REMOTE_CODEX_BASE_HOME"
export CODEX_HOME="$REMOTE_CODEX_HOME"

exec codex login --device-auth
EOF
}

fetch_remote_codex_auth() {
  host_ip=$1
  local_path=$2

  old_umask=$(umask)
  umask 077
  ssh_exec "$host_ip" "ONBOARDING_CODEX_AUTH_JSON_PATH='$ONBOARDING_CODEX_AUTH_JSON_PATH' sh -s" <<'EOF' >"$local_path"
set -eu
[ -f "$ONBOARDING_CODEX_AUTH_JSON_PATH" ] || {
  echo "onboarding: expected remote auth file at $ONBOARDING_CODEX_AUTH_JSON_PATH" >&2
  exit 1
}
cat "$ONBOARDING_CODEX_AUTH_JSON_PATH"
EOF
  umask "$old_umask"
  chmod 600 "$local_path"
}

prepare_bootstrap_codex_auth() {
  host_ip=$1
  tmpdir_path=$2

  BOOTSTRAP_CODEX_AUTH_JSON_PATH=

  if remote_codex_auth_exists "$host_ip"; then
    log "onboarding: found remote Codex auth at $ONBOARDING_CODEX_AUTH_JSON_PATH"
  else
    log "onboarding: no remote Codex auth found at $ONBOARDING_CODEX_AUTH_JSON_PATH; preparing device auth on the target host"
    ensure_remote_codex_cli "$host_ip"
    run_remote_codex_device_auth "$host_ip"
    if ! remote_codex_auth_exists "$host_ip"; then
      die "onboarding: Codex device auth completed without creating $ONBOARDING_CODEX_AUTH_JSON_PATH on the target host"
    fi
  fi

  BOOTSTRAP_CODEX_AUTH_JSON_PATH="$tmpdir_path/remote-codex-auth.json"
  fetch_remote_codex_auth "$host_ip" "$BOOTSTRAP_CODEX_AUTH_JSON_PATH"
}

matrix_user_id() {
  username=$1
  printf '@%s:%s\n' "$username" "$MATRIX_SERVER_NAME"
}

welcome_room_alias() {
  printf '#%s:%s\n' "$ONBOARDING_BOOTSTRAP_WELCOME_ROOM_ALIAS_LOCALPART" "$MATRIX_SERVER_NAME"
}

welcome_message_body() {
  user_id=$1
  printf 'Welcome.\n\nClick this user ID to start a DM with the onboarding agent:\n%s' "$user_id"
}

legacy_matrix_uri_welcome_message_body() {
  user_id=$1
  printf 'Welcome.\n\nClick this link to start a DM with the onboarding agent:\nmatrix:u/%s' "${user_id#@}"
}

legacy_matrix_to_welcome_message_body() {
  user_id=$1
  printf 'Welcome.\n\nClick this link to start a DM with the onboarding agent:\nhttps://matrix.to/#/%s?action=chat' "$user_id"
}

write_welcome_room_management_payload() {
  output_path=$1

  jq -n \
    --arg managed_by "infra/onboarding" \
    --arg kind "$ONBOARDING_MANAGED_ROOM_KIND_WELCOME" \
    --arg room_alias "$(welcome_room_alias)" \
    '{
      managed_by: $managed_by,
      kind: $kind,
      room_alias: $room_alias
    }' >"$output_path"
}

write_welcome_room_power_levels_payload() {
  output_path=$1
  admin_user_id=$2
  onboarding_bot_user_id=$3

  jq -n \
    --arg admin_user_id "$admin_user_id" \
    --arg onboarding_bot_user_id "$onboarding_bot_user_id" \
    '{
      users: {
        ($admin_user_id): 100,
        ($onboarding_bot_user_id): 100
      },
      users_default: 0,
      state_default: 50,
      events: {
        "m.room.message": 50
      }
    }' >"$output_path"
}

api_error_message() {
  body_path=$1
  if message=$(jq -r 'if type == "object" then (.error // .message // empty) else empty end' "$body_path" 2>/dev/null) && [ -n "$message" ]; then
    printf '%s\n' "$message"
    return 0
  fi

  message=$(tr '\n' ' ' <"$body_path" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
  if [ -n "$message" ]; then
    printf '%s\n' "$message"
  else
    printf 'unknown error\n'
  fi
}

matrix_error_code() {
  body_path=$1
  jq -r 'if type == "object" then (.errcode // empty) else empty end' "$body_path" 2>/dev/null
}

uri_encode() {
  printf '%s' "$1" | jq -Rr @uri
}

http_request() {
  method=$1
  url=$2
  payload_path=$3
  auth_token=$4
  out_file=$5
  status_file=$6

  : >"$out_file"

  if [ -n "$payload_path" ]; then
    if [ -n "$auth_token" ]; then
      status=$(curl -sS -o "$out_file" -w "%{http_code}" -X "$method" "$url" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $auth_token" \
        --data "@$payload_path") || status=000
    else
      status=$(curl -sS -o "$out_file" -w "%{http_code}" -X "$method" "$url" \
        -H "Content-Type: application/json" \
        --data "@$payload_path") || status=000
    fi
  else
    if [ -n "$auth_token" ]; then
      status=$(curl -sS -o "$out_file" -w "%{http_code}" -X "$method" "$url" \
        -H "Authorization: Bearer $auth_token") || status=000
    else
      status=$(curl -sS -o "$out_file" -w "%{http_code}" -X "$method" "$url") || status=000
    fi
  fi

  printf '%s\n' "$status" >"$status_file"
}

manager_api_get_to_file() {
  path=$1
  out_file=$2
  status_file=$3
  http_request GET "http://127.0.0.1:$ONBOARDING_MANAGER_TUNNEL_PORT$path" "" "" "$out_file" "$status_file"
}

manager_api_post_json() {
  path=$1
  payload_path=$2
  out_file=$3
  status_file=$4
  http_request POST "http://127.0.0.1:$ONBOARDING_MANAGER_TUNNEL_PORT$path" "$payload_path" "" "$out_file" "$status_file"
}

manager_api_delete_to_file() {
  path=$1
  out_file=$2
  status_file=$3
  http_request DELETE "http://127.0.0.1:$ONBOARDING_MANAGER_TUNNEL_PORT$path" "" "" "$out_file" "$status_file"
}

matrix_api_get_to_file() {
  url=$1
  auth_token=$2
  out_file=$3
  status_file=$4
  http_request GET "$url" "" "$auth_token" "$out_file" "$status_file"
}

matrix_api_post_json() {
  url=$1
  payload_path=$2
  auth_token=$3
  out_file=$4
  status_file=$5
  http_request POST "$url" "$payload_path" "$auth_token" "$out_file" "$status_file"
}

matrix_api_put_json() {
  url=$1
  payload_path=$2
  auth_token=$3
  out_file=$4
  status_file=$5
  http_request PUT "$url" "$payload_path" "$auth_token" "$out_file" "$status_file"
}

expect_http_success() {
  status_file=$1
  body_path=$2
  context=$3
  status=$(cat "$status_file")
  case "$status" in
    2??)
      return 0
      ;;
  esac
  die "$context failed with HTTP $status: $(api_error_message "$body_path")"
}

json_add_optional_file() {
  json_path=$1
  key=$2
  source_path=$3

  if [ -z "$source_path" ]; then
    return 0
  fi

  tmp_json=$(mktemp "$tmpdir/json.XXXXXX")
  jq --rawfile value "$(local_abs_path "$source_path")" --arg key "$key" '. + {($key): $value}' "$json_path" >"$tmp_json"
  mv "$tmp_json" "$json_path"
}

json_add_optional_string() {
  json_path=$1
  key=$2
  value=$3

  if [ -z "$value" ]; then
    return 0
  fi

  tmp_json=$(mktemp "$tmpdir/json.XXXXXX")
  jq --arg key "$key" --arg value "$value" '. + {($key): $value}' "$json_path" >"$tmp_json"
  mv "$tmp_json" "$json_path"
}

bootstrap_only_source_urls_text() {
  printf '%s\n' "$PROVISIONER_SOURCE_URL" "$ONBOARDING_SOURCE_URL" "$AUTH_PROXY_SOURCE_URL" |
    jq -Rsc --arg default_agent_source_url "$DEFAULT_AGENT_SOURCE_URL" '
      split("\n")
      | map(select(length > 0 and . != $default_agent_source_url))
      | unique
      | join("\n")
    ' |
    jq -r '.'
}

write_empty_json() {
  output_path=$1
  printf '{}\n' >"$output_path"
}

write_auth_proxy_root_config_json() {
  output_path=$1
  jq -n --rawfile auth_json "$BOOTSTRAP_CODEX_AUTH_JSON_PATH" '{auth_json: $auth_json}' >"$output_path"
}

write_auth_proxy_metadata_json() {
  output_path=$1
  jq -n --arg kind "$ONBOARDING_METADATA_KIND_AUTH_PROXY" '{kind: $kind}' >"$output_path"
}

write_provisioner_root_config_json() {
  output_path=$1
  jq -n \
    --arg listen_addr ":8080" \
    --arg matrix_bindable_service_name "$ONBOARDING_MATRIX_BINDABLE_SERVICE_NAME" \
    --arg default_agent_source_url "$DEFAULT_AGENT_SOURCE_URL" \
    --arg shared_responses_bindable_service_id "$CURRENT_SHARED_RESPONSES_BINDABLE_SERVICE_ID" \
    --arg default_agent_model "$ONBOARDING_DEFAULT_AGENT_MODEL" \
    --arg default_agent_model_reasoning_effort "$ONBOARDING_DEFAULT_AGENT_MODEL_REASONING_EFFORT" \
    --arg revoked_source_urls "$(bootstrap_only_source_urls_text)" \
    '{
      listen_addr: $listen_addr,
      matrix_bindable_service_name: $matrix_bindable_service_name,
      default_agent_source_url: $default_agent_source_url,
      shared_responses_bindable_service_id: $shared_responses_bindable_service_id,
      default_agent_model: $default_agent_model,
      default_agent_model_reasoning_effort: $default_agent_model_reasoning_effort,
      revoked_source_urls: $revoked_source_urls
    }' >"$output_path"

  json_add_optional_string "$output_path" registration_token "$MATRIX_REGISTRATION_TOKEN"
  json_add_optional_file "$output_path" default_agent_developer_instructions "$ONBOARDING_DEFAULT_AGENT_DEVELOPER_INSTRUCTIONS_PATH"
  json_add_optional_file "$output_path" default_agent_agents_md "$ONBOARDING_DEFAULT_AGENT_AGENTS_MD_PATH"
  json_add_optional_file "$output_path" default_agent_workspace_agents_md "$ONBOARDING_DEFAULT_AGENT_WORKSPACE_AGENTS_MD_PATH"
  json_add_optional_file "$output_path" default_agent_config_toml "$CODEX_CONFIG_PATH"
}

write_provisioner_external_slots_json() {
  output_path=$1
  matrix_service_id=$2
  manager_service_id=$3

  jq -n \
    --arg matrix_service_id "$matrix_service_id" \
    --arg manager_service_id "$manager_service_id" \
    '{
      matrix: {bindable_service_id: $matrix_service_id},
      amber_manager_api: {bindable_service_id: $manager_service_id}
    }' >"$output_path"
}

write_provisioner_metadata_json() {
  output_path=$1
  jq -n \
    --arg kind "$ONBOARDING_METADATA_KIND_PROVISIONER" \
    --arg default_agent_source "$DEFAULT_AGENT_SOURCE_URL" \
    '{kind: $kind, default_agent_source: $default_agent_source}' >"$output_path"
}

write_onboarding_root_config_json() {
  output_path=$1
  jq -n \
    --arg matrix_username "$ONBOARDING_BOOTSTRAP_ONBOARDING_BOT_USERNAME" \
    --arg matrix_password "$ONBOARDING_BOT_PASSWORD" \
    --arg model "$ONBOARDING_ONBOARDING_MODEL" \
    --arg model_reasoning_effort "$ONBOARDING_ONBOARDING_MODEL_REASONING_EFFORT" \
    '{
      matrix_username: $matrix_username,
      matrix_password: $matrix_password,
      model: $model,
      model_reasoning_effort: $model_reasoning_effort
    }' >"$output_path"

  json_add_optional_file "$output_path" developer_instructions "$ONBOARDING_ONBOARDING_DEVELOPER_INSTRUCTIONS_PATH"
  json_add_optional_file "$output_path" agents_md "$ONBOARDING_ONBOARDING_AGENTS_MD_PATH"
  json_add_optional_file "$output_path" workspace_agents_md "$ONBOARDING_ONBOARDING_WORKSPACE_AGENTS_MD_PATH"
  json_add_optional_file "$output_path" config_toml "$CODEX_CONFIG_PATH"
}

write_onboarding_external_slots_json() {
  output_path=$1
  matrix_service_id=$2
  shared_responses_service_id=$3
  provisioner_mcp_service_id=$4

  jq -n \
    --arg matrix_service_id "$matrix_service_id" \
    --arg shared_responses_service_id "$shared_responses_service_id" \
    --arg provisioner_mcp_service_id "$provisioner_mcp_service_id" \
    '{
      matrix: {bindable_service_id: $matrix_service_id},
      responses_api: {bindable_service_id: $shared_responses_service_id},
      provisioning_mcp: {bindable_service_id: $provisioner_mcp_service_id}
    }' >"$output_path"
}

write_onboarding_metadata_json() {
  output_path=$1
  provisioner_scenario_id=$2
  jq -n \
    --arg kind "$ONBOARDING_METADATA_KIND_ONBOARDING" \
    --arg welcome_room_id "$CURRENT_WELCOME_ROOM_ID" \
    --arg onboarding_bot_id "$CURRENT_ONBOARDING_BOT_USER_ID" \
    --arg provisioner_id "$provisioner_scenario_id" \
    '{
      kind: $kind,
      welcome_room_id: $welcome_room_id,
      onboarding_bot_id: $onboarding_bot_id,
      provisioner_id: $provisioner_id
    }' >"$output_path"
}

json_files_equal() {
  left_path=$1
  right_path=$2
  left_canon=$(mktemp "$tmpdir/json-left.XXXXXX")
  right_canon=$(mktemp "$tmpdir/json-right.XXXXXX")
  jq -S . "$left_path" >"$left_canon"
  jq -S . "$right_path" >"$right_canon"
  cmp -s "$left_canon" "$right_canon"
}

lookup_scenario_id_by_kind() {
  kind=$1
  scenarios_path=$(mktemp "$tmpdir/scenarios.XXXXXX")
  status_path=$(mktemp "$tmpdir/scenarios-status.XXXXXX")
  manager_api_get_to_file /v1/scenarios "$scenarios_path" "$status_path"
  expect_http_success "$status_path" "$scenarios_path" "onboarding: list scenarios"

  count=$(jq --arg kind "$kind" '[.[] | select(.metadata.kind == $kind)] | length' "$scenarios_path")
  if [ "$count" -gt 1 ]; then
    die "onboarding: found multiple scenarios for kind $kind"
  fi

  jq -r --arg kind "$kind" '[.[] | select(.metadata.kind == $kind)][0].scenario_id // ""' "$scenarios_path"
}

get_scenario_detail() {
  scenario_id=$1
  output_path=$2
  status_path=$(mktemp "$tmpdir/scenario-detail-status.XXXXXX")
  manager_api_get_to_file "/v1/scenarios/$scenario_id" "$output_path" "$status_path"
  expect_http_success "$status_path" "$output_path" "onboarding: load scenario $scenario_id"
}

scenario_contract_matches() {
  detail_path=$1
  source_url=$2
  root_config_path=$3
  external_slots_path=$4
  metadata_path=$5

  actual_source_url=$(jq -r '.source_url // ""' "$detail_path")
  [ "$actual_source_url" = "$source_url" ] || return 1

  bundle_stored=$(jq -r '.bundle_stored' "$detail_path")
  [ "$bundle_stored" = "true" ] || return 1

  actual_root_config=$(mktemp "$tmpdir/actual-root.XXXXXX")
  desired_root_config=$(mktemp "$tmpdir/desired-root.XXXXXX")
  actual_external_slots=$(mktemp "$tmpdir/actual-slots.XXXXXX")
  actual_metadata=$(mktemp "$tmpdir/actual-metadata.XXXXXX")

  jq '.root_config // {}' "$detail_path" >"$actual_root_config"
  secret_paths=$(jq -c '.secret_root_config_paths // []' "$detail_path")
  jq --argjson secret_paths "$secret_paths" '
    reduce $secret_paths[] as $path (.;
      delpaths([($path | split("."))])
    )
  ' "$root_config_path" >"$desired_root_config"

  json_files_equal "$actual_root_config" "$desired_root_config" || return 1

  jq '(.external_slots // {}) | with_entries(.value = {bindable_service_id: (.value.bindable_service_id // "")})' "$detail_path" >"$actual_external_slots"
  json_files_equal "$actual_external_slots" "$external_slots_path" || return 1

  jq '.metadata // {}' "$detail_path" >"$actual_metadata"
  json_files_equal "$actual_metadata" "$metadata_path" || return 1

  return 0
}

LOOKUP_BINDABLE_SERVICE_ID=
LOOKUP_BINDABLE_SERVICE_SCENARIO_ID=
lookup_bindable_service_id_by_display_name() {
  name=$1
  LOOKUP_BINDABLE_SERVICE_ID=
  LOOKUP_BINDABLE_SERVICE_SCENARIO_ID=
  services_path=$(mktemp "$tmpdir/services.XXXXXX")
  status_path=$(mktemp "$tmpdir/services-status.XXXXXX")
  manager_api_get_to_file /v1/bindable-services "$services_path" "$status_path"
  expect_http_success "$status_path" "$services_path" "onboarding: list bindable services"

  count=$(jq --arg name "$name" '[.[] | select(.display_name == $name)] | length' "$services_path")
  if [ "$count" -eq 0 ]; then
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    die "onboarding: found multiple bindable services with display name $name"
  fi

  available=$(jq -r --arg name "$name" '[.[] | select(.display_name == $name)][0].available' "$services_path")
  if [ "$available" != "true" ]; then
    return 2
  fi

  LOOKUP_BINDABLE_SERVICE_ID=$(jq -r --arg name "$name" '[.[] | select(.display_name == $name)][0].bindable_service_id' "$services_path")
  LOOKUP_BINDABLE_SERVICE_SCENARIO_ID=$(jq -r --arg name "$name" '[.[] | select(.display_name == $name)][0].scenario_id // ""' "$services_path")
  return 0
}

lookup_bindable_service_id_by_id() {
  bindable_service_id=$1
  LOOKUP_BINDABLE_SERVICE_ID=
  LOOKUP_BINDABLE_SERVICE_SCENARIO_ID=
  services_path=$(mktemp "$tmpdir/services.XXXXXX")
  status_path=$(mktemp "$tmpdir/services-status.XXXXXX")
  manager_api_get_to_file /v1/bindable-services "$services_path" "$status_path"
  expect_http_success "$status_path" "$services_path" "onboarding: list bindable services"

  count=$(jq --arg bindable_service_id "$bindable_service_id" '[.[] | select(.bindable_service_id == $bindable_service_id)] | length' "$services_path")
  if [ "$count" -eq 0 ]; then
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    die "onboarding: found multiple bindable services with id $bindable_service_id"
  fi

  available=$(jq -r --arg bindable_service_id "$bindable_service_id" '[.[] | select(.bindable_service_id == $bindable_service_id)][0].available' "$services_path")
  if [ "$available" != "true" ]; then
    return 2
  fi

  LOOKUP_BINDABLE_SERVICE_ID=$(jq -r --arg bindable_service_id "$bindable_service_id" '[.[] | select(.bindable_service_id == $bindable_service_id)][0].bindable_service_id' "$services_path")
  LOOKUP_BINDABLE_SERVICE_SCENARIO_ID=$(jq -r --arg bindable_service_id "$bindable_service_id" '[.[] | select(.bindable_service_id == $bindable_service_id)][0].scenario_id // ""' "$services_path")
  return 0
}

wait_for_manager_operation_succeeded() {
  operation_id=$1
  attempts=${2:-300}
  count=0

  while [ "$count" -lt "$attempts" ]; do
    status_path=$(mktemp "$tmpdir/operation-status.XXXXXX")
    body_path=$(mktemp "$tmpdir/operation-body.XXXXXX")
    manager_api_get_to_file "/v1/operations/$operation_id" "$body_path" "$status_path"
    expect_http_success "$status_path" "$body_path" "onboarding: load operation $operation_id"

    status=$(jq -r '.status' "$body_path")
    case "$status" in
      succeeded)
        return 0
        ;;
      failed)
        last_error=$(jq -r '.last_error // ""' "$body_path")
        if [ -n "$last_error" ]; then
          die "onboarding: manager operation $operation_id failed: $last_error"
        fi
        die "onboarding: manager operation $operation_id failed"
        ;;
    esac

    count=$((count + 1))
    sleep 1
  done

  die "onboarding: timed out waiting for manager operation $operation_id"
}

scenario_failure_is_transient() {
  last_error=$(printf '%s' "$1" | tr -d '\n')
  case "$last_error" in
    '')
      return 0
      ;;
    *"docker compose reports no services"*|*" is created"*|*" is exited"*|*"service \"amber-init\" didn't complete successfully"*|*"service \"amber-provisioner\" didn't complete successfully"*)
      return 0
      ;;
  esac
  return 1
}

wait_for_scenario_running() {
  scenario_id=$1
  attempts=${2:-300}
  count=0

  while [ "$count" -lt "$attempts" ]; do
    detail_path=$(mktemp "$tmpdir/scenario-running.XXXXXX")
    get_scenario_detail "$scenario_id" "$detail_path"
    observed_state=$(jq -r '.observed_state // ""' "$detail_path")
    case "$observed_state" in
      running)
        return 0
        ;;
      failed)
        last_error=$(jq -r '.last_error // ""' "$detail_path")
        if ! scenario_failure_is_transient "$last_error"; then
          if [ -n "$last_error" ]; then
            die "onboarding: scenario $scenario_id failed: $last_error"
          fi
          die "onboarding: scenario $scenario_id failed"
        fi
        ;;
    esac

    count=$((count + 1))
    sleep 1
  done

  die "onboarding: timed out waiting for scenario $scenario_id to reach running"
}

run_manager_scenario_upgrade() {
  scenario_id=$1
  payload_path=$2
  response_path=$3
  status_path=$4
  context=$5
  attempts=${6:-120}

  count=0
  while true; do
    manager_api_post_json "/v1/scenarios/$scenario_id/upgrade" "$payload_path" "$response_path" "$status_path"
    status=$(cat "$status_path")

    case "$status" in
      2??)
        return 0
        ;;
      409)
        if [ "$count" -ge "$attempts" ]; then
          die "$context failed with HTTP 409: operation still in progress after $attempts retries"
        fi

        detail_path=$(mktemp "$tmpdir/scenario-conflict-detail.XXXXXX")
        get_scenario_detail "$scenario_id" "$detail_path"
        observed_state=$(jq -r '.observed_state // ""' "$detail_path")
        if [ "$observed_state" = "failed" ]; then
          last_error=$(jq -r '.last_error // ""' "$detail_path")
          if [ -n "$last_error" ]; then
            die "onboarding: scenario $scenario_id failed while waiting to retry operation: $last_error"
          fi
          die "onboarding: scenario $scenario_id failed while waiting to retry operation"
        fi

        count=$((count + 1))
        sleep_seconds=$((count * 2))
        [ "$sleep_seconds" -lt 20 ] || sleep_seconds=20
        log "onboarding: scenario $scenario_id has an operation in progress; waiting ${sleep_seconds}s and retrying ($count/$attempts)"
        sleep "$sleep_seconds"
        continue
        ;;
      *)
        die "$context failed with HTTP $status: $(api_error_message "$response_path")"
        ;;
    esac
  done
}

wait_for_scenario_export_service_id() {
  scenario_id=$1
  export_name=$2
  result_var=$3
  attempts=${4:-300}
  count=0

  while [ "$count" -lt "$attempts" ]; do
    services_path=$(mktemp "$tmpdir/export-services.XXXXXX")
    status_path=$(mktemp "$tmpdir/export-services-status.XXXXXX")
    manager_api_get_to_file /v1/bindable-services "$services_path" "$status_path"
    expect_http_success "$status_path" "$services_path" "onboarding: list bindable services"

    service_id=$(jq -r \
      --arg scenario_id "$scenario_id" \
      --arg export_name "$export_name" \
      '[.[] | select(.scenario_id == $scenario_id and .export == $export_name and .available == true)][0].bindable_service_id // ""' \
      "$services_path")
    if [ -n "$service_id" ]; then
      eval "$result_var=\$service_id"
      return 0
    fi

    count=$((count + 1))
    sleep 1
  done

  die "onboarding: timed out waiting for scenario $scenario_id export $export_name"
}

ensure_managed_scenario() {
  kind=$1
  source_url=$2
  root_config_path=$3
  external_slots_path=$4
  metadata_path=$5
  result_var=$6

  scenario_id=$(lookup_scenario_id_by_kind "$kind")
  if [ -z "$scenario_id" ]; then
    log "onboarding: creating scenario for kind $kind"
    payload_path=$(mktemp "$tmpdir/scenario-create.XXXXXX")
    jq -n \
      --arg source_url "$source_url" \
      --slurpfile root_config "$root_config_path" \
      --slurpfile external_slots "$external_slots_path" \
      --slurpfile metadata "$metadata_path" \
      '{
        source_url: $source_url,
        root_config: $root_config[0],
        external_slots: $external_slots[0],
        metadata: $metadata[0],
        store_bundle: true,
        start: true
      }' >"$payload_path"

    response_path=$(mktemp "$tmpdir/scenario-create-response.XXXXXX")
    status_path=$(mktemp "$tmpdir/scenario-create-status.XXXXXX")
    manager_api_post_json /v1/scenarios "$payload_path" "$response_path" "$status_path"
    expect_http_success "$status_path" "$response_path" "onboarding: create scenario for kind $kind"

    scenario_id=$(jq -r '.scenario_id // ""' "$response_path")
    operation_id=$(jq -r '.operation_id // ""' "$response_path")
    [ -n "$scenario_id" ] || die "onboarding: create scenario for kind $kind did not return a scenario_id"
    [ -n "$operation_id" ] || die "onboarding: create scenario for kind $kind did not return an operation_id"
    wait_for_manager_operation_succeeded "$operation_id"
  else
    detail_path=$(mktemp "$tmpdir/scenario-detail.XXXXXX")
    get_scenario_detail "$scenario_id" "$detail_path"
    observed_state=$(jq -r '.observed_state // ""' "$detail_path")
    needs_upgrade=false
    if scenario_contract_matches "$detail_path" "$source_url" "$root_config_path" "$external_slots_path" "$metadata_path"; then
      if [ "$observed_state" = "running" ]; then
        log "onboarding: scenario $scenario_id ($kind) already matches the desired contract"
      else
        log "onboarding: scenario $scenario_id ($kind) matches the desired contract but is $observed_state; forcing reconcile"
        needs_upgrade=true
      fi
    else
      log "onboarding: upgrading scenario $scenario_id ($kind)"
      needs_upgrade=true
    fi

    if [ "$needs_upgrade" = "true" ]; then
      actual_source_url=$(jq -r '.source_url // ""' "$detail_path")
      source_changed=false
      if [ "$actual_source_url" != "$source_url" ]; then
        source_changed=true
      fi

      payload_path=$(mktemp "$tmpdir/scenario-upgrade.XXXXXX")
      jq -n \
        --arg source_url "$source_url" \
        --argjson source_changed "$source_changed" \
        --slurpfile root_config "$root_config_path" \
        --slurpfile external_slots "$external_slots_path" \
        --slurpfile metadata "$metadata_path" \
        '{
          root_config: $root_config[0],
          external_slots: $external_slots[0],
          metadata: $metadata[0],
          store_bundle: true
        } + (if $source_changed then {source_url: $source_url} else {} end)' >"$payload_path"

      response_path=$(mktemp "$tmpdir/scenario-upgrade-response.XXXXXX")
      status_path=$(mktemp "$tmpdir/scenario-upgrade-status.XXXXXX")
      run_manager_scenario_upgrade \
        "$scenario_id" \
        "$payload_path" \
        "$response_path" \
        "$status_path" \
        "onboarding: upgrade scenario $scenario_id"

      operation_id=$(jq -r '.operation_id // ""' "$response_path")
      [ -n "$operation_id" ] || die "onboarding: upgrade scenario $scenario_id did not return an operation_id"
      wait_for_manager_operation_succeeded "$operation_id"
    fi
  fi

  wait_for_scenario_running "$scenario_id"
  eval "$result_var=\$scenario_id"
}

LOGIN_USER_ID=
LOGIN_ACCESS_TOKEN=
LOGIN_STATUS=

matrix_login_user_with_retry() {
  username=$1
  password=$2
  attempts=${3:-40}

  LOGIN_USER_ID=
  LOGIN_ACCESS_TOKEN=
  LOGIN_STATUS=

  payload_path=$(mktemp "$tmpdir/matrix-login.XXXXXX")
  jq -n \
    --arg user_id "$(matrix_user_id "$username")" \
    --arg password "$password" \
    '{
      type: "m.login.password",
      identifier: {type: "m.id.user", user: $user_id},
      password: $password
    }' >"$payload_path"

  count=0
  while [ "$count" -lt "$attempts" ]; do
    response_path=$(mktemp "$tmpdir/matrix-login-response.XXXXXX")
    status_path=$(mktemp "$tmpdir/matrix-login-status.XXXXXX")
    matrix_api_post_json "$MATRIX_BASE_URL/_matrix/client/v3/login" "$payload_path" "" "$response_path" "$status_path"
    LOGIN_STATUS=$(cat "$status_path")

    if [ "$LOGIN_STATUS" = "200" ]; then
      LOGIN_USER_ID=$(jq -r '.user_id // ""' "$response_path")
      LOGIN_ACCESS_TOKEN=$(jq -r '.access_token // ""' "$response_path")
      [ -n "$LOGIN_USER_ID" ] || return 1
      [ -n "$LOGIN_ACCESS_TOKEN" ] || return 1
      return 0
    fi

    count=$((count + 1))
    sleep 1
  done

  return 1
}

register_matrix_user() {
  username=$1
  password=$2
  REGISTERED_MATRIX_USER_ID=

  initial_payload=$(mktemp "$tmpdir/matrix-register.XXXXXX")
  jq -n \
    --arg username "$username" \
    --arg password "$password" \
    '{
      username: $username,
      password: $password,
      inhibit_login: true
    }' >"$initial_payload"

  response_path=$(mktemp "$tmpdir/matrix-register-response.XXXXXX")
  status_path=$(mktemp "$tmpdir/matrix-register-status.XXXXXX")
  matrix_api_post_json "$MATRIX_BASE_URL/_matrix/client/v3/register" "$initial_payload" "" "$response_path" "$status_path"
  status=$(cat "$status_path")

  case "$status" in
    200)
      REGISTERED_MATRIX_USER_ID=$(jq -r '.user_id // ""' "$response_path")
      [ -n "$REGISTERED_MATRIX_USER_ID" ] || die "onboarding: Matrix registration for $username returned 200 without a user_id"
      return 0
      ;;
    400)
      if [ "$(jq -r '.errcode // ""' "$response_path")" = "M_USER_IN_USE" ]; then
        return 1
      fi
      die "onboarding: Matrix registration for $username failed: $(api_error_message "$response_path")"
      ;;
    401)
      session=$(jq -r '.session // ""' "$response_path")
      [ -n "$session" ] || die "onboarding: Matrix registration for $username returned 401 without a session"

      if [ -n "$MATRIX_REGISTRATION_TOKEN" ] && jq -e --arg stage "m.login.registration_token" '
        [.flows[]?.stages]
        | any(length == 1 and .[0] == $stage)
      ' "$response_path" >/dev/null 2>&1; then
        auth_payload=$(jq -cn --arg session "$session" --arg token "$MATRIX_REGISTRATION_TOKEN" '{
          type: "m.login.registration_token",
          session: $session,
          token: $token
        }')
      elif jq -e --arg stage "m.login.dummy" '
        [.flows[]?.stages]
        | any(length == 1 and .[0] == $stage)
      ' "$response_path" >/dev/null 2>&1; then
        auth_payload=$(jq -cn --arg session "$session" '{
          type: "m.login.dummy",
          session: $session
        }')
      elif [ -z "$MATRIX_REGISTRATION_TOKEN" ] && jq -e --arg stage "m.login.registration_token" '
        [.flows[]?.stages]
        | any(length == 1 and .[0] == $stage)
      ' "$response_path" >/dev/null 2>&1; then
        die "onboarding: Matrix homeserver requires a registration token for account creation, but MATRIX_REGISTRATION_TOKEN is empty"
      else
        die "onboarding: Matrix homeserver exposed an unsupported registration auth flow for $username"
      fi

      final_payload=$(mktemp "$tmpdir/matrix-register-final.XXXXXX")
      jq -n \
        --arg username "$username" \
        --arg password "$password" \
        --argjson auth "$auth_payload" \
        '{
          username: $username,
          password: $password,
          inhibit_login: true,
          auth: $auth
        }' >"$final_payload"

      final_response_path=$(mktemp "$tmpdir/matrix-register-final-response.XXXXXX")
      final_status_path=$(mktemp "$tmpdir/matrix-register-final-status.XXXXXX")
      matrix_api_post_json "$MATRIX_BASE_URL/_matrix/client/v3/register" "$final_payload" "" "$final_response_path" "$final_status_path"
      final_status=$(cat "$final_status_path")
      case "$final_status" in
        200)
          REGISTERED_MATRIX_USER_ID=$(jq -r '.user_id // ""' "$final_response_path")
          [ -n "$REGISTERED_MATRIX_USER_ID" ] || die "onboarding: Matrix registration for $username returned 200 without a user_id"
          return 0
          ;;
        400)
          if [ "$(jq -r '.errcode // ""' "$final_response_path")" = "M_USER_IN_USE" ]; then
            return 1
          fi
          die "onboarding: Matrix registration for $username failed: $(api_error_message "$final_response_path")"
          ;;
      esac
      die "onboarding: Matrix registration for $username failed with HTTP $final_status: $(api_error_message "$final_response_path")"
      ;;
  esac

  die "onboarding: Matrix registration for $username failed with HTTP $status: $(api_error_message "$response_path")"
}

reset_matrix_user_password_on_host() {
  host_ip=$1
  username=$2
  password=$3

  password_b64=$(printf '%s' "$password" | base64 | tr -d '\n')
  ssh_exec "$host_ip" \
    "MATRIX_DATA_ROOT='$MATRIX_DATA_ROOT' MATRIX_SERVER_NAME='$MATRIX_SERVER_NAME' TUWUNEL_IMAGE='$TUWUNEL_IMAGE' USERNAME='$username' PASSWORD_B64='$password_b64' sh -s" <<'EOF'
set -eu

password=$(printf '%s' "$PASSWORD_B64" | base64 -d)
execute_command="users reset_password $USERNAME $password"
log_file=$(mktemp)
compose_cmd="docker compose --env-file \"$MATRIX_DATA_ROOT/.env\" -f \"$MATRIX_DATA_ROOT/docker-compose.yml\""
container_name="onboarding-tuwunel-password-reset"

restore_tuwunel_service() {
  docker rm -f "$container_name" >/dev/null 2>&1 || true
  sh -c "$compose_cmd up -d tuwunel" >/dev/null 2>&1 || true
}

trap restore_tuwunel_service EXIT

sh -c "$compose_cmd stop tuwunel"

set +e
timeout 120 docker run --rm --name "$container_name" \
  -e TUWUNEL_CONFIG=/etc/tuwunel/tuwunel.toml \
  -v "$MATRIX_DATA_ROOT/tuwunel/config:/etc/tuwunel:ro" \
  -v "$MATRIX_DATA_ROOT/tuwunel/data:/data" \
  -v "$MATRIX_DATA_ROOT/secrets:/run/secrets:ro" \
  "$TUWUNEL_IMAGE" \
  --maintenance \
  --execute "$execute_command" >"$log_file" 2>&1
run_status=$?
set -e

cat "$log_file" >&2

case "$run_status" in
  0|124)
    ;;
  *)
    exit "$run_status"
    ;;
esac
EOF

  if ! wait_for_remote_matrix_ready "$host_ip" 120; then
    die "onboarding: Matrix did not become ready after resetting password for @$username:$MATRIX_SERVER_NAME"
  fi
}

ensure_matrix_user() {
  host_ip=$1
  username=$2
  password=$3
  user_id_var=$4
  access_token_var=$5

  if ! matrix_login_user_with_retry "$username" "$password" 5; then
    if ! register_matrix_user "$username" "$password"; then
      log "onboarding: resetting password for managed Matrix user @$username:$MATRIX_SERVER_NAME"
      reset_matrix_user_password_on_host "$host_ip" "$username" "$password"

      if ! matrix_login_user_with_retry "$username" "$password" 40; then
        die "onboarding: matrix username $username already exists and could not be recovered with the host-managed password"
      fi
    elif ! matrix_login_user_with_retry "$username" "$password" 20; then
      die "onboarding: failed to log in as Matrix user $username after registration"
    fi
  fi

  if [ "$user_id_var" != "_" ]; then
    eval "$user_id_var=\$LOGIN_USER_ID"
  fi
  eval "$access_token_var=\$LOGIN_ACCESS_TOKEN"
}

ensure_matrix_admin_access_token() {
  if ! matrix_login_user_with_retry "$MATRIX_ADMIN_USERNAME" "$MATRIX_ADMIN_PASSWORD" 5; then
    die "onboarding: failed to log in as Matrix admin @$MATRIX_ADMIN_USERNAME:$MATRIX_SERVER_NAME"
  fi

  CURRENT_BOOTSTRAP_ADMIN_USER_ID=$LOGIN_USER_ID
  CURRENT_MATRIX_ADMIN_ACCESS_TOKEN=$LOGIN_ACCESS_TOKEN
}

resolve_room_alias() {
  room_alias=$1
  access_token=$2

  response_path=$(mktemp "$tmpdir/room-alias.XXXXXX")
  status_path=$(mktemp "$tmpdir/room-alias-status.XXXXXX")
  matrix_api_get_to_file "$MATRIX_BASE_URL/_matrix/client/v3/directory/room/$(uri_encode "$room_alias")" "$access_token" "$response_path" "$status_path"
  status=$(cat "$status_path")
  case "$status" in
    200)
      RESOLVED_ROOM_ID=$(jq -r '.room_id // ""' "$response_path")
      [ -n "$RESOLVED_ROOM_ID" ] || die "onboarding: alias $room_alias resolved without a room_id"
      return 0
      ;;
    404)
      RESOLVED_ROOM_ID=
      return 1
      ;;
  esac

  die "onboarding: resolve room alias $room_alias failed with HTTP $status: $(api_error_message "$response_path")"
}

ensure_welcome_room() {
  host_ip=$1
  admin_access_token=$2
  alias=$(welcome_room_alias)
  CURRENT_WELCOME_ROOM_ID=

  if resolve_room_alias "$alias" "$admin_access_token"; then
    room_id=$RESOLVED_ROOM_ID
    if room_is_onboarding_managed_welcome_room "$room_id" "$admin_access_token"; then
      CURRENT_WELCOME_ROOM_ID=$room_id
      return 0
    fi

    log "onboarding: replacing welcome room $room_id because it is not infra-managed"
    delete_matrix_room_on_host "$host_ip" "$room_id"
    if ! wait_for_remote_matrix_ready "$host_ip" 120; then
      die "onboarding: Matrix did not become ready after deleting stale welcome room $room_id"
    fi
    if ! wait_for_room_alias_absent "$alias" "$admin_access_token" 60; then
      die "onboarding: welcome room alias $alias still resolves after deleting room $room_id"
    fi
  fi

  payload_path=$(mktemp "$tmpdir/welcome-room.XXXXXX")
  jq -n \
    --arg name "Welcome" \
    --arg visibility "public" \
    --arg preset "public_chat" \
    --arg room_alias_name "$ONBOARDING_BOOTSTRAP_WELCOME_ROOM_ALIAS_LOCALPART" \
    '{
      name: $name,
      visibility: $visibility,
      preset: $preset,
      room_alias_name: $room_alias_name
    }' >"$payload_path"

  create_attempts=5
  create_count=0
  while true; do
    response_path=$(mktemp "$tmpdir/welcome-room-response.XXXXXX")
    status_path=$(mktemp "$tmpdir/welcome-room-status.XXXXXX")
    matrix_api_post_json "$MATRIX_BASE_URL/_matrix/client/v3/createRoom" "$payload_path" "$admin_access_token" "$response_path" "$status_path"

    status=$(cat "$status_path")
    case "$status" in
      2??)
        CURRENT_WELCOME_ROOM_ID=$(jq -r '.room_id // ""' "$response_path")
        [ -n "$CURRENT_WELCOME_ROOM_ID" ] || die "onboarding: create welcome room returned 200 without a room_id"
        return 0
        ;;
      400)
        if [ "$(matrix_error_code "$response_path")" = "M_ROOM_IN_USE" ] && [ "$create_count" -lt "$create_attempts" ]; then
          if resolve_room_alias "$alias" "$admin_access_token"; then
            existing_room_id=$RESOLVED_ROOM_ID
            if room_is_onboarding_managed_welcome_room "$existing_room_id" "$admin_access_token"; then
              CURRENT_WELCOME_ROOM_ID=$existing_room_id
              return 0
            fi

            log "onboarding: welcome room alias $alias is in use; replacing stale room $existing_room_id"
            delete_matrix_room_on_host "$host_ip" "$existing_room_id"
            if ! wait_for_remote_matrix_ready "$host_ip" 120; then
              die "onboarding: Matrix did not become ready after deleting stale welcome room $existing_room_id"
            fi
            if ! wait_for_room_alias_absent "$alias" "$admin_access_token" 60; then
              die "onboarding: welcome room alias $alias still resolves after deleting stale room $existing_room_id"
            fi
            create_count=$((create_count + 1))
            sleep 1
            continue
          fi
        fi
        ;;
    esac

    die "onboarding: create welcome room failed with HTTP $status: $(api_error_message "$response_path")"
  done
}

room_is_onboarding_managed_welcome_room() {
  room_id=$1
  access_token=$2

  response_path=$(mktemp "$tmpdir/welcome-room-managed.XXXXXX")
  status_path=$(mktemp "$tmpdir/welcome-room-managed-status.XXXXXX")
  matrix_api_get_to_file "$MATRIX_BASE_URL/_matrix/client/v3/rooms/$(uri_encode "$room_id")/state/$(uri_encode "$ONBOARDING_MANAGED_ROOM_EVENT_TYPE")/" "$access_token" "$response_path" "$status_path"
  status=$(cat "$status_path")

  case "$status" in
    200)
      jq -e \
        --arg managed_by "infra/onboarding" \
        --arg kind "$ONBOARDING_MANAGED_ROOM_KIND_WELCOME" \
        --arg room_alias "$(welcome_room_alias)" \
        '.managed_by == $managed_by and .kind == $kind and .room_alias == $room_alias' \
        "$response_path" >/dev/null 2>&1
      ;;
    403|404)
      return 1
      ;;
    *)
      die "onboarding: load welcome room management marker for $room_id failed with HTTP $status: $(api_error_message "$response_path")"
      ;;
  esac
}

set_room_state_event() {
  room_id=$1
  event_type=$2
  payload_path=$3
  access_token=$4
  context=$5

  response_path=$(mktemp "$tmpdir/room-state-response.XXXXXX")
  status_path=$(mktemp "$tmpdir/room-state-status.XXXXXX")
  matrix_api_put_json "$MATRIX_BASE_URL/_matrix/client/v3/rooms/$(uri_encode "$room_id")/state/$(uri_encode "$event_type")/" "$payload_path" "$access_token" "$response_path" "$status_path"
  expect_http_success "$status_path" "$response_path" "$context"
}

set_room_state_event_allow_forbidden() {
  room_id=$1
  event_type=$2
  payload_path=$3
  access_token=$4
  context=$5

  response_path=$(mktemp "$tmpdir/room-state-response.XXXXXX")
  status_path=$(mktemp "$tmpdir/room-state-status.XXXXXX")
  matrix_api_put_json "$MATRIX_BASE_URL/_matrix/client/v3/rooms/$(uri_encode "$room_id")/state/$(uri_encode "$event_type")/" "$payload_path" "$access_token" "$response_path" "$status_path"
  status=$(cat "$status_path")
  case "$status" in
    2??)
      return 0
      ;;
    403)
      return 1
      ;;
  esac

  die "$context failed with HTTP $status: $(api_error_message "$response_path")"
}

set_room_directory_visibility() {
  room_id=$1
  visibility=$2
  access_token=$3

  payload_path=$(mktemp "$tmpdir/room-directory-visibility.XXXXXX")
  jq -n --arg visibility "$visibility" '{visibility: $visibility}' >"$payload_path"

  response_path=$(mktemp "$tmpdir/room-directory-visibility-response.XXXXXX")
  status_path=$(mktemp "$tmpdir/room-directory-visibility-status.XXXXXX")
  matrix_api_put_json "$MATRIX_BASE_URL/_matrix/client/v3/directory/list/room/$(uri_encode "$room_id")" "$payload_path" "$access_token" "$response_path" "$status_path"
  expect_http_success "$status_path" "$response_path" "onboarding: set room directory visibility for $room_id"
}

ensure_welcome_room_shape() {
  room_id=$1
  admin_user_id=$2
  onboarding_bot_user_id=$3
  admin_access_token=$4

  managed_payload=$(mktemp "$tmpdir/welcome-room-managed-payload.XXXXXX")
  write_welcome_room_management_payload "$managed_payload"
  if ! set_room_state_event_allow_forbidden \
    "$room_id" \
    "$ONBOARDING_MANAGED_ROOM_EVENT_TYPE" \
    "$managed_payload" \
    "$admin_access_token" \
    "onboarding: set welcome room management marker"; then
    return 1
  fi

  name_payload=$(mktemp "$tmpdir/welcome-room-name.XXXXXX")
  jq -n --arg name "Welcome" '{name: $name}' >"$name_payload"
  set_room_state_event "$room_id" "m.room.name" "$name_payload" "$admin_access_token" "onboarding: set welcome room name"

  join_rules_payload=$(mktemp "$tmpdir/welcome-room-join-rules.XXXXXX")
  jq -n '{join_rule: "public"}' >"$join_rules_payload"
  set_room_state_event "$room_id" "m.room.join_rules" "$join_rules_payload" "$admin_access_token" "onboarding: set welcome room join rules"

  history_visibility_payload=$(mktemp "$tmpdir/welcome-room-history-visibility.XXXXXX")
  jq -n '{history_visibility: "shared"}' >"$history_visibility_payload"
  set_room_state_event "$room_id" "m.room.history_visibility" "$history_visibility_payload" "$admin_access_token" "onboarding: set welcome room history visibility"

  power_levels_payload=$(mktemp "$tmpdir/welcome-room-power-levels.XXXXXX")
  write_welcome_room_power_levels_payload "$power_levels_payload" "$admin_user_id" "$onboarding_bot_user_id"
  set_room_state_event "$room_id" "m.room.power_levels" "$power_levels_payload" "$admin_access_token" "onboarding: set welcome room power levels"

  set_room_directory_visibility "$room_id" "public" "$admin_access_token"
}

load_room_join_rule() {
  room_id=$1
  access_token=$2

  response_path=$(mktemp "$tmpdir/room-join-rules.XXXXXX")
  status_path=$(mktemp "$tmpdir/room-join-rules-status.XXXXXX")
  matrix_api_get_to_file "$MATRIX_BASE_URL/_matrix/client/v3/rooms/$(uri_encode "$room_id")/state/m.room.join_rules/" "$access_token" "$response_path" "$status_path"
  expect_http_success "$status_path" "$response_path" "onboarding: load room join rules for $room_id"

  CURRENT_ROOM_JOIN_RULE=$(jq -r '.join_rule // ""' "$response_path")
  [ -n "$CURRENT_ROOM_JOIN_RULE" ] || die "onboarding: room $room_id join-rules state was missing join_rule"
}

load_room_directory_visibility() {
  room_id=$1
  access_token=$2

  response_path=$(mktemp "$tmpdir/room-directory-visibility.XXXXXX")
  status_path=$(mktemp "$tmpdir/room-directory-visibility-status.XXXXXX")
  matrix_api_get_to_file "$MATRIX_BASE_URL/_matrix/client/v3/directory/list/room/$(uri_encode "$room_id")" "$access_token" "$response_path" "$status_path"
  expect_http_success "$status_path" "$response_path" "onboarding: load room directory visibility for $room_id"

  CURRENT_ROOM_DIRECTORY_VISIBILITY=$(jq -r '.visibility // ""' "$response_path")
  [ -n "$CURRENT_ROOM_DIRECTORY_VISIBILITY" ] || die "onboarding: room $room_id directory visibility response was missing visibility"
}

load_room_message_power_policy() {
  room_id=$1
  admin_user_id=$2
  onboarding_bot_user_id=$3
  access_token=$4

  response_path=$(mktemp "$tmpdir/room-power-levels.XXXXXX")
  status_path=$(mktemp "$tmpdir/room-power-levels-status.XXXXXX")
  matrix_api_get_to_file "$MATRIX_BASE_URL/_matrix/client/v3/rooms/$(uri_encode "$room_id")/state/m.room.power_levels/" "$access_token" "$response_path" "$status_path"
  expect_http_success "$status_path" "$response_path" "onboarding: load room power levels for $room_id"

  CURRENT_ROOM_MESSAGE_POWER_LEVEL=$(jq -r '.events["m.room.message"] // .events_default // 0' "$response_path")
  CURRENT_ROOM_USERS_DEFAULT=$(jq -r '.users_default // 0' "$response_path")
  CURRENT_ROOM_ADMIN_POWER_LEVEL=$(jq -r --arg user_id "$admin_user_id" '(.users[$user_id] // .users_default // 0)' "$response_path")
  CURRENT_ROOM_ONBOARDING_BOT_POWER_LEVEL=$(jq -r --arg user_id "$onboarding_bot_user_id" '(.users[$user_id] // .users_default // 0)' "$response_path")
}

access_token_joined_room() {
  room_id=$1
  access_token=$2

  response_path=$(mktemp "$tmpdir/joined-rooms.XXXXXX")
  status_path=$(mktemp "$tmpdir/joined-rooms-status.XXXXXX")
  matrix_api_get_to_file "$MATRIX_BASE_URL/_matrix/client/v3/joined_rooms" "$access_token" "$response_path" "$status_path"
  expect_http_success "$status_path" "$response_path" "onboarding: load joined rooms"

  jq -e --arg room_id "$room_id" '.joined_rooms[]? | select(. == $room_id)' "$response_path" >/dev/null 2>&1
}

ensure_room_membership() {
  room_id=$1
  user_id=$2
  admin_access_token=$3
  member_access_token=$4

  if access_token_joined_room "$room_id" "$member_access_token"; then
    return 0
  fi

  admin_joined=false
  if access_token_joined_room "$room_id" "$admin_access_token"; then
    admin_joined=true

    invite_payload=$(mktemp "$tmpdir/invite-user.XXXXXX")
    jq -n --arg user_id "$user_id" '{user_id: $user_id}' >"$invite_payload"
    invite_response=$(mktemp "$tmpdir/invite-user-response.XXXXXX")
    invite_status=$(mktemp "$tmpdir/invite-user-status.XXXXXX")
    matrix_api_post_json "$MATRIX_BASE_URL/_matrix/client/v3/rooms/$(uri_encode "$room_id")/invite" "$invite_payload" "$admin_access_token" "$invite_response" "$invite_status"
    case "$(cat "$invite_status")" in
      2??|403|409)
        ;;
      *)
        die "onboarding: invite $user_id to $room_id failed: $(api_error_message "$invite_response")"
        ;;
    esac
  fi

  join_payload=$(mktemp "$tmpdir/join-room.XXXXXX")
  printf '{}\n' >"$join_payload"
  attempts=60
  count=0
  while [ "$count" -lt "$attempts" ]; do
    join_response=$(mktemp "$tmpdir/join-room-response.XXXXXX")
    join_status=$(mktemp "$tmpdir/join-room-status.XXXXXX")
    matrix_api_post_json "$MATRIX_BASE_URL/_matrix/client/v3/join/$(uri_encode "$room_id")" "$join_payload" "$member_access_token" "$join_response" "$join_status"

    case "$(cat "$join_status")" in
      2??|403|409)
        ;;
      *)
        die "onboarding: join $user_id to $room_id failed: $(api_error_message "$join_response")"
        ;;
    esac

    if access_token_joined_room "$room_id" "$member_access_token"; then
      return 0
    fi

    count=$((count + 1))
    sleep 1
  done

  if [ "$admin_joined" != "true" ]; then
  die "onboarding: $user_id is not joined to $room_id, and server admin is not a member of that room to invite it"
  fi

  die "onboarding: timed out waiting for $user_id to join $room_id"
}

sync_room_timeline_to_file() {
  room_id=$1
  access_token=$2
  response_path=$3
  status_path=$4

  filter_json=$(jq -cn --arg room_id "$room_id" '{
    room: {
      rooms: [$room_id],
      timeline: {limit: 100}
    }
  }')

  matrix_api_get_to_file "$MATRIX_BASE_URL/_matrix/client/v3/sync?timeout=0&filter=$(uri_encode "$filter_json")" "$access_token" "$response_path" "$status_path"
  expect_http_success "$status_path" "$response_path" "onboarding: sync room timeline for $room_id"
}

room_exact_message_event_ids_to_file() {
  room_id=$1
  sender_user_id=$2
  body=$3
  access_token=$4
  output_path=$5

  response_path=$(mktemp "$tmpdir/room-sync.XXXXXX")
  status_path=$(mktemp "$tmpdir/room-sync-status.XXXXXX")
  sync_room_timeline_to_file "$room_id" "$access_token" "$response_path" "$status_path"

  jq -r \
    --arg room_id "$room_id" \
    --arg sender_user_id "$sender_user_id" \
    --arg body "$body" \
    '.rooms.join[$room_id].timeline.events[]?
      | select(.type == "m.room.message" and .sender == $sender_user_id and .content.body == $body)
      | .event_id // empty' \
    "$response_path" >"$output_path"
}

room_has_exact_message() {
  room_id=$1
  sender_user_id=$2
  body=$3
  access_token=$4

  event_ids_path=$(mktemp "$tmpdir/room-message-event-ids.XXXXXX")
  room_exact_message_event_ids_to_file "$room_id" "$sender_user_id" "$body" "$access_token" "$event_ids_path"
  [ -s "$event_ids_path" ]
}

redact_room_event() {
  room_id=$1
  event_id=$2
  access_token=$3
  context=$4

  payload_path=$(mktemp "$tmpdir/redact-event.XXXXXX")
  jq -n '{}' >"$payload_path"

  response_path=$(mktemp "$tmpdir/redact-event-response.XXXXXX")
  status_path=$(mktemp "$tmpdir/redact-event-status.XXXXXX")
  txn_id="redact-$(date +%s)-$$"
  matrix_api_put_json "$MATRIX_BASE_URL/_matrix/client/v3/rooms/$(uri_encode "$room_id")/redact/$(uri_encode "$event_id")/$txn_id" "$payload_path" "$access_token" "$response_path" "$status_path"
  expect_http_success "$status_path" "$response_path" "$context"
}

redact_exact_message_events() {
  room_id=$1
  sender_user_id=$2
  body=$3
  access_token=$4

  event_ids_path=$(mktemp "$tmpdir/room-redact-event-ids.XXXXXX")
  room_exact_message_event_ids_to_file "$room_id" "$sender_user_id" "$body" "$access_token" "$event_ids_path"

  found=false
  while IFS= read -r event_id; do
    [ -n "$event_id" ] || continue
    found=true
    redact_room_event "$room_id" "$event_id" "$access_token" "onboarding: redact stale welcome message $event_id"
  done <"$event_ids_path"

  [ "$found" = "true" ]
}

ensure_welcome_message() {
  room_id=$1
  bot_user_id=$2
  admin_access_token=$3
  bot_access_token=$4

  redact_exact_message_events \
    "$room_id" \
    "$bot_user_id" \
    "$(legacy_matrix_uri_welcome_message_body "$bot_user_id")" \
    "$admin_access_token" || true

  redact_exact_message_events \
    "$room_id" \
    "$bot_user_id" \
    "$(legacy_matrix_to_welcome_message_body "$bot_user_id")" \
    "$admin_access_token" || true

  body=$(welcome_message_body "$bot_user_id")
  if room_has_exact_message "$room_id" "$bot_user_id" "$body" "$bot_access_token"; then
    return 0
  fi

  payload_path=$(mktemp "$tmpdir/welcome-message.XXXXXX")
  jq -n --arg body "$body" '{msgtype: "m.text", body: $body}' >"$payload_path"

  response_path=$(mktemp "$tmpdir/welcome-message-response.XXXXXX")
  status_path=$(mktemp "$tmpdir/welcome-message-status.XXXXXX")
  txn_id="welcome-$(date +%s)-$$"
  matrix_api_put_json "$MATRIX_BASE_URL/_matrix/client/v3/rooms/$(uri_encode "$room_id")/send/m.room.message/$txn_id" "$payload_path" "$bot_access_token" "$response_path" "$status_path"
  expect_http_success "$status_path" "$response_path" "onboarding: send welcome message"
}

run_remote_tuwunel_maintenance_command() {
  host_ip=$1
  command_text=$2
  context=$3
  timeout_seconds=${4:-120}

  command_b64=$(printf '%s' "$command_text" | base64 | tr -d '\n')
  ssh_exec "$host_ip" \
    "MATRIX_DATA_ROOT='$MATRIX_DATA_ROOT' TUWUNEL_IMAGE='$TUWUNEL_IMAGE' TIMEOUT_SECONDS='$timeout_seconds' COMMAND_B64='$command_b64' sh -s" <<'EOF'
set -eu

command_text=$(printf '%s' "$COMMAND_B64" | base64 -d)
timeout_seconds="$TIMEOUT_SECONDS"
log_file=$(mktemp)
compose_cmd="docker compose --env-file \"$MATRIX_DATA_ROOT/.env\" -f \"$MATRIX_DATA_ROOT/docker-compose.yml\""
container_name="onboarding-tuwunel-maintenance"

restore_tuwunel_service() {
  docker rm -f "$container_name" >/dev/null 2>&1 || true
  sh -c "$compose_cmd up -d tuwunel" >/dev/null 2>&1 || true
}

trap restore_tuwunel_service EXIT

sh -c "$compose_cmd stop tuwunel"

set +e
timeout "$timeout_seconds" docker run --rm --name "$container_name" \
  -e TUWUNEL_CONFIG=/etc/tuwunel/tuwunel.toml \
  -v "$MATRIX_DATA_ROOT/tuwunel/config:/etc/tuwunel:ro" \
  -v "$MATRIX_DATA_ROOT/tuwunel/data:/data" \
  -v "$MATRIX_DATA_ROOT/secrets:/run/secrets:ro" \
  "$TUWUNEL_IMAGE" \
  --maintenance \
  --execute "$command_text" >"$log_file" 2>&1
run_status=$?
set -e

cat "$log_file" >&2

case "$run_status" in
  0|124)
    ;;
  *)
    exit "$run_status"
    ;;
esac
EOF
}

delete_matrix_room_on_host() {
  host_ip=$1
  room_id=$2

  log "onboarding: evicting local users from stale Matrix room $room_id through Tuwunel maintenance mode"
  run_remote_tuwunel_maintenance_command \
    "$host_ip" \
    "room moderation ban-room $room_id" \
    "onboarding: ban stale room $room_id" \
    180

  log "onboarding: deleting Matrix room $room_id through Tuwunel maintenance mode"
  run_remote_tuwunel_maintenance_command \
    "$host_ip" \
    "rooms delete $room_id --force" \
    "onboarding: delete room $room_id" \
    600
}

deactivate_matrix_user_on_host() {
  host_ip=$1
  username=$2
  user_id=$(matrix_user_id "$username")

  log "onboarding: deactivating Matrix user $user_id"
  run_remote_tuwunel_maintenance_command "$host_ip" "users deactivate $user_id" "onboarding: deactivate $user_id"
}

cleanup_remote_onboarding_artifacts() {
  host_ip=$1

  admin_password_path=$(remote_admin_matrix_password_path)
  onboarding_bot_password_path=$(remote_onboarding_bot_password_path)
  onboarding_secret_dir=$(remote_onboarding_secret_dir)

  ssh_exec "$host_ip" \
    "ADMIN_PASSWORD_PATH='$admin_password_path' ONBOARDING_BOT_PASSWORD_PATH='$onboarding_bot_password_path' ONBOARDING_SECRET_DIR='$onboarding_secret_dir' sh -s" <<'EOF'
set -eu

rm -f "$ADMIN_PASSWORD_PATH"
rm -f "$ONBOARDING_BOT_PASSWORD_PATH"
rmdir "$ONBOARDING_SECRET_DIR" >/dev/null 2>&1 || true
EOF
}

ensure_matrix_product_state() {
  host_ip=$1

  ensure_matrix_admin_access_token
  CURRENT_BOOTSTRAP_ADMIN_ACCESS_TOKEN=$CURRENT_MATRIX_ADMIN_ACCESS_TOKEN

  ensure_welcome_room "$host_ip" "$CURRENT_BOOTSTRAP_ADMIN_ACCESS_TOKEN"

  ensure_matrix_user \
    "$host_ip" \
    "$ONBOARDING_BOOTSTRAP_ONBOARDING_BOT_USERNAME" \
    "$ONBOARDING_BOT_PASSWORD" \
    CURRENT_ONBOARDING_BOT_USER_ID \
    CURRENT_ONBOARDING_BOT_ACCESS_TOKEN

  ensure_room_membership \
    "$CURRENT_WELCOME_ROOM_ID" \
    "$CURRENT_ONBOARDING_BOT_USER_ID" \
    "$CURRENT_BOOTSTRAP_ADMIN_ACCESS_TOKEN" \
    "$CURRENT_ONBOARDING_BOT_ACCESS_TOKEN"

  ensure_room_membership \
    "$CURRENT_WELCOME_ROOM_ID" \
    "$CURRENT_BOOTSTRAP_ADMIN_USER_ID" \
    "$CURRENT_ONBOARDING_BOT_ACCESS_TOKEN" \
    "$CURRENT_BOOTSTRAP_ADMIN_ACCESS_TOKEN"

  if ! ensure_welcome_room_shape \
    "$CURRENT_WELCOME_ROOM_ID" \
    "$CURRENT_BOOTSTRAP_ADMIN_USER_ID" \
    "$CURRENT_ONBOARDING_BOT_USER_ID" \
    "$CURRENT_BOOTSTRAP_ADMIN_ACCESS_TOKEN"; then
    log "onboarding: replacing welcome room $CURRENT_WELCOME_ROOM_ID because it cannot be reconciled by the server admin"
    delete_matrix_room_on_host "$host_ip" "$CURRENT_WELCOME_ROOM_ID"
    if ! wait_for_remote_matrix_ready "$host_ip" 120; then
      die "onboarding: Matrix did not become ready after deleting irreconcilable welcome room"
    fi

    ensure_welcome_room "$host_ip" "$CURRENT_BOOTSTRAP_ADMIN_ACCESS_TOKEN"
    ensure_room_membership \
      "$CURRENT_WELCOME_ROOM_ID" \
      "$CURRENT_ONBOARDING_BOT_USER_ID" \
      "$CURRENT_BOOTSTRAP_ADMIN_ACCESS_TOKEN" \
      "$CURRENT_ONBOARDING_BOT_ACCESS_TOKEN"
    ensure_room_membership \
      "$CURRENT_WELCOME_ROOM_ID" \
      "$CURRENT_BOOTSTRAP_ADMIN_USER_ID" \
      "$CURRENT_ONBOARDING_BOT_ACCESS_TOKEN" \
      "$CURRENT_BOOTSTRAP_ADMIN_ACCESS_TOKEN"
    ensure_welcome_room_shape \
      "$CURRENT_WELCOME_ROOM_ID" \
      "$CURRENT_BOOTSTRAP_ADMIN_USER_ID" \
      "$CURRENT_ONBOARDING_BOT_USER_ID" \
      "$CURRENT_BOOTSTRAP_ADMIN_ACCESS_TOKEN" || die "onboarding: failed to reconcile recreated welcome room"
  fi

  ensure_welcome_message \
    "$CURRENT_WELCOME_ROOM_ID" \
    "$CURRENT_ONBOARDING_BOT_USER_ID" \
    "$CURRENT_BOOTSTRAP_ADMIN_ACCESS_TOKEN" \
    "$CURRENT_ONBOARDING_BOT_ACCESS_TOKEN"
}

verify_matrix_product_state() {
  ensure_matrix_admin_access_token
  CURRENT_BOOTSTRAP_ADMIN_ACCESS_TOKEN=$CURRENT_MATRIX_ADMIN_ACCESS_TOKEN

  if ! resolve_room_alias "$(welcome_room_alias)" "$CURRENT_BOOTSTRAP_ADMIN_ACCESS_TOKEN"; then
    die "onboarding: expected welcome room alias $(welcome_room_alias) to exist"
  fi
  CURRENT_WELCOME_ROOM_ID=$RESOLVED_ROOM_ID

  if ! matrix_login_user_with_retry "$ONBOARDING_BOOTSTRAP_ONBOARDING_BOT_USERNAME" "$ONBOARDING_BOT_PASSWORD" 5; then
    die "onboarding: failed to log in as onboarding bot @$ONBOARDING_BOOTSTRAP_ONBOARDING_BOT_USERNAME:$MATRIX_SERVER_NAME"
  fi
  CURRENT_ONBOARDING_BOT_USER_ID=$LOGIN_USER_ID
  CURRENT_ONBOARDING_BOT_ACCESS_TOKEN=$LOGIN_ACCESS_TOKEN

  if ! access_token_joined_room "$CURRENT_WELCOME_ROOM_ID" "$CURRENT_ONBOARDING_BOT_ACCESS_TOKEN"; then
    die "onboarding: onboarding bot $CURRENT_ONBOARDING_BOT_USER_ID is not joined to welcome room $CURRENT_WELCOME_ROOM_ID"
  fi

  load_room_join_rule "$CURRENT_WELCOME_ROOM_ID" "$CURRENT_BOOTSTRAP_ADMIN_ACCESS_TOKEN"
  [ "$CURRENT_ROOM_JOIN_RULE" = "public" ] || die "onboarding: welcome room $CURRENT_WELCOME_ROOM_ID has join_rule=$CURRENT_ROOM_JOIN_RULE, want public"

  load_room_directory_visibility "$CURRENT_WELCOME_ROOM_ID" "$CURRENT_BOOTSTRAP_ADMIN_ACCESS_TOKEN"
  [ "$CURRENT_ROOM_DIRECTORY_VISIBILITY" = "public" ] || die "onboarding: welcome room $CURRENT_WELCOME_ROOM_ID has directory visibility $CURRENT_ROOM_DIRECTORY_VISIBILITY, want public"

  load_room_message_power_policy \
    "$CURRENT_WELCOME_ROOM_ID" \
    "$CURRENT_BOOTSTRAP_ADMIN_USER_ID" \
    "$CURRENT_ONBOARDING_BOT_USER_ID" \
    "$CURRENT_BOOTSTRAP_ADMIN_ACCESS_TOKEN"
  [ "$CURRENT_ROOM_USERS_DEFAULT" -lt "$CURRENT_ROOM_MESSAGE_POWER_LEVEL" ] || die "onboarding: welcome room $CURRENT_WELCOME_ROOM_ID still allows ordinary users to send messages (users_default=$CURRENT_ROOM_USERS_DEFAULT, m.room.message=$CURRENT_ROOM_MESSAGE_POWER_LEVEL)"
  [ "$CURRENT_ROOM_ADMIN_POWER_LEVEL" -ge "$CURRENT_ROOM_MESSAGE_POWER_LEVEL" ] || die "onboarding: server admin $CURRENT_BOOTSTRAP_ADMIN_USER_ID cannot send welcome-room messages after power-level reconciliation"
  [ "$CURRENT_ROOM_ONBOARDING_BOT_POWER_LEVEL" -ge "$CURRENT_ROOM_MESSAGE_POWER_LEVEL" ] || die "onboarding: onboarding bot $CURRENT_ONBOARDING_BOT_USER_ID cannot send the welcome message after power-level reconciliation"

  room_is_onboarding_managed_welcome_room "$CURRENT_WELCOME_ROOM_ID" "$CURRENT_BOOTSTRAP_ADMIN_ACCESS_TOKEN" || {
    die "onboarding: welcome room $CURRENT_WELCOME_ROOM_ID is missing the infra ownership marker"
  }

  if ! room_has_exact_message \
    "$CURRENT_WELCOME_ROOM_ID" \
    "$CURRENT_ONBOARDING_BOT_USER_ID" \
    "$(welcome_message_body "$CURRENT_ONBOARDING_BOT_USER_ID")" \
    "$CURRENT_ONBOARDING_BOT_ACCESS_TOKEN"; then
    die "onboarding: welcome room is missing the canonical onboarding welcome message"
  fi

  if room_has_exact_message \
    "$CURRENT_WELCOME_ROOM_ID" \
    "$CURRENT_ONBOARDING_BOT_USER_ID" \
    "$(legacy_matrix_uri_welcome_message_body "$CURRENT_ONBOARDING_BOT_USER_ID")" \
    "$CURRENT_ONBOARDING_BOT_ACCESS_TOKEN"; then
    die "onboarding: welcome room still contains the legacy matrix:u onboarding welcome message"
  fi

  if room_has_exact_message \
    "$CURRENT_WELCOME_ROOM_ID" \
    "$CURRENT_ONBOARDING_BOT_USER_ID" \
    "$(legacy_matrix_to_welcome_message_body "$CURRENT_ONBOARDING_BOT_USER_ID")" \
    "$CURRENT_ONBOARDING_BOT_ACCESS_TOKEN"; then
    die "onboarding: welcome room still contains the transient matrix.to onboarding welcome message"
  fi
}

ensure_auth_proxy_scenario() {
  host_ip=$1

  prepare_bootstrap_codex_auth "$host_ip" "$tmpdir"

  root_config_path=$(mktemp "$tmpdir/auth-proxy-root.XXXXXX")
  external_slots_path=$(mktemp "$tmpdir/auth-proxy-slots.XXXXXX")
  metadata_path=$(mktemp "$tmpdir/auth-proxy-metadata.XXXXXX")
  write_auth_proxy_root_config_json "$root_config_path"
  write_empty_json "$external_slots_path"
  write_auth_proxy_metadata_json "$metadata_path"

  ensure_managed_scenario \
    "$ONBOARDING_METADATA_KIND_AUTH_PROXY" \
    "$AUTH_PROXY_SOURCE_URL" \
    "$root_config_path" \
    "$external_slots_path" \
    "$metadata_path" \
    CURRENT_AUTH_PROXY_SCENARIO_ID

  wait_for_scenario_export_service_id "$CURRENT_AUTH_PROXY_SCENARIO_ID" responses_api CURRENT_SHARED_RESPONSES_BINDABLE_SERVICE_ID
}

resolve_shared_responses_service() {
  provider_is_auth_proxy=false

  if [ -n "$ONBOARDING_SHARED_RESPONSES_BINDABLE_SERVICE_ID" ]; then
    if ! lookup_bindable_service_id_by_id "$ONBOARDING_SHARED_RESPONSES_BINDABLE_SERVICE_ID"; then
      die "onboarding: configured shared responses bindable service id $ONBOARDING_SHARED_RESPONSES_BINDABLE_SERVICE_ID is missing or unavailable"
    fi
    CURRENT_SHARED_RESPONSES_BINDABLE_SERVICE_ID=$LOOKUP_BINDABLE_SERVICE_ID
    CURRENT_AUTH_PROXY_SCENARIO_ID=
    if [ -n "$LOOKUP_BINDABLE_SERVICE_SCENARIO_ID" ]; then
      detail_path=$(mktemp "$tmpdir/shared-responses-scenario.XXXXXX")
      get_scenario_detail "$LOOKUP_BINDABLE_SERVICE_SCENARIO_ID" "$detail_path"
      if [ "$(jq -r '.metadata.kind // ""' "$detail_path")" = "$ONBOARDING_METADATA_KIND_AUTH_PROXY" ]; then
        CURRENT_AUTH_PROXY_SCENARIO_ID=$LOOKUP_BINDABLE_SERVICE_SCENARIO_ID
        provider_is_auth_proxy=true
      fi
    fi
    if [ "$provider_is_auth_proxy" = "true" ] && [ -n "$AUTH_PROXY_SOURCE_URL" ]; then
      ensure_auth_proxy_scenario "$1"
    fi
    return 0
  fi

  if lookup_bindable_service_id_by_display_name "$ONBOARDING_SHARED_RESPONSES_BINDABLE_SERVICE_NAME"; then
    CURRENT_SHARED_RESPONSES_BINDABLE_SERVICE_ID=$LOOKUP_BINDABLE_SERVICE_ID
    CURRENT_AUTH_PROXY_SCENARIO_ID=
    if [ -n "$LOOKUP_BINDABLE_SERVICE_SCENARIO_ID" ]; then
      detail_path=$(mktemp "$tmpdir/shared-responses-scenario.XXXXXX")
      get_scenario_detail "$LOOKUP_BINDABLE_SERVICE_SCENARIO_ID" "$detail_path"
      if [ "$(jq -r '.metadata.kind // ""' "$detail_path")" = "$ONBOARDING_METADATA_KIND_AUTH_PROXY" ]; then
        CURRENT_AUTH_PROXY_SCENARIO_ID=$LOOKUP_BINDABLE_SERVICE_SCENARIO_ID
        provider_is_auth_proxy=true
      fi
    fi
    if [ "$provider_is_auth_proxy" = "true" ]; then
      ensure_auth_proxy_scenario "$1"
    fi
    return 0
  fi

  if [ -z "$AUTH_PROXY_SOURCE_URL" ]; then
    die "onboarding: no shared responses bindable service is available and auth-proxy bootstrap is not configured"
  fi

  ensure_auth_proxy_scenario "$1"
}

reconcile_remote_control_plane() {
  host_ip=$1

  ensure_onboarding_passwords "$host_ip" apply
  prepare_codex_config "$tmpdir"
  ensure_matrix_product_state "$host_ip"
  ensure_local_manager_tunnel_healthy "$host_ip"
  resolve_shared_responses_service "$host_ip"

  if ! lookup_bindable_service_id_by_display_name "$ONBOARDING_MATRIX_BINDABLE_SERVICE_NAME"; then
    die "onboarding: matrix bindable service $ONBOARDING_MATRIX_BINDABLE_SERVICE_NAME is missing or unavailable"
  fi
  matrix_service_id=$LOOKUP_BINDABLE_SERVICE_ID

  if ! lookup_bindable_service_id_by_display_name "$ONBOARDING_MANAGER_BINDABLE_SERVICE_NAME"; then
    die "onboarding: manager bindable service $ONBOARDING_MANAGER_BINDABLE_SERVICE_NAME is missing or unavailable"
  fi
  manager_service_id=$LOOKUP_BINDABLE_SERVICE_ID

  provisioner_root_config=$(mktemp "$tmpdir/provisioner-root.XXXXXX")
  provisioner_external_slots=$(mktemp "$tmpdir/provisioner-slots.XXXXXX")
  provisioner_metadata=$(mktemp "$tmpdir/provisioner-metadata.XXXXXX")
  write_provisioner_root_config_json "$provisioner_root_config"
  write_provisioner_external_slots_json "$provisioner_external_slots" "$matrix_service_id" "$manager_service_id"
  write_provisioner_metadata_json "$provisioner_metadata"

  ensure_managed_scenario \
    "$ONBOARDING_METADATA_KIND_PROVISIONER" \
    "$PROVISIONER_SOURCE_URL" \
    "$provisioner_root_config" \
    "$provisioner_external_slots" \
    "$provisioner_metadata" \
    CURRENT_PROVISIONER_SCENARIO_ID

  wait_for_scenario_export_service_id "$CURRENT_PROVISIONER_SCENARIO_ID" mcp provisioner_mcp_service_id

  onboarding_root_config=$(mktemp "$tmpdir/onboarding-root.XXXXXX")
  onboarding_external_slots=$(mktemp "$tmpdir/onboarding-slots.XXXXXX")
  onboarding_metadata=$(mktemp "$tmpdir/onboarding-metadata.XXXXXX")
  write_onboarding_root_config_json "$onboarding_root_config"
  write_onboarding_external_slots_json "$onboarding_external_slots" "$matrix_service_id" "$CURRENT_SHARED_RESPONSES_BINDABLE_SERVICE_ID" "$provisioner_mcp_service_id"
  write_onboarding_metadata_json "$onboarding_metadata" "$CURRENT_PROVISIONER_SCENARIO_ID"

  ensure_managed_scenario \
    "$ONBOARDING_METADATA_KIND_ONBOARDING" \
    "$ONBOARDING_SOURCE_URL" \
    "$onboarding_root_config" \
    "$onboarding_external_slots" \
    "$onboarding_metadata" \
    CURRENT_ONBOARDING_SCENARIO_ID
}

cleanup_remote_bundle() {
  host_ip=$1
  ssh_exec "$host_ip" "MATRIX_DATA_ROOT='$MATRIX_DATA_ROOT' REMOTE_SUFFIX='$REMOTE_MANAGER_SOURCE_DIR_SUFFIX' sh -s" <<'EOF'
set -eu
rm -rf "$MATRIX_DATA_ROOT/$REMOTE_SUFFIX"
EOF
}

destroy_remote_control_plane() {
  host_ip=$1

  start_manager_tunnel "$host_ip"
  if ! wait_for_local_manager_ready 60; then
    die "onboarding: local manager tunnel did not become ready"
  fi

  scenarios_path=$(mktemp "$tmpdir/destroy-scenarios.XXXXXX")
  status_path=$(mktemp "$tmpdir/destroy-scenarios-status.XXXXXX")
  manager_api_get_to_file /v1/scenarios "$scenarios_path" "$status_path"
  expect_http_success "$status_path" "$scenarios_path" "onboarding: list scenarios before destroy"

  user_agent_count=$(jq '[.[] | select(.metadata.kind == "user-agent" and .metadata.provisioning_source == "onboarding")] | length' "$scenarios_path")
  if [ "$user_agent_count" -gt 0 ] && [ "$ONBOARDING_DESTROY_INCLUDE_USER_AGENTS" != "true" ]; then
    die "onboarding: found $user_agent_count onboarding-created user-agent scenario(s); set ONBOARDING_DESTROY_INCLUDE_USER_AGENTS=true if you want destroy to remove them too"
  fi

  destroy_plan=$(jq -r --arg include_user_agents "$ONBOARDING_DESTROY_INCLUDE_USER_AGENTS" '
    [
      .[]
      | select(
          .metadata.kind == "onboarding-agent"
          or .metadata.kind == "onboarding-provisioner"
          or .metadata.kind == "onboarding-auth-proxy"
          or (
            $include_user_agents == "true"
            and .metadata.kind == "user-agent"
            and .metadata.provisioning_source == "onboarding"
          )
        )
      | {
          priority: (
            if .metadata.kind == "user-agent" then 0
            elif .metadata.kind == "onboarding-agent" then 1
            elif .metadata.kind == "onboarding-provisioner" then 2
            else 3
            end
          ),
          scenario_id,
          kind: (.metadata.kind // "")
        }
    ]
    | sort_by(.priority)
    | .[]
    | [.scenario_id, .kind] | @tsv
  ' "$scenarios_path")

  tab=$(printf '\t')
  printf '%s\n' "$destroy_plan" | while IFS="$tab" read -r scenario_id kind; do
    [ -n "${scenario_id:-}" ] || continue
    log "onboarding: deleting scenario $scenario_id ($kind)"
    delete_response=$(mktemp "$tmpdir/destroy-response.XXXXXX")
    delete_status=$(mktemp "$tmpdir/destroy-status.XXXXXX")
    manager_api_delete_to_file "/v1/scenarios/$scenario_id?destroy_storage=true" "$delete_response" "$delete_status"
    expect_http_success "$delete_status" "$delete_response" "onboarding: delete scenario $scenario_id"
    operation_id=$(jq -r '.operation_id // ""' "$delete_response")
    [ -n "$operation_id" ] || die "onboarding: delete scenario $scenario_id did not return an operation_id"
    wait_for_manager_operation_succeeded "$operation_id"
  done

  render_allowlist_json "$tmpdir/allowlist-destroy.json"
  set_remote_manager_allowlist "$host_ip" "$tmpdir/allowlist-destroy.json"
  cleanup_remote_bundle "$host_ip"

  remaining_path=$(mktemp "$tmpdir/destroy-remaining.XXXXXX")
  remaining_status=$(mktemp "$tmpdir/destroy-remaining-status.XXXXXX")
  manager_api_get_to_file /v1/scenarios "$remaining_path" "$remaining_status"
  expect_http_success "$remaining_status" "$remaining_path" "onboarding: list scenarios after destroy"

  jq -e --arg include_user_agents "$ONBOARDING_DESTROY_INCLUDE_USER_AGENTS" '
    [
      .[]
      | select(
          .metadata.kind == "onboarding-agent"
          or .metadata.kind == "onboarding-provisioner"
          or .metadata.kind == "onboarding-auth-proxy"
          or (
            $include_user_agents == "true"
            and .metadata.kind == "user-agent"
            and .metadata.provisioning_source == "onboarding"
          )
        )
    ]
    | length == 0
  ' "$remaining_path" >/dev/null || die "onboarding: destroy did not remove all targeted onboarding scenarios"

  config_path="$tmpdir/manager-config.destroy.json"
  ssh_exec "$host_ip" "MATRIX_DATA_ROOT='$MATRIX_DATA_ROOT' sh -s" <<'EOF' >"$config_path"
set -eu
cat "$MATRIX_DATA_ROOT/amber-manager/config/manager-config.json"
EOF
  allowlist_json=$(jq -c '.scenario_source_allowlist // []' "$config_path")
  [ "$allowlist_json" = "[]" ] || die "onboarding: manager allowlist is not empty after destroy"

  ensure_matrix_admin_access_token
  if resolve_room_alias "$(welcome_room_alias)" "$CURRENT_MATRIX_ADMIN_ACCESS_TOKEN"; then
    delete_matrix_room_on_host "$host_ip" "$RESOLVED_ROOM_ID"
    if ! wait_for_remote_matrix_ready "$host_ip" 120; then
      die "onboarding: Matrix did not become ready after deleting the welcome room during destroy"
    fi
    if ! wait_for_room_alias_absent "$(welcome_room_alias)" "$CURRENT_MATRIX_ADMIN_ACCESS_TOKEN" 60; then
      die "onboarding: welcome room alias still resolves after destroy"
    fi
  fi

  deactivate_matrix_user_on_host "$host_ip" "$ONBOARDING_BOOTSTRAP_ONBOARDING_BOT_USERNAME"
  if ! wait_for_remote_matrix_ready "$host_ip" 120; then
    die "onboarding: Matrix did not become ready after deactivating onboarding users during destroy"
  fi

  cleanup_remote_onboarding_artifacts "$host_ip"

  log "onboarding: destroy completed and removed the onboarding-managed Matrix resources"
}

verify_managed_scenario_contract() {
  kind=$1
  source_url=$2
  root_config_path=$3
  external_slots_path=$4
  metadata_path=$5
  result_var=$6

  scenario_id=$(lookup_scenario_id_by_kind "$kind")
  [ -n "$scenario_id" ] || die "onboarding: expected one scenario for kind $kind"

  detail_path=$(mktemp "$tmpdir/verify-scenario.XXXXXX")
  get_scenario_detail "$scenario_id" "$detail_path"
  if [ "$(jq -r '.observed_state // ""' "$detail_path")" != "running" ]; then
    wait_for_scenario_running "$scenario_id"
    get_scenario_detail "$scenario_id" "$detail_path"
  fi
  scenario_contract_matches "$detail_path" "$source_url" "$root_config_path" "$external_slots_path" "$metadata_path" || {
    die "onboarding: scenario $scenario_id ($kind) does not match the desired root contract"
  }

  observed_state=$(jq -r '.observed_state // ""' "$detail_path")
  [ "$observed_state" = "running" ] || die "onboarding: scenario $scenario_id ($kind) is not running"

  eval "$result_var=\$scenario_id"
}

inspect_shared_responses_service() {
  CURRENT_SHARED_RESPONSES_BINDABLE_SERVICE_ID=
  CURRENT_AUTH_PROXY_SCENARIO_ID=

  if [ -n "$ONBOARDING_SHARED_RESPONSES_BINDABLE_SERVICE_ID" ]; then
    if ! lookup_bindable_service_id_by_id "$ONBOARDING_SHARED_RESPONSES_BINDABLE_SERVICE_ID"; then
      die "onboarding: configured shared responses bindable service id $ONBOARDING_SHARED_RESPONSES_BINDABLE_SERVICE_ID is missing or unavailable"
    fi
    CURRENT_SHARED_RESPONSES_BINDABLE_SERVICE_ID=$LOOKUP_BINDABLE_SERVICE_ID
  elif lookup_bindable_service_id_by_display_name "$ONBOARDING_SHARED_RESPONSES_BINDABLE_SERVICE_NAME"; then
    CURRENT_SHARED_RESPONSES_BINDABLE_SERVICE_ID=$LOOKUP_BINDABLE_SERVICE_ID
  fi

  if [ -n "$LOOKUP_BINDABLE_SERVICE_SCENARIO_ID" ]; then
    detail_path=$(mktemp "$tmpdir/inspect-shared-responses.XXXXXX")
    get_scenario_detail "$LOOKUP_BINDABLE_SERVICE_SCENARIO_ID" "$detail_path"
    if [ "$(jq -r '.metadata.kind // ""' "$detail_path")" = "$ONBOARDING_METADATA_KIND_AUTH_PROXY" ]; then
      CURRENT_AUTH_PROXY_SCENARIO_ID=$LOOKUP_BINDABLE_SERVICE_SCENARIO_ID
    fi
  fi

  if [ -n "$CURRENT_SHARED_RESPONSES_BINDABLE_SERVICE_ID" ]; then
    return 0
  fi

  auth_proxy_scenario_id=$(lookup_scenario_id_by_kind "$ONBOARDING_METADATA_KIND_AUTH_PROXY")
  if [ -n "$auth_proxy_scenario_id" ]; then
    CURRENT_AUTH_PROXY_SCENARIO_ID=$auth_proxy_scenario_id
    wait_for_scenario_running "$CURRENT_AUTH_PROXY_SCENARIO_ID"
    wait_for_scenario_export_service_id "$CURRENT_AUTH_PROXY_SCENARIO_ID" responses_api CURRENT_SHARED_RESPONSES_BINDABLE_SERVICE_ID
    return 0
  fi

  die "onboarding: no shared responses bindable service is available"
}

verify_remote_control_plane() {
  host_ip=$1

  start_manager_tunnel "$host_ip"
  if ! wait_for_local_manager_ready 60; then
    die "onboarding: local manager tunnel did not become ready"
  fi

  versions_path=$(mktemp "$tmpdir/matrix-versions.XXXXXX")
  versions_status=$(mktemp "$tmpdir/matrix-versions-status.XXXXXX")
  matrix_api_get_to_file "$MATRIX_BASE_URL/_matrix/client/versions" "" "$versions_path" "$versions_status"
  expect_http_success "$versions_status" "$versions_path" "onboarding: probe Matrix versions endpoint"

  ensure_onboarding_passwords "$host_ip" verify
  verify_matrix_product_state
  prepare_codex_config "$tmpdir"
  inspect_shared_responses_service

  if ! lookup_bindable_service_id_by_display_name "$ONBOARDING_MATRIX_BINDABLE_SERVICE_NAME"; then
    die "onboarding: matrix bindable service $ONBOARDING_MATRIX_BINDABLE_SERVICE_NAME is missing or unavailable"
  fi
  matrix_service_id=$LOOKUP_BINDABLE_SERVICE_ID

  if ! lookup_bindable_service_id_by_display_name "$ONBOARDING_MANAGER_BINDABLE_SERVICE_NAME"; then
    die "onboarding: manager bindable service $ONBOARDING_MANAGER_BINDABLE_SERVICE_NAME is missing or unavailable"
  fi
  manager_service_id=$LOOKUP_BINDABLE_SERVICE_ID

  if [ -n "$CURRENT_AUTH_PROXY_SCENARIO_ID" ] && [ -n "$AUTH_PROXY_SOURCE_URL" ]; then
    BOOTSTRAP_CODEX_AUTH_JSON_PATH="$tmpdir/verify-auth.json"
    printf '{}\n' >"$BOOTSTRAP_CODEX_AUTH_JSON_PATH"

    auth_proxy_root_config=$(mktemp "$tmpdir/verify-auth-proxy-root.XXXXXX")
    auth_proxy_external_slots=$(mktemp "$tmpdir/verify-auth-proxy-slots.XXXXXX")
    auth_proxy_metadata=$(mktemp "$tmpdir/verify-auth-proxy-metadata.XXXXXX")
    write_auth_proxy_root_config_json "$auth_proxy_root_config"
    write_empty_json "$auth_proxy_external_slots"
    write_auth_proxy_metadata_json "$auth_proxy_metadata"

    verify_managed_scenario_contract \
      "$ONBOARDING_METADATA_KIND_AUTH_PROXY" \
      "$AUTH_PROXY_SOURCE_URL" \
      "$auth_proxy_root_config" \
      "$auth_proxy_external_slots" \
      "$auth_proxy_metadata" \
      CURRENT_AUTH_PROXY_SCENARIO_ID

    wait_for_scenario_export_service_id "$CURRENT_AUTH_PROXY_SCENARIO_ID" responses_api CURRENT_SHARED_RESPONSES_BINDABLE_SERVICE_ID
  elif [ -n "$CURRENT_AUTH_PROXY_SCENARIO_ID" ]; then
    wait_for_scenario_export_service_id "$CURRENT_AUTH_PROXY_SCENARIO_ID" responses_api CURRENT_SHARED_RESPONSES_BINDABLE_SERVICE_ID
  fi

  provisioner_root_config=$(mktemp "$tmpdir/verify-provisioner-root.XXXXXX")
  provisioner_external_slots=$(mktemp "$tmpdir/verify-provisioner-slots.XXXXXX")
  provisioner_metadata=$(mktemp "$tmpdir/verify-provisioner-metadata.XXXXXX")
  write_provisioner_root_config_json "$provisioner_root_config"
  write_provisioner_external_slots_json "$provisioner_external_slots" "$matrix_service_id" "$manager_service_id"
  write_provisioner_metadata_json "$provisioner_metadata"

  verify_managed_scenario_contract \
    "$ONBOARDING_METADATA_KIND_PROVISIONER" \
    "$PROVISIONER_SOURCE_URL" \
    "$provisioner_root_config" \
    "$provisioner_external_slots" \
    "$provisioner_metadata" \
    CURRENT_PROVISIONER_SCENARIO_ID

  wait_for_scenario_export_service_id "$CURRENT_PROVISIONER_SCENARIO_ID" mcp provisioner_mcp_service_id

  onboarding_root_config=$(mktemp "$tmpdir/verify-onboarding-root.XXXXXX")
  onboarding_external_slots=$(mktemp "$tmpdir/verify-onboarding-slots.XXXXXX")
  onboarding_metadata=$(mktemp "$tmpdir/verify-onboarding-metadata.XXXXXX")
  write_onboarding_root_config_json "$onboarding_root_config"
  write_onboarding_external_slots_json "$onboarding_external_slots" "$matrix_service_id" "$CURRENT_SHARED_RESPONSES_BINDABLE_SERVICE_ID" "$provisioner_mcp_service_id"
  write_onboarding_metadata_json "$onboarding_metadata" "$CURRENT_PROVISIONER_SCENARIO_ID"

  verify_managed_scenario_contract \
    "$ONBOARDING_METADATA_KIND_ONBOARDING" \
    "$ONBOARDING_SOURCE_URL" \
    "$onboarding_root_config" \
    "$onboarding_external_slots" \
    "$onboarding_metadata" \
    CURRENT_ONBOARDING_SCENARIO_ID

  wait_for_scenario_export_service_id "$CURRENT_ONBOARDING_SCENARIO_ID" a2a onboarding_a2a_service_id
  [ -n "$onboarding_a2a_service_id" ] || die "onboarding: onboarding scenario did not publish an a2a export"

  config_path="$tmpdir/manager-config.verify.json"
  ssh_exec "$host_ip" "MATRIX_DATA_ROOT='$MATRIX_DATA_ROOT' sh -s" <<'EOF' >"$config_path"
set -eu
cat "$MATRIX_DATA_ROOT/amber-manager/config/manager-config.json"
EOF
  allowlist_json=$(jq -c '.scenario_source_allowlist // []' "$config_path")

  expected_allowlist=$(printf '%s\n' "$DEFAULT_AGENT_SOURCE_URL" | jq -Rsc 'split("\n") | map(select(length > 0))')
  [ "$allowlist_json" = "$expected_allowlist" ] || die "onboarding: manager allowlist is not in steady state for default-agent provisioning"

  log "onboarding: control plane and Matrix product invariants are healthy on top of $MATRIX_BASE_URL"
}

run_apply() {
  validate_apply_config

  if ! hcloud_server_exists "$HCLOUD_SERVER_NAME"; then
    die "onboarding: server \"$HCLOUD_SERVER_NAME\" does not exist; apply infra/matrix first"
  fi
  host_ip=$(hcloud_server_ipv4 "$HCLOUD_SERVER_NAME")
  [ -n "$host_ip" ] || die "onboarding: failed to resolve server IPv4 for \"$HCLOUD_SERVER_NAME\""

  ssh_wait_for_ready "$host_ip"
  if ! wait_for_remote_manager_ready "$host_ip" 120; then
    die "onboarding: amber-manager is not ready on the target host"
  fi

  tmpdir=$(mktemp -d)
  trap handle_interrupt INT TERM

  bundle_dir="$tmpdir/bundle"
  render_bundle "$bundle_dir"
  deploy_bundle "$host_ip" "$bundle_dir"

  render_allowlist_json "$tmpdir/allowlist-bootstrap.json" \
    "$PROVISIONER_SOURCE_URL" \
    "$ONBOARDING_SOURCE_URL" \
    "$DEFAULT_AGENT_SOURCE_URL" \
    "$AUTH_PROXY_SOURCE_URL"
  set_remote_manager_allowlist "$host_ip" "$tmpdir/allowlist-bootstrap.json"

  start_manager_tunnel "$host_ip"
  if ! wait_for_local_manager_ready 60; then
    die "onboarding: local manager tunnel did not become ready"
  fi

  reconcile_remote_control_plane "$host_ip"

  render_allowlist_json "$tmpdir/allowlist-steady.json" "$DEFAULT_AGENT_SOURCE_URL"
  set_remote_manager_allowlist "$host_ip" "$tmpdir/allowlist-steady.json"

  verify_remote_control_plane "$host_ip"
}

run_verify() {
  validate_verify_config
  resolve_source_urls

  if ! hcloud_server_exists "$HCLOUD_SERVER_NAME"; then
    die "onboarding: server \"$HCLOUD_SERVER_NAME\" does not exist"
  fi
  host_ip=$(hcloud_server_ipv4 "$HCLOUD_SERVER_NAME")
  [ -n "$host_ip" ] || die "onboarding: failed to resolve server IPv4 for \"$HCLOUD_SERVER_NAME\""

  ssh_wait_for_ready "$host_ip"
  if ! wait_for_remote_manager_ready "$host_ip" 120; then
    die "onboarding: amber-manager is not ready on the target host"
  fi

  tmpdir=$(mktemp -d)
  trap handle_interrupt INT TERM

  verify_remote_control_plane "$host_ip"
}

run_destroy() {
  validate_destroy_config

  if ! hcloud_server_exists "$HCLOUD_SERVER_NAME"; then
    die "onboarding: server \"$HCLOUD_SERVER_NAME\" does not exist"
  fi
  host_ip=$(hcloud_server_ipv4 "$HCLOUD_SERVER_NAME")
  [ -n "$host_ip" ] || die "onboarding: failed to resolve server IPv4 for \"$HCLOUD_SERVER_NAME\""

  ssh_wait_for_ready "$host_ip"
  if ! wait_for_remote_manager_ready "$host_ip" 120; then
    die "onboarding: amber-manager is not ready on the target host"
  fi

  tmpdir=$(mktemp -d)
  trap handle_interrupt INT TERM

  destroy_remote_control_plane "$host_ip"
}

trap 'cleanup_tunnel; cleanup_tmpdir' EXIT

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 1
fi

case "$1" in
  apply)
    run_apply
    ;;
  verify)
    run_verify
    ;;
  destroy)
    run_destroy
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
