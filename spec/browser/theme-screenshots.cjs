const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const origin = process.env.BACKUP_ORIGIN || 'https://127.0.0.1:45529';
const directory = 'tmp/backup-screenshots/themes';

function contrast(a, b) {
  function luminance(value) {
    const parts = value.match(/[\d.]+/g).slice(0, 3).map(n => Number(n) / 255).map(n => n <= .04045 ? n / 12.92 : ((n + .055) / 1.055) ** 2.4);
    return parts[0] * .2126 + parts[1] * .7152 + parts[2] * .0722;
  }
  const x = luminance(a), y = luminance(b);
  return (Math.max(x, y) + .05) / (Math.min(x, y) + .05);
}

(async () => {
  fs.mkdirSync(directory, { recursive: true });
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    const context = await browser.newContext({ ignoreHTTPSErrors: true, storageState: 'tmp/backup-browser-state.json' });
    const page = await context.newPage();
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    fs.writeFileSync(path.join(process.env.BACKUP_FIXTURE_DIR, 'device-1.txt'), 'changed synthetic description');
    await page.goto(origin + '/node/show/device-1');
    await page.getByRole('button', { name: 'Backup Now', exact: true }).click();
    await page.locator('#backup-summary').filter({ hasText: 'Succeeded 1' }).waitFor();
    await page.reload();
    assert.equal(await page.locator('.detail-card-revisions strong').innerText(), '2');
    await page.goto(origin + '/node/version?node_full=device-1');
    const diff = await page.getByTitle('Compare with previous version', { exact: true }).first().getAttribute('href');
    await page.goto(origin + diff);
    assert.match(await page.locator('#unifiedDiff').textContent(), /changed synthetic description/);
    const pages = [['dashboard', '/nodes'], ['management', '/admin/devices'], ['details', '/node/show/device-1'], ['history', '/node/version?node_full=device-1'], ['diff', diff], ['users', '/admin/users']];
    const sizes = [[1920, 1080], [1440, 900], [1366, 768], [1024, 768], [768, 1024], [390, 844]];
    for (const theme of ['light', 'dark']) {
      await page.evaluate(theme => localStorage.setItem('theme', theme), theme);
      for (const [width, height] of sizes) {
        await page.setViewportSize({ width, height });
        for (const [name, url] of pages) {
          await page.goto(origin + url);
          assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true, `${name}/${theme}/${width} overflows`);
          await page.screenshot({ path: `${directory}/${name}-${theme}-${width}.png` });
        }
      }
      await page.setViewportSize({ width: 1366, height: 768 });
      await page.goto(origin + '/admin/devices');
      for (const selector of ['.backup-all', '#bulkDevices .btn-outline-primary', '.pagination .active .page-link']) {
        const control = page.locator(selector).first();
        if (selector.includes('outline')) await control.hover();
        await control.evaluate(el => Promise.all(el.getAnimations().map(animation => animation.finished)));
        const colors = await control.evaluate(el => ({ color: getComputedStyle(el).color, bg: getComputedStyle(el).backgroundColor }));
        assert.ok(contrast(colors.color, colors.bg) >= 4.5, `${theme} ${selector} contrast: ${JSON.stringify(colors)}`);
      }
      const loginContext = await browser.newContext({ ignoreHTTPSErrors: true });
      await loginContext.addInitScript(theme => localStorage.setItem('theme', theme), theme);
      const login = await loginContext.newPage();
      for (const [width, height] of sizes) {
        await login.setViewportSize({ width, height }); await login.goto(origin + '/login');
        await login.screenshot({ path: `${directory}/login-${theme}-${width}.png` });
      }
      await loginContext.close();
    }
    assert.deepEqual(errors, []);
    console.log('PASS: actual changed Git diff, exactly one additional revision, 84 light/dark screenshots, overflow and control contrast checks');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
