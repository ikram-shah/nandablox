#!/bin/bash
# Put the hosted harness's shared secret into the *built place*, never the repo.
#
#   NANDA_HARNESS_TOKEN=… tools/secret.sh     # write it (tools/publish.sh calls this)
#   tools/secret.sh --clear                   # take it away again
#   tools/secret.sh --status                  # is there one, and how long (never what)
#
# It writes src/server/secrets/LlmToken.luau, which is gitignored and which
# play.project.json picks up as an *optional* path, so the place builds either
# way. The module lands in ServerStorage.NandaSecrets, which Roblox never
# replicates to a client: a player cannot read it, and RedBlueServer sends it
# as `Authorization: Bearer …` when it polls the harness.
#
# Second best, and only because the first needs a browser. The real place for
# it is the experience's secrets store (Creator Dashboard > NANDA Town >
# Secrets, name `nanda_harness_token`, domain
# nanda-harness-production.up.railway.app); RedBlueServer prefers that
# whenever HttpService:GetSecret finds it, and then this file can go.
#
# The token is never echoed, never put on a command line, and never committed.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
dir="$here/src/server/secrets"
file="$dir/LlmToken.luau"

case "${1:-write}" in
  --clear)
    rm -f "$file"
    rmdir "$dir" 2>/dev/null || true
    echo "no secret in the build: removed ${file#$here/}"
    exit 0
    ;;
  --status)
    if [ -f "$file" ]; then
      n="$(sed -n 's/^return "\(.*\)"$/\1/p' "$file" | tr -d '\n' | wc -c)"
      echo "${file#$here/}: present ($n characters, not shown)"
    else
      echo "${file#$here/}: absent — a published place would get 401 from the harness"
    fi
    exit 0
    ;;
  write|"") ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  *) echo "usage: tools/secret.sh [--clear | --status]" >&2; exit 2 ;;
esac

token="${NANDA_HARNESS_TOKEN:-}"
if [ -z "$token" ]; then
  echo "no NANDA_HARNESS_TOKEN in the environment: leaving the place without a secret." >&2
  echo "  (it is in ~/.env; publish with: zsh -c 'source ~/.env; tools/publish.sh')" >&2
  exit 0
fi
# a token is ours to choose, so insist on one that cannot end a Luau string
case "$token" in
  *[!A-Za-z0-9._-]*) echo "NANDA_HARNESS_TOKEN has characters outside [A-Za-z0-9._-]; refusing to bake it in" >&2; exit 1 ;;
esac

mkdir -p "$dir"
umask 077
printf -- '-- Written by tools/secret.sh from $NANDA_HARNESS_TOKEN. Never committed.\nreturn "%s"\n' "$token" > "$file"
echo "secret baked into the build: ${file#$here/} (${#token} characters, not shown)"
