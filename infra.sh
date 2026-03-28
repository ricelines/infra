#!/bin/sh
set -eu

SCRIPT_DIR=$(
  CDPATH='' cd -- "$(dirname -- "$0")" && pwd
)

. "$SCRIPT_DIR/matrix/lib/log.sh"
# shellcheck source=infra/matrix/lib/config.sh
. "$SCRIPT_DIR/matrix/lib/config.sh"
# shellcheck source=infra/matrix/lib/hcloud.sh
. "$SCRIPT_DIR/matrix/lib/hcloud.sh"
# shellcheck source=infra/matrix/lib/ssh.sh
. "$SCRIPT_DIR/matrix/lib/ssh.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  logs amber [--tail N] [--follow] [--all] [--no-summary] [--env FILE] [--host IP]

Collect manager-related logs:
  logs amber
    Collect logs from docker containers currently managed by amber-manager.
    Defaults to host resolution from Hetzner metadata unless --host is given.
    --tail N     Number of lines per container (default: 200)
    --follow     Follow logs (similar to docker logs -f)
    --all        Include non-running containers
    --no-summary Skip amber-manager API summaries before container logs
    --env FILE   Load matrix environment overrides for host/key discovery
    --host IP    Skip Hetzner lookup and connect directly to IP
EOF
}

log_line() {
  printf '\n%s\n' "===== $* ====="
}

load_matrix_env() {
  env_file=$1

  if [ ! -f "$env_file" ]; then
    die "logs: matrix env file does not exist: $env_file"
  fi

  set -a
  # shellcheck source=/dev/null
  . "$env_file"
  set +a
}

resolve_server_ip() {
  if [ -n "${OVERRIDE_HOST_IP:-}" ]; then
    printf '%s\n' "$OVERRIDE_HOST_IP"
    return 0
  fi

  hcloud_require_cli
  hcloud_require_auth
  host_ip=$(hcloud_server_ipv4 "$HCLOUD_SERVER_NAME")
  [ -n "${host_ip:-}" ] || die "logs: could not resolve IPv4 for server \"$HCLOUD_SERVER_NAME\""
  printf '%s\n' "$host_ip"
}

collect_amber_manager_container_logs() {
  host_ip=$1
  tail_count=$2
  follow_flag=$3
  all_filter=$4

  AMBER_LOG_TAIL=$tail_count
  AMBER_LOG_FOLLOW=$follow_flag
  AMBER_LOG_INCLUDE_ALL=$all_filter
  MATRIX_DATA_ROOT=${MATRIX_DATA_ROOT:-/srv/matrix}

  ssh_exec "$host_ip" \
    "AMBER_LOG_TAIL='$AMBER_LOG_TAIL' AMBER_LOG_FOLLOW='$AMBER_LOG_FOLLOW' AMBER_LOG_INCLUDE_ALL='$AMBER_LOG_INCLUDE_ALL' MATRIX_DATA_ROOT='$MATRIX_DATA_ROOT' AMBER_MANAGER_IMAGE='${AMBER_MANAGER_IMAGE:-}' sh -s" <<'EOF'
set -eu

follow_flag=
[ "$AMBER_LOG_FOLLOW" = "1" ] && follow_flag="-f"

ps_filter=""
if [ "$AMBER_LOG_INCLUDE_ALL" = "1" ]; then
  ps_filter="-a"
fi

docker_ps() {
  if [ "$AMBER_LOG_INCLUDE_ALL" = "1" ]; then
    docker ps -a "$@"
    return
  fi
  docker ps "$@"
}

append_container_ids() {
  docker_ps "$@" --format '{{.ID}}' >>"$container_ids" || true
}

container_ids=$(mktemp)
append_container_ids --filter "name=amber-manager"
append_container_ids --filter "name=amber-"
append_container_ids --filter "name=amber_"
append_container_ids --filter "name=amber-init"
append_container_ids --filter "name=amber-provisioner"
if [ -n "$AMBER_MANAGER_IMAGE" ]; then
  append_container_ids --filter "ancestor=$AMBER_MANAGER_IMAGE"
fi
docker_ps --format '{{.ID}} {{.Names}}' | awk '/amber/ {print $1}' >>"$container_ids" || true

sort -u "$container_ids" >"${container_ids}.uniq"
mv "${container_ids}.uniq" "$container_ids"

if ! [ -s "$container_ids" ]; then
  printf 'No docker containers matched amber-manager container heuristics on this host.\n'
fi

while IFS= read -r container_id; do
  [ -z "$container_id" ] && continue
  container_name=$(docker inspect --format '{{.Name}}' "$container_id" 2>/dev/null | sed 's#^/##' || true)
  if [ -z "$container_name" ]; then
    printf '\n===== container=<disappeared> id=%s =====\n' "$container_id"
    printf 'Container disappeared before logs could be collected.\n'
    continue
  fi
  log_line="$(printf 'container=%s id=%s' "$container_name" "$container_id")"
  printf '\n%s\n' "===== $log_line ====="
  if [ -n "$follow_flag" ]; then
    if ! docker logs --timestamps --tail="$AMBER_LOG_TAIL" "$follow_flag" "$container_id"; then
      if docker inspect "$container_id" >/dev/null 2>&1; then
        printf 'Failed to collect logs for container=%s id=%s.\n' "$container_name" "$container_id" >&2
      else
        printf 'Container disappeared while logs were being collected.\n'
      fi
    fi
  else
    if ! docker logs --timestamps --tail="$AMBER_LOG_TAIL" "$container_id"; then
      if docker inspect "$container_id" >/dev/null 2>&1; then
        printf 'Failed to collect logs for container=%s id=%s.\n' "$container_name" "$container_id" >&2
      else
        printf 'Container disappeared while logs were being collected.\n'
      fi
    fi
  fi
done <"$container_ids"

  if [ ! -s "$container_ids" ] && [ -f "$MATRIX_DATA_ROOT/docker-compose.yml" ]; then
  printf '\nNo amber-specific containers found from name/image heuristics.\n'
  printf 'Falling back to compose service log for amber-manager only.\n'
  cd "$MATRIX_DATA_ROOT"
  if [ -n "$follow_flag" ]; then
    docker compose --env-file '.env' -f 'docker-compose.yml' logs --timestamps --tail="$AMBER_LOG_TAIL" "$follow_flag" amber-manager
  else
    docker compose --env-file '.env' -f 'docker-compose.yml' logs --timestamps --tail="$AMBER_LOG_TAIL" amber-manager
  fi
fi

rm -f "$container_ids"
EOF
}

print_amber_manager_summary() {
  host_ip=$1

  if ! command -v jq >/dev/null 2>&1; then
    return 0
  fi

  summary_tmpdir=$(mktemp -d)
  readyz_path=$summary_tmpdir/readyz.json
  scenarios_path=$summary_tmpdir/scenarios.json
  services_path=$summary_tmpdir/bindable-services.json

  if ssh_exec "$host_ip" "curl -fsS http://127.0.0.1:4100/readyz" >"$readyz_path" 2>/dev/null; then
    log_line "amber-manager readyz"
    if ! jq -r '
      if type == "object" then
        to_entries | sort_by(.key) | map("\(.key)=\(.value | tostring)") | join(" ")
      else
        "Unexpected readyz payload"
      end
    ' "$readyz_path"; then
      cat "$readyz_path"
    fi
  fi

  if ssh_exec "$host_ip" "curl -fsS http://127.0.0.1:4100/v1/scenarios" >"$scenarios_path" 2>/dev/null; then
    log_line "amber-manager scenarios"
    if ! jq -r '
      if type != "array" then
        "Unexpected scenarios payload"
      elif length == 0 then
        "No scenarios."
      else
        sort_by([(.observed_state != "failed"), (.metadata.kind // ""), (.scenario_id // "")])
        | .[]
        | [
            (.scenario_id // ""),
            ("state=" + (.observed_state // "")),
            ("kind=" + (.metadata.kind // "-")),
            if (.metadata.provisioning_source // "") != "" then
              "provisioning_source=" + .metadata.provisioning_source
            else
              empty
            end,
            if (.last_error // "") != "" then
              "last_error=" + .last_error
            else
              empty
            end
          ]
        | join(" ")
      end
    ' "$scenarios_path"; then
      cat "$scenarios_path"
    fi
  fi

  if ssh_exec "$host_ip" "curl -fsS http://127.0.0.1:4100/v1/bindable-services" >"$services_path" 2>/dev/null; then
    log_line "amber-manager bindable-services"
    if ! jq -r '
      if type != "array" then
        "Unexpected bindable-services payload"
      elif length == 0 then
        "No bindable services."
      else
        sort_by([(.available == true), (.display_name // ""), (.bindable_service_id // "")])
        | .[]
        | [
            (.bindable_service_id // ""),
            ("name=" + (.display_name // "-")),
            ("available=" + ((.available // false) | tostring)),
            if (.scenario_id // "") != "" then
              "scenario_id=" + .scenario_id
            else
              empty
            end
          ]
        | join(" ")
      end
    ' "$services_path"; then
      cat "$services_path"
    fi
  fi

  rm -rf "$summary_tmpdir"
}

run_logs_amber() {
  tail_count=200
  follow=0
  include_all=0
  show_summary=1

  while [ $# -gt 0 ]; do
    case "$1" in
      --env)
        load_matrix_env "$2"
        shift 2
        ;;
      --host)
        OVERRIDE_HOST_IP=$2
        shift 2
        ;;
      --tail)
        tail_count=$2
        if [ -z "$tail_count" ] || ! printf '%s\n' "$tail_count" | grep -Eq '^[0-9]+$'; then
          die "logs: --tail requires a non-negative integer"
        fi
        shift 2
        ;;
      --follow|-f)
        follow=1
        shift
        ;;
      --all)
        include_all=1
        shift
        ;;
      --no-summary)
        show_summary=0
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "logs: unknown option: $1"
        ;;
    esac
  done

  host_ip=$(resolve_server_ip)
  derive_ssh_config
  require_file "$HCLOUD_SSH_PRIVATE_KEY_PATH"
  ssh_require_cli

  ssh_wait_for_ready "$host_ip"
  if [ "$show_summary" = "1" ]; then
    print_amber_manager_summary "$host_ip"
  fi
  collect_amber_manager_container_logs "$host_ip" "$tail_count" "$follow" "$include_all"
}

main() {
  if [ $# -lt 2 ]; then
    usage >&2
    exit 1
  fi

  command=$1
  shift

  case "$command" in
    logs)
      what=$1
      shift
      case "$what" in
        amber)
          run_logs_amber "$@"
          ;;
        *)
          die "logs: unsupported target \"$what\" (supported: amber)"
          ;;
      esac
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
