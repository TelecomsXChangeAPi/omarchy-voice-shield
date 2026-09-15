# Shared config, auth and HTTP for the Open Voice Shield helpers.
# Sourced, never executed on its own.
#
# Every helper keeps the same contract: one JSON object on stdout, exit 0 no
# matter what went wrong, so a QML Process never fails and the panel renders a
# diagnosable state instead of going blank.
#
# The API key is read from the config file here and is never passed on a
# command line, so it stays out of the process table.

OVS_CONFIG_PATH="${OVS_CONFIG:-$HOME/.config/omarchy/ovs.json}"
OVS_DEFAULT_BASE="https://ovs.telecomsxchange.com/api"

ovs_fail() { jq -nc --arg e "$1" '{ok: false, error: $e}'; exit 0; }

# Sets `key`, `base` and `days` for the caller, or exits with an error object.
ovs_load_config() {
  command -v jq >/dev/null 2>&1 || { printf '{"ok":false,"error":"jq-missing"}\n'; exit 0; }
  command -v curl >/dev/null 2>&1 || ovs_fail "curl-missing"
  [[ -r "$OVS_CONFIG_PATH" ]] || ovs_fail "no-config"
  jq -e . "$OVS_CONFIG_PATH" >/dev/null 2>&1 || ovs_fail "bad-config"

  key=$(jq -r '.apiKey // empty' "$OVS_CONFIG_PATH")
  [[ -n "$key" ]] || ovs_fail "no-key"

  base=$(jq -r --arg d "$OVS_DEFAULT_BASE" '.baseUrl // $d' "$OVS_CONFIG_PATH")
  base="${base%/}"
  days=$(jq -r '.days // 7' "$OVS_CONFIG_PATH")
  [[ "$days" =~ ^[0-9]+$ ]] || days=7
}

ovs_get() { curl -sS --max-time 12 -H "X-API-Key: $key" "$base$1" 2>/dev/null; }

# POST with the HTTP status appended on its own final line: a queued test call
# (202) and a refusal (409 no destination, 422 unusable number) both come back
# as JSON, and only the code tells them apart.
ovs_post() {
  curl -sS --max-time 20 -X POST \
    -H "X-API-Key: $key" \
    -H "Content-Type: application/json" \
    -d "$2" \
    -w $'\n%{http_code}' \
    "$base$1" 2>/dev/null
}

# The human-readable half of an error body. FastAPI answers with {"detail": …},
# where detail is a string for a deliberate refusal and a list of field errors
# for a validation failure; both get flattened to one line.
ovs_error_message() {
  jq -r '
    if (.detail? | type) == "array" then
      (.detail[0].msg? // (.detail[0] | tostring))
    elif .detail? then (.detail | tostring)
    elif .error? then (.error | tostring)
    else empty end
  ' 2>/dev/null <<<"$1"
}
