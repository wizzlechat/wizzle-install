#!/usr/bin/env bash
# Installs, updates or removes Wizzle on a NanoClaw checkout or an OpenClaw install.
# Usage: curl -fsSL https://wizzle.app/install.sh | bash [-s -- --runtime <r> | --dir <path> | --version <v> | --uninstall]
set -euo pipefail

DIST_URL="${WIZZLE_DIST_URL:-https://wizzle.app/dist/nanoclaw}"
OC_DIST_URL="${WIZZLE_OPENCLAW_DIST_URL:-https://wizzle.app/dist/openclaw}"
RELAY_URL="${WIZZLE_RELAY_URL:-wss://relay.wizzle.app}"
OWNER_ID='wizzle:owner'
BARREL='src/channels/index.ts'
BARREL_LINE="import './wizzle.js';"
SKILLS='add-wizzle add-wizzle-core'
PAYLOAD='src/channels/wizzle.ts src/channels/wizzle-adapter container/skills/wizzle-elements container/skills/wizzle-rooms'
PAUSE_TEST='src/agent-group-pause.test.ts'
CORE_PATCH='.claude/skills/add-wizzle-core/core.patch'
PAIRING='data/wizzle/pairing.json'
SAVED_CHANNELS='data/wizzle/removed-channels.json'
RESULT='data/wizzle/update-result.json'
OC_PLUGIN='wizzle'

mode=install
runtime=''
dir_arg=''
want_version=''
root=''
work=''
bundle=''
patch=''
core_step=''
changed=0
restarted=0
only=0
found=()
scanned=0
bundle_version=''
archive=''
backup=''
yes=0
from=''

usage() {
  cat <<'EOF'
wizzle.sh installs the Wizzle channel into NanoClaw or OpenClaw, updates it, or removes it.
Type ? at any question to ask Claude Code for help.

  --runtime <r>     nanoclaw or openclaw (asked when both are on this machine)
  --dir <path>      the NanoClaw checkout (asked when not given)
  --version <v>     install this Wizzle version instead of the latest
  --yes             answer every question with its default, with no terminal (the Wizzle app's Update button)
  --uninstall       remove Wizzle from the checkout
  -h, --help        this text
EOF
}

runtime_name() {
  case "$runtime" in
    openclaw) printf 'OpenClaw' ;;
    nanoclaw) printf 'NanoClaw' ;;
    *) printf 'NanoClaw or OpenClaw' ;;
  esac
}

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '%s\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }

# Claude Code is help only, as in NanoClaw's setup: the user asks for it, or a step failed.
claude_help() {
  if ! command -v claude >/dev/null 2>&1; then
    note 'Claude Code is not installed, so there is no help to open.' >/dev/tty
    return 0
  fi
  note 'Opening Claude Code. Type /exit to come back here.' >/dev/tty
  (cd "${root:-$PWD}" && claude "$1") </dev/tty >/dev/tty 2>&1 || true
}

# Questions read the terminal, because under curl | bash stdin is this script.
ask() {
  local prompt="$1" default="${2:-}" answer=''
  if [ "$yes" = 1 ]; then
    [ -n "$default" ] || die "--yes has no answer for: $1"
    printf '%s' "$default"
    return 0
  fi
  [ -n "$default" ] && prompt="$prompt [$default]"
  while :; do
    printf '%s: ' "$prompt" >/dev/tty
    IFS= read -r answer </dev/tty || true
    [ "$answer" = '?' ] || break
    claude_help "The user is running wizzle.sh, which installs the Wizzle channel into $(runtime_name), and asked for help with this question: $1. Explain; do not change any files."
  done
  printf '%s' "${answer:-$default}"
}

confirm() {
  case "$(ask "$1 (y/n)" "${2:-y}")" in
    y | Y | yes | Yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

# Stops before anything changed, for causes the message itself explains.
die() {
  printf '\033[31m%s\033[0m\n' "$*" >&2
  write_result 0 "Wizzle update failed: $*"
  exit 1
}

# A step failed: offers help, then an undo of what changed.
fail() {
  local restored=0
  printf '\033[31m%s\033[0m\n' "$*" >&2
  if confirm 'Open Claude Code to help with this?' n; then
    claude_help "wizzle.sh, which installs the Wizzle channel into $(runtime_name), stopped with: $*. Help the user find the cause. Do not commit, and do not restart or reconfigure $(runtime_name)."
  fi
  if [ "$changed" = 1 ]; then
    changed=0
    if confirm "Undo the changes made to $root so far?" y; then
      undo_changes
      restored=1
    fi
  fi
  [ -z "$backup" ] || note "The files as they were before this run are in $backup."
  if [ "$restored" = 1 ]; then
    write_result 0 "Wizzle update failed: $* The files were put back from $backup."
  else
    write_result 0 "Wizzle update failed: $*${backup:+ The files as they were before are in $backup.}"
  fi
  exit 1
}

# Leaves the outcome of an update where the bridge finds it, to show in the Wizzle app once the host is back.
write_result() {
  [ "$runtime" = nanoclaw ] && [ "$mode" = install ] && [ -n "$root" ] && [ -n "$from" ] || return 0
  mkdir -p "$root/data/wizzle" 2>/dev/null || return 0
  node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({ ok: process.argv[2] === "1", message: process.argv[3] }) + "\n")' \
    "$root/$RESULT" "$1" "$2" 2>/dev/null || true
}

# Deletes what the manifest marks absent and puts back what it saved, then rebuilds and restarts if a restart began.
undo_changes() {
  local state path
  while read -r state path; do
    [ -n "$path" ] || continue
    rm -rf "${root:?}/$path"
    [ "$state" = saved ] || continue
    mkdir -p "$(dirname "$root/$path")" && cp -Rp "$backup/files/$path" "$root/$path" ||
      warn "Could not put back $path; its saved copy is in $backup/files."
  done <"$backup/manifest"
  (cd "$root" && pnpm run build >/dev/null 2>&1) || warn "The rebuild after the undo failed; run pnpm run build in $root."
  if [ "$restarted" = 1 ]; then
    (cd "$root" && bash setup/lib/restart.sh) || warn "NanoClaw did not come back up after the undo. Its log is $root/logs/nanoclaw.log."
  else
    note 'NanoClaw was not restarted, so it still runs what it ran before.'
  fi
  note "Restored from $backup."
}

# Drops the lines grep matches with flags $2 and pattern $3, in place so the file keeps its mode (.env is private).
# The x keeps the trailing newlines that $(...) would strip.
drop_line() {
  local file="$1" flags="$2" pattern="$3" kept
  [ -f "$file" ] || return 0
  kept="$(grep -v "$flags" -e "$pattern" "$file" || true; printf x)"
  printf '%s' "${kept%x}" >"$file"
}

append_line() {
  local file="$1" line="$2"
  if [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ]; then printf '\n' >>"$file"; fi
  printf '%s\n' "$line" >>"$file"
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not installed. $2"
}

check_tools() {
  if [ "$runtime" = openclaw ]; then
    need openclaw 'Install OpenClaw first: https://docs.openclaw.ai/install'
  else
    need git 'NanoClaw needs it as well.'
    need pnpm 'NanoClaw needs it as well.'
  fi
  need node "$(runtime_name) needs it as well."
  need curl ''
  need tar ''
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

json_field() {
  node -p 'require(require("path").resolve(process.argv[1]))[process.argv[2]]' "$1" "$2" 2>/dev/null
}

is_nanoclaw() {
  [ -f "$1/package.json" ] && [ -f "$1/setup/lib/restart.sh" ] && [ -x "$1/bin/ncl" ] &&
    [ "$(json_field "$1/package.json" name)" = nanoclaw ]
}

# Fills found once with the NanoClaw checkouts in the usual places, resolved and without repeats.
scan_checkouts() {
  local dir seen
  [ "$scanned" = 1 ] && return 0
  scanned=1
  for dir in "$PWD" "$HOME"/nanoclaw* "$HOME"/*/nanoclaw*; do
    [ -d "$dir" ] && is_nanoclaw "$dir" || continue
    dir="$(cd "$dir" && pwd -P)"
    for seen in ${found[@]+"${found[@]}"}; do [ "$seen" = "$dir" ] && continue 2; done
    found+=("$dir")
  done
}

# --runtime or --dir decides; otherwise the one runtime found, and a question when both are.
choose_runtime() {
  local nano=0 open=0
  if [ -n "$runtime" ]; then
    case "$runtime" in
      nanoclaw | openclaw) return 0 ;;
      *) die "--runtime is nanoclaw or openclaw, not $runtime." ;;
    esac
  fi
  if [ -n "$dir_arg" ]; then
    runtime=nanoclaw
    return 0
  fi
  scan_checkouts
  [ "${#found[@]}" -gt 0 ] && nano=1
  command -v openclaw >/dev/null 2>&1 && open=1
  if [ "$nano" = 1 ] && [ "$open" = 1 ]; then
    case "$(ask 'NanoClaw and OpenClaw are both on this machine. Which one gets Wizzle? (nanoclaw/openclaw)')" in
      nanoclaw | NanoClaw | n) runtime=nanoclaw ;;
      openclaw | OpenClaw | o) runtime=openclaw ;;
      *) die 'Answer nanoclaw or openclaw, or pass --runtime.' ;;
    esac
  elif [ "$open" = 1 ]; then
    runtime=openclaw
  else
    # Nothing found asks for a NanoClaw path, as before; an OpenClaw install is always on PATH.
    runtime=nanoclaw
  fi
}

find_root() {
  local dir i=0 choice
  if [ -n "$dir_arg" ]; then
    dir="${dir_arg/#\~/$HOME}"
  else
    scan_checkouts
    # Never picks one by itself: the user chooses from the list or types a path.
    if [ "${#found[@]}" -gt 0 ]; then
      note 'NanoClaw checkouts found on this machine:'
      for dir in "${found[@]}"; do
        i=$((i + 1))
        note "  $i) $dir"
      done
      choice="$(ask 'Type a number from the list, or the path to your NanoClaw checkout')"
    else
      note 'No NanoClaw checkout found in the current directory, ~/nanoclaw* or ~/*/nanoclaw*, and no openclaw command on PATH.'
      note 'For OpenClaw, install it first (https://docs.openclaw.ai/install) and run wizzle.sh again.'
      choice="$(ask 'Path to your NanoClaw checkout')"
    fi
    case "$choice" in
      '' | *[!0-9]*) dir="${choice/#\~/$HOME}" ;;
      *)
        [ "$choice" -ge 1 ] && [ "$choice" -le "${#found[@]}" ] || die "$choice is not a number from the list."
        dir="${found[$((10#$choice - 1))]}"
        ;;
    esac
  fi
  [ -n "$dir" ] && is_nanoclaw "$dir" ||
    die "No NanoClaw checkout at '$dir'. Wizzle needs NanoClaw installed first: https://docs.nanoclaw.dev/quickstart"
  root="$(cd "$dir" && pwd -P)"
}

# NanoClaw runs as the user that owns the checkout; anyone else would leave files NanoClaw cannot change.
check_owner() {
  [ -O "$root" ] && return 0
  die "$root belongs to $(ls -ld "$root" | awk '{ print $3 }'). Run wizzle.sh as that user, without sudo."
}

# The core patch is applied with git apply, so $root has to be the top of its git checkout.
check_git_root() {
  [ "$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" = "$root" ] ||
    die "$root is not the top of a git checkout, which NanoClaw's updater needs."
}

installed_version() {
  grep -qxF "$BARREL_LINE" "$root/$BARREL" 2>/dev/null || return 0
  cat "$root/.claude/skills/add-wizzle/VERSION" 2>/dev/null || printf 'unknown'
}

# Downloads $2-<version>$3 from $1 into $work and checks its SHA-256; sets bundle_version and archive.
fetch_checked() {
  local base="$1" name expected
  bundle_version="$want_version"
  if [ -z "$bundle_version" ]; then
    bundle_version="$(curl -fsSL "$base/latest" | tr -d '[:space:]')" || die "Could not reach $base."
  fi
  [[ "$bundle_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "'$bundle_version' is not a Wizzle version."
  name="$2-$bundle_version$3"
  archive="$work/$name"
  curl -fsSL "$base/$name" -o "$archive" || die "Could not download Wizzle $bundle_version for $(runtime_name)."
  expected="$(curl -fsSL "$base/$name.sha256" | cut -d' ' -f1)" || die "Could not download the checksum of Wizzle $bundle_version."
  [ "$(sha256 "$archive")" = "$expected" ] || die "Wizzle $bundle_version does not match its checksum; nothing was installed."
}

fetch_bundle() {
  fetch_checked "$DIST_URL" wizzle-nanoclaw .tar.gz
  tar -xzf "$archive" -C "$work"
  bundle="$work/wizzle-nanoclaw-$bundle_version"
  [ -f "$bundle/skills/add-wizzle/SKILL.md" ] && [ -f "$bundle/skills/add-wizzle-core/REMOVE.md" ] &&
    [ -d "$bundle/patches" ] && [ "$(cat "$bundle/VERSION" 2>/dev/null)" = "$bundle_version" ] ||
    die "Wizzle $bundle_version is incomplete."
}

# Only a NanoClaw version with a patch in the bundle is supported; nothing is guessed.
select_patch() {
  local current supported
  current="$(json_field "$root/package.json" version)"
  patch="$bundle/patches/$current.patch"
  [ -f "$patch" ] && return 0
  supported="$(ls "$bundle/patches" | sed 's/\.patch$//' | paste -s -d, -)"
  die "Wizzle $bundle_version supports NanoClaw ${supported:-(none)}; this checkout runs $current. Nothing was changed."
}

# Decides before anything changes: apply the patch, keep it, or swap an older installed one.
plan_core() {
  local installed="$root/$CORE_PATCH"
  if git -C "$root" apply --check "$patch" 2>/dev/null; then
    core_step=apply
  elif git -C "$root" apply -R --check "$patch" 2>/dev/null; then
    core_step=present
  elif [ -f "$installed" ] && git -C "$root" apply -R --check "$installed" 2>/dev/null; then
    core_step=swap
  else
    git -C "$root" apply --check "$patch" 2>&1 | sed 's/^/  /' >&2 || true
    fail "The Wizzle core changes do not apply to this checkout; the files above differ from NanoClaw $(json_field "$root/package.json" version). Nothing was changed."
  fi
}

apply_core() {
  case "$core_step" in
    apply) git -C "$root" apply "$patch" || fail 'Applying the core changes failed.' ;;
    present) note 'The core changes are already in place.' ;;
    swap)
      git -C "$root" apply -R "$root/$CORE_PATCH" || fail 'Removing the older core changes failed.'
      git -C "$root" apply "$patch" || fail 'Applying the new core changes failed.'
      ;;
  esac
}

# Copies what the add-wizzle skill's copy and append steps would, from the same skill folder.
copy_payload() {
  local skill="$bundle/skills/add-wizzle"
  cp -R "$skill/src/." "$root/src/"
  cp -R "$skill/container/." "$root/container/"
  cp "$bundle/skills/add-wizzle-core/$PAUSE_TEST" "$root/$PAUSE_TEST"
  grep -qxF "$BARREL_LINE" "$root/$BARREL" || append_line "$root/$BARREL" "$BARREL_LINE"
}

# The old payload goes first, so nothing a previous version shipped stays behind.
remove_payload() {
  local path
  for path in $PAYLOAD; do rm -rf "${root:?}/$path"; done
  rm -f "$root"/src/channels/wizzle-*.test.ts
}

# Keeps a relay URL the user already set.
set_relay() {
  local env="$root/.env"
  grep -q '^WIZZLE_RELAY_URL=' "$env" 2>/dev/null && return 0
  [ -f "$env" ] || (umask 077 && : >"$env")
  append_line "$env" "WIZZLE_RELAY_URL=$RELAY_URL"
}

# NanoClaw's updater refreshes the channel from .claude/skills/add-wizzle, so the skills stay in the checkout.
place_skills() {
  local skill
  mkdir -p "$root/.claude/skills"
  for skill in $SKILLS; do
    rm -rf "${root:?}/.claude/skills/$skill"
    cp -R "$bundle/skills/$skill" "$root/.claude/skills/$skill"
  done
  cp "$bundle/VERSION" "$root/.claude/skills/add-wizzle/VERSION"
  cp "$patch" "$root/$CORE_PATCH"
}

check_build() {
  say 'Building and running the Wizzle tests.'
  (cd "$root" && pnpm run build) || fail 'The build fails.'
  (cd "$root" && pnpm exec vitest run src/channels/wizzle "$PAUSE_TEST") || fail 'The Wizzle tests fail.'
}

# Prints the files a core patch touches, from its --- a/ and +++ b/ lines.
patch_paths() {
  sed -n -e 's#^--- a/##p' -e 's#^+++ b/##p' "$1"
}

# Prints each path the run ($1: install or uninstall) changes once, relative to $root, leaving out paths inside another.
backup_paths() {
  local path
  {
    printf '%s\n' $PAYLOAD .env "$BARREL" "$PAUSE_TEST"
    for path in $SKILLS; do printf '.claude/skills/%s\n' "$path"; done
    for path in "$root"/src/channels/wizzle-*.test.ts; do [ ! -e "$path" ] || printf '%s\n' "${path#"$root"/}"; done
    if [ "$1" = install ]; then
      (cd "$bundle/skills/add-wizzle" && find src container -type f)
      patch_paths "$patch"
    fi
    [ ! -f "$root/$CORE_PATCH" ] || patch_paths "$root/$CORE_PATCH"
  } | LC_ALL=C sort -u | awk '{ for (d in kept) if (index($0, d "/") == 1) next; kept[$0] = 1; print }'
}

# Copies each path the run changes, as it is now, into a git-ignored folder in the checkout that is never deleted.
# The manifest marks each path saved, or absent so the undo deletes what the run created.
backup_files() {
  local list path
  list="$(backup_paths "$1")" || die 'Could not list the files to back up. Nothing was changed.'
  backup="$root/.tmp-wizzle-backup-$(date -u +%Y%m%dT%H%M%SZ)"
  say "Backing up the files this run changes to $backup."
  (umask 077 && mkdir "$backup" "$backup/files") || die "Could not create $backup. Nothing was changed."
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ -e "$root/$path" ] || [ -L "$root/$path" ]; then
      mkdir -p "$backup/files/$(dirname "$path")" && cp -Rp "$root/$path" "$backup/files/$path" ||
        die "Could not back up $path into $backup. Nothing was changed."
      printf 'saved %s\n' "$path" >>"$backup/manifest"
    else
      printf 'absent %s\n' "$path" >>"$backup/manifest"
    fi
  done <<<"$list"
}

# Writes the channels helper: lists, takes off and puts back the agents' channels other than Wizzle and the terminal.
write_channels_helper() {
  cat >"$work/channels.mjs" <<'EOF'
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const [mode, root, file] = process.argv.slice(2);
const KEPT = new Set(['wizzle', 'cli']);

function ncl(...args) {
  try {
    return JSON.parse(execFileSync(path.join(root, 'bin/ncl'), [...args, '--json'], { cwd: root, encoding: 'utf8' })).data;
  } catch (err) {
    const answer = err.stdout ? JSON.parse(err.stdout) : null;
    throw new Error(`ncl ${args.join(' ')}: ${answer?.error?.message ?? err.message}`);
  }
}

const chats = new Map(ncl('messaging-groups', 'list', '--limit', '100000').map((g) => [g.id, g]));
const agents = new Map(ncl('groups', 'list', '--limit', '100000').map((g) => [g.id, g.name]));
const other = (chatId) => chats.has(chatId) && !KEPT.has(chats.get(chatId).channel_type);
const line = (agentId, chatId) => `  ${agents.get(agentId) ?? agentId}: ${chats.get(chatId).channel_type} ${chats.get(chatId).name ?? chatId}`;

if (mode === 'list' || mode === 'only') {
  const wirings = ncl('wirings', 'list', '--limit', '100000');
  // Only an agent that already has its Wizzle conversation loses its other channels.
  const onWizzle = new Set(wirings.filter((w) => chats.get(w.messaging_group_id)?.channel_type === 'wizzle').map((w) => w.agent_group_id));
  const off = wirings.filter((w) => onWizzle.has(w.agent_group_id) && other(w.messaging_group_id));
  for (const w of off) console.log(line(w.agent_group_id, w.messaging_group_id));
  if (mode === 'list') process.exit(0);
  const dests = ncl('destinations', 'list').filter((d) => onWizzle.has(d.agent_group_id) && d.target_type === 'channel' && other(d.target_id));
  // Saved before anything goes, so uninstall can put back even a half finished run.
  const saved = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : { wirings: [], destinations: [] };
  saved.wirings.push(...off);
  saved.destinations.push(...dests);
  fs.writeFileSync(file, `${JSON.stringify(saved, null, 2)}\n`, { mode: 0o600 });
  for (const d of dests) ncl('destinations', 'remove', '--agent-group-id', d.agent_group_id, '--local-name', d.local_name);
  for (const w of off) ncl('wirings', 'delete', w.id);
}

if (mode === 'restore') {
  const saved = JSON.parse(fs.readFileSync(file, 'utf8'));
  const names = new Set(ncl('destinations', 'list').map((d) => `${d.agent_group_id} ${d.local_name}`));
  // Destinations go first: a wiring only adds one for a chat the agent has none for, under a new name.
  for (const d of saved.destinations) {
    if (names.has(`${d.agent_group_id} ${d.local_name}`)) continue;
    ncl('destinations', 'add', '--agent-group-id', d.agent_group_id, '--local-name', d.local_name, '--target-type', 'channel', '--target-id', d.target_id);
  }
  for (const w of saved.wirings) {
    const args = ['wirings', 'create', '--messaging-group-id', w.messaging_group_id, '--agent-group-id', w.agent_group_id];
    for (const key of ['engage_mode', 'engage_pattern', 'sender_scope', 'ignored_message_policy', 'session_mode', 'threads', 'priority']) {
      if (w[key] !== null && w[key] !== undefined) args.push(`--${key.replace(/_/g, '-')}`, String(w[key]));
    }
    ncl(...args);
    console.log(line(w.agent_group_id, w.messaging_group_id));
  }
  fs.rmSync(file);
}
EOF
}

channels() {
  (cd "$root" && node "$work/channels.mjs" "$1" "$root" "$root/$SAVED_CHANNELS")
}

# Asks only when the agents have other channels and Wizzle has not taken any off before.
choose_channels() {
  local others
  only=0
  [ -f "$root/$SAVED_CHANNELS" ] && return 0
  others="$(channels list)" || fail 'Could not read the channels of this install.'
  [ -n "$others" ] || return 0
  note 'Your agents are also reachable here:'
  printf '%s\n' "$others"
  note 'The terminal chat stays either way.'
  case "$(ask 'Reach your agents only through Wizzle, or alongside these channels? (only/alongside)' alongside)" in
    only | Only | o) only=1 ;;
  esac
}

# Watches the pairing the bridge writes, until the app scans the code or the code expires.
wait_paired() {
  local file="$root/$PAIRING" expires
  grep -q '"wizzleKey"' "$file" 2>/dev/null && return 0
  expires="$(json_field "$file" expiresAt)" || expires=0
  case "$expires" in '' | *[!0-9]*) expires=0 ;; esac
  note 'Waiting for the Wizzle app to scan the code.'
  while [ "$(date +%s)" -lt "$expires" ]; do
    sleep 2
    grep -q '"wizzleKey"' "$file" 2>/dev/null && return 0
  done
  return 1
}

# The other channels come off only once Wizzle is paired, so the agents are never out of reach.
pair_and_route() {
  choose_channels
  pair_wizzle
  [ "$only" = 1 ] || return 0
  if wait_paired; then
    say 'Wizzle is paired. Taking these channels off your agents:'
    channels only || fail 'Could not take every channel off. wizzle.sh --uninstall puts back what was taken off.'
  else
    note 'The code expired before the app scanned it, so your agents keep their other channels. Run wizzle.sh again to pair.'
  fi
}

restart_service() {
  say 'Restarting NanoClaw.'
  restarted=1
  (cd "$root" && bash setup/lib/restart.sh) || fail "NanoClaw did not come back up. Its log is $root/logs/nanoclaw.log."
}

# A reinstall keeps the Wizzle user and its role; roles grant would add a second global owner row.
grant_owner() {
  local name user='' current='' owners
  if user="$(cd "$root" && ./bin/ncl users get "$OWNER_ID" --json 2>/dev/null)"; then
    current="$(printf '%s' "$user" | node -p 'JSON.parse(require("fs").readFileSync(0, "utf8")).data.display_name ?? ""')"
  else
    user=''
  fi
  name="$(ask 'Your name, shown on approvals' "${current:-$(id -un)}")"
  if [ -n "$user" ]; then
    (cd "$root" && ./bin/ncl users update "$OWNER_ID" --display-name "$name" >/dev/null) ||
      fail 'Could not rename the Wizzle user.'
  else
    (cd "$root" && ./bin/ncl users create --id "$OWNER_ID" --kind wizzle --display-name "$name" >/dev/null) ||
      fail 'Could not create the Wizzle user.'
  fi
  owners="$(cd "$root" && ./bin/ncl roles list --user-id "$OWNER_ID" --role owner --json |
    node -p 'JSON.parse(require("fs").readFileSync(0, "utf8")).data.length')" ||
    fail 'Could not read the roles of this install.'
  [ "$owners" -gt 0 ] && return 0
  (cd "$root" && ./bin/ncl roles grant --user "$OWNER_ID" --role owner >/dev/null) ||
    fail 'Could not make Wizzle the owner of this install.'
}

wizzle_cli() {
  if [ "$runtime" = openclaw ]; then
    openclaw wizzle "$@"
  else
    (cd "$root" && ./bin/ncl wizzle "$@")
  fi
}

pair_wizzle() {
  local out
  say 'Pair Wizzle: in the Wizzle app choose Pair, then scan this code.'
  if out="$(wizzle_cli pair 2>&1)"; then
    printf '%s\n' "$out"
    return 0
  fi
  case "$out" in
    *'already paired'*)
      if confirm 'Wizzle is already paired. Unpair it and pair again?' n; then
        wizzle_cli pair --replace || fail 'Pairing failed.'
      fi
      ;;
    *) printf '%s\n' "$out" >&2 && fail 'Pairing failed.' ;;
  esac
}

install() {
  local to
  from="$(installed_version)"
  fetch_bundle
  select_patch
  to="$bundle_version"
  if [ "$from" = "$to" ]; then
    say "Wizzle $to is already installed in $root."
    write_result 1 "Wizzle $to is already installed."
    confirm 'Pair Wizzle now?' n && pair_and_route
    return 0
  fi
  plan_core
  if [ -n "$from" ]; then
    say "Updating Wizzle $from to $to in $root."
  else
    say "Installing Wizzle $to into $root."
  fi
  confirm 'Continue?' y || exit 0
  backup_files install
  changed=1
  [ -n "$from" ] && remove_payload
  apply_core
  copy_payload
  set_relay
  place_skills
  check_build
  write_result 1 "Wizzle updated from $from to $to. The files as they were before are in $backup."
  restart_service
  changed=0
  if [ -z "$from" ]; then
    grant_owner
    pair_and_route
  elif confirm 'Pair Wizzle now?' n; then
    pair_and_route
  fi
  say "Wizzle $to is installed."
  note "The files as they were before this run are in $backup."
}

uninstall() {
  local installed="$root/$CORE_PATCH" skill
  [ -n "$(installed_version)" ] || die "Wizzle is not installed in $root."
  [ -f "$installed" ] ||
    fail "$CORE_PATCH is missing from $root, so the Wizzle core changes cannot be reversed automatically. .claude/skills/add-wizzle-core/REMOVE.md lists them. Nothing was changed."
  if ! git -C "$root" apply -R --check "$installed" 2>/dev/null; then
    fail "The Wizzle core changes in $root changed after they were installed, most likely in a NanoClaw update, so they cannot be reversed automatically. .claude/skills/add-wizzle-core/REMOVE.md lists them. Nothing was changed."
  fi
  confirm "Remove Wizzle from $root?" n || exit 0
  if [ -f "$root/$SAVED_CHANNELS" ] && confirm 'Put back the channels Wizzle took off your agents?' y; then
    say 'Putting back:'
    channels restore || fail 'Could not put every channel back; the rest are listed in data/wizzle/removed-channels.json. Nothing else was changed.'
  fi
  backup_files uninstall
  changed=1
  remove_payload
  rm -f "${root:?}/$PAUSE_TEST"
  drop_line "$root/$BARREL" -xF "$BARREL_LINE"
  drop_line "$root/.env" -G '^WIZZLE_RELAY_URL='
  git -C "$root" apply -R "$installed" || fail 'Reversing the core changes failed.'
  for skill in $SKILLS; do rm -rf "${root:?}/.claude/skills/$skill"; done
  say 'Building to confirm.'
  (cd "$root" && pnpm run build) || fail 'The build fails.'
  restart_service
  changed=0
  if [ -d "$root/data/wizzle" ] && confirm 'Also delete the pairing data in data/wizzle?' n; then
    # The list of channels Wizzle took off stays: it is the only record of them.
    find "$root/data/wizzle" -mindepth 1 -maxdepth 1 ! -name "${SAVED_CHANNELS##*/}" -exec rm -rf {} +
    if [ -f "$root/$SAVED_CHANNELS" ]; then note "Kept $SAVED_CHANNELS, the list of channels Wizzle took off your agents."; fi
  fi
  say 'Wizzle is removed. Remove this install from the Wizzle app too.'
  note "The files as they were before this run are in $backup."
}

oc_version() {
  openclaw --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

# True when $1 is the same as or newer than $2.
version_at_least() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# Plugin changes apply to the running Gateway, and pairing talks to it, so it has to be up.
oc_check_gateway() {
  openclaw gateway call health >/dev/null 2>&1 ||
    die 'The OpenClaw Gateway is not running. Start it (openclaw gateway start, or openclaw gateway run) and run wizzle.sh again.'
}

oc_installed_version() {
  local list
  list="$(openclaw plugins list --json 2>/dev/null)" || die 'Could not list the OpenClaw plugins (openclaw plugins list).'
  printf '%s' "$list" | node -e '
let raw = "";
process.stdin.on("data", (chunk) => (raw += chunk)).on("end", () => {
  const start = raw.indexOf("{");
  const list = start < 0 ? {} : JSON.parse(raw.slice(start));
  const plugin = (list.plugins ?? []).find((entry) => entry.id === process.argv[1]);
  process.stdout.write(plugin?.version ?? "");
});' "$OC_PLUGIN"
}

# The OpenClaw bundle is the plugin's npm pack archive; its package.json names the oldest OpenClaw it runs on.
oc_fetch_bundle() {
  fetch_checked "$OC_DIST_URL" wizzle-openclaw .tgz
  bundle="$archive"
  mkdir -p "$work/meta"
  tar -xzf "$bundle" -C "$work/meta" package/package.json package/openclaw.plugin.json 2>/dev/null &&
    [ "$(json_field "$work/meta/package/package.json" version)" = "$bundle_version" ] || die "Wizzle $bundle_version is incomplete."
}

oc_check_support() {
  local have min
  have="$(oc_version)" || have=''
  min="$(node -p 'require(process.argv[1]).openclaw.compat.minGatewayVersion' "$work/meta/package/package.json" 2>/dev/null)"
  [ -n "$have" ] || die 'Could not read the OpenClaw version from openclaw --version.'
  version_at_least "$have" "$min" ||
    die "Wizzle $bundle_version needs OpenClaw $min or newer; this install runs $have. Update OpenClaw (openclaw update) first. Nothing was changed."
}

# Keeps a relay URL the user already set.
oc_configure() {
  local current
  current="$(openclaw config get channels.wizzle.relayUrl 2>/dev/null)" || current=''
  if [ -z "$current" ]; then
    openclaw config set channels.wizzle.relayUrl "$RELAY_URL" >/dev/null || fail 'Could not set channels.wizzle.relayUrl.'
  fi
  openclaw config set channels.wizzle.enabled true >/dev/null || fail 'Could not enable the Wizzle channel.'
}

oc_wait_channel() {
  local i
  for i in $(seq 1 30); do
    openclaw wizzle status >/dev/null 2>&1 && return 0
    sleep 1
  done
  fail 'The Wizzle channel did not start. openclaw logs shows why.'
}

oc_install() {
  local from to
  oc_fetch_bundle
  oc_check_support
  from="$(oc_installed_version)"
  to="$bundle_version"
  if [ "$from" = "$to" ]; then
    say "Wizzle $to is already installed in OpenClaw."
    confirm 'Pair Wizzle now?' n && pair_wizzle
    return 0
  fi
  if [ -n "$from" ]; then
    say "Updating Wizzle $from to $to in OpenClaw $(oc_version)."
  else
    say "Installing Wizzle $to into OpenClaw $(oc_version)."
  fi
  confirm 'Continue?' y || exit 0
  # --force only confirms the source, which this script downloaded and checked; OpenClaw still asks to accept the plugin's capabilities.
  openclaw plugins install "npm-pack:$bundle" --force </dev/tty || fail 'OpenClaw did not install the Wizzle plugin.'
  # A reinstall keeps the enabled: false an earlier uninstall left behind.
  openclaw plugins enable "$OC_PLUGIN" </dev/tty >/dev/null || fail 'OpenClaw did not enable the Wizzle plugin.'
  oc_configure
  oc_wait_channel
  if [ -z "$from" ] || confirm 'Pair Wizzle now?' n; then pair_wizzle; fi
  say "Wizzle $to is installed."
}

oc_uninstall() {
  local installed
  installed="$(oc_installed_version)"
  [ -n "$installed" ] || die 'Wizzle is not installed in OpenClaw.'
  confirm 'Remove Wizzle from OpenClaw?' n || exit 0
  if confirm 'Also unpair the Wizzle app, so the relay forgets this install?' y; then
    openclaw wizzle unpair || warn 'Could not unpair; remove this install from the Wizzle app too.'
  fi
  openclaw plugins uninstall "$OC_PLUGIN" --force </dev/tty || fail 'OpenClaw did not remove the Wizzle plugin.'
  say 'Wizzle is removed. Remove this install from the Wizzle app too.'
}

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --runtime) [ "$#" -ge 2 ] || die '--runtime needs nanoclaw or openclaw.'; runtime="$2"; shift ;;
      --dir) [ "$#" -ge 2 ] || die '--dir needs a path.'; dir_arg="$2"; shift ;;
      --version) [ "$#" -ge 2 ] || die '--version needs a version.'; want_version="$2"; shift ;;
      --yes) yes=1 ;;
      --uninstall) mode=uninstall ;;
      -h | --help) usage; exit 0 ;;
      *) die "Unknown option $1 (see --help)." ;;
    esac
    shift
  done
  if [ "$yes" != 1 ]; then
    { : </dev/tty; } 2>/dev/null || die 'wizzle.sh asks questions, so run it from a terminal, or pass --yes.'
  fi
  if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then
    die "wizzle.sh runs without sudo. Run it again as $SUDO_USER."
  fi
  choose_runtime
  check_tools
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  if [ "$runtime" = openclaw ]; then
    oc_check_gateway
    if [ "$mode" = uninstall ]; then oc_uninstall; else oc_install; fi
    return 0
  fi
  find_root
  check_owner
  check_git_root
  write_channels_helper
  if [ "$mode" = uninstall ]; then uninstall; else install; fi
}

# Called last, so a partly downloaded script runs nothing.
main "$@"
