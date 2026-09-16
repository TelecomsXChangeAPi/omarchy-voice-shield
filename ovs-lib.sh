# Shared config, auth and HTTP for the Open Voice Shield helpers.
# Sourced, never executed on its own.
#
# Every helper keeps the same contract: one JSON object on stdout, exit 0 no
# matter what went wrong, so a QML Process never fails and the panel renders a
# diagnosable state instead of going blank.
#
# Credentials, phone numbers and API response bodies never go on a command line.
# /proc/PID/cmdline is world-readable, so any argv — curl's or jq's — can be
# read by every local user for as long as that process runs. The API key
# reaches curl through an inherited pipe (see ovs_curl); request bodies,
# responses and error text reach curl and jq on stdin.

OVS_CONFIG_PATH="${OVS_CONFIG:-$HOME/.config/omarchy/ovs.json}"
OVS_DEFAULT_BASE="https://ovs.telecomsxchange.com/api"

# Hard ceiling on any response body we will hold in memory. A hostile or broken
# endpoint — a compromised API, a `baseUrl` pointed elsewhere, or an
# intermediary — must not be able to grow this helper, or the shell that
# collects our stdout, without bound. `--max-time` alone does not bound size.
#
# Oversized responses are rejected outright rather than truncated: half a body
# is not valid JSON, and acting on a partial answer is worse than failing. We
# never send Accept-Encoding, so curl performs no decompression and this ceiling
# applies to the bytes on the wire rather than to an inflated body.
OVS_MAX_BYTES="${OVS_MAX_BYTES:-262144}"   # 256 KiB

# Byte length of a string, independent of locale/multibyte settings.
ovs_bytes() { printf '%s' "$1" | LC_ALL=C wc -c; }

# The message can be text lifted out of an API response, so it reaches jq on
# stdin rather than as an --arg.
ovs_fail() { printf '%s' "$1" | jq -Rsc '{ok: false, error: .}'; exit 0; }

# Sets `key`, `base` and `days` for the caller, or exits with an error object.
ovs_load_config() {
  command -v jq >/dev/null 2>&1 || { printf '{"ok":false,"error":"jq-missing"}\n'; exit 0; }
  command -v curl >/dev/null 2>&1 || ovs_fail "curl-missing"
  [[ -r "$OVS_CONFIG_PATH" ]] || ovs_fail "no-config"
  jq -e . "$OVS_CONFIG_PATH" >/dev/null 2>&1 || ovs_fail "bad-config"

  key=$(jq -r '.apiKey // empty' "$OVS_CONFIG_PATH")
  [[ -n "$key" ]] || ovs_fail "no-key"
  # A key is a single token (OVS issues `ovs_` plus URL-safe base64).
  # Whitespace, quotes or a line break can only mean a damaged config, and a
  # line break would split the one-line header ovs_curl hands to curl in two.
  [[ "$key" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || ovs_fail "bad-config"

  base=$(jq -r --arg d "$OVS_DEFAULT_BASE" '.baseUrl // $d' "$OVS_CONFIG_PATH")
  base="${base%/}"
  days=$(jq -r '.days // 7' "$OVS_CONFIG_PATH")
  [[ "$days" =~ ^[0-9]+$ ]] || days=7
}

# curl with the API key attached, without the key ever being an argument. The
# printf builtin writes the header into a pipe — a builtin runs no program, so
# the key lands in no argv, and `key` is never exported, so in no environment —
# and curl inherits the read end as a descriptor it reads as a header file.
# curl's argv names only that descriptor (-H @/dev/fd/N), and another user
# cannot open a process's descriptors. Nothing is written to disk, so nothing
# needs cleaning up: however the request ends — completed, timed out, or the
# helper killed — the pipe is gone with the processes that hold it.
#
# $1 is the API path; any further arguments are passed to curl.
ovs_curl() {
  local path="$1"
  shift
  curl -sS -H @<(printf 'X-API-Key: %s\n' "$key") "$@" "$base$path" 2>/dev/null
}

# GET, capped by reading at most one byte past the ceiling: that extra byte is
# what distinguishes "too large" from "exactly at the limit", and closing the
# pipe there kills the transfer. This single read cap is the guarantee, and it
# holds for every shape of response — chunked, close-delimited, or one whose
# declared Content-Length lies. (curl's own --max-filesize is deliberately not
# used: it only helps when the peer declares its size honestly, and when it
# fires it yields an empty body indistinguishable from a network error.)
# An over-limit answer becomes a small rejection object, which the callers'
# existing error handling reports.
ovs_get() {
  local body
  body=$(ovs_curl "$1" --max-time 12 | head -c "$((OVS_MAX_BYTES + 1))")
  if (( $(ovs_bytes "$body") > OVS_MAX_BYTES )); then
    jq -nc '{ok: false, error: "response-too-large"}'
    return 0
  fi
  printf '%s' "$body"
}

# POST with the HTTP status appended on its own final line: a queued test call
# (202) and a refusal (409 no destination, 422 unusable number) both come back
# as JSON, and only the code tells them apart. Capped the same way; an oversized
# body is reported as a synthetic 413 so the caller's status parsing still works
# (the real status is lost with the body we refused to read). The request body
# carries the dialled number, so curl reads it from stdin (--data-binary @-).
ovs_post() {
  local raw
  raw=$(printf '%s' "$2" \
    | ovs_curl "$1" --max-time 20 -X POST \
        -H "Content-Type: application/json" \
        --data-binary @- \
        -w $'\n%{http_code}' \
    | head -c "$((OVS_MAX_BYTES + 1))")
  if (( $(ovs_bytes "$raw") > OVS_MAX_BYTES )); then
    printf '%s\n413' '{"ok":false,"error":"response-too-large"}'
    return 0
  fi
  printf '%s' "$raw"
}

# The human-readable half of an error body. FastAPI answers with {"detail": …},
# where detail is a string for a deliberate refusal and a list of field errors
# for a validation failure; both get flattened to one line. The result is kept
# short: an error body is still attacker-influenced text that ends up on screen,
# so only a small bounded message is carried out of here.
OVS_MAX_ERROR_CHARS=200
ovs_error_message() {
  jq -r '
    if (.detail? | type) == "array" then
      (.detail[0].msg? // (.detail[0] | tostring))
    elif .detail? then (.detail | tostring)
    elif .error? then (.error | tostring)
    else empty end
  ' 2>/dev/null <<<"$1" | head -c "$OVS_MAX_ERROR_CHARS" | tr -d '\r\n'
}
