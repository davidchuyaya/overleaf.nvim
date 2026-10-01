'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const SocketManager = require('../../node/socket');

function fixture() {
  const listeners = {};
  const emitted = [];
  const manager = new SocketManager('test_cookie', 'test_project', () => {});
  manager.socket = {
    on: (event, handler) => { listeners[event] = handler; },
    emit: (...args) => { emitted.push(args); },
    disconnect: () => {},
  };
  manager.connected = true;
  manager._setupEventHandlers();
  return { manager, listeners, emitted };
}

test('cursor updates use the browser event without waiting for an acknowledgement', () => {
  const { manager, emitted } = fixture();
  const position = { doc_id: 'doc_main', row: 2, column: 5 };
  assert.deepEqual(manager.updatePosition(position), {});
  assert.deepEqual(emitted, [['clientTracking.updatePosition', position]]);
  assert.equal(emitted[0].length, 2); // No callback / ACK timeout.
});

test('only protocol cursor fields are sent, and caller mutation cannot affect refreshes', () => {
  const { manager, emitted, listeners } = fixture();
  const position = { doc_id: 'doc_main', row: 1, column: 3, name: 'Do not spoof', id: 'fake' };
  manager.updatePosition(position);
  position.row = 99;
  emitted[0][1].id = 'server-added';
  listeners['clientTracking.refresh']();
  assert.deepEqual(emitted[1], ['clientTracking.updatePosition', { doc_id: 'doc_main', row: 1, column: 3 }]);
});

test('leaving the document clears its cursor and can be refreshed', () => {
  const { manager, emitted, listeners } = fixture();
  manager.updatePosition({ doc_id: null });
  listeners['clientTracking.refresh']();
  assert.deepEqual(emitted, [
    ['clientTracking.updatePosition', { doc_id: null }],
    ['clientTracking.updatePosition', { doc_id: null }],
  ]);
});

test('refresh requests do not emit after disconnection', () => {
  const { manager, emitted, listeners } = fixture();
  manager.updatePosition({ doc_id: 'doc_main', row: 0, column: 0 });
  manager.disconnect();
  listeners['clientTracking.refresh']();
  assert.equal(emitted.length, 1);
  assert.equal(manager.lastPosition, null);
  assert.throws(() => manager.updatePosition({ doc_id: null }), { code: 'NOT_CONNECTED' });
});

test('malformed cursor coordinates are rejected before reaching the server', () => {
  const { manager, emitted } = fixture();
  for (const position of [
    { doc_id: 'doc_main', row: -1, column: 0 },
    { doc_id: 'doc_main', row: 0, column: 1.5 },
    { doc_id: 'doc_main', row: 0 },
  ]) {
    assert.throws(() => manager.updatePosition(position), { code: 'INVALID_PARAM' });
  }
  assert.deepEqual(emitted, []);
});

test('connected users are fetched with an acknowledged snapshot request', async () => {
  const { manager } = fixture();
  const users = [{ client_id: 'other', first_name: 'Alice', cursorData: { doc_id: 'doc_main', row: 1, column: 2 } }];
  manager.socket.emit = (event, callback) => {
    assert.equal(event, 'clientTracking.getConnectedUsers');
    assert.equal(typeof callback, 'function');
    callback(null, users);
  };
  assert.deepEqual(await manager.getConnectedUsers(), { users });
});

test('snapshot errors propagate, and disconnected snapshots fail immediately', async () => {
  const { manager } = fixture();
  manager.socket.emit = (_, callback) => { callback({ message: 'lookup failed' }); };
  await assert.rejects(manager.getConnectedUsers(), { code: 'EMIT_ERROR', message: 'lookup failed' });
  manager.connected = false;
  await assert.rejects(manager.getConnectedUsers(), { code: 'NOT_CONNECTED' });
});
