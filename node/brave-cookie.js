'use strict';

const crypto = require('crypto');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { execFileSync } = require('child_process');

/**
 * Extract Overleaf session cookie from Brave on macOS.
 * Brave encrypts cookies using AES-128-CBC with a key derived from
 * the Keychain password via PBKDF2.
 */

const BRAVE_BASE_DIR = path.join(
  os.homedir(),
  'Library/Application Support/BraveSoftware/Brave-Browser'
);

function cookiesDatabase(profileDir) {
  if (typeof profileDir !== 'string' || !/^(Default|Profile \d+)$/.test(profileDir)) {
    throw { code: 'INVALID_PROFILE', message: 'Invalid Brave profile directory' };
  }
  const profilePath = path.join(BRAVE_BASE_DIR, profileDir);
  return [path.join(profilePath, 'Network', 'Cookies'), path.join(profilePath, 'Cookies')]
    .find(db => fs.existsSync(db));
}

/**
 * List available Brave profiles.
 * Returns array of { dir: 'Default', name: 'Person 1' }
 */
function listProfiles() {
  if (os.platform() !== 'darwin') {
    throw { code: 'UNSUPPORTED', message: 'Brave cookie extraction only supported on macOS' };
  }

  if (!fs.existsSync(BRAVE_BASE_DIR)) {
    throw { code: 'NOT_FOUND', message: 'Brave data directory not found' };
  }

  const profiles = [];
  const entries = fs.readdirSync(BRAVE_BASE_DIR, { withFileTypes: true });

  for (const entry of entries) {
    if (!entry.isDirectory()) continue;

    // Brave uses the same profile directory names as Chromium.
    if (!/^(Default|Profile \d+)$/.test(entry.name)) continue;

    if (!cookiesDatabase(entry.name)) continue;

    let displayName = entry.name;
    let email = '';
    try {
      const prefsPath = path.join(BRAVE_BASE_DIR, entry.name, 'Preferences');
      if (fs.existsSync(prefsPath)) {
        const prefs = JSON.parse(fs.readFileSync(prefsPath, 'utf-8'));
        // Try to get email from account_info
        if (prefs.account_info && Array.isArray(prefs.account_info) && prefs.account_info[0]) {
          email = prefs.account_info[0].email || '';
        }
        if (prefs.profile && prefs.profile.name) {
          displayName = email || prefs.profile.name;
        }
      }
    } catch (e) {
      // Use directory name as fallback
    }

    profiles.push({ dir: entry.name, name: displayName, email });
  }

  return profiles;
}

function getEncryptionKey() {
  let password;
  try {
    password = execFileSync('security', [
      'find-generic-password', '-w', '-s', 'Brave Safe Storage', '-a', 'Brave',
    ], { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  } catch (_) {
    throw { code: 'KEYCHAIN_FAILED', message: 'Cannot read Brave Safe Storage. Allow Keychain access or set a cookie manually.' };
  }

  return crypto.pbkdf2Sync(password, 'saltysalt', 1003, 16, 'sha1');
}

function decryptCookieValue(encryptedValue, key) {
  if (!encryptedValue || encryptedValue.length === 0) {
    return '';
  }

  const prefix = encryptedValue.slice(0, 3).toString('utf-8');
  if (prefix !== 'v10') {
    return encryptedValue.toString('utf-8');
  }

  const encrypted = encryptedValue.slice(3);
  const iv = Buffer.alloc(16, ' ');

  const decipher = crypto.createDecipheriv('aes-128-cbc', key, iv);
  let decrypted = decipher.update(encrypted);
  decrypted = Buffer.concat([decrypted, decipher.final()]);
  const raw = decrypted.toString('utf-8');

  // Skip any Chromium domain-hash prefix. Overleaf session cookies
  // contain 's%3A' (URL-encoded 's:' Express session prefix).
  const idx = raw.indexOf('s%3A');
  if (idx >= 0) {
    return raw.substring(idx);
  }

  return raw;
}

/**
 * Extract Overleaf cookie from a specific Brave profile.
 * @param {string} profileDir - Profile directory name (e.g. 'Default', 'Profile 1')
 */
async function getOverleafCookie(profileDir) {
  profileDir = profileDir || 'Default';

  if (os.platform() !== 'darwin') {
    throw { code: 'UNSUPPORTED', message: 'Brave cookie extraction only supported on macOS' };
  }

  const cookiesDb = cookiesDatabase(profileDir);
  if (!cookiesDb) {
    throw { code: 'NOT_FOUND', message: `Brave Cookies database not found for profile: ${profileDir}` };
  }

  const key = getEncryptionKey();

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'overleaf_brave_cookies_'));
  const tmpDb = path.join(tmpDir, 'Cookies');

  try {
    // SQLite's backup includes committed WAL changes while Brave is open.
    execFileSync('sqlite3', ['-readonly', cookiesDb, `.backup '${tmpDb.replace(/'/g, "''")}'`],
      { stdio: ['ignore', 'pipe', 'pipe'] });
    fs.chmodSync(tmpDb, 0o600);
    // Extract domain from OVERLEAF_URL for self-hosted instances
    let cookieDomain = 'overleaf.com';
    if (process.env.OVERLEAF_URL) {
      try {
        const parsedUrl = new URL(process.env.OVERLEAF_URL);
        cookieDomain = parsedUrl.hostname;
      } catch (e) { /* keep default */ }
    }
    const domain = cookieDomain.replace(/'/g, "''");
    const query = `SELECT name, hex(encrypted_value) FROM cookies WHERE host_key IN ('${domain}', '.${domain}') AND name = 'overleaf_session2' ORDER BY expires_utc DESC LIMIT 1;`;
    const result = execFileSync(
      'sqlite3', ['-readonly', tmpDb, query],
      { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'pipe'] }
    ).trim();

    if (!result) {
      throw { code: 'NO_COOKIE', message: 'No overleaf_session2 cookie found in Brave. Log in to Overleaf in Brave first.' };
    }

    const [name, hexValue] = result.split('|');
    if (!hexValue) {
      throw { code: 'NO_COOKIE', message: 'Cookie value is empty' };
    }

    const encryptedValue = Buffer.from(hexValue, 'hex');
    const value = decryptCookieValue(encryptedValue, key);

    if (!value || !value.startsWith('s%3A')) {
      throw { code: 'DECRYPT_FAILED', message: 'Failed to decrypt cookie. Try setting cookie manually.' };
    }

    return `${name}=${value}`;
  } finally {
    try { fs.unlinkSync(tmpDb); } catch (e) { /* ignore */ }
    try { fs.rmdirSync(tmpDir); } catch (e) { /* ignore */ }
  }
}

module.exports = { getOverleafCookie, listProfiles };
