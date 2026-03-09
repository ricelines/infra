# shellcheck shell=sh

ssh_require_cli() {
  if ! command -v ssh >/dev/null 2>&1; then
    die "ssh not found. Install it and retry."
  fi
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    die "ssh-keygen not found. Install it and retry."
  fi
  if ! command -v tar >/dev/null 2>&1; then
    die "tar not found. Install it and retry."
  fi

  known_hosts_dir=$(dirname "$HCLOUD_SSH_KNOWN_HOSTS_FILE")
  mkdir -p "$known_hosts_dir"
  touch "$HCLOUD_SSH_KNOWN_HOSTS_FILE"
  chmod 600 "$HCLOUD_SSH_KNOWN_HOSTS_FILE"
}

ssh_target() {
  printf '%s@%s' "$HCLOUD_SSH_USER" "$1"
}

ssh_exec() {
  host=$1
  shift
  ssh \
    -i "$HCLOUD_SSH_PRIVATE_KEY_PATH" \
    -p "$HCLOUD_SSH_PORT" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout="$HCLOUD_SSH_CONNECT_TIMEOUT_SECONDS" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$HCLOUD_SSH_KNOWN_HOSTS_FILE" \
    "$(ssh_target "$host")" \
    "$@"
}

ssh_forget_host_key() {
  host=$1
  ssh-keygen -R "$host" -f "$HCLOUD_SSH_KNOWN_HOSTS_FILE" >/dev/null 2>&1 || true
  ssh-keygen -R "[$host]:$HCLOUD_SSH_PORT" -f "$HCLOUD_SSH_KNOWN_HOSTS_FILE" >/dev/null 2>&1 || true
}

ssh_error_is_stale_host_key() {
  err=$1
  case "$err" in
    *"REMOTE HOST IDENTIFICATION HAS CHANGED"*|*"Host key verification failed"*|*"POSSIBLE DNS SPOOFING DETECTED"*|*"Offending "*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ssh_error_is_fatal() {
  err=$1
  case "$err" in
    *"Permission denied"*)
      return 0
      ;;
    *"Too many authentication failures"*)
      return 0
      ;;
    *"No supported authentication methods available"*)
      return 0
      ;;
    *"Could not resolve hostname"*)
      return 0
      ;;
    *"Name or service not known"*)
      return 0
      ;;
    *"Temporary failure in name resolution"*)
      return 0
      ;;
    *"Bad owner or permissions on "*)
      return 0
      ;;
    *"Load key "*)
      return 0
      ;;
    *"invalid format"*)
      return 0
      ;;
    *"No such file or directory"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

ssh_wait_for_ready() {
  host=$1
  attempts=$((HCLOUD_SSH_READY_TIMEOUT_SECONDS / 5))
  if [ "$attempts" -lt 1 ]; then
    attempts=1
  fi

  last_err_summary=""
  last_err_raw=""
  last_err=""
  count=0
  while [ "$count" -lt "$attempts" ]; do
    err_file=$(mktemp)
    if ssh_exec "$host" "true" >/dev/null 2>"$err_file"; then
      rm -f "$err_file"
      return 0
    fi

    last_err_raw=$(cat "$err_file")
    last_err_summary=$(printf '%s\n' "$last_err_raw" | awk 'NF { print; exit }')
    if [ -z "$last_err_summary" ]; then
      last_err_summary="unknown ssh error"
    fi
    log "ssh: probe $((count + 1))/$attempts for $host failed: $last_err_summary"

    if ssh_error_is_stale_host_key "$last_err_raw"; then
      log "ssh: host key mismatch detected for $host; removing stale known_hosts entry"
      ssh_forget_host_key "$host"
      rm -f "$err_file"
      count=$((count + 1))
      sleep 2
      continue
    fi

    last_err=$(printf '%s' "$last_err_raw" | tr '\n' ' ' | tr -s ' ' | sed -e 's/^ //' -e 's/ $//')
    if [ -z "$last_err" ]; then
      last_err="unknown ssh error"
    fi

    if ssh_error_is_fatal "$last_err"; then
      rm -f "$err_file"
      hint=""
      case "$last_err" in
        *"Permission denied"*|*"Too many authentication failures"*|*"No supported authentication methods available"*)
          hint=" (check HCLOUD_SSH_PRIVATE_KEY_PATH, HCLOUD_SSH_PUBLIC_KEY_PATH, and HCLOUD_SSH_USER)"
          ;;
        *"Could not resolve hostname"*|*"Name or service not known"*|*"Temporary failure in name resolution"*)
          hint=" (check server address and local DNS/network)"
          ;;
        *"Bad owner or permissions on "*|*"Load key "*|*"invalid format"*|*"No such file or directory"*)
          hint=" (check the SSH private key file path/format/permissions)"
          ;;
      esac
      die "failed to establish SSH to $host: $last_err_summary$hint
ssh stderr:
$last_err_raw"
    fi

    rm -f "$err_file"

    count=$((count + 1))
    sleep 5
  done

  die "timed out waiting for SSH on $host after ${HCLOUD_SSH_READY_TIMEOUT_SECONDS}s (last error: $last_err_summary)
last ssh stderr:
$last_err_raw"
}

ssh_push_dir() {
  host=$1
  local_dir=$2
  remote_dir=$3

  tar -C "$local_dir" -cf - . | ssh_exec "$host" "rm -rf '$remote_dir' && mkdir -p '$remote_dir' && tar -C '$remote_dir' -xf -"
}
