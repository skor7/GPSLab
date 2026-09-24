import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Notifier, createChannels, ConsoleChannel, ConsoleEmailProvider, FileChannel } from '../src/notifications/channels.js';
import { Store } from '../src/store/store.js';
import { testConfig } from './helpers.js';

test('console channel is selected by default and records the notification', async () => {
  const store = new Store();
  const captured = [];
  const notifier = new Notifier({ store, now: () => 1, channels: createChannels({ config: testConfig(), sink: (entry) => captured.push(entry) }) });
  const entry = await notifier.notify({ to: 'a@example.com', subject: 'Hi', body: 'Body', template: 't' });
  assert.equal(captured.length, 1);
  assert.equal(entry.results[0].channel, 'console');
  assert.equal(entry.results[0].ok, true);
  assert.equal(store.notifications.length, 1);
});

test('email channel uses the console provider when no endpoint is configured', async () => {
  const config = testConfig({ NOTIFY_CHANNELS: 'email' });
  const channels = createChannels({ config });
  assert.equal(channels.length, 1);
  assert.equal(channels[0].name, 'email');
  assert.equal(channels[0].provider.name, 'console-email');
  const result = await channels[0].send({ to: 'a@example.com', subject: 's', body: 'b' });
  assert.equal(result.ok, true);
});

test('file channel appends JSONL without throwing', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mawqie-notify-'));
  const filePath = path.join(dir, 'notifications.log');
  const channel = new FileChannel({ filePath });
  const result = await channel.send({ to: 'a@example.com', subject: 's', body: 'b' });
  assert.equal(result.ok, true);
  const lines = fs.readFileSync(filePath, 'utf8').trim().split('\n');
  assert.equal(lines.length, 1);
  assert.equal(JSON.parse(lines[0]).to, 'a@example.com');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('a failing channel is recorded but never thrown', async () => {
  const store = new Store();
  const failing = { name: 'boom', send: async () => { throw new Error('channel down'); } };
  const notifier = new Notifier({ store, now: () => 1, channels: [failing, new ConsoleChannel()] });
  const entry = await notifier.notify({ to: 'a@example.com', subject: 's', body: 'b' });
  assert.equal(entry.results[0].ok, false);
  assert.equal(entry.results[0].error, 'Error');
  assert.equal(entry.results[1].ok, true);
});

test('channel selection is configurable and ignores unknown names', () => {
  const config = testConfig({ NOTIFY_CHANNELS: 'console, file, made-up' });
  const channels = createChannels({ config });
  assert.deepEqual(channels.map((channel) => channel.name), ['console', 'file']);
});

test('ConsoleEmailProvider reports success', async () => {
  const result = await new ConsoleEmailProvider().send({ to: 'a@example.com', subject: 's', text: 't' });
  assert.equal(result.ok, true);
});
