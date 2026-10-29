#!/bin/bash
# Publish the play place (play.project.json) to its experience with Open Cloud.
#
#   tools/publish.sh            # rojo build, then publish a new Published version
#   tools/publish.sh --check    # only check the key: does it have universe-places:write here?
#   tools/publish.sh --dry-run  # build and print what would be sent, send nothing
#
# Run it with the environment loaded, so the hosted harness's shared secret
# goes into the build (tools/secret.sh; never into the repo):
#
#   zsh -c 'source ~/.env; tools/publish.sh'
#
# The place is built by the pinned Rojo from the repo (hermetic: nothing made by
# hand in Studio) into build/play.rbxl, then sent with
#
#   POST https://apis.roblox.com/universes/v1/{universeId}/places/{placeId}/versions?versionType=Published
#   x-api-key: $ROBLOX_PUBLISH_API_KEY      Content-Type: application/octet-stream (.rbxl)
#
# (.rbxlx would be Content-Type: application/xml; the binary file is smaller.)
# Docs: https://create.roblox.com/docs/cloud/guides/usage-place-publishing
#
# IDs come from roblox/place.json (committed). The key comes from the
# environment: ROBLOX_PUBLISH_API_KEY, else ROBLOX_OPEN_CLOUD_API_KEY. It needs
# the universe-places scope with Write on this experience (Creator Hub > Open
# Cloud > API Keys); --check asks POST /api-keys/v1/introspect.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
mode="publish"
case "${1:-}" in
  --check) mode=check ;;
  --dry-run) mode=dry ;;
  "") ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  *) echo "usage: tools/publish.sh [--check | --dry-run]" >&2; exit 2 ;;
esac

place_json="${PLACE_JSON:-$here/place.json}"   # PLACE_JSON: for testing only
universe="$(jq -r '.universeId // empty' "$place_json")"
place="$(jq -r '.placeId // empty' "$place_json")"
need_ids() {
  if [ -z "$universe" ] || [ -z "$place" ]; then
    cat >&2 <<EOF
roblox/place.json has no universeId/placeId yet, so there is nowhere to publish.
One-time setup (README "Publish"): create the experience (private), then put its
Universe ID and start Place ID in roblox/place.json and commit it.
EOF
    exit 1
  fi
  case "$universe$place" in *[!0-9]*) echo "place.json: universeId and placeId must be numbers" >&2; exit 1 ;; esac
}

key="${ROBLOX_PUBLISH_API_KEY:-${ROBLOX_OPEN_CLOUD_API_KEY:-}}"
keyvar="ROBLOX_PUBLISH_API_KEY"
[ -n "${ROBLOX_PUBLISH_API_KEY:-}" ] || keyvar="ROBLOX_OPEN_CLOUD_API_KEY"

# Introspect the key: prints a verdict, returns 0 only if it can publish here.
check_key() {
  if [ -z "$key" ]; then
    echo "no API key: set ROBLOX_PUBLISH_API_KEY (or ROBLOX_OPEN_CLOUD_API_KEY)" >&2
    return 1
  fi
  local resp code
  resp="$(mktemp)"
  code="$(NANDA_KEY="$key" jq -n '{apiKey: env.NANDA_KEY}' | curl -sS -o "$resp" -w '%{http_code}' \
    -X POST https://apis.roblox.com/api-keys/v1/introspect \
    -H 'Content-Type: application/json' --data-binary @-)"
  if [ "$code" != 200 ]; then
    echo "introspect failed (HTTP $code) for \$$keyvar: $(head -c 400 "$resp")" >&2
    rm -f "$resp"
    return 1
  fi
  # never print the key; the response carries only its name, owner and scopes
  jq -r --arg u "$universe" --arg var "$keyvar" '
    def ids: (.universeIds // .universeIdList // []) | map(tostring);
    [.scopes[]? | select(.name == "universe-places")] as $sp
    | ($sp | map(select((.operations // []) | index("write")))
           | map(select((ids | index($u)) or (ids | index("*")))) | length > 0) as $ok
    | "key:      \(.name // "?") (\($var)), authorized user \(.authorizedUserId // "?")",
      "state:    \(if .expired == true then "EXPIRED" elif .enabled == false then "DISABLED" else "active" end)"
        + (if .expirationTime then ", expires \(.expirationTime)" else "" end),
      "scopes:   \([.scopes[]? | "\(.name):\((.operations // []) | join("+"))"] | join(", "))",
      "publish:  universe-places:write on universe \($u): \(if $ok then "YES" else "NO" end)"
  ' "$resp"
  local ok
  ok="$(jq -r --arg u "$universe" '
    def ids: (.universeIds // .universeIdList // []) | map(tostring);
    ([.scopes[]? | select(.name == "universe-places")
      | select((.operations // []) | index("write"))
      | select((ids | index($u)) or (ids | index("*")))] | length > 0)
    and (.expired != true) and (.enabled != false)' "$resp")"
  rm -f "$resp"
  [ "$ok" = true ]
}

if [ "$mode" = check ]; then
  [ -n "$universe" ] || echo "note: place.json has no universeId yet; checking the key against no universe" >&2
  if check_key; then
    echo "ok: this key can publish universe $universe place $place"
  else
    echo "not ready: create a key with universe-places Write on this experience (README \"Publish\")" >&2
    exit 1
  fi
  exit 0
fi

need_ids
mkdir -p "$here/build"
# the hosted harness's shared secret, into the build only (never the repo);
# a no-op without NANDA_HARNESS_TOKEN, and the place still builds
"$here/tools/secret.sh" >&2
"$here/tools/rojo.sh" build play.project.json -o build/play.rbxl >&2
file="$here/build/play.rbxl"
url="https://apis.roblox.com/universes/v1/$universe/places/$place/versions?versionType=Published"
echo "built $file ($(stat -c%s "$file") bytes)"

if [ "$mode" = dry ]; then
  echo "dry run: would POST $url (Content-Type: application/octet-stream, x-api-key from \$$keyvar)"
  exit 0
fi

check_key || { echo "not publishing: the key can't publish here (tools/publish.sh --check)" >&2; exit 1; }

# the key goes in a header file, not on curl's command line (ps would show it)
hdr="$(mktemp)"; resp="$(mktemp)"
trap 'rm -f "$hdr" "$resp"' EXIT
chmod 600 "$hdr"
printf 'x-api-key: %s\n' "$key" > "$hdr"
code="$(curl -sS -o "$resp" -w '%{http_code}' -X POST "$url" \
  -H @"$hdr" -H 'Content-Type: application/octet-stream' --data-binary @"$file")"
if [ "$code" != 200 ]; then
  echo "publish failed (HTTP $code): $(head -c 600 "$resp")" >&2
  if [ "$code" = 409 ]; then
    cat >&2 <<'EOF'
409 "Server is busy": on 2026-10-12 Open Cloud answered this (twice, 90 s apart)
while Studio had the place open in a Team Create (live editing) session, which
it was in after Publish to Roblox As... Close the place in Studio, or turn
Team Create off, and run this again; or publish once from Studio
(File > Publish to Roblox) while Rojo has it synced.
EOF
  fi
  exit 1
fi
version="$(jq -r '.versionNumber // empty' "$resp")"
[ -n "$version" ] || { echo "publish returned 200 without a versionNumber" >&2; exit 1; }
echo "published universe $universe place $place: version $version"
echo "join: https://www.roblox.com/games/$place"
