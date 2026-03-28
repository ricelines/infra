#!/bin/sh
set -eu

SCRIPT_DIR=$(
	CDPATH='' cd -- "$(dirname -- "$0")" && pwd
)
INFRA_SH="$SCRIPT_DIR/infra.sh"

tmpdir=$(mktemp -d)
cleanup() {
	rm -rf "$tmpdir"
}
trap cleanup EXIT INT TERM

function_path="$tmpdir/functions.sh"
awk '
  /^write_upgrade_payload_from_detail_json\(\) \{/ {
    capture = 1
  }
  capture {
    print
    if ($0 == "}") {
      exit
    }
  }
' "$INFRA_SH" >"$function_path"

[ -s "$function_path" ] || {
	echo "failed to extract write_upgrade_payload_from_detail_json from $INFRA_SH" >&2
	exit 1
}

# shellcheck source=/dev/null
. "$function_path"

detail_path="$tmpdir/detail.json"
payload_path="$tmpdir/payload.json"

cat >"$detail_path" <<'EOF'
{
  "root_config": {
    "matrix_username": "alice-bot"
  },
  "secret_root_config_paths": [
    "matrix_password"
  ],
  "external_slots": {
    "matrix": {
      "bindable_service_id": "svc_matrix",
      "provider_scenario_id": "scn_provider"
    }
  },
  "metadata": {
    "kind": "user-agent",
    "bot_username": "alice-bot"
  }
}
EOF

write_upgrade_payload_from_detail_json "$detail_path" "$payload_path"

jq -e '
  . == {
    external_slots: {
      matrix: {
        bindable_service_id: "svc_matrix"
      }
    },
    metadata: {
      kind: "user-agent",
      bot_username: "alice-bot"
    },
    store_bundle: true
  }
' "$payload_path" >/dev/null
