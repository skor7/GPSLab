import test from 'node:test';
import assert from 'node:assert/strict';
import { startServer, Client } from './helpers.js';
import { TicketService, TICKET_CATEGORIES, TICKET_STATUSES } from '../src/tickets.js';
import { AuditLog } from '../src/audit.js';
import { Notifier, ConsoleChannel } from '../src/notifications/channels.js';

function service() {
  const store = { tickets: new Map(), notifications: [], audit: [], touch() {} };
  const audit = new AuditLog({ store, now: () => 1 });
  const notifier = new Notifier({ store, now: () => 1, channels: [new ConsoleChannel()] });
  return { store, tickets: new TicketService({ store, now: () => 1, audit, notifier }) };
}

test('tickets are created with a category and status new', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    const general = await client.post('/api/tickets', { category: 'general', name: 'A', email: 'a@example.com', subject: 'Help', message: 'Body' });
    assert.equal(general.status, 201);
    assert.equal(general.body.status, 'new');
    const technical = await client.post('/api/tickets', { category: 'technical', name: 'B', email: 'b@example.com', subject: 'Idea', message: 'Nice' });
    assert.equal(technical.status, 201);
  } finally {
    await server.close();
  }
});

test('invalid ticket category or email is rejected with field errors', async () => {
  const server = await startServer();
  try {
    const client = new Client(server.baseUrl);
    const badCategory = await client.post('/api/tickets', { category: 'spam', name: 'A', email: 'a@example.com', subject: 's', message: 'm' });
    assert.equal(badCategory.status, 400);
    assert.ok(badCategory.body.fields.category);
    const badEmail = await client.post('/api/tickets', { category: 'general', name: 'A', email: 'nope', subject: 's', message: 'm' });
    assert.equal(badEmail.status, 400);
    assert.ok(badEmail.body.fields.email);
  } finally {
    await server.close();
  }
});

test('the status workflow only allows valid transitions', () => {
  const { tickets } = service();
  const ticket = tickets.create({ category: 'general', name: 'A', email: 'a@example.com', subject: 's', message: 'm' });
  assert.equal(ticket.status, 'new');
  assert.equal(tickets.updateStatus(ticket.id, 'reviewing').status, 'reviewing');
  assert.equal(tickets.updateStatus(ticket.id, 'answered').status, 'answered');
  assert.equal(tickets.updateStatus(ticket.id, 'closed').status, 'closed');
  assert.equal(tickets.updateStatus(ticket.id, 'new').status, 'new');
  assert.throws(() => tickets.updateStatus(ticket.id, 'invalid_status'), /status must be one of/);
  assert.throws(() => tickets.updateStatus('missing', 'closed'), /not found/);
});

test('the requested statuses and six categories are exactly declared', () => {
  assert.deepEqual([...TICKET_STATUSES], ['new', 'reviewing', 'answered', 'closed']);
  assert.equal(TICKET_CATEGORIES.length, 6);
  assert.deepEqual(
    [...TICKET_CATEGORIES],
    ['general', 'technical', 'billing', 'activation', 'suggestion', 'other']
  );
});

test('ticket creation is recorded in the audit log', () => {
  const { tickets, store } = service();
  tickets.create({ category: 'suggestion', name: 'A', email: 'a@example.com', subject: 's', message: 'm' });
  assert.ok(store.tickets.size === 1);
});
