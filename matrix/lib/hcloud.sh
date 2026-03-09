# shellcheck shell=sh

hcloud_require_cli() {
  if ! command -v hcloud >/dev/null 2>&1; then
    die "hcloud CLI not found. Install it and retry."
  fi
}

hcloud_require_auth() {
  if ! hcloud server list -o noheader -o columns=id >/dev/null 2>&1; then
    die "hcloud authentication failed. Configure a context or HCLOUD_TOKEN."
  fi
}

hcloud_server_exists() {
  hcloud server describe "$1" >/dev/null 2>&1
}

hcloud_server_id() {
  hcloud server list -o noheader -o columns=name,id | awk -v target="$1" '
    $1 == target {
      print $2
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  '
}

hcloud_server_ipv4() {
  hcloud server list -o noheader -o columns=name,ipv4 | awk -v target="$1" '
    $1 == target {
      print $2
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  '
}

hcloud_wait_for_ipv4() {
  attempts=0
  max_attempts=60
  while [ "$attempts" -lt "$max_attempts" ]; do
    ipv4=$(hcloud_server_ipv4 "$1" 2>/dev/null || true)
    if [ -n "$ipv4" ] && [ "$ipv4" != "-" ]; then
      printf '%s\n' "$ipv4"
      return 0
    fi

    attempts=$((attempts + 1))
    sleep 2
  done

  die "timed out waiting for IPv4 on server \"$1\""
}

hcloud_ssh_key_exists() {
  hcloud ssh-key describe "$1" >/dev/null 2>&1
}

hcloud_ensure_ssh_key() {
  key_name=$1
  key_path=$2

  if hcloud_ssh_key_exists "$key_name"; then
    return 0
  fi

  hcloud ssh-key create --name "$key_name" --public-key-from-file "$key_path" >/dev/null
}

hcloud_firewall_exists() {
  hcloud firewall describe "$1" >/dev/null 2>&1
}

hcloud_create_firewall() {
  name=$1
  rules_file=$2
  hcloud firewall create --name "$name" --rules-file "$rules_file" >/dev/null
}

hcloud_replace_firewall_rules() {
  name=$1
  rules_file=$2
  hcloud firewall replace-rules --rules-file "$rules_file" "$name" >/dev/null
}

hcloud_ensure_firewall() {
  name=$1
  rules_file=$2

  if hcloud_firewall_exists "$name"; then
    hcloud_replace_firewall_rules "$name" "$rules_file"
    return 0
  fi

  hcloud_create_firewall "$name" "$rules_file"
}

hcloud_attach_firewall_to_server() {
  firewall_name=$1
  server_name=$2

  output=$(hcloud firewall apply-to-resource \
    --type server \
    --server "$server_name" \
    "$firewall_name" \
    2>&1) || {
      case "$output" in
        *firewall_already_applied*)
          return 0
          ;;
      esac
      printf '%s\n' "$output" >&2
      return 1
    }

  return 0
}

hcloud_detach_firewall_from_server() {
  firewall_name=$1
  server_name=$2

  hcloud firewall remove-from-resource \
    --type server \
    --server "$server_name" \
    "$firewall_name" \
    >/dev/null
}

hcloud_delete_firewall() {
  hcloud firewall delete "$1" >/dev/null
}

hcloud_create_server() {
  name=$1
  type=$2
  image=$3
  location=$4

  if [ "$HCLOUD_FIREWALL_ENABLE" = "true" ]; then
    hcloud server create \
      --name "$name" \
      --type "$type" \
      --image "$image" \
      --location "$location" \
      --ssh-key "$HCLOUD_SSH_KEY_NAME" \
      --firewall "$HCLOUD_FIREWALL_NAME" \
      --label "$HCLOUD_LABEL_MANAGED_BY_KEY=$HCLOUD_LABEL_MANAGED_BY_VALUE" \
      --label "$HCLOUD_LABEL_STACK_KEY=$HCLOUD_LABEL_STACK_VALUE" \
      >/dev/null
    return 0
  fi

  hcloud server create \
    --name "$name" \
    --type "$type" \
    --image "$image" \
    --location "$location" \
    --ssh-key "$HCLOUD_SSH_KEY_NAME" \
    --label "$HCLOUD_LABEL_MANAGED_BY_KEY=$HCLOUD_LABEL_MANAGED_BY_VALUE" \
    --label "$HCLOUD_LABEL_STACK_KEY=$HCLOUD_LABEL_STACK_VALUE" \
    >/dev/null
}

hcloud_create_server_across_locations() {
  used_locations=''
  for location in "$4" $5; do
    if [ -z "$location" ]; then
      continue
    fi

    case " $used_locations " in
      *" $location "*) continue ;;
    esac
    used_locations="$used_locations $location"

    if hcloud_create_server "$1" "$2" "$3" "$location"; then
      printf '%s\n' "$location"
      return 0
    fi
  done

  return 1
}

hcloud_delete_server() {
  hcloud server delete "$1" >/dev/null
}

hcloud_wait_until_absent() {
  attempts=0
  max_attempts=60
  while [ "$attempts" -lt "$max_attempts" ]; do
    if ! hcloud_server_exists "$1"; then
      return 0
    fi

    attempts=$((attempts + 1))
    sleep 2
  done

  die "timed out waiting for deletion of server \"$1\""
}
