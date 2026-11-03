#!/usr/bin/env bash
# Writes patches/<version>.patch: the fork's Wizzle core changes against the upstream commit the fork is based on.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fork="${WIZZLE_FORK:-$HOME/Workspace/nanoclaw}"
upstream="${WIZZLE_UPSTREAM_REF:-upstream/main}"
files=(
  src/mailbox/types.ts
  src/mailbox/sqlite/index.ts
  src/modules/cross-session-context/backfill.test.ts
  src/channels/adapter.ts
  src/channels/channel-registry.ts
  src/delivery.ts
  src/types.ts
  src/db/schema.ts
  src/db/agent-groups.ts
  src/db/migrations/026-agent-group-paused.ts
  src/db/migrations/index.ts
  src/router.ts
  src/reconcile-session.ts
  src/cli/resources/groups.ts
)

base="$(git -C "$fork" merge-base main "$upstream")"
version="$(git -C "$fork" show "$base:package.json" | node -p 'JSON.parse(require("fs").readFileSync(0, "utf8")).version')"
mkdir -p "$here/patches"
out="$here/patches/$version.patch"

# The fork's numbered migration becomes a named one, so it never collides with one NanoClaw ships later.
git -C "$fork" diff --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ "$base" main -- "${files[@]}" |
  sed -e 's#026-agent-group-paused#wizzle-agent-group-paused#g' \
    -e 's#migration026#migrationWizzleAgentGroupPaused#g' \
    -e "s#name: 'agent-group-paused'#name: 'wizzle-agent-group-paused'#" \
    -e 's# (migration 026)##' >"$out"

if [ ! -s "$out" ]; then
  rm -f "$out"
  echo "No core changes between $base and main in $fork" >&2
  exit 1
fi
echo "Wrote $out (NanoClaw $version, upstream commit $base)"
