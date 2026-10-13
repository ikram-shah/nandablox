#!/bin/bash
# Publish the play place to its Roblox experience with Open Cloud.
#
#   tools/publish.sh             # build play.project.json -> build/play.rbxl, check the key, publish
#   tools/publish.sh --check     # only introspect the key: is it live, and does it have
#                                # universe-places:write for the universe in place.json?
#   tools/publish.sh --dry-run   # build and check, but don't publish
#
# The IDs come from roblox/place.json (committed): {"universeId": ..., "placeId": ...}.
# They are null until the experience exists; see README.md, "Publish".
# The key comes from $ROBLOX_PUBLISH_API_KEY, else $ROBLOX_OPEN_CLOUD_API_KEY. It
# needs the universe-places API with the Write operation for this experience.
# The key never goes on a command line (it would show in ps): curl reads it
# from a private temp file.
#
# The place is built from the repo by the pinned Rojo, as binary .rbxl
# (Content-Type application/octet-stream; .rbxlx would be application/xml), and
# POSTed to
#   https://apis.roblox.com/universes/v1/{universeId}/places/{placeId}/versions?versionType=Published
# which answers {"versionNumber": N}. Docs:
#   https://create.roblox.com/docs/cloud/guides/usage-place-publishing
#   https://create.roblox.com/docs/cloud/auth/api-keys (introspect)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
mode=publish
case "${1:-}" in
  "") ;;
  --check) mode=check ;;
  --dry-run) mode=dry ;;
  -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
  *) echo "usage: tools/publish.sh [--check | --dry-run]" >&2; exit 2 ;;
esac

ids_file="$here/place.json"
[ -f "$ids_file" ] || { echo "missing $ids_file" >&2; exit 1; }
read -r universe place < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
def get(k):
    v = d.get(k)
    return "" if v in (None, "") else str(int(v))
print(get("universeId") or "-", get("placeId") or "-")' "$ids_file")
[ "$universe" = - ] && universe=""
[ "$place" = - ] && place=""

key="${ROBLOX_PUBLISH_API_KEY:-${ROBLOX_OPEN_CLOUD_API_KEY:-}}"
key_var=ROBLOX_PUBLISH_API_KEY
[ -n "${ROBLOX_PUBLISH_API_KEY:-}" ] || key_var=ROBLOX_OPEN_CLOUD_API_KEY
if [ -z "$key" ]; then
  echo "no API key: set ROBLOX_PUBLISH_API_KEY (or ROBLOX_OPEN_CLOUD_API_KEY) to a key with" >&2
  echo "universe-places Write for this experience (Creator Hub -> Open Cloud -> API Keys)" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
umask 077
printf 'x-api-key: %s\n' "$key" > "$tmp/header"   # printf is a builtin: no argv in ps
# the introspect body, from the environment (not argv)
python3 - "$tmp/introspect.json" <<'PY'
import json, os, sys
key = os.environ.get("ROBLOX_PUBLISH_API_KEY") or os.environ.get("ROBLOX_OPEN_CLOUD_API_KEY")
json.dump({"apiKey": key}, open(sys.argv[1], "w"))
PY

# ---- check: introspect the key
check() {
  local out code
  code="$(curl -sS -o "$tmp/introspect.out" -w '%{http_code}' -X POST \
    https://apis.roblox.com/api-keys/v1/introspect \
    -H 'Content-Type: application/json' --data-binary @"$tmp/introspect.json")"
  python3 - "$tmp/introspect.out" "$code" "$universe" "$key_var" <<'PY'
import json, sys
path, code, universe, var = sys.argv[1:5]
raw = open(path).read()
try:
    d = json.loads(raw)
except ValueError:
    d = None
if code != "200" or not isinstance(d, dict):
    print(f"introspect failed (HTTP {code}): {raw[:300]}")
    sys.exit(1)
print(f"key ({var}): {d.get('name')!r}, enabled={d.get('enabled')}, expired={d.get('expired')}, "
      f"expires {d.get('expirationTimeUtc')}")
for s in d.get("scopes", []):
    res = {k: v for k, v in s.items() if k not in ("name", "operations")}
    print(f"  scope {s.get('name')}: {','.join(s.get('operations', []))}  {json.dumps(res)}")
problems = []
if not d.get("enabled", False):
    problems.append("the key is disabled")
if d.get("expired", False):
    problems.append("the key has expired (regenerate it in Creator Hub)")
ok_scope = False
for s in d.get("scopes", []):
    if s.get("name") == "universe-places" and "write" in [o.lower() for o in s.get("operations", [])]:
        ids = [str(u) for u in s.get("universeIds", []) or []]
        if not universe or "*" in ids or universe in ids:
            ok_scope = True
if not ok_scope:
    target = f"universe {universe}" if universe else "this experience"
    problems.append(f"no universe-places:write for {target}")
if not universe:
    problems.append("place.json has no universeId yet, so the scope can't be matched to the experience")
if problems:
    print("NOT READY: " + "; ".join(problems))
    sys.exit(1)
print(f"ready: universe-places:write covers universe {universe}")
PY
}

if [ "$mode" = check ]; then
  check
  exit $?
fi

if [ -z "$universe" ] || [ -z "$place" ]; then
  echo "roblox/place.json has no universeId/placeId yet (both are null)." >&2
  echo "Create the experience first (README.md, \"Publish\"), then put its IDs there:" >&2
  echo '  {"universeId": 1234567890, "placeId": 9876543210}' >&2
  exit 1
fi

check || { echo "key check failed; not publishing" >&2; exit 1; }

mkdir -p "$here/build"
"$here/tools/rojo.sh" build play.project.json -o build/play.rbxl >&2
rbxl="$here/build/play.rbxl"
echo "built $rbxl ($(stat -c%s "$rbxl") bytes, git $(git -C "$here" rev-parse --short HEAD)$(git -C "$here" diff --quiet HEAD -- . || echo '+dirty'))"

if [ "$mode" = dry ]; then
  echo "dry run: would POST it to universe $universe, place $place (versionType=Published)"
  exit 0
fi

url="https://apis.roblox.com/universes/v1/$universe/places/$place/versions?versionType=Published"
code="$(curl -sS -o "$tmp/publish.out" -w '%{http_code}' -X POST "$url" \
  -H @"$tmp/header" -H 'Content-Type: application/octet-stream' --data-binary @"$rbxl")"
if [ "$code" != 200 ]; then
  echo "publish failed (HTTP $code): $(head -c 500 "$tmp/publish.out")" >&2
  exit 1
fi
version="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["versionNumber"])' "$tmp/publish.out")"
echo "published: universe $universe, place $place, version $version"
echo "join: https://www.roblox.com/games/$place"
