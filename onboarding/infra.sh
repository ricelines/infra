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

: "${ONBOARDING_BOOTSTRAP_OPERATOR_USERNAME:=${ONBOARDING_BOOTSTRAP_ADMIN_USERNAME:-bootstrap-operator}}"
: "${ONBOARDING_BOOTSTRAP_OPERATOR_PASSWORD:=${ONBOARDING_BOOTSTRAP_ADMIN_PASSWORD:-}}"
: "${ONBOARDING_BOOTSTRAP_ONBOARDING_BOT_USERNAME:=onboarding}"
: "${ONBOARDING_BOOTSTRAP_ONBOARDING_BOT_PASSWORD:=}"
: "${ONBOARDING_BOOTSTRAP_WELCOME_ROOM_ALIAS_LOCALPART:=welcome}"

: "${ONBOARDING_ONBOARDING_MODEL:=gpt-5.4-mini}"
: "${ONBOARDING_ONBOARDING_MODEL_REASONING_EFFORT:=medium}"
: "${ONBOARDING_DEFAULT_AGENT_MODEL:=gpt-5.4-mini}"
: "${ONBOARDING_DEFAULT_AGENT_MODEL_REASONING_EFFORT:=medium}"

: "${ONBOARDING_DEFAULT_AGENT_SOURCE_URL:=https://raw.githubusercontent.com/ricelines/scenarios/refs/heads/main/amber/user-agent.json5}"
: "${ONBOARDING_AUTH_PROXY_SOURCE_URL:=https://raw.githubusercontent.com/ricelines/codex-a2a/refs/heads/main/amber/codex-auth-proxy.json5}"
: "${ONBOARDING_SHARED_RESPONSES_BINDABLE_SERVICE_ID:=}"
: "${ONBOARDING_CODEX_AUTH_JSON_PATH:=}"
: "${ONBOARDING_DESTROY_CONFIRM:=}"
: "${ONBOARDING_DESTROY_INCLUDE_USER_AGENTS:=false}"

: "${ONBOARDING_PROVISIONER_MANIFEST_PATH:=$REPO_ROOT/onboarding/amber/agent-provisioner.json5}"
: "${ONBOARDING_ONBOARDING_MANIFEST_PATH:=$REPO_ROOT/onboarding/amber/onboarding-agent.json5}"
: "${ONBOARDING_ONBOARDING_DEVELOPER_INSTRUCTIONS_PATH:=$REPO_ROOT/onboarding/prompts/onboarding-developer-instructions.md}"
: "${ONBOARDING_ONBOARDING_AGENTS_MD_PATH:=$REPO_ROOT/onboarding/agents/onboarding-agent.md}"
: "${ONBOARDING_DEFAULT_AGENT_DEVELOPER_INSTRUCTIONS_PATH:=$REPO_ROOT/onboarding/prompts/default-user-agent-developer-instructions.md}"
: "${ONBOARDING_DEFAULT_AGENT_AGENTS_MD_PATH:=$REPO_ROOT/onboarding/agents/default-user-agent.md}"
: "${ONBOARDING_CODEX_CONFIG_TOML_PATH:=}"

REMOTE_MANAGER_SOURCE_DIR_SUFFIX=amber-manager/data/bootstrap-sources
REMOTE_MANAGER_SOURCE_URL_PREFIX=file:///var/lib/amber-manager/bootstrap-sources

PROVISIONER_SOURCE_URL=
ONBOARDING_SOURCE_URL=
DEFAULT_AGENT_SOURCE_URL=
AUTH_PROXY_SOURCE_URL=

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

Required onboarding environment:
  ONBOARDING_BOOTSTRAP_OPERATOR_PASSWORD
  ONBOARDING_BOOTSTRAP_ONBOARDING_BOT_PASSWORD

One of:
  ONBOARDING_SHARED_RESPONSES_BINDABLE_SERVICE_ID
  ONBOARDING_AUTH_PROXY_SOURCE_URL + ONBOARDING_CODEX_AUTH_JSON_PATH

Important notes:
  - ONBOARDING_CODEX_AUTH_JSON_PATH is a local path on the machine running this script.
  - apply temporarily allowlists bootstrap-only scenario sources in amber-manager,
    runs onboarding bootstrap from the local checkout, then leaves only the default
    agent source allowlisted for future provisioning.
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
  require_local_command go
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

  require_nonempty ONBOARDING_BOOTSTRAP_OPERATOR_PASSWORD
  require_nonempty ONBOARDING_BOOTSTRAP_ONBOARDING_BOT_PASSWORD
  require_nonempty ONBOARDING_DEFAULT_AGENT_SOURCE_URL
  require_nonempty ONBOARDING_ONBOARDING_MODEL
  require_nonempty ONBOARDING_DEFAULT_AGENT_MODEL

  require_file "$(local_abs_path "$ONBOARDING_PROVISIONER_MANIFEST_PATH")"
  require_file "$(local_abs_path "$ONBOARDING_ONBOARDING_MANIFEST_PATH")"
  require_file "$(local_abs_path "$ONBOARDING_ONBOARDING_DEVELOPER_INSTRUCTIONS_PATH")"
  require_file "$(local_abs_path "$ONBOARDING_ONBOARDING_AGENTS_MD_PATH")"
  require_file "$(local_abs_path "$ONBOARDING_DEFAULT_AGENT_DEVELOPER_INSTRUCTIONS_PATH")"
  require_file "$(local_abs_path "$ONBOARDING_DEFAULT_AGENT_AGENTS_MD_PATH")"

  if [ -n "$ONBOARDING_CODEX_CONFIG_TOML_PATH" ]; then
    require_file "$(local_abs_path "$ONBOARDING_CODEX_CONFIG_TOML_PATH")"
  fi

  if [ -z "$ONBOARDING_SHARED_RESPONSES_BINDABLE_SERVICE_ID" ]; then
    require_nonempty ONBOARDING_AUTH_PROXY_SOURCE_URL
    require_nonempty ONBOARDING_CODEX_AUTH_JSON_PATH
    require_file "$(local_abs_path "$ONBOARDING_CODEX_AUTH_JSON_PATH")"
  fi
}

validate_verify_config() {
  validate_common_config
  require_local_prereqs
  require_nonempty ONBOARDING_DEFAULT_AGENT_SOURCE_URL
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

run_bootstrap_locally() {
  tmpdir_path=$1

  prepare_codex_config "$tmpdir_path"
  state_path="$tmpdir_path/bootstrap-state.json"
  printf '%s\n' '{}' >"$state_path"

  log "onboarding: running onboarding bootstrap against $MATRIX_BASE_URL via manager tunnel on 127.0.0.1:$ONBOARDING_MANAGER_TUNNEL_PORT"
  (
    cd "$REPO_ROOT/onboarding"
    ONBOARDING_BOOTSTRAP_STATE_PATH="$state_path" \
    ONBOARDING_BOOTSTRAP_MATRIX_HOMESERVER_URL="$MATRIX_BASE_URL" \
    ONBOARDING_BOOTSTRAP_MATRIX_SERVER_NAME="$MATRIX_SERVER_NAME" \
    ONBOARDING_BOOTSTRAP_REGISTRATION_TOKEN="$MATRIX_REGISTRATION_TOKEN" \
    ONBOARDING_BOOTSTRAP_MANAGER_URL="http://127.0.0.1:$ONBOARDING_MANAGER_TUNNEL_PORT" \
    ONBOARDING_BOOTSTRAP_OPERATOR_USERNAME="$ONBOARDING_BOOTSTRAP_OPERATOR_USERNAME" \
    ONBOARDING_BOOTSTRAP_OPERATOR_PASSWORD="$ONBOARDING_BOOTSTRAP_OPERATOR_PASSWORD" \
    ONBOARDING_BOOTSTRAP_ONBOARDING_BOT_USERNAME="$ONBOARDING_BOOTSTRAP_ONBOARDING_BOT_USERNAME" \
    ONBOARDING_BOOTSTRAP_ONBOARDING_BOT_PASSWORD="$ONBOARDING_BOOTSTRAP_ONBOARDING_BOT_PASSWORD" \
    ONBOARDING_BOOTSTRAP_WELCOME_ROOM_ALIAS_LOCALPART="$ONBOARDING_BOOTSTRAP_WELCOME_ROOM_ALIAS_LOCALPART" \
    ONBOARDING_BOOTSTRAP_PROVISIONER_SOURCE_URL="$PROVISIONER_SOURCE_URL" \
    ONBOARDING_BOOTSTRAP_ONBOARDING_SOURCE_URL="$ONBOARDING_SOURCE_URL" \
    ONBOARDING_BOOTSTRAP_DEFAULT_AGENT_SOURCE_URL="$DEFAULT_AGENT_SOURCE_URL" \
    ONBOARDING_BOOTSTRAP_SHARED_RESPONSES_BINDABLE_SERVICE_ID="$ONBOARDING_SHARED_RESPONSES_BINDABLE_SERVICE_ID" \
    ONBOARDING_BOOTSTRAP_AUTH_PROXY_SOURCE_URL="$AUTH_PROXY_SOURCE_URL" \
    ONBOARDING_BOOTSTRAP_CODEX_AUTH_JSON_PATH="$ONBOARDING_CODEX_AUTH_JSON_PATH" \
    ONBOARDING_BOOTSTRAP_ONBOARDING_MODEL="$ONBOARDING_ONBOARDING_MODEL" \
    ONBOARDING_BOOTSTRAP_ONBOARDING_MODEL_REASONING_EFFORT="$ONBOARDING_ONBOARDING_MODEL_REASONING_EFFORT" \
    ONBOARDING_BOOTSTRAP_DEFAULT_AGENT_MODEL="$ONBOARDING_DEFAULT_AGENT_MODEL" \
    ONBOARDING_BOOTSTRAP_DEFAULT_AGENT_MODEL_REASONING_EFFORT="$ONBOARDING_DEFAULT_AGENT_MODEL_REASONING_EFFORT" \
    ONBOARDING_BOOTSTRAP_ONBOARDING_DEVELOPER_INSTRUCTIONS_PATH="$(local_abs_path "$ONBOARDING_ONBOARDING_DEVELOPER_INSTRUCTIONS_PATH")" \
    ONBOARDING_BOOTSTRAP_ONBOARDING_AGENTS_MD_PATH="$(local_abs_path "$ONBOARDING_ONBOARDING_AGENTS_MD_PATH")" \
    ONBOARDING_BOOTSTRAP_ONBOARDING_CONFIG_TOML_PATH="$CODEX_CONFIG_PATH" \
    ONBOARDING_BOOTSTRAP_DEFAULT_AGENT_DEVELOPER_INSTRUCTIONS_PATH="$(local_abs_path "$ONBOARDING_DEFAULT_AGENT_DEVELOPER_INSTRUCTIONS_PATH")" \
    ONBOARDING_BOOTSTRAP_DEFAULT_AGENT_AGENTS_MD_PATH="$(local_abs_path "$ONBOARDING_DEFAULT_AGENT_AGENTS_MD_PATH")" \
    ONBOARDING_BOOTSTRAP_DEFAULT_AGENT_CONFIG_TOML_PATH="$CODEX_CONFIG_PATH" \
    go run ./cmd/onboarding-bootstrap
  )
}

manager_api_get() {
  path=$1
  curl -fsS "http://127.0.0.1:$ONBOARDING_MANAGER_TUNNEL_PORT$path"
}

manager_api_delete_scenario() {
  scenario_id=$1
  curl -fsS -X DELETE "http://127.0.0.1:$ONBOARDING_MANAGER_TUNNEL_PORT/v1/scenarios/$scenario_id?destroy_storage=true"
}

wait_for_manager_operation_succeeded() {
  operation_id=$1
  attempts=${2:-300}
  count=0

  while [ "$count" -lt "$attempts" ]; do
    status_json=$(manager_api_get "/v1/operations/$operation_id")
    status=$(printf '%s\n' "$status_json" | jq -r '.status')
    case "$status" in
      succeeded)
        return 0
        ;;
      failed)
        last_error=$(printf '%s\n' "$status_json" | jq -r '.last_error // ""')
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

  scenarios_json=$(manager_api_get /v1/scenarios)
  user_agent_count=$(printf '%s\n' "$scenarios_json" | jq '[.[] | select(.metadata.kind == "user-agent" and .metadata.provisioning_source == "onboarding")] | length')
  if [ "$user_agent_count" -gt 0 ] && [ "$ONBOARDING_DESTROY_INCLUDE_USER_AGENTS" != "true" ]; then
    die "onboarding: found $user_agent_count onboarding-created user-agent scenario(s); set ONBOARDING_DESTROY_INCLUDE_USER_AGENTS=true if you want destroy to remove them too"
  fi

  destroy_plan=$(printf '%s\n' "$scenarios_json" | jq -r --arg include_user_agents "$ONBOARDING_DESTROY_INCLUDE_USER_AGENTS" '
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
  ')

  tab=$(printf '\t')
  printf '%s\n' "$destroy_plan" | while IFS="$tab" read -r scenario_id kind; do
    [ -n "${scenario_id:-}" ] || continue
    log "onboarding: deleting scenario $scenario_id ($kind)"
    delete_json=$(manager_api_delete_scenario "$scenario_id")
    operation_id=$(printf '%s\n' "$delete_json" | jq -r '.operation_id')
    [ -n "$operation_id" ] || die "onboarding: delete scenario $scenario_id did not return an operation_id"
    wait_for_manager_operation_succeeded "$operation_id"
  done

  render_allowlist_json "$tmpdir/allowlist-destroy.json"
  set_remote_manager_allowlist "$host_ip" "$tmpdir/allowlist-destroy.json"
  cleanup_remote_bundle "$host_ip"

  remaining_json=$(manager_api_get /v1/scenarios)
  printf '%s\n' "$remaining_json" | jq -e --arg include_user_agents "$ONBOARDING_DESTROY_INCLUDE_USER_AGENTS" '
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
  ' >/dev/null || die "onboarding: destroy did not remove all targeted onboarding scenarios"

  config_path="$tmpdir/manager-config.destroy.json"
  ssh_exec "$host_ip" "MATRIX_DATA_ROOT='$MATRIX_DATA_ROOT' sh -s" <<'EOF' >"$config_path"
set -eu
cat "$MATRIX_DATA_ROOT/amber-manager/config/manager-config.json"
EOF
  allowlist_json=$(jq -c '.scenario_source_allowlist // []' "$config_path")
  [ "$allowlist_json" = "[]" ] || die "onboarding: manager allowlist is not empty after destroy"

  log "onboarding: destroy completed; Matrix-side bot accounts and rooms were left in place intentionally"
}

verify_remote_control_plane() {
  host_ip=$1
  attempts=${2:-120}
  count=0

  start_manager_tunnel "$host_ip"
  if ! wait_for_local_manager_ready 60; then
    die "onboarding: local manager tunnel did not become ready"
  fi

  while [ "$count" -lt "$attempts" ]; do
    scenarios_json=$(manager_api_get /v1/scenarios)

    if printf '%s\n' "$scenarios_json" | jq -e '
      ([.[] | select(.metadata.kind == "onboarding-provisioner")] | length) == 1
      and ([.[] | select(.metadata.kind == "onboarding-agent")] | length) == 1
      and ([.[] | select(.metadata.kind == "onboarding-provisioner" and .observed_state == "running")] | length) == 1
      and ([.[] | select(.metadata.kind == "onboarding-agent" and .observed_state == "running")] | length) == 1
    ' >/dev/null; then
      if [ -z "$ONBOARDING_SHARED_RESPONSES_BINDABLE_SERVICE_ID" ]; then
        if printf '%s\n' "$scenarios_json" | jq -e '
          ([.[] | select(.metadata.kind == "onboarding-auth-proxy")] | length) == 1
          and ([.[] | select(.metadata.kind == "onboarding-auth-proxy" and .observed_state == "running")] | length) == 1
        ' >/dev/null; then
          break
        fi
      else
        break
      fi
    fi

    count=$((count + 1))
    if [ $((count % 10)) -eq 0 ] || [ "$count" -eq "$attempts" ]; then
      log "onboarding: waiting for onboarding control-plane scenarios to be running ($count/$attempts)"
    fi
    sleep 2
  done

  if [ "$count" -ge "$attempts" ]; then
    die "onboarding: expected one running onboarding-provisioner and one running onboarding-agent scenario"
  fi

  config_path="$tmpdir/manager-config.verify.json"
  ssh_exec "$host_ip" "MATRIX_DATA_ROOT='$MATRIX_DATA_ROOT' sh -s" <<'EOF' >"$config_path"
set -eu
cat "$MATRIX_DATA_ROOT/amber-manager/config/manager-config.json"
EOF
  allowlist_json=$(jq -c '.scenario_source_allowlist // []' "$config_path")

  expected_allowlist=$(printf '%s\n' "$DEFAULT_AGENT_SOURCE_URL" | jq -Rsc 'split("\n") | map(select(length > 0))')
  [ "$allowlist_json" = "$expected_allowlist" ] || die "onboarding: manager allowlist is not in steady state for default-agent provisioning"

  log "onboarding: control plane is healthy on top of $MATRIX_BASE_URL"
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

  run_bootstrap_locally "$tmpdir"

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
