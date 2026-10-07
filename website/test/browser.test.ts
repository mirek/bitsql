import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import { mkdir } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
// Opt in after a production build: BITSQL_BROWSER_TEST=1 pnpm test:browser.
// Native Node runner; Playwright supplies only browser automation.
test('production site: SQL worker, safe rendering, reset, stop, mobile layout', { skip: process.env.BITSQL_BROWSER_TEST !== '1' }, async () => {
  const server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', 'preview', '--host', '127.0.0.1', '--port', '47339', '--strictPort', '--base', '/bitsql/'], { stdio: 'pipe' });
  let browser;
  let serverOutput = '';
  server.stderr.on('data', chunk => { serverOutput += String(chunk); });
  try {
    let ready = false;
    for (let i = 0; i < 100; i++) {
      if (server.exitCode !== null) throw new Error(`Preview server stopped: ${serverOutput}`);
      try { if ((await fetch('http://127.0.0.1:47339/bitsql/')).ok) { ready = true; break; } } catch {}
      await delay(100);
    }
    assert.ok(ready, `Preview server did not start: ${serverOutput}`);
    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    const errors: string[] = [];
    page.on('pageerror', e => errors.push(e.message));
    await page.goto('http://127.0.0.1:47339/bitsql/');
    assert.equal(await page.locator('.chart').count(), 6);
    await page.locator('#run').click();
    await page.waitForFunction(() => document.querySelector('#query-status')?.textContent?.startsWith('Completed'));
    assert.match(await page.locator('#results').innerText(), /bitsql emulator/);
    await page.locator('#example').selectOption('1');
    await page.locator('#run').click();
    await page.waitForFunction(() => document.querySelector('#query-status')?.textContent?.startsWith('Completed'));
    assert.match(await page.locator('#results').innerText(), /Grace/);
    await page.locator('#sql').fill("SELECT N'<img src=x onerror=alert(1)>' AS [<script>];");
    await page.locator('#run').click();
    await page.waitForFunction(() => document.querySelector('#query-status')?.textContent?.startsWith('Completed'));
    assert.equal(await page.locator('#results img, #results script').count(), 0);
    assert.match(await page.locator('#results').innerText(), /<img/);
    await page.locator('#reset').click();
    await page.locator('#sql').fill('SELECT * FROM customers');
    await page.locator('#run').click();
    await page.waitForFunction(() => document.querySelector('#query-status')?.textContent?.startsWith('Completed with SQL errors'));
    await page.locator('#sql').fill('WHILE 1 = 1 BEGIN SELECT 1; END');
    await page.locator('#run').click();
    await page.locator('#stop').click();
    assert.match(await page.locator('#query-status').innerText(), /stopped/);
    await page.locator('#example').selectOption('0');
    await page.locator('#run').click();
    await page.waitForFunction(() => document.querySelector('#query-status')?.textContent?.startsWith('Completed'));
    await mkdir('test-artifacts', { recursive: true });
    await page.screenshot({ path: 'test-artifacts/desktop.png', fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    await page.screenshot({ path: 'test-artifacts/mobile.png', fullPage: true });
    assert.deepEqual(errors, []);
  } finally { await browser?.close(); server.kill(); }
});
