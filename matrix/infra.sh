#!/bin/sh
set -eu

SCRIPT_DIR=$(
  CDPATH='' cd -- "$(dirname -- "$0")" && pwd
)

ENV_FILE=${MATRIX_ENV_FILE:-$SCRIPT_DIR/.env}
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
fi

# shellcheck source=infra/matrix/lib/log.sh
. "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=infra/matrix/lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=infra/matrix/lib/hcloud.sh
. "$SCRIPT_DIR/lib/hcloud.sh"
# shellcheck source=infra/matrix/lib/cloudflare.sh
. "$SCRIPT_DIR/lib/cloudflare.sh"
# shellcheck source=infra/matrix/lib/ssh.sh
. "$SCRIPT_DIR/lib/ssh.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  apply    Ensure Matrix infrastructure + deployment are up to date (idempotent)
  verify   Validate deployed Matrix behavior (health + optional registration probe)
  destroy  Ensure Matrix infrastructure is deleted (idempotent)

Config file:
  MATRIX_ENV_FILE            default: $SCRIPT_DIR/.env

Core environment:
  HCLOUD_SERVER_NAME           default: $HCLOUD_SERVER_NAME
  HCLOUD_SERVER_TYPE           default: $HCLOUD_SERVER_TYPE
  HCLOUD_SERVER_IMAGE          default: $HCLOUD_SERVER_IMAGE
  HCLOUD_SERVER_LOCATION       default: $HCLOUD_SERVER_LOCATION
  HCLOUD_SERVER_LOCATION_FALLBACKS  default: $HCLOUD_SERVER_LOCATION_FALLBACKS

  SSH keypair                  defaults to ~/.ssh/id_ed25519(.pub)
  HCLOUD_SSH_ALLOWED_NETS      default: $HCLOUD_SSH_ALLOWED_NETS

  MATRIX_BASE_URL              required
  MATRIX_SERVER_NAME           required
  MATRIX_LETSENCRYPT_EMAIL     derived as letsencrypt@MATRIX_SERVER_NAME
  MATRIX_REGISTRATION_TOKEN    required unless open registration is enabled

  CLOUDFLARE_API_TOKEN         required (DNS management + Traefik DNS-01)
  CLOUDFLARE_ZONE_NAME         defaults to MATRIX_SERVER_NAME

Optional security + behavior:
  HCLOUD_FIREWALL_ENABLE       default: $HCLOUD_FIREWALL_ENABLE
  HCLOUD_HTTP_ALLOW_CLOUDFLARE_ONLY default: $HCLOUD_HTTP_ALLOW_CLOUDFLARE_ONLY
  CLOUDFLARE_MANAGE_DNS        default: $CLOUDFLARE_MANAGE_DNS

Advanced overrides:
  CLOUDFLARE_ZONE_NAME         override only for unusual delegated-zone setups
  HCLOUD_SSH_KEY_NAME          default: $HCLOUD_SSH_KEY_NAME
  HCLOUD_SSH_PUBLIC_KEY_PATH   default: $HCLOUD_SSH_PUBLIC_KEY_PATH
  HCLOUD_SSH_PRIVATE_KEY_PATH  default: derived from public key path
  HCLOUD_SSH_KNOWN_HOSTS_FILE  default: $HCLOUD_SSH_KNOWN_HOSTS_FILE
EOF
}

cleanup_tmpdir() {
  if [ -n "${tmpdir:-}" ] && [ -d "$tmpdir" ]; then
    rm -rf "$tmpdir"
  fi
}

handle_interrupt() {
  trap - INT TERM EXIT
  cleanup_tmpdir
  exit 130
}

render_firewall_rules() {
  output_path=$1

  # shellcheck disable=SC2086
  ssh_sources=$(printf '%s\n' $HCLOUD_SSH_ALLOWED_NETS | jq -Rsc 'split("\n") | map(select(length > 0))')
  if [ "$HCLOUD_HTTP_ALLOW_CLOUDFLARE_ONLY" = "true" ]; then
    http_sources=$(cloudflare_public_edge_cidrs | jq -Rsc 'split("\n") | map(select(length > 0))')
  else
    http_sources=$(printf '%s\n' "0.0.0.0/0" "::/0" | jq -Rsc 'split("\n") | map(select(length > 0))')
  fi

  jq -n \
    --argjson ssh_sources "$ssh_sources" \
    --argjson http_sources "$http_sources" \
    '[
      {
        direction: "in",
        protocol: "tcp",
        port: "22",
        source_ips: $ssh_sources
      },
      {
        direction: "in",
        protocol: "tcp",
        port: "80",
        source_ips: $http_sources
      },
      {
        direction: "in",
        protocol: "tcp",
        port: "443",
        source_ips: $http_sources
      }
    ]' >"$output_path"
}

ensure_firewall_if_enabled() {
  rules_path=$1
  if [ "$HCLOUD_FIREWALL_ENABLE" != "true" ]; then
    return 0
  fi

  render_firewall_rules "$rules_path"
  hcloud_ensure_firewall "$HCLOUD_FIREWALL_NAME" "$rules_path"
  log "apply: firewall \"$HCLOUD_FIREWALL_NAME\" reconciled"
}

ensure_server_exists() {
  if hcloud_server_exists "$HCLOUD_SERVER_NAME"; then
    ipv4=$(hcloud_server_ipv4 "$HCLOUD_SERVER_NAME")
    log "apply: server \"$HCLOUD_SERVER_NAME\" already exists with public IPv4 $ipv4"
    return 0
  fi

  log "apply: creating server \"$HCLOUD_SERVER_NAME\" (type=$HCLOUD_SERVER_TYPE, primary_location=$HCLOUD_SERVER_LOCATION, image=$HCLOUD_SERVER_IMAGE)"
  created_location=$(hcloud_create_server_across_locations \
    "$HCLOUD_SERVER_NAME" \
    "$HCLOUD_SERVER_TYPE" \
    "$HCLOUD_SERVER_IMAGE" \
    "$HCLOUD_SERVER_LOCATION" \
    "$HCLOUD_SERVER_LOCATION_FALLBACKS") || {
      if hcloud_server_exists "$HCLOUD_SERVER_NAME"; then
        log "apply: create call raced with existing server; continuing"
      else
        die "apply: failed to create server \"$HCLOUD_SERVER_NAME\""
      fi
    }

  if [ -n "${created_location:-}" ]; then
    log "apply: server \"$HCLOUD_SERVER_NAME\" created in location $created_location"
  fi
}

ensure_cloudflare_dns_if_enabled() {
  ipv4=$1

  if [ "$CLOUDFLARE_MANAGE_DNS" != "true" ]; then
    return 0
  fi

  zone_id=$(cloudflare_resolve_zone_id)
  cloudflare_ensure_a_record "$zone_id" "$MATRIX_BASE_HOST_NO_DOT" "$ipv4"
}

render_tuwunel_config() {
  output_path=$1
  template_path=$SCRIPT_DIR/tuwunel.toml.template

  require_file "$template_path"

  awk \
    -v matrix_server_name="$MATRIX_SERVER_NAME" \
    -v matrix_allow_registration="$MATRIX_ALLOW_REGISTRATION" \
    -v matrix_allow_open_registration="$MATRIX_ALLOW_OPEN_REGISTRATION" \
    -v has_emergency_password="$([ -n "$MATRIX_EMERGENCY_PASSWORD" ] && printf 'true' || printf 'false')" \
    -v matrix_base_url="$MATRIX_BASE_URL" \
    -v matrix_base_host_no_dot="$MATRIX_BASE_HOST_NO_DOT" \
    '
      {
        if ($0 == "@REGISTRATION_CONFIG@") {
          if (matrix_allow_registration == "true") {
            print "allow_registration = true"
            if (matrix_allow_open_registration == "true") {
              print "yes_i_am_very_very_sure_i_want_an_open_registration_server_prone_to_abuse = true"
            } else {
              print "registration_token_file = \"/run/secrets/registration_token\""
            }
          } else {
            print "allow_registration = false"
          }
          next
        }

        if ($0 == "@EMERGENCY_PASSWORD_CONFIG@") {
          if (has_emergency_password == "true") {
            print "emergency_password_file = \"/run/secrets/emergency_password\""
          }
          next
        }

        gsub(/@MATRIX_SERVER_NAME@/, matrix_server_name)
        gsub(/@MATRIX_BASE_URL@/, matrix_base_url)
        gsub(/@MATRIX_BASE_HOST_NO_DOT@/, matrix_base_host_no_dot)
        print
      }
    ' \
    "$template_path" >"$output_path"
}

render_deployment_identity_file() {
  output_path=$1
  cat >"$output_path" <<EOF
MATRIX_SERVER_NAME=$MATRIX_SERVER_NAME
MATRIX_BASE_HOST=$MATRIX_BASE_HOST_NO_DOT
EOF
}

needs_registration_secret() {
  [ "$MATRIX_ALLOW_REGISTRATION" = "true" ] && [ "$MATRIX_ALLOW_OPEN_REGISTRATION" != "true" ]
}

needs_emergency_secret() {
  [ -n "$MATRIX_EMERGENCY_PASSWORD" ]
}

render_compose_file() {
  output_path=$1

  {
    cat <<EOF
services:
  traefik:
    image: $TRAEFIK_IMAGE
    container_name: traefik
    restart: unless-stopped
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --certificatesresolvers.le.acme.email=\${MATRIX_LETSENCRYPT_EMAIL}
      - --certificatesresolvers.le.acme.storage=/acme/acme.json
      - --certificatesresolvers.le.acme.dnschallenge=true
      - --certificatesresolvers.le.acme.dnschallenge.provider=cloudflare
      - --log.level=INFO
    environment:
      - CF_DNS_API_TOKEN=\${CLOUDFLARE_API_TOKEN}
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./traefik/acme:/acme
      - /var/run/docker.sock:/var/run/docker.sock:ro

  tuwunel:
    image: $TUWUNEL_IMAGE
    container_name: tuwunel
    restart: unless-stopped
    environment:
      - TUWUNEL_CONFIG=/etc/tuwunel/tuwunel.toml
    volumes:
      - ./tuwunel/config:/etc/tuwunel:ro
      - ./tuwunel/data:/data
EOF

    if needs_registration_secret || needs_emergency_secret; then
      printf '%s\n' "    secrets:"
      if needs_registration_secret; then
        printf '%s\n' "      - registration_token"
      fi
      if needs_emergency_secret; then
        printf '%s\n' "      - emergency_password"
      fi
    fi

    cat <<EOF
    labels:
      - traefik.enable=true
      - traefik.http.routers.matrix.rule=Host(\`$MATRIX_BASE_HOST_NO_DOT\`)
      - traefik.http.routers.matrix.entrypoints=websecure
      - traefik.http.routers.matrix.tls=true
      - traefik.http.routers.matrix.tls.certresolver=le
      - traefik.http.services.matrix.loadbalancer.server.port=8008
EOF

    if needs_registration_secret || needs_emergency_secret; then
      printf '\n%s\n' "secrets:"
      if needs_registration_secret; then
        printf '%s\n' "  registration_token:"
        printf '%s\n' "    file: ./secrets/registration_token"
      fi
      if needs_emergency_secret; then
        printf '%s\n' "  emergency_password:"
        printf '%s\n' "    file: ./secrets/emergency_password"
      fi
    fi
  } >"$output_path"
}

render_env_file() {
  output_path=$1
  cat >"$output_path" <<EOF
MATRIX_LETSENCRYPT_EMAIL=$MATRIX_LETSENCRYPT_EMAIL
CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN
EOF
}

render_bundle() {
  bundle_dir=$1

  render_compose_file "$bundle_dir/docker-compose.yml"
  render_tuwunel_config "$bundle_dir/tuwunel.toml"
  render_deployment_identity_file "$bundle_dir/deployment-identity.env"
  render_env_file "$bundle_dir/.env"

  if needs_registration_secret; then
    printf '%s\n' "$MATRIX_REGISTRATION_TOKEN" >"$bundle_dir/registration_token"
  fi
  if needs_emergency_secret; then
    printf '%s\n' "$MATRIX_EMERGENCY_PASSWORD" >"$bundle_dir/emergency_password"
  fi
}

ensure_remote_identity_compatible() {
  host_ip=$1

  ssh_exec "$host_ip" \
    "MATRIX_DATA_ROOT='$MATRIX_DATA_ROOT' TARGET_SERVER_NAME='$MATRIX_SERVER_NAME' TARGET_BASE_HOST='$MATRIX_BASE_HOST_NO_DOT' sh -s" <<'EOF'
set -eu

identity_file="$MATRIX_DATA_ROOT/deployment-identity.env"
config_file="$MATRIX_DATA_ROOT/tuwunel/config/tuwunel.toml"
compose_file="$MATRIX_DATA_ROOT/docker-compose.yml"
data_dir="$MATRIX_DATA_ROOT/tuwunel/data"

existing_server_name=""
existing_base_host=""
data_has_content=false

if [ -f "$identity_file" ]; then
  existing_server_name=$(sed -n 's/^MATRIX_SERVER_NAME=//p' "$identity_file" | sed -n '1p')
  existing_base_host=$(sed -n 's/^MATRIX_BASE_HOST=//p' "$identity_file" | sed -n '1p')
fi

if [ -z "$existing_server_name" ] && [ -f "$config_file" ]; then
  existing_server_name=$(sed -n 's/^server_name = "\(.*\)"$/\1/p' "$config_file" | sed -n '1p')
fi

if [ -z "$existing_base_host" ] && [ -f "$compose_file" ]; then
  existing_base_host=$(sed -n 's/.*traefik\.http\.routers\.matrix\.rule=Host(`\([^`]*\)`).*/\1/p' "$compose_file" | sed -n '1p')
fi

if [ -d "$data_dir" ] && find "$data_dir" -mindepth 1 -print -quit | grep -q .; then
  data_has_content=true
fi

if [ -n "$existing_server_name" ] && [ "$existing_server_name" != "$TARGET_SERVER_NAME" ]; then
  echo "existing Matrix deployment uses server_name=$existing_server_name but apply requested server_name=$TARGET_SERVER_NAME" >&2
  echo "destroy the server or clear $MATRIX_DATA_ROOT before changing MATRIX_SERVER_NAME" >&2
  exit 1
fi

if [ -n "$existing_base_host" ] && [ "$existing_base_host" != "$TARGET_BASE_HOST" ]; then
  echo "existing Matrix deployment uses base host=$existing_base_host but apply requested base host=$TARGET_BASE_HOST" >&2
  echo "destroy the server or clear $MATRIX_DATA_ROOT before changing MATRIX_BASE_URL" >&2
  exit 1
fi

if [ "$data_has_content" = true ] && [ -z "$existing_server_name" ] && [ -z "$existing_base_host" ]; then
  echo "existing Matrix data found in $data_dir, but deployment identity could not be determined" >&2
  echo "destroy the server or clear $MATRIX_DATA_ROOT before changing domains on a reused host" >&2
  exit 1
fi
EOF
}

ensure_remote_base_system() {
  host_ip=$1

  ssh_exec "$host_ip" "MATRIX_DATA_ROOT='$MATRIX_DATA_ROOT' sh -s" <<'EOF'
set -eu
export DEBIAN_FRONTEND=noninteractive

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  apt-get update
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.asc ]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi

  codename=$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")
  arch=$(dpkg --print-architecture)
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian %s stable\n' "$arch" "$codename" > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

systemctl enable --now docker

install -d -m 750 "$MATRIX_DATA_ROOT"
install -d -m 755 "$MATRIX_DATA_ROOT/traefik/acme"
install -d -m 755 "$MATRIX_DATA_ROOT/tuwunel/config"
install -d -m 755 "$MATRIX_DATA_ROOT/tuwunel/data"
install -d -m 700 "$MATRIX_DATA_ROOT/secrets"
install -d -m 755 "$MATRIX_DATA_ROOT/backups"
touch "$MATRIX_DATA_ROOT/traefik/acme/acme.json"
chmod 600 "$MATRIX_DATA_ROOT/traefik/acme/acme.json"
EOF
}

deploy_bundle() {
  host_ip=$1
  bundle_dir=$2
  stage_dir="/tmp/nq-matrix-deploy-$HCLOUD_SERVER_NAME"

  ssh_push_dir "$host_ip" "$bundle_dir" "$stage_dir"

  ssh_exec "$host_ip" "MATRIX_DATA_ROOT='$MATRIX_DATA_ROOT' STAGE_DIR='$stage_dir' sh -s" <<'EOF'
set -eu

install -m 644 "$STAGE_DIR/docker-compose.yml" "$MATRIX_DATA_ROOT/docker-compose.yml"
install -m 644 "$STAGE_DIR/tuwunel.toml" "$MATRIX_DATA_ROOT/tuwunel/config/tuwunel.toml"
install -m 644 "$STAGE_DIR/deployment-identity.env" "$MATRIX_DATA_ROOT/deployment-identity.env"
install -m 600 "$STAGE_DIR/.env" "$MATRIX_DATA_ROOT/.env"

if [ -f "$STAGE_DIR/registration_token" ]; then
  install -m 600 "$STAGE_DIR/registration_token" "$MATRIX_DATA_ROOT/secrets/registration_token"
else
  rm -f "$MATRIX_DATA_ROOT/secrets/registration_token"
fi

if [ -f "$STAGE_DIR/emergency_password" ]; then
  install -m 600 "$STAGE_DIR/emergency_password" "$MATRIX_DATA_ROOT/secrets/emergency_password"
else
  rm -f "$MATRIX_DATA_ROOT/secrets/emergency_password"
fi

docker compose --env-file "$MATRIX_DATA_ROOT/.env" -f "$MATRIX_DATA_ROOT/docker-compose.yml" pull
docker compose --env-file "$MATRIX_DATA_ROOT/.env" -f "$MATRIX_DATA_ROOT/docker-compose.yml" up -d --remove-orphans
# Always recreate tuwunel so bind-mounted config and secret changes take effect.
docker compose --env-file "$MATRIX_DATA_ROOT/.env" -f "$MATRIX_DATA_ROOT/docker-compose.yml" up -d --force-recreate --no-deps tuwunel

rm -rf "$STAGE_DIR"
EOF
}

check_public_matrix_versions() {
  host_ip=$1
  versions_url="$MATRIX_BASE_URL/_matrix/client/versions"

  if ! response=$(ssh_exec "$host_ip" "curl -fsS '$versions_url'"); then
    log "verify: failed to fetch public versions endpoint at $versions_url"
    return 1
  fi

  if ! printf '%s\n' "$response" | jq -e '.versions | type == "array"' >/dev/null 2>&1; then
    log "verify: versions endpoint response did not contain a JSON array at .versions"
    return 1
  fi

  log "verify: public versions endpoint is healthy at $versions_url"
}

check_origin_matrix_versions() {
  host_ip=$1

  if ! ssh_exec "$host_ip" "curl -fsS --resolve '$MATRIX_BASE_HOST_NO_DOT:443:127.0.0.1' 'https://$MATRIX_BASE_HOST_NO_DOT/_matrix/client/versions' >/dev/null"; then
    log "verify: origin check failed for traefik listener on 443"
    return 1
  fi

  log "verify: origin check passed via traefik listener on 443"
}

check_remote_stack_state() {
  host_ip=$1
  if ! stack_json=$(ssh_exec "$host_ip" "docker compose -f '$MATRIX_DATA_ROOT/docker-compose.yml' --env-file '$MATRIX_DATA_ROOT/.env' ps --format json"); then
    log "verify: failed to query docker compose stack state"
    return 1
  fi

  if ! printf '%s\n' "$stack_json" | jq -s -e '
    map({service: .Service, state: .State}) as $rows
    | ($rows | any(.service == "traefik" and .state == "running"))
      and ($rows | any(.service == "tuwunel" and .state == "running"))
  ' >/dev/null 2>&1; then
    log "verify: stack state check failed; traefik/tuwunel are not both running"
    return 1
  fi

  if ! traefik_logs=$(ssh_exec "$host_ip" "docker compose -f '$MATRIX_DATA_ROOT/docker-compose.yml' --env-file '$MATRIX_DATA_ROOT/.env' logs --tail=120 traefik"); then
    log "verify: failed to retrieve traefik logs"
    return 1
  fi

  if printf '%s\n' "$traefik_logs" | grep -Eq 'client version .* too old|providerName=.*docker.*ERR|Failed to retrieve information of the docker client and server host'; then
    log "verify: traefik logs show docker-provider errors"
    return 1
  fi

  log "verify: remote stack state is healthy"
}

collect_remote_diagnostics() {
  host_ip=$1

  log "verify: collecting remote diagnostics from $host_ip"
  ssh_exec "$host_ip" "
    set -e
    docker compose -f '$MATRIX_DATA_ROOT/docker-compose.yml' --env-file '$MATRIX_DATA_ROOT/.env' ps
    echo '--- traefik logs ---'
    docker compose -f '$MATRIX_DATA_ROOT/docker-compose.yml' --env-file '$MATRIX_DATA_ROOT/.env' logs --tail=200 traefik
    echo '--- tuwunel logs ---'
    docker compose -f '$MATRIX_DATA_ROOT/docker-compose.yml' --env-file '$MATRIX_DATA_ROOT/.env' logs --tail=200 tuwunel
  " || true
}

http_post_json() {
  url=$1
  payload=$2
  out_file=$3
  status_file=$4

  if [ -n "${MATRIX_VERIFY_REMOTE_HOST_IP:-}" ]; then
    payload_b64=$(printf '%s' "$payload" | base64 | tr -d '\n')
    if ! response=$(ssh_exec "$MATRIX_VERIFY_REMOTE_HOST_IP" \
      "URL='$url' HOST='$MATRIX_BASE_HOST_NO_DOT' PAYLOAD_B64='$payload_b64' sh -s" <<'EOF'
set -eu
tmp=$(mktemp)
payload=$(printf '%s' "$PAYLOAD_B64" | base64 -d)
status=$(curl -sS --resolve "$HOST:443:127.0.0.1" -o "$tmp" -w "%{http_code}" -X POST "$URL" -H "Content-Type: application/json" --data "$payload")
printf '__STATUS__%s\n' "$status"
cat "$tmp"
rm -f "$tmp"
EOF
    ); then
      printf '000\n' >"$status_file"
      : >"$out_file"
      return 0
    fi

    status=$(printf '%s\n' "$response" | sed -n '1s/^__STATUS__//p')
    printf '%s\n' "$status" >"$status_file"
    printf '%s\n' "$response" | sed '1d' >"$out_file"
    return 0
  fi

  status=$(curl -sS -o "$out_file" -w "%{http_code}" -X POST "$url" \
    -H "Content-Type: application/json" \
    --data "$payload")

  printf '%s\n' "$status" >"$status_file"
}

wait_for_origin_matrix_versions() {
  host_ip=$1
  attempts=${2:-90}
  count=0

  while [ "$count" -lt "$attempts" ]; do
    if ssh_exec "$host_ip" "curl -fsS --resolve '$MATRIX_BASE_HOST_NO_DOT:443:127.0.0.1' 'https://$MATRIX_BASE_HOST_NO_DOT/_matrix/client/versions' >/dev/null 2>&1"; then
      return 0
    fi

    count=$((count + 1))
    if [ $((count % 10)) -eq 0 ] || [ "$count" -eq "$attempts" ]; then
      log "apply: waiting for origin endpoint https://$MATRIX_BASE_HOST_NO_DOT/_matrix/client/versions ($count/$attempts)"
    fi
    sleep 2
  done

  return 1
}

verify_registration_flow() (
  register_url="$MATRIX_BASE_URL/_matrix/client/v3/register"
  login_url="$MATRIX_BASE_URL/_matrix/client/v3/login"
  username="nq-probe-$(date +%s)"
  password=$(openssl rand -base64 24 | tr -d '\n')

  tmpdir=$(mktemp -d)
  trap cleanup_tmpdir EXIT
  trap handle_interrupt INT TERM

  auth_type="m.login.dummy"
  auth_payload='{"type":"m.login.dummy"}'
  if [ "$MATRIX_ALLOW_OPEN_REGISTRATION" != "true" ]; then
    auth_type="m.login.registration_token"
    auth_payload=$(jq -cn --arg token "$MATRIX_REGISTRATION_TOKEN" '{type: "m.login.registration_token", token: $token}')
  fi

  first_payload=$(jq -cn \
    --arg username "$username" \
    --arg password "$password" \
    --argjson auth "$auth_payload" \
    '{username: $username, password: $password, inhibit_login: false, auth: $auth}')

  http_post_json "$register_url" "$first_payload" "$tmpdir/register1.json" "$tmpdir/register1.status"
  status1=$(cat "$tmpdir/register1.status")

  if [ "$status1" = "200" ]; then
    :
  elif [ "$status1" = "401" ]; then
    session=$(jq -r '.session // empty' "$tmpdir/register1.json")
    [ -n "$session" ] || die "verify: registration flow returned 401 without session"

    second_stage="m.login.dummy"
    if [ "$auth_type" = "m.login.dummy" ]; then
      second_stage="m.login.dummy"
    fi
    second_auth=$(jq -cn --arg session "$session" --arg stage "$second_stage" '{type: $stage, session: $session}')
    second_payload=$(jq -cn \
      --arg username "$username" \
      --arg password "$password" \
      --argjson auth "$second_auth" \
      '{username: $username, password: $password, inhibit_login: false, auth: $auth}')

    http_post_json "$register_url" "$second_payload" "$tmpdir/register2.json" "$tmpdir/register2.status"
    status2=$(cat "$tmpdir/register2.status")
    [ "$status2" = "200" ] || die "verify: registration failed with HTTP $status2"
  else
    die "verify: registration failed with HTTP $status1"
  fi

  user_id="@$username:$MATRIX_SERVER_NAME"
  login_payload=$(jq -cn \
    --arg user "$user_id" \
    --arg password "$password" \
    '{
      type: "m.login.password",
      identifier: { type: "m.id.user", user: $user },
      password: $password
    }')

  http_post_json "$login_url" "$login_payload" "$tmpdir/login.json" "$tmpdir/login.status"
  login_status=$(cat "$tmpdir/login.status")
  [ "$login_status" = "200" ] || die "verify: login probe failed with HTTP $login_status"

  token=$(jq -r '.access_token // empty' "$tmpdir/login.json")
  [ -n "$token" ] || die "verify: login probe did not return an access token"

  log "verify: registration + login probe succeeded for $user_id"
)

run_apply() {
  validate_apply_config
  hcloud_require_cli
  hcloud_require_auth
  cloudflare_require_cli
  ssh_require_cli

  hcloud_ensure_ssh_key "$HCLOUD_SSH_KEY_NAME" "$HCLOUD_SSH_PUBLIC_KEY_PATH"
  log "apply: SSH key \"$HCLOUD_SSH_KEY_NAME\" is ready"

  tmpdir=$(mktemp -d)
  trap cleanup_tmpdir EXIT
  trap handle_interrupt INT TERM

  ensure_firewall_if_enabled "$tmpdir/firewall-rules.json"
  ensure_server_exists

  ipv4=$(hcloud_wait_for_ipv4 "$HCLOUD_SERVER_NAME")
  log "apply: server \"$HCLOUD_SERVER_NAME\" is ready with public IPv4 $ipv4"

  if [ "$HCLOUD_FIREWALL_ENABLE" = "true" ]; then
    hcloud_attach_firewall_to_server "$HCLOUD_FIREWALL_NAME" "$HCLOUD_SERVER_NAME"
    log "apply: firewall \"$HCLOUD_FIREWALL_NAME\" attached to \"$HCLOUD_SERVER_NAME\""
  fi

  ensure_cloudflare_dns_if_enabled "$ipv4"

  ssh_wait_for_ready "$ipv4"
  ensure_remote_base_system "$ipv4"
  ensure_remote_identity_compatible "$ipv4"

  bundle_dir="$tmpdir/bundle"
  mkdir -p "$bundle_dir"
  render_bundle "$bundle_dir"
  deploy_bundle "$ipv4" "$bundle_dir"
  if ! wait_for_origin_matrix_versions "$ipv4" 120; then
    collect_remote_diagnostics "$ipv4"
    die "apply: matrix client API did not become ready on the origin listener"
  fi

  log "apply: matrix deployment is reconciled for $MATRIX_BASE_URL (origin IPv4: $ipv4)"
}

run_verify() {
  validate_verify_config
  hcloud_require_cli
  hcloud_require_auth
  cloudflare_require_cli
  ssh_require_cli

  if ! hcloud_server_exists "$HCLOUD_SERVER_NAME"; then
    die "verify: server \"$HCLOUD_SERVER_NAME\" does not exist"
  fi
  host_ip=$(hcloud_server_ipv4 "$HCLOUD_SERVER_NAME")
  [ -n "$host_ip" ] || die "verify: failed to resolve server IPv4 for \"$HCLOUD_SERVER_NAME\""

  ssh_wait_for_ready "$host_ip"

  if ! check_remote_stack_state "$host_ip"; then
    collect_remote_diagnostics "$host_ip"
    die "verify: remote stack state checks failed"
  fi

  if ! check_origin_matrix_versions "$host_ip"; then
    collect_remote_diagnostics "$host_ip"
    die "verify: origin endpoint checks failed"
  fi

  if ! check_public_matrix_versions "$host_ip"; then
    collect_remote_diagnostics "$host_ip"
    die "verify: public endpoint checks failed"
  fi

  if [ "$MATRIX_ALLOW_REGISTRATION" = "true" ]; then
    if ! command -v openssl >/dev/null 2>&1; then
      die "openssl is required for registration probe"
    fi
    MATRIX_VERIFY_REMOTE_HOST_IP=$host_ip
    if ! verify_registration_flow; then
      unset MATRIX_VERIFY_REMOTE_HOST_IP
      collect_remote_diagnostics "$host_ip"
      die "verify: registration/login probe failed"
    fi
    unset MATRIX_VERIFY_REMOTE_HOST_IP
  else
    log "verify: registration probe skipped because MATRIX_ALLOW_REGISTRATION=false"
  fi

  log "verify: matrix checks completed for $MATRIX_BASE_URL"
}

run_destroy() {
  validate_destroy_config
  hcloud_require_cli
  hcloud_require_auth

  if [ "$CLOUDFLARE_MANAGE_DNS" = "true" ]; then
    cloudflare_require_cli
    zone_id=$(cloudflare_resolve_zone_id)
    cloudflare_delete_a_record_if_present "$zone_id" "$MATRIX_BASE_HOST_NO_DOT"
  fi

  if hcloud_server_exists "$HCLOUD_SERVER_NAME"; then
    log "destroy: deleting server \"$HCLOUD_SERVER_NAME\""
    if ! hcloud_delete_server "$HCLOUD_SERVER_NAME"; then
      if hcloud_server_exists "$HCLOUD_SERVER_NAME"; then
        die "destroy: failed to delete server \"$HCLOUD_SERVER_NAME\""
      fi
    fi

    hcloud_wait_until_absent "$HCLOUD_SERVER_NAME"
    log "destroy: server \"$HCLOUD_SERVER_NAME\" has been deleted"
  else
    log "destroy: server \"$HCLOUD_SERVER_NAME\" is already absent"
  fi

  if [ "$HCLOUD_FIREWALL_ENABLE" = "true" ] && hcloud_firewall_exists "$HCLOUD_FIREWALL_NAME"; then
    if hcloud_server_exists "$HCLOUD_SERVER_NAME"; then
      hcloud_detach_firewall_from_server "$HCLOUD_FIREWALL_NAME" "$HCLOUD_SERVER_NAME" || true
    fi
    hcloud_delete_firewall "$HCLOUD_FIREWALL_NAME"
    log "destroy: firewall \"$HCLOUD_FIREWALL_NAME\" has been deleted"
  fi
}

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 1
fi

case "$1" in
  # apply
  apply)
    run_apply
    ;;
  # verify
  verify)
    run_verify
    ;;
  # destroy
  destroy)
    run_destroy
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
