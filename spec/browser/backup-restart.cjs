const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assert = require('node:assert/strict');
const origin = process.env.BACKUP_ORIGIN || 'https://127.0.0.1:45529';

(async () => {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    const context = await browser.newContext({ ignoreHTTPSErrors: true, storageState: 'tmp/backup-browser-state.json' });
    await context.addInitScript(() => sessionStorage.setItem('oxidized-backups', '["device-2"]'));
    const page = await context.newPage();
    await page.goto(origin + '/node/show/device-2');
    await page.locator('#backup-summary').filter({ hasText: 'Tracking unavailable' }).waitFor();
    assert.equal(await page.locator('.detail-card-revisions strong').innerText(), '1');
    const devices = await page.evaluate(async () => (await (await fetch('/admin/backups.json')).json()).devices);
    assert.ok(devices.every(device => device.state === 'not_requested'));
    assert.match(await page.locator('#backup-results').innerText(), /tracking unavailable after restart/);
    await page.screenshot({ path: 'tmp/backup-screenshots/after-restart.png' });
    console.log('PASS: restart loses transient queue tracking honestly and preserves Git history and authentication');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
