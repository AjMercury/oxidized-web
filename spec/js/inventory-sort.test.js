const assert = require('node:assert/strict');
const fs = require('node:fs');
const test = require('node:test');
const vm = require('node:vm');

test('software version comparator sorts numeric components and unknown values deterministically', () => {
  const context = {
    Intl,
    window: { Intl },
    dayjs: { unix: () => ({ local: () => ({ format: () => '' }) }) },
    $: (callback) => {
      if (typeof callback === 'function') callback();
      return {
        each() {},
        click() {},
        on() {},
        removeClass() { return this; },
        addClass() { return this; },
        text() { return this; },
        always() { return this; }
      };
    }
  };
  context.$.fn = { dataTable: { ext: { type: { order: {} } } } };
  vm.runInNewContext(fs.readFileSync('lib/oxidized/web/public/scripts/oxidized.js', 'utf8'), context);

  const order = context.$.fn.dataTable.ext.type.order;
  assert.equal(order['version-sort-asc']('7.9', '7.15') < 0, true);
  assert.equal(order['version-sort-asc']('7.15', '7.24.5') < 0, true);
  assert.equal(order['version-sort-desc']('7.9', '7.15') > 0, true);
  assert.equal(order['version-sort-pre']('Unknown'), '');
  assert.equal(order['ip-sort-pre']('192.168.1.12') > order['ip-sort-pre']('192.168.1.2'), true);
  assert.equal(order['ip-sort-pre']('192.168.1.2') < order['ip-sort-pre']('192.168.1.12'), true);
});
