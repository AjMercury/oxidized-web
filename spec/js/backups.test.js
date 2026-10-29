const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

test('restored completed selection keeps polling another active device until its button can be enabled', async () => {
  const handlers = {};
  const timers = [];
  const button = { setAttribute() {} };
  const elements = {
    'backup-progress': { dataset: { endpoint: '/admin/backups.json', csrf: 'synthetic' }, hidden: true },
    'backup-summary': {},
    'backup-meter': {},
    'backup-results': { replaceChildren() {}, appendChild() {} }
  };
  const batches = [
    [{ name: 'done', state: 'succeeded' }, { name: 'busy', state: 'running' }],
    [{ name: 'done', state: 'succeeded' }, { name: 'busy', state: 'succeeded' }]
  ];
  const document = {
    addEventListener(name, handler) { handlers[name] = handler; },
    getElementById(id) { return elements[id] || null; },
    createElement() { return {}; },
    querySelectorAll(selector) {
      return selector.startsWith('form[') ? [{ action: '/node/next/busy', querySelector: () => button }] : [];
    }
  };
  const context = vm.createContext({
    document, sessionStorage: { getItem: () => '["done"]' },
    fetch: async () => ({ ok: true, headers: { get: () => 'application/json' }, json: async () => ({ devices: batches.shift() }) }),
    setTimeout(fn) { timers.push(fn); }, clearTimeout() {}, URLSearchParams
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../../lib/oxidized/web/public/scripts/backups.js'), 'utf8'), context);
  handlers.DOMContentLoaded();
  await new Promise(setImmediate);
  assert.equal(button.disabled, true);
  assert.equal(timers.length, 1);
  await timers.shift()();
  assert.equal(button.disabled, false);
  assert.equal(timers.length, 0);
});
