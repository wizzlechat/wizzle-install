# wizzle-install

The one command a user runs to put Wizzle on their agent runtime: NanoClaw or
OpenClaw, through the same script.

```bash
curl -fsSL https://wizzle.app/install.sh | bash
```

## What `wizzle.sh` does

Every install step runs in the script itself. Claude Code is help only, as in
NanoClaw's setup: typing `?` at a question opens it, and a failed step offers
it. Without Claude Code installed the script works the same.

It first picks the runtime: `--runtime nanoclaw|openclaw`, or NanoClaw when
`--dir` is given, or the one it finds (a NanoClaw checkout where step 1 looks,
an `openclaw` command on PATH), asking when both are there. With neither it
asks for a NanoClaw path as before.

### NanoClaw

1. Lists every NanoClaw checkout it finds (the current directory,
   `~/nanoclaw*`, `~/*/nanoclaw*`) and lets the user pick one by number or type
   a path; it never picks one by itself. `--dir` skips the question. It stops
   when the path is not a NanoClaw checkout.
2. Refuses to run under sudo or as anyone but the checkout's owner, the user
   NanoClaw runs as.
3. Downloads the latest bundle (or `--version`) and checks its SHA-256.
4. Picks `patches/<NanoClaw version>.patch` from the bundle and stops when
   there is none for this checkout's version: only versions with a patch are
   supported. Before changing anything it checks with `git apply --check`
   whether the patch applies, is already in place, or replaces an older
   installed one, and stops when none fits.
5. Applies the core changes (history ids, delivery ids, agent pause), copies
   the adapter, the bridge, the protocol and the agents' element skill from the
   `add-wizzle` skill folder, appends `import './wizzle.js';` to
   `src/channels/index.ts`, and sets `WIZZLE_RELAY_URL` in `.env` unless it is
   already set.
6. Places `add-wizzle` and `add-wizzle-core` (with the applied `core.patch`) in
   `.claude/skills/`; NanoClaw's updater refreshes the channel from there.
7. Runs `pnpm run build` and the Wizzle tests.
8. Restarts NanoClaw with `setup/lib/restart.sh`.
9. On a first install, makes `wizzle:owner` the install owner
   (`ncl users create`, `ncl roles grant`), then shows the pairing QR with
   `ncl wizzle pair`.
10. When the agents have other channels (anything but Wizzle and the terminal
    chat), asks whether they reach the user only through Wizzle or alongside
    them. "Only" waits until the app has scanned the code, saves those wirings
    and their destinations to `data/wizzle/removed-channels.json`, then takes
    them off; `--uninstall` offers to put them back as they were.

Running it again on an installed checkout updates to the newest bundle.
`--yes` answers every question with its default and needs no terminal; the
Wizzle app's Update button runs `wizzle.sh --dir <checkout> --yes` on the host
this way, and `--dir` is required for it. An update leaves its outcome in
`data/wizzle/update-result.json`, which the bridge shows in the app once the
host is back. `--uninstall` checks first that `core.patch` still reverses, then removes the
adapter, the barrel import, the relay URL and the core changes, and restarts.
Before the first change, install and uninstall back up every file they change
to `.tmp-wizzle-backup-<UTC time>/` in the checkout, which NanoClaw's
`.gitignore` ignores, and print its path; the backup is never deleted. When a
step fails after files changed, including the restart, it offers to undo them
from that backup.

### OpenClaw

1. Stops unless the OpenClaw Gateway answers (`openclaw gateway call health`),
   since plugin changes apply to the running Gateway and pairing talks to it.
2. Downloads the latest OpenClaw bundle (or `--version`), checks its SHA-256,
   and stops when this OpenClaw is older than the bundle's
   `openclaw.compat.minGatewayVersion`.
3. Installs it with `openclaw plugins install npm-pack:<bundle> --force` (the
   flag only confirms the source; OpenClaw still runs its capability review),
   then `openclaw plugins enable wizzle`, because a reinstall keeps the
   `enabled: false` an earlier uninstall leaves behind.
4. Sets `channels.wizzle.relayUrl` unless it is already set, and
   `channels.wizzle.enabled`, then waits for the channel to answer
   `openclaw wizzle status`.
5. On a first install shows the pairing QR with `openclaw wizzle pair`.

Running it again updates to the newest bundle and keeps the pairing; the same
version only offers to pair. `--uninstall` offers to unpair the app at the
relay (`openclaw wizzle unpair`), then runs `openclaw plugins uninstall wizzle`,
which also removes `channels.wizzle`. No restart, git or build is involved:
OpenClaw applies plugin changes live. The other-channels question is
NanoClaw only.

`WIZZLE_DIST_URL` (default `https://wizzle.app/dist/nanoclaw`),
`WIZZLE_OPENCLAW_DIST_URL` (default `https://wizzle.app/dist/openclaw`) and
`WIZZLE_RELAY_URL` (default `wss://relay.wizzle.app`) override the defaults;
`file://` works for the bundle URLs.
