const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const origin = process.env.BACKUP_ORIGIN || 'https://127.0.0.1:45529';
(async () => {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    const context = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1366, height: 768 } });
    const page = await context.newPage();
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    await page.goto(origin + '/login');
    await page.locator('#username').fill('fixture-admin');
    await page.locator('#password').fill('synthetic-password-123');
    await page.locator('#loginSubmit').click(); await page.waitForURL('**/nodes');
    await page.getByRole('button', { name: /Run configuration backup for device-1$/ }).click();
    await page.locator('#backup-summary').filter({ hasText: 'Succeeded 1' }).waitFor();
    await page.goto(origin + '/admin/devices');
    let confirmation;
    page.once('dialog', async dialog => { confirmation = dialog.message(); await dialog.accept(); });
    await page.getByRole('button', { name: 'Backup All Now', exact: true }).click();
    await page.locator('#backup-summary').filter({ hasText: 'Total 23' }).waitFor();
    assert.match(confirmation, /all 23 devices/);
    const duplicate = await page.evaluate(async () => {
      const endpoint = document.getElementById('backup-progress').dataset.endpoint;
      const headers = { 'X-CSRF-Token': document.getElementById('backup-progress').dataset.csrf };
      const a = await (await fetch(endpoint)).json();
      const b = await (await fetch(endpoint, { method: 'POST', headers, body: new URLSearchParams({ all: 'true' }) })).json();
      return a.devices.filter(n => ['queued', 'running'].includes(n.state)).every(n =>
        b.devices.find(x => x.name === n.name).requested_at === n.requested_at);
    });
    assert.equal(duplicate, true);
    await page.locator('#backup-summary').filter({ hasText: 'Completed 23' }).waitFor({ timeout: 30000 });
    assert.match(await page.locator('#backup-summary').innerText(), /Succeeded 22 · Failed 1/);
    assert.match(await page.locator('#backup-results').innerText(), /Connection could not be established/);
    await page.goto(origin + '/node/show/device-1');
    assert.equal(await page.locator('.detail-card-revisions strong').innerText(), '1', 'identical collections must not add a Git revision');
    fs.mkdirSync('tmp/backup-screenshots', { recursive: true });
    await page.screenshot({ path: 'tmp/backup-screenshots/desktop.png' });
    await page.goto(origin + '/admin/devices');
    // DataTables selection includes a row on a different pagination page.
    await page.evaluate(() => {
      const table = jQuery('#managedDevices').DataTable();
      table.$('.device-selection').each(function () { this.checked = ['device-2', 'device-22'].includes(this.value); });
    });
    page.once('dialog', dialog => dialog.accept());
    await page.getByRole('button', { name: 'Apply to selected' }).click();
    await page.locator('#backup-summary').filter({ hasText: 'Total 2' }).waitFor();
    await page.locator('#backup-summary').filter({ hasText: 'Succeeded 2' }).waitFor();
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto(origin + '/node/show/device-2');
    await page.getByRole('button', { name: 'Backup Now', exact: true }).click();
    await page.locator('#backup-summary').filter({ hasText: 'Succeeded 1' }).waitFor();
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    await page.screenshot({ path: 'tmp/backup-screenshots/mobile.png' });
    await context.storageState({ path: 'tmp/backup-browser-state.json' });
    await context.close();
    const viewer = await browser.newContext({ ignoreHTTPSErrors: true });
    const v = await viewer.newPage(); await v.goto(origin + '/login');
    await v.locator('#username').fill('fixture-viewer'); await v.locator('#password').fill('synthetic-password-123');
    await v.locator('#loginSubmit').click(); await v.waitForURL('**/nodes');
    assert.equal(await v.locator('.backup-all').count(), 0);
    const status = await v.evaluate(async () => (await fetch('/admin/backups.json', {
      method: 'POST', headers: { 'X-CSRF-Token': document.querySelector('input[name="csrf_token"]').value },
      body: new URLSearchParams({ all: 'true' })
    })).status);
    assert.equal(status, 403); assert.deepEqual(errors, []);
    console.log('PASS: single, all 23, selected across pages, duplicates, real success/failure, mobile and viewer denial');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
