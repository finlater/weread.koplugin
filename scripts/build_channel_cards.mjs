// Render matching channel cards: generate the video QR and preserve the two account codes.
// Requires Playwright, qrcode (or PLAYWRIGHT_MODULE / QRCODE_MODULE paths), and Chromium.
// Optional: CHROMIUM_PATH=/path/to/chrome node scripts/build_channel_cards.mjs
import { copyFileSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || "playwright");
const QRCode = require(process.env.QRCODE_MODULE || "qrcode");
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const demoURL = "https://b23.tv/eVFfl76";
const cards = [
  ["bilibili", null, "png", 740, 740,
    "0 0 740 740", "哔哩哔哩", "扫码观看演示视频"],
  ["xianyu", "screenshots/xianyu-qr.png", "png", 209, 209,
    "13 12 183 183", "闲鱼", "请作者喝咖啡 · 获取使用方式"],
  ["xiaohongshu", "icons/xiaohongshu.jpeg", "jpeg", 987, 1347,
    "155 136 684 684", "小红书", "扫码观看演示视频"],
];
const browser = await chromium.launch({
  headless: true,
  ...(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {}),
});
try {
  const page = await browser.newPage({ viewport: { width: 1074, height: 1465 }, deviceScaleFactor: 1 });
  for (const [name, source, mime, width, height, crop, label, caption] of cards) {
    const imageURL = name === "bilibili"
      ? await QRCode.toDataURL(demoURL, { width: 740, margin: 0, errorCorrectionLevel: "H" })
      : `data:image/${mime};base64,${readFileSync(resolve(root, source)).toString("base64")}`;
    await page.setContent(`<html><head><meta charset="utf-8"></head><body style="margin:0">
      <svg xmlns="http://www.w3.org/2000/svg" width="1074" height="1465" viewBox="0 0 1074 1465">
        <title>finlater · ${label} · ${caption}</title>
        <rect width="1074" height="1465" fill="white"/>
        <svg x="177" y="177" width="720" height="720" viewBox="${crop}" overflow="hidden">
          <image width="${width}" height="${height}" href="${imageURL}" style="image-rendering:pixelated"/>
        </svg>
        <g text-anchor="middle" font-family="Arial, 'PingFang SC', 'Noto Sans CJK SC', sans-serif">
          <text x="537" y="1107" font-size="88" font-weight="700" fill="#222">finlater</text>
          <text x="537" y="1182" font-size="46" fill="#999">${label}</text>
          <text x="537" y="1346" font-size="44" fill="#555">${caption}</text>
        </g>
      </svg></body></html>`);
    await page.evaluate(async () => {
      await document.fonts.ready;
      const image = document.querySelector("image");
      const probe = new Image();
      probe.src = image.getAttribute("href");
      await probe.decode();
    });
    const target = resolve(root, "icons", `${name}.png`);
    await page.locator("body > svg").screenshot({ path: target });
    // Keep the existing public image link working with the corrected code.
    if (name === "xianyu") copyFileSync(target, resolve(root, "screenshots/wereader-xianyu.png"));
    if (name === "bilibili") copyFileSync(target, resolve(root, "screenshots/wereader-bilibili.png"));
    console.log(target);
  }
} finally {
  await browser.close();
}
