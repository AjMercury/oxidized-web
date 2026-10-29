const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');

function renderTimeCells(cells) {
  const formatted = [];
  const $ = (target) => {
    if (target === '.time') {
      return {
        each(callback) {
          cells.forEach((cell) => callback.call(cell));
        }
      };
    }
    if (typeof target === 'function') return undefined;
    return {
      text(value) {
        if (value === undefined) return target.text;
        target.text = value;
        return this;
      },
      attr(name) { return target.attributes[name]; }
    };
  };
  const sandbox = {
    $, window: {},
    dayjs: { unix(value) { return { local() { return { format() { formatted.push(value); return `local-${value}`; } }; } }; } }
  };
  const source = fs.readFileSync(path.join(__dirname, '../../lib/oxidized/web/public/scripts/oxidized.js'), 'utf8');
  vm.runInNewContext(source, sandbox);
  sandbox.convertTime();
  return { cells, formatted };
}

test('does not turn an empty last-backup epoch into January 1, 1970', () => {
  const result = renderTimeCells([{ text: 'Not checked this session', attributes: { epoch: '' } }]);
  assert.deepEqual(result.formatted, []);
  assert.equal(result.cells[0].text, 'Not checked this session');
});

test('formats a valid positive backup epoch in local time', () => {
  const result = renderTimeCells([{ text: '2026-10-29', attributes: { epoch: '1793275200' } }]);
  assert.deepEqual(result.formatted, [1793275200]);
  assert.equal(result.cells[0].text, 'local-1793275200');
});
