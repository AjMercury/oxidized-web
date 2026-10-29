const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(
  path.join(__dirname, '../../lib/oxidized/web/public/scripts/login.js'),
  'utf8'
);

function setup() {
  const listeners = {};
  const icon = { className: 'bi bi-eye' };
  const password = { type: 'password' };
  const toggle = {
    attributes: {},
    setAttribute(name, value) { this.attributes[name] = value; },
    addEventListener(name, callback) { listeners[`toggle:${name}`] = callback; },
    querySelector: () => icon
  };
  const submit = {
    disabled: false,
    classes: [],
    classList: { add: (name) => submit.classes.push(name) },
    setAttribute(name, value) { this[name] = value; }
  };
  const form = { addEventListener(name, callback) { listeners[`form:${name}`] = callback; } };
  const elements = { password, togglePassword: toggle, loginForm: form, loginSubmit: submit };
  const document = {
    addEventListener(name, callback) { listeners[`document:${name}`] = callback; },
    getElementById(id) { return elements[id] || null; }
  };
  vm.runInNewContext(source, { document });
  listeners['document:DOMContentLoaded']();
  return { listeners, icon, password, toggle, submit };
}

test('login password control toggles visibility and accessible label', () => {
  const { listeners, icon, password, toggle } = setup();
  listeners['toggle:click']();
  assert.equal(password.type, 'text');
  assert.equal(toggle.attributes['aria-pressed'], 'true');
  assert.equal(toggle.attributes['aria-label'], 'Hide password');
  assert.equal(icon.className, 'bi bi-eye-slash');
  listeners['toggle:click']();
  assert.equal(password.type, 'password');
  assert.equal(toggle.attributes['aria-pressed'], 'false');
});

test('login submission gives feedback and prevents duplicate submits', () => {
  const { listeners, submit } = setup();
  listeners['form:submit']();
  assert.equal(submit.disabled, true);
  assert.equal(submit.classes.includes('is-loading'), true);
  assert.equal(submit['aria-busy'], 'true');
});
