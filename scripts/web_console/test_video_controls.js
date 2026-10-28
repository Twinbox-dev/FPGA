// Exercise the real sendKey handler with a busy board during video playback.
const assert = require('assert');
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const html = fs.readFileSync(path.join(__dirname, 'templates', 'index.html'), 'utf8');
const match = html.match(/async function sendKey\(k\) \{[\s\S]*?\n\}\r?\nconst subtitleInput/);
assert(match, 'sendKey handler not found');
const calls = [];
const context = {
  connected: true, videoActive: true, viewPending: false,
  boardView: {busy: true}, IMAGE_KEYS: ['n', 'p', 'd', '6', '7', '8'],
  mode: 'eth', CSS: {escape: s => s}, document: {querySelector: () => null},
  fetch: async (_url, request) => { calls.push(JSON.parse(request.body).key); return {json: async () => ({ok: true})}; },
  addLog: () => {}, updateViewControls: () => {}, scheduleViewRecovery: () => {},
  setTimeout, viewSawBusy: false, viewRecovery: false
};
vm.createContext(context);
vm.runInContext(match[0].replace(/\r?\nconst subtitleInput$/, ''), context);
(async () => {
  for (const key of ['+', '-', 's', 'n']) await context.sendKey(key);
  assert.deepStrictEqual(calls, ['+', '-', 's']);
  context.videoActive = false;
  await context.sendKey('+');
  assert.deepStrictEqual(calls, ['+', '-', 's']);
  console.log('PASS: video volume and status pass the busy guard; image requests remain blocked');
})().catch(error => { console.error(error); process.exitCode = 1; });
