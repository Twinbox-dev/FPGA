// Run with: node scripts/web_console/test_frame_view.js
// Exercise the actual inline page renderer with one complete 3:1 readback frame.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, 'templates/index.html'), 'utf8');
const begin = html.indexOf('let lastFrameId = ');
const end = html.indexOf('document.getElementById("bmpFile").addEventListener', begin);
assert(begin >= 0 && end > begin, 'frame renderer not found');

function canvas() {
  const ctx = {
    image: null,
    createImageData(w, h) { return {data: new Uint8ClampedArray(w * h * 4)}; },
    putImageData(img) { this.image = img; },
    getImageData() { return this.image; },
  };
  return {ctx, getContext() { return ctx; }, style: {}};
}
const wr = canvas(), rb = canvas();
const elements = {
  frameCv: wr, frameCvRb: rb,
  frameCard: {style: {}}, frameHint: {textContent: ''},
  frameHintRb: {textContent: ''}, diffHint: {textContent: ''},
  diffHintRb: {textContent: ''},
};
const raw = new ArrayBuffer(153600 * 4);
const view = new DataView(raw);
view.setUint32(0, 0x0000F800, true);       // frame word 0: red low pixel
view.setUint32(4, 0x001F0000, true);       // frame word 3: blue high pixel
view.setUint32(76693 * 4, 0x0000F800, true); // row 359, word 319
const snapshotRaw = new ArrayBuffer(460800 * 4);
new DataView(snapshotRaw).setUint32(0, 0x0000F800, true); // bottom-up source row 0 -> canvas row 719
const fetched = [];

const env = {
  document: {getElementById(id) { assert(elements[id], id); return elements[id]; }},
  fetch: async url => {
    fetched.push(url);
    const isSnapshot = url.endsWith("slot=snapshot");
    return ({
    ok: true,
    headers: {get(name) { return ({'X-Frame-Id': '1',
      'X-Frame-Words': isSnapshot ? '460800' : '153600',
      'X-Frame-Gaps': '0', 'X-Frame-Stride': isSnapshot ? '1' : '3'})[name]; }},
    arrayBuffer: async () => isSnapshot ? snapshotRaw : raw,
  });
  },
  DataView, Uint8ClampedArray, Math, ArrayBuffer,
};
vm.createContext(env);
vm.runInContext(html.slice(begin, end), env);

(async () => {
  await vm.runInContext('showFrame({kind:"rb", id:1, ts:"test"})', env);
  const px = rb.ctx.image.data;
  assert.equal(px[0], 255);              // original word 0, low pixel = red
  assert.equal(px[2 * 4 + 3], 0);       // original word 1 was not sampled
  assert.equal(px[7 * 4 + 2], 255);     // original word 3, high pixel = blue
  assert(!elements.frameHintRb.textContent.includes('失败'));

  // Six-pixel BMP centred at x=637, y=359; only word 230079 is sampled.
  const bmp = new ArrayBuffer(54 + 20);
  const bmpView = new DataView(bmp);
  bmpView.setUint8(54 + 3 + 2, 255);    // local pixel x=1 is red
  env.__bmp = bmpView;
  await vm.runInContext(
    'bmpImg={dv:__bmp, off:54, w:6, h:1, bottomUp:true, stride:20}; diffAll()', env);
  assert(elements.diffHintRb.textContent.includes('图像差异 0/2'),
    elements.diffHintRb.textContent);
  assert(elements.diffHintRb.textContent.includes('黑边差异 2/307198'),
    elements.diffHintRb.textContent);
  await vm.runInContext('bmpImg=null; showFrame({kind:"rb", source:"snapshot", id:1, ts:"snapshot"})', env);
  const snap = rb.ctx.image.data;
  assert.equal(snap[(719 * 1280) * 4], 255); // BMP source row 0 is the bottom display row
  assert.equal(snap[(719 * 1280) * 4 + 3], 255);
  assert.equal(snap[0], 0);                  // no accidental red pixel at the top row
  assert(fetched.includes('/api/frame?slot=rb'));
  assert(fetched.includes('/api/frame?slot=snapshot'));
  console.log('Probe and bottom-up D snapshot rendering: PASS');
})().catch(e => { console.error(e); process.exitCode = 1; });
