---
name: add-wizzle-core
description: Core changes the Wizzle channel needs, message ids for adapters and agent group pause. wizzle.sh applies them as core.patch.
---

# Wizzle core changes

The Wizzle adapter (`/add-wizzle`) needs three changes in NanoClaw's core.
`wizzle.sh` applies them from `core.patch` in this folder, the patch for this
checkout's NanoClaw version, and removes them with the same patch. This file
describes the same changes for a checkout the patch does not fit, applied by
hand. Each is given by what it does and where, with reference code from the
NanoClaw version Wizzle is built on (`2026.10.1-rc.2`): apply every change by
its intent and keep the surrounding code as it is.

Check for each change first and skip it when it is already there (a re-run, or
an install that already carries it).

## Apply

### 1. Message ids in mailbox history

`MailboxHistoryMessage` in `src/mailbox/types.ts` gets the row id:

```ts
export interface MailboxHistoryMessage {
  id: string;
  timestamp: string;
  kind: string;
  content: string;
}
```

In `src/mailbox/sqlite/index.ts` both history reads select it:

- `getInboundHistory`: `SELECT id, timestamp, kind, content FROM messages_in ORDER BY seq DESC LIMIT ?`
- `getOutboundHistory`: `SELECT id, timestamp, kind, content FROM messages_out ORDER BY seq DESC LIMIT ?`

Any other mailbox backend in this checkout that implements these two reads
returns the id as well.

### 2. Message ids on delivery

`OutboundMessage` in `src/channels/adapter.ts`:

```ts
  id?: string; // messages_out row id, when the host passes one
```

`ChannelDeliveryAdapter.deliver` in `src/delivery.ts` takes one more optional
parameter after `instance`, and `deliverMessage` passes `msg.id` as that last
argument:

```ts
    /** The messages_out row id, for adapters that key messages by it. */
    messageId?: string,
```

`createChannelDeliveryAdapter().deliver` in `src/channels/channel-registry.ts`
takes the same trailing `messageId?: string` and hands it on only when defined:

```ts
      return adapter.deliver(platformId, threadId, {
        kind,
        content: JSON.parse(content),
        files,
        ...(messageId !== undefined && { id: messageId }),
      });
```

### 3. Agent group pause

A paused agent group keeps everything that arrives for it (messages from every
channel, due tasks) and runs it on resume.

**Migration.** Skip it when this checkout already has a migration that adds
`paused_at` to `agent_groups`. Otherwise create
`src/db/migrations/wizzle-agent-group-paused.ts`, with `version` one above the
highest built-in migration version:

```ts
import type { Migration } from './index.js';

// NULL means running; an ISO timestamp means paused since then, and nothing wakes the group.
export const migrationWizzleAgentGroupPaused: Migration = {
  version: 26,
  name: 'wizzle-agent-group-paused',
  async up(db) {
    await db.exec(`ALTER TABLE agent_groups ADD COLUMN paused_at TEXT;`);
  },
};
```

Import it in `src/db/migrations/index.ts` and append it as the last entry of
the `migrations` array. NanoClaw records applied migrations by `name`, so this
file never collides with a numbered migration that NanoClaw ships later.

In `src/db/schema.ts` (the reference copy of the schema) `agent_groups` gets
`paused_at TEXT -- NULL = running; set = paused, nothing wakes it` after
`created_at`.

**Type.** `AgentGroup` in `src/types.ts`:

```ts
  /** ISO time the group was paused, NULL while running. */
  paused_at?: string | null;
```

**Database.** In `src/db/agent-groups.ts`, after `updateAgentGroup`:

```ts
// Only stamps a running group, so a second pause keeps the first time; answers whether it changed.
export async function setAgentGroupPaused(id: string, paused: boolean): Promise<boolean> {
  const result = paused
    ? await getDb().run(
        'UPDATE agent_groups SET paused_at = ? WHERE id = ? AND paused_at IS NULL',
        new Date().toISOString(),
        id,
      )
    : await getDb().run('UPDATE agent_groups SET paused_at = NULL WHERE id = ? AND paused_at IS NOT NULL', id);
  return result.changes > 0;
}
```

**Router.** In `src/router.ts`, `routeInbound` collects the paused groups it
delivered to and logs them once, and `deliverToAgent` holds only the wake:

```ts
  const pausedGroups: string[] = [];
  // in the engaged branch, right after deliverToAgent(...) and engagedCount++:
      if (agentGroup.paused_at) pausedGroups.push(agentGroup.id);
  // after the loop over agents:
  if (pausedGroups.length > 0) {
    log.info('Message stored without wake, agent group paused', { agentGroupIds: pausedGroups });
  }
```

```ts
  // A paused group keeps the row as a pending trigger, so resume runs it; only the wake is held.
  if (wake && !agentGroup.paused_at) {
```

**Reconcile.** In `src/reconcile-session.ts`, `reconcileActiveSession` does not
wake a paused group:

```ts
      // A paused group keeps its due rows for resume, which reconciles each session again.
      shouldWake = dueCount > 0 && !isContainerRunning(session.id) && !agentGroup.paused_at;
```

**CLI.** In `src/cli/resources/groups.ts`, two operations next to `restart`
(imports: `isContainerRunning` from `../../container-runner.js`, `getAgentGroup`
and `setAgentGroupPaused` from `../../db/agent-groups.js`,
`getSessionsByAgentGroup` from `../../db/sessions.js`, `reconcileSession` from
`../../reconcile-session.js`):

```ts
    pause: {
      access: 'approval',
      description:
        'Pause a group. Use --id <group-id>. Stops every running container and keeps the group asleep: ' +
        'messages from any channel and due tasks accumulate and run on resume. Pausing a paused group changes nothing.',
      handler: async (args) => {
        const id = args.id as string;
        if (!id) throw new Error('--id is required');
        if (!(await getAgentGroup(id))) throw new Error(`Agent group not found: ${id}`);
        const changed = await setAgentGroupPaused(id, true);
        let stopped = 0;
        for (const session of await getSessionsByAgentGroup(id)) {
          if (!isContainerRunning(session.id)) continue;
          killContainer(session.id, 'paused via ncl');
          stopped++;
        }
        return { id, paused: changed, stopped };
      },
    },
    resume: {
      access: 'approval',
      description:
        'Resume a paused group. Use --id <group-id>. Each active session with work that accumulated while paused ' +
        'wakes once. Resuming a running group changes nothing.',
      handler: async (args) => {
        const id = args.id as string;
        if (!id) throw new Error('--id is required');
        if (!(await getAgentGroup(id))) throw new Error(`Agent group not found: ${id}`);
        const changed = await setAgentGroupPaused(id, false);
        let reconciled = 0;
        for (const session of await getSessionsByAgentGroup(id)) {
          if (session.status !== 'active') continue;
          await reconcileSession(session.id);
          reconciled++;
        }
        return { id, resumed: changed, reconciled };
      },
    },
```

### 4. Test and build

Copy the pause suite from this skill folder to the same path in the checkout:

```
src/agent-group-pause.test.ts
```

Then both of these pass:

```bash
pnpm run build
pnpm exec vitest run src/agent-group-pause.test.ts
```

When the suite fails because this checkout's core moved something it imports
(a renamed helper, a moved module), point the import at the new place and keep
every assertion.

## Remove

See `REMOVE.md`.
