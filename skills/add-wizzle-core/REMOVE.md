# Remove the Wizzle core changes

`wizzle.sh --uninstall` reverses `core.patch` on its own. These steps are for a
checkout where it no longer reverses, because a NanoClaw update changed those
lines. Remove the Wizzle adapter first, since it uses everything below. Every
step is safe to re-run.

1. **Pause.** Remove the `pause` and `resume` operations from
   `src/cli/resources/groups.ts` and the imports only they used, the
   `paused_at` checks in `src/router.ts` and `src/reconcile-session.ts`,
   `setAgentGroupPaused` from `src/db/agent-groups.ts`, and `paused_at` from
   `AgentGroup` in `src/types.ts` and from `src/db/schema.ts`.
2. **Migration.** Remove `src/db/migrations/wizzle-agent-group-paused.ts` and
   its import and entry in `src/db/migrations/index.ts`. The column stays in an
   existing database, because NanoClaw's migrations only go forward; nothing
   reads it once the code above is gone.
3. **Delivery ids.** Remove the trailing `messageId` parameter from
   `ChannelDeliveryAdapter.deliver` in `src/delivery.ts` and from
   `createChannelDeliveryAdapter().deliver` in `src/channels/channel-registry.ts`,
   the `msg.id` argument in `deliverMessage`, and `id` from `OutboundMessage` in
   `src/channels/adapter.ts`. Leave all of these when another installed channel
   uses them.
4. **History ids.** Remove `id` from `MailboxHistoryMessage` in
   `src/mailbox/types.ts` and from both history `SELECT`s in
   `src/mailbox/sqlite/index.ts`, unless another installed channel uses it.
5. **Test.** Delete `src/agent-group-pause.test.ts`.
6. **Build.** `pnpm run build` passes.
