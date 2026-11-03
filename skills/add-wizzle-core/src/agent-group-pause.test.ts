// A paused agent group never wakes: routeInbound and the sweep both hold its work until groups-resume.
import fs from 'fs';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  initTestDb,
  closeDb,
  runMigrations,
  createAgentGroup,
  createMessagingGroup,
  createMessagingGroupAgent,
  getDb,
} from './db/index.js';
import { getAgentGroup } from './db/agent-groups.js';
import { getSessionsByAgentGroup } from './db/sessions.js';
import { initChannelAdapters, registerChannelAdapter, teardownChannelAdapters } from './channels/channel-registry.js';
import { isContainerRunning, killContainer, wakeContainer } from './container-runner.js';
import { reconcileSession } from './reconcile-session.js';
import { routeInbound } from './router.js';
import { withExistingMailboxSession, writeSessionMessage } from './session-manager.js';
import { dispatch } from './cli/dispatch.js';
import './cli/resources/groups.js';
import type { ChannelAdapter, ChannelDefaults } from './channels/adapter.js';

vi.mock('./container-runner.js', () => ({
  wakeContainer: vi.fn().mockResolvedValue(true),
  isContainerRunning: vi.fn().mockReturnValue(false),
  getActiveContainerCount: vi.fn().mockReturnValue(0),
  getContainerStartedAtMs: vi.fn().mockReturnValue(undefined),
  killContainer: vi.fn(),
  buildAgentGroupImage: vi.fn().mockResolvedValue(undefined),
}));

vi.mock('./config.js', async () => {
  const actual = await vi.importActual('./config.js');
  return { ...actual, DATA_DIR: '/tmp/nanoclaw-test-agent-group-pause' };
});

const TEST_DIR = '/tmp/nanoclaw-test-agent-group-pause';
const HOST = { caller: 'host' as const };

const channelDefaults: ChannelDefaults = {
  dm: { engageMode: 'pattern', engagePattern: '.', threads: true, unknownSenderPolicy: 'public' },
  group: { engageMode: 'mention-sticky', threads: true, unknownSenderPolicy: 'request_approval' },
  mentions: 'platform',
};

function now(): string {
  return new Date().toISOString();
}

function makeAdapter(): ChannelAdapter {
  return {
    name: 'testchat',
    channelType: 'testchat',
    supportsThreads: true,
    defaults: channelDefaults,
    setup: async () => {},
    teardown: async () => {},
    isConnected: () => true,
    deliver: async () => undefined,
  };
}

async function seed(): Promise<void> {
  registerChannelAdapter('testchat', { factory: () => makeAdapter(), defaults: channelDefaults });
  await initChannelAdapters(() => ({
    onInbound: () => {},
    onInboundEvent: () => {},
    onMetadata: () => {},
    onAction: () => {},
  }));
  await createAgentGroup({ id: 'ag-1', name: 'Test Agent', folder: 'test-agent', agent_provider: null, created_at: now() });
  await createMessagingGroup({
    id: 'mg-1',
    channel_type: 'testchat',
    platform_id: 'testchat:C1',
    instance: 'testchat',
    name: 'Test Chat',
    is_group: 0,
    unknown_sender_policy: 'public',
    created_at: now(),
  });
  await createMessagingGroupAgent({
    id: 'mga-1',
    messaging_group_id: 'mg-1',
    agent_group_id: 'ag-1',
    engage_mode: 'pattern',
    engage_pattern: '.',
    sender_scope: 'all',
    ignored_message_policy: 'drop',
    session_mode: 'shared',
    priority: 0,
    threads: 0,
    created_at: now(),
  });
}

async function inbound(id: string, text: string): Promise<void> {
  await routeInbound({
    channelType: 'testchat',
    platformId: 'testchat:C1',
    threadId: null,
    message: {
      id,
      kind: 'chat-sdk',
      content: JSON.stringify({ sender: 'Alex', senderId: 'U1', text }),
      timestamp: now(),
      isMention: true,
      isGroup: false,
    },
  });
}

function command(name: string) {
  return dispatch({ id: 'test', command: name, args: { id: 'ag-1' } }, HOST);
}

async function onlySession(): Promise<string> {
  const sessions = await getSessionsByAgentGroup('ag-1');
  expect(sessions).toHaveLength(1);
  return sessions[0].id;
}

async function dueCount(sessionId: string): Promise<number> {
  let count = 0;
  await withExistingMailboxSession('ag-1', sessionId, async (mailbox) => {
    count = mailbox.countDueMessages();
    return true;
  });
  return count;
}

beforeEach(async () => {
  if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true });
  fs.mkdirSync(TEST_DIR, { recursive: true });
  await runMigrations(await initTestDb());
  vi.mocked(wakeContainer).mockClear();
  vi.mocked(killContainer).mockClear();
  vi.mocked(isContainerRunning).mockReturnValue(false);
  await seed();
});

afterEach(async () => {
  await teardownChannelAdapters();
  await closeDb();
  if (fs.existsSync(TEST_DIR)) fs.rmSync(TEST_DIR, { recursive: true });
});

describe('agent group pause', () => {
  it('the pause migration adds paused_at, NULL for existing groups', async () => {
    const columns = await getDb().all<{ name: string }>('PRAGMA table_info(agent_groups)');
    expect(columns.map((column) => column.name)).toContain('paused_at');
    expect((await getAgentGroup('ag-1'))?.paused_at).toBeNull();
  });

  it('routeInbound stores a message for a paused group as a pending trigger without waking it', async () => {
    await inbound('m-0', 'first');
    expect(wakeContainer).toHaveBeenCalledTimes(1);
    vi.mocked(wakeContainer).mockClear();

    await command('groups-pause');
    await inbound('m-1', 'while paused');
    expect(wakeContainer).not.toHaveBeenCalled();
    expect(await dueCount(await onlySession())).toBe(2);
  });

  it('the sweep leaves due messages and a past due task alone while paused', async () => {
    await inbound('m-0', 'first');
    const sessionId = await onlySession();
    await command('groups-pause');
    vi.mocked(wakeContainer).mockClear();

    await writeSessionMessage('ag-1', sessionId, {
      id: 'task-1',
      kind: 'task',
      timestamp: now(),
      content: JSON.stringify({ prompt: 'check in' }),
      processAfter: new Date(Date.now() - 60_000).toISOString(),
    });
    await reconcileSession(sessionId);
    expect(wakeContainer).not.toHaveBeenCalled();
    expect(await dueCount(sessionId)).toBe(2);
  });

  it('resume wakes once for the whole backlog', async () => {
    await inbound('m-0', 'first');
    const sessionId = await onlySession();
    await command('groups-pause');
    await inbound('m-1', 'one');
    await inbound('m-2', 'two');
    await inbound('m-3', 'three');
    vi.mocked(wakeContainer).mockClear();

    const result = await command('groups-resume');
    expect(result).toMatchObject({ ok: true, data: { id: 'ag-1', resumed: true, reconciled: 1 } });
    expect(wakeContainer).toHaveBeenCalledTimes(1);
    expect(await dueCount(sessionId)).toBe(4);
    expect((await getAgentGroup('ag-1'))?.paused_at).toBeNull();
  });

  it('pause stops running containers, and a second pause keeps the first stamp and changes nothing', async () => {
    await inbound('m-0', 'first');
    vi.mocked(isContainerRunning).mockReturnValue(true);

    const first = await command('groups-pause');
    expect(first).toMatchObject({ ok: true, data: { paused: true, stopped: 1 } });
    expect(killContainer).toHaveBeenCalledTimes(1);
    const stamp = (await getAgentGroup('ag-1'))?.paused_at;
    expect(stamp).toBeTruthy();

    vi.mocked(isContainerRunning).mockReturnValue(false);
    const second = await command('groups-pause');
    expect(second).toMatchObject({ ok: true, data: { paused: false, stopped: 0 } });
    expect((await getAgentGroup('ag-1'))?.paused_at).toBe(stamp);

    await command('groups-resume');
    const again = await command('groups-resume');
    expect(again).toMatchObject({ ok: true, data: { resumed: false } });
  });
});
