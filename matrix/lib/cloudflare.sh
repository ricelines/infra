# shellcheck shell=sh

cloudflare_require_cli() {
  if ! command -v curl >/dev/null 2>&1; then
    die "curl not found. Install it and retry."
  fi
  if ! command -v jq >/dev/null 2>&1; then
    die "jq not found. Install it and retry."
  fi
}

cloudflare_public_edge_cidrs() {
  response=$(curl -sS "https://api.cloudflare.com/client/v4/ips")
  if [ "$(printf '%s' "$response" | jq -r '.success // false')" != "true" ]; then
    die "failed to fetch Cloudflare edge IP ranges"
  fi

  printf '%s\n' "$response" | jq -r '.result.ipv4_cidrs[], .result.ipv6_cidrs[]'
}

cloudflare_api() {
  method=$1
  path=$2
  data=${3:-}
  url="https://api.cloudflare.com/client/v4$path"

  tmp=$(mktemp)
  if [ -n "$data" ]; then
    status=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" \
      "$url" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$data")
  else
    status=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" \
      "$url" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H "Content-Type: application/json")
  fi
  body=$(cat "$tmp")
  rm -f "$tmp"

  case "$status" in
    2??) ;;
    *)
      die "Cloudflare API $method $path failed with HTTP $status"
      ;;
  esac

  if [ "$(printf '%s' "$body" | jq -r '.success // false')" != "true" ]; then
    die "Cloudflare API $method $path returned an error response"
  fi

  printf '%s\n' "$body"
}

cloudflare_resolve_zone_id() {
  if [ -n "$CLOUDFLARE_ZONE_ID" ]; then
    printf '%s\n' "$CLOUDFLARE_ZONE_ID"
    return 0
  fi

  response=$(cloudflare_api GET "/zones?name=$CLOUDFLARE_ZONE_NAME&status=active")
  count=$(printf '%s' "$response" | jq '.result | length')
  if [ "$count" -ne 1 ]; then
    die "expected exactly one Cloudflare zone named $CLOUDFLARE_ZONE_NAME, found $count"
  fi

  CLOUDFLARE_ZONE_ID=$(printf '%s' "$response" | jq -r '.result[0].id')
  printf '%s\n' "$CLOUDFLARE_ZONE_ID"
}

cloudflare_build_a_payload() {
  dns_name=$1
  ipv4=$2

  case "$CLOUDFLARE_DNS_TTL" in
    ''|*[!0-9]*)
      die "CLOUDFLARE_DNS_TTL must be a numeric value, got: $CLOUDFLARE_DNS_TTL"
      ;;
  esac

  jq -cn \
    --arg name "$dns_name" \
    --arg content "$ipv4" \
    --argjson proxied "$CLOUDFLARE_DNS_PROXIED" \
    --argjson ttl "$CLOUDFLARE_DNS_TTL" \
    '{type: "A", name: $name, content: $content, proxied: $proxied, ttl: $ttl}'
}

cloudflare_ensure_a_record() {
  zone_id=$1
  dns_name=$2
  ipv4=$3

  lookup=$(cloudflare_api GET "/zones/$zone_id/dns_records?type=A&name=$dns_name")
  count=$(printf '%s' "$lookup" | jq '.result | length')
  payload=$(cloudflare_build_a_payload "$dns_name" "$ipv4")

  if [ "$count" -eq 0 ]; then
    cloudflare_api POST "/zones/$zone_id/dns_records" "$payload" >/dev/null
    log "cloudflare: created A record $dns_name -> $ipv4"
    return 0
  fi

  if [ "$count" -gt 1 ]; then
    die "cloudflare: expected at most one A record for $dns_name but found $count"
  fi

  record_id=$(printf '%s' "$lookup" | jq -r '.result[0].id')
  current_content=$(printf '%s' "$lookup" | jq -r '.result[0].content')
  current_proxied=$(printf '%s' "$lookup" | jq -r '.result[0].proxied')
  current_ttl=$(printf '%s' "$lookup" | jq -r '.result[0].ttl')

  if [ "$current_content" = "$ipv4" ] && [ "$current_proxied" = "$CLOUDFLARE_DNS_PROXIED" ] && [ "$current_ttl" = "$CLOUDFLARE_DNS_TTL" ]; then
    log "cloudflare: A record $dns_name already up to date"
    return 0
  fi

  cloudflare_api PUT "/zones/$zone_id/dns_records/$record_id" "$payload" >/dev/null
  log "cloudflare: updated A record $dns_name -> $ipv4"
}

cloudflare_delete_a_record_if_present() {
  zone_id=$1
  dns_name=$2

  lookup=$(cloudflare_api GET "/zones/$zone_id/dns_records?type=A&name=$dns_name")
  ids=$(printf '%s' "$lookup" | jq -r '.result[]?.id')

  if [ -z "$ids" ]; then
    log "cloudflare: no A records to delete for $dns_name"
    return 0
  fi

  printf '%s\n' "$ids" | while IFS= read -r record_id; do
    [ -n "$record_id" ] || continue
    cloudflare_api DELETE "/zones/$zone_id/dns_records/$record_id" >/dev/null
    log "cloudflare: deleted A record $dns_name (id=$record_id)"
  done
}
