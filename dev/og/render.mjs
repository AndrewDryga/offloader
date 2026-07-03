// Renders dev/og/template.html → site/og.png at 2400×1260 (1200×630 @2×, the OG 1.91:1 ratio).
// Needs Playwright + Chromium: `npm i playwright && npx playwright install chromium`, then `node dev/og/render.mjs`.
import { chromium } from 'playwright';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const here = dirname(fileURLToPath(import.meta.url));
const template = 'file://' + join(here, 'template.html');
const out = join(here, '..', '..', 'site', 'og.png');

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 2 });
await page.goto(template, { waitUntil: 'networkidle' });
await page.waitForTimeout(300); // let webfonts settle before the shot
await page.locator('.og').screenshot({ path: out });
await browser.close();
console.log('wrote', out);
