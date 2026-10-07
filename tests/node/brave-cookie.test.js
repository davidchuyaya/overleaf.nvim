'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// Isolate browser/Keychain access; no real credentials are read by these tests.
function fixture(options = {}) {
  const base = '/test/home/Library/Application Support/BraveSoftware/Brave-Browser';
  const tmp = '/test/tmp/overleaf_brave_cookies_fixture';
  const files = new Map([[base, ''], [base + '/Default/Cookies', 'database']]);
  const commands = [];
  const removed = [];
  let mode;
  const password = 'fixture-safe-storage-password';
  const value = options.value || 's%3Afixture-session.signature';
  const key = crypto.pbkdf2Sync(password, 'saltysalt', 1003, 16, 'sha1');
  const cipher = crypto.createCipheriv('aes-128-cbc', key, Buffer.alloc(16, ' '));
  const plaintext = Buffer.concat([
    options.hashPrefix ? crypto.createHash('sha256').update('.overleaf.com').digest() : Buffer.alloc(0),
    Buffer.from(value),
  ]);
  const encrypted = Buffer.concat([Buffer.from('v10'), cipher.update(plaintext), cipher.final()]);
  const mockFs = {
    existsSync: file => files.has(file),
    readdirSync: () => (options.entries || ['Default']).map(name => ({ name, isDirectory: () => true })),
    readFileSync: file => files.get(file),
    mkdtempSync: prefix => { assert.equal(prefix, '/test/tmp/overleaf_brave_cookies_'); return tmp; },
    chmodSync: (file, permissions) => { assert.equal(file, tmp + '/Cookies'); mode = permissions; },
    unlinkSync: file => removed.push(file),
    rmdirSync: file => removed.push(file),
  };
  const mockChild = {
    execFileSync: (file, args) => {
      commands.push({ file, args });
      if (file === 'security') {
        assert.deepEqual(Array.from(args), ['find-generic-password', '-w', '-s', 'Brave Safe Storage', '-a', 'Brave']);
        if (options.keychainError) throw new Error('confidential system error');
        return password + '\n';
      }
      assert.equal(file, 'sqlite3');
      assert.equal(args[0], '-readonly');
      if (args[2].startsWith('.backup')) {
        if (options.backupError) throw new Error('backup failed');
        return '';
      }
      return options.empty ? '' : 'overleaf_session2|' + encrypted.toString('hex') + '\n';
    },
  };
  const module = { exports: {} };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../../node/brave-cookie.js'), 'utf8'), {
    module, Buffer, URL,
    process: { env: options.url ? { OVERLEAF_URL: options.url } : {} },
    require: name => {
      if (name === 'fs') return mockFs;
      if (name === 'os') return { homedir: () => '/test/home', tmpdir: () => '/test/tmp', platform: () => options.platform || 'darwin' };
      if (name === 'child_process') return mockChild;
      return require(name);
    },
  });
  return { api: module.exports, files, base, tmp, commands, removed, mode: () => mode, value };
}

test('profiles come from Brave only, with legacy and Network cookie paths', () => {
  const f = fixture({ entries: ['Default', 'Profile 2', 'Profile 3', 'Profile bogus', 'System Profile'] });
  f.files.set(f.base + '/Default/Preferences', JSON.stringify({ profile: { name: 'Personal' } }));
  f.files.set(f.base + '/Profile 2/Network/Cookies', 'database');
  f.files.set(f.base + '/Profile 2/Preferences', '{broken json');
  assert.deepEqual(JSON.parse(JSON.stringify(f.api.listProfiles())), [
    { dir: 'Default', name: 'Personal', email: '' },
    { dir: 'Profile 2', name: 'Profile 2', email: '' },
  ]);
  assert.deepEqual(f.commands, []);
});

for (const hashPrefix of [false, true]) {
  test(`Brave Keychain decrypts a session ${hashPrefix ? 'with' : 'without'} a domain hash`, async () => {
    const f = fixture({ hashPrefix });
    assert.equal(await f.api.getOverleafCookie('Default'), 'overleaf_session2=' + f.value);
    assert.equal(f.commands[1].args[1], f.base + '/Default/Cookies');
    assert.match(f.commands[1].args[2], /^\.backup /);
    assert.equal(f.mode(), 0o600);
    assert.deepEqual(f.removed, [f.tmp + '/Cookies', f.tmp]);
    assert.match(f.commands[2].args[2], /host_key IN \('overleaf\.com', '\.overleaf\.com'\)/);
  });
}

test('Network cookie database takes priority when both locations exist', async () => {
  const f = fixture();
  f.files.set(f.base + '/Default/Network/Cookies', 'database');
  await f.api.getOverleafCookie();
  assert.equal(f.commands[1].args[1], f.base + '/Default/Network/Cookies');
});

test('self-hosted instances use the configured host and argument-safe SQLite', async () => {
  const f = fixture({ url: 'https://latex.example.test/project' });
  await f.api.getOverleafCookie();
  assert.match(f.commands[2].args[2], /host_key IN \('latex\.example\.test', '\.latex\.example\.test'\)/);
});

test('missing login and failed snapshots clean up private temporary files', async () => {
  for (const options of [{ empty: true }, { backupError: true }]) {
    const f = fixture(options);
    await assert.rejects(f.api.getOverleafCookie(), error => options.empty ? error.code === 'NO_COOKIE' : error.message === 'backup failed');
    assert.deepEqual(f.removed, [f.tmp + '/Cookies', f.tmp]);
  }
});

test('Keychain errors are sanitized and never fall back to Chrome', async () => {
  const f = fixture({ keychainError: true });
  await assert.rejects(f.api.getOverleafCookie(), error => error.code === 'KEYCHAIN_FAILED' && !error.message.includes('confidential'));
  assert.equal(f.commands.length, 1);
});

test('missing databases and invalid profile paths fail before Keychain access', async () => {
  const f = fixture();
  await assert.rejects(f.api.getOverleafCookie('../Chrome/Default'), error => error.code === 'INVALID_PROFILE');
  await assert.rejects(f.api.getOverleafCookie('Profile 7'), error => error.code === 'NOT_FOUND');
  f.files.delete(f.base);
  assert.throws(() => f.api.listProfiles(), error => error.code === 'NOT_FOUND');
  assert.deepEqual(f.commands, []);
});

test('automatic extraction remains macOS-only', async () => {
  const f = fixture({ platform: 'linux' });
  assert.throws(() => f.api.listProfiles(), error => error.code === 'UNSUPPORTED');
  await assert.rejects(f.api.getOverleafCookie(), error => error.code === 'UNSUPPORTED');
});

test('invalid decrypted values are rejected', async () => {
  const f = fixture({ value: 'not-an-overleaf-session' });
  await assert.rejects(f.api.getOverleafCookie(), error => error.code === 'DECRYPT_FAILED');
  assert.deepEqual(f.removed, [f.tmp + '/Cookies', f.tmp]);
});
