#!/usr/bin/env node
// Render the actual console page with a local headless Chrome and verify its
// responsive width plus the D, SD diagnostic, subtitle, and keyboard behavior.
const fs = require('node:fs/promises');
const path = require('node:path');
const net = require('node:net');
const http = require('node:http');
const {spawn} = require('node:child_process');

const root = path.resolve(__dirname);
const template = path.join(root, 'templates', 'index.html');
const outputDir = path.join(root, 'screenshots');
const profile = path.join(outputDir, `.chrome-cdp-${process.pid}`);
const chrome = process.env.CHROME_PATH ||
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const fileUrl = `file:///${template.replaceAll('\\', '/')}`;
const mockKeys = {
  keys: [
    ['p','上一张'],['n','下一张'],['a','自动轮播'],['s','状态回读'],
    ['0','直接切'],['1','交叉溶解'],['2','柔边滑动'],
    ['3','面板关闭'],['4','面板调节后 3 秒'],['5','面板始终显示'],
    ['-','音量-'],['+','音量+'],['<','周期-1s'],['>','周期+1s'],
    ['[','亮度-'],[']','亮度+'],[',','对比度-'],['.','对比度+'],
    [';','频谱灵敏度-'],["'",'频谱灵敏度+'],['q','频谱开关'],
    ['i','SD 卡状态诊断'],['l','播放列表转储(调试)'],
  ].map(([key,label]) => ({key,label})),
  groups: [
    {name:'播放',keys:['p','n','a','s']},
    {name:'切换特效',keys:['0','1','2']},
    {name:'OSD 面板',keys:['3','4','5']},
    {name:'音量',keys:['-','+']},
    {name:'轮播周期',keys:['<','>']},
    {name:'亮度 / 对比度',keys:['[',']',',','.']},
    {name:'音频频谱',keys:[';',"'",'q']},
    {name:'SD 卡诊断',keys:['i']},
    {name:'调试',keys:['l']},
  ],
};

async function choosePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const port = server.address().port;
  await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
  return port;
}

function queryDevTools(port) {
  return new Promise((resolve, reject) => {
    const request = http.get({hostname: '127.0.0.1', port, path: '/json', timeout: 1000}, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => {
        try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
        catch (error) { reject(error); }
      });
    });
    request.on('timeout', () => request.destroy(new Error('DevTools request timed out')));
    request.on('error', reject);
  });
}

async function waitForDevTools(port) {
  let lastError = 'no page target returned';
  for (let attempt = 0; attempt < 300; attempt++) {
    try {
      const pages = await queryDevTools(port);
      const page = pages.find(item => item.type === 'page');
      if (page) return {port, page};
    } catch (error) { lastError = error.message; }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error(`Chrome DevTools unavailable at 127.0.0.1:${port}: ${lastError}`);
}

function connectCdp(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const pending = new Map();
    let nextId = 0;
    ws.addEventListener('open', () => resolve({
      ws,
      command(method, params = {}) {
        const id = ++nextId;
        return new Promise((done, fail) => {
          pending.set(id, {done, fail});
          ws.send(JSON.stringify({id, method, params}));
        });
      },
      evaluate(expression) {
        return this.command('Runtime.evaluate', {
          expression, awaitPromise: true, returnByValue: true, userGesture: true,
        }).then(reply => {
          if (reply.exceptionDetails)
            throw new Error(reply.exceptionDetails.text || 'browser evaluation failed');
          return reply.result ? reply.result.value : undefined;
        });
      },
      close() { ws.close(); },
    }));
    ws.addEventListener('message', event => {
      const msg = JSON.parse(event.data);
      if (!msg.id || !pending.has(msg.id)) return;
      const entry = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) entry.fail(new Error(msg.error.message));
      else entry.done(msg.result || {});
    });
    ws.addEventListener('error', reject);
  });
}

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function capture(cdp, name, width, height) {
  const metrics = await cdp.evaluate(`({
    viewport: window.innerWidth,
    page: Math.max(document.documentElement.scrollWidth, document.body.scrollWidth),
    height: Math.min(Math.max(document.documentElement.scrollHeight, document.body.scrollHeight,
                              window.innerHeight), ${height}),
  })`);
  if (metrics.page > width + 1)
    throw new Error(`${name} has horizontal overflow: ${metrics.page}px > ${width}px`);
  const image = await cdp.command('Page.captureScreenshot', {
    format: 'png', fromSurface: true, captureBeyondViewport: true,
    clip: {x: 0, y: 0, width, height: metrics.height, scale: 1},
  });
  await fs.writeFile(path.join(outputDir, name), Buffer.from(image.data, 'base64'));
  return metrics;
}

(async () => {
  await fs.mkdir(outputDir, {recursive: true});
  await fs.mkdir(profile, {recursive: true});
  const port = await choosePort();
  const browser = spawn(chrome, [
    '--headless=new', '--no-sandbox', '--disable-gpu', '--hide-scrollbars',
    `--remote-debugging-port=${port}`, '--remote-allow-origins=*',
    `--user-data-dir=${profile}`, 'about:blank',
  ], {stdio: 'ignore', windowsHide: true});
  let cdp = null;

  try {
    const {page} = await waitForDevTools(port);
    cdp = await connectCdp(page.webSocketDebuggerUrl);
    await cdp.command('Page.enable');
    await cdp.command('Runtime.enable');
    await cdp.command('Emulation.setDeviceMetricsOverride', {
      width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false,
    });
    await cdp.command('Page.navigate', {url: fileUrl});
    await sleep(700);
    await cdp.evaluate(`(() => {
      connState.eth = true; setMode('eth', false); setLink(true, 'preview');
      const calls = [];
      window.fetch = async (url, options = {}) => {
        calls.push({url, body: options.body ? JSON.parse(options.body) : null});
        const keys = ${JSON.stringify(mockKeys)};
        const body = url === '/api/keys' ? keys : {ok:true, length:160, acknowledged:true};
        return {ok:true, status:200, json:async()=>body};
      };
      window.__testCalls = calls;
    })()`);
    const controls = await cdp.evaluate(`(async () => {
      await buildPad();
      const required = ['0','1','2','3','4','5','i','l'];
      const missing = required.filter(k => !document.querySelector('#pad button[data-k="'+k+'"]'));
      if (missing.length) throw new Error('missing controls: '+missing.join(','));
      document.getElementById('btnSnapshot').click();
      await new Promise(resolve => setTimeout(resolve, 0));
      const padButtons = Array.from(document.querySelectorAll('#pad button[data-k]'));
      const padKeys = padButtons.map(button => button.dataset.k);
      padButtons.forEach(button => button.click());
      await new Promise(resolve => setTimeout(resolve, 0));
      const sentKeys = window.__testCalls.filter(item => item.url === '/api/cmd').map(item => item.body.key);
      const unsent = padKeys.filter(key => !sentKeys.includes(key));
      if (unsent.length) throw new Error('buttons did not send commands: '+unsent.join(','));
      const before = window.__testCalls.length;
      const field = document.getElementById('subtitleText');
      field.value = 'n'; field.focus();
      field.dispatchEvent(new KeyboardEvent('keydown', {key:'n', bubbles:true, cancelable:true}));
      await new Promise(resolve => setTimeout(resolve, 0));
      if (window.__testCalls.length !== before) throw new Error('typing triggered a board command');
      field.value = 'A'.repeat(160); field.dispatchEvent(new Event('input', {bubbles:true}));
      document.getElementById('btnSubtitle').click();
      await new Promise(resolve => setTimeout(resolve, 0));
      const data = window.__testCalls;
      const snapshot = data.find(item => item.url === '/api/cmd' && item.body.key === 'd');
      if (!snapshot) throw new Error('D snapshot button did not send D');
      const subtitle = data.find(item => item.url === '/api/subtitle');
      if (!subtitle || subtitle.body.text.length !== 160) throw new Error('160-character subtitle was not sent');
      field.value = ''; document.getElementById('subtitleCount').textContent = '0/160';
      document.getElementById('btnSubtitleClear').click();
      await new Promise(resolve => setTimeout(resolve, 0));
      if (!data.some(item => item.url === '/api/subtitle' && item.body.text === ''))
        throw new Error('clear subtitle button did not send an empty upload');
      document.querySelector('[data-frame-view="wr"]').click();
      if (document.getElementById('frameViewWr').hidden) throw new Error('write preview tab did not open');
      document.querySelector('[data-frame-view="rb"]').click();
      if (document.getElementById('frameViewRb').hidden) throw new Error('readback preview tab did not open');
      document.getElementById('toast').className = 'toast';
      return {controls:padKeys.length, d:snapshot.body.key, subtitleLength:subtitle.body.text.length,
              typedKeySent:false};
    })()`);
    const desktop = await capture(cdp, 'console-desktop.png', 1600, 2400);

    await cdp.command('Emulation.setDeviceMetricsOverride', {
      width: 390, height: 844, deviceScaleFactor: 1, mobile: true,
      screenWidth: 390, screenHeight: 844,
    });
    await cdp.evaluate('window.dispatchEvent(new Event("resize")); slide()');
    await sleep(100);
    const mobile = await capture(cdp, 'console-mobile.png', 390, 844);
    cdp.close();
    console.log(JSON.stringify({controls, desktop, mobile}, null, 2));
  } finally {
    if (cdp) {
      try { await Promise.race([cdp.command('Browser.close'), sleep(500)]); } catch (_) {}
      cdp.close();
    }
    browser.kill();
    if (browser.exitCode === null) {
      await Promise.race([
        new Promise(resolve => browser.once('exit', resolve)),
        sleep(3000),
      ]);
    }
    const outputRoot = path.resolve(outputDir) + path.sep;
    const profilePath = path.resolve(profile);
    if (!profilePath.startsWith(outputRoot)) throw new Error('refusing to remove profile outside screenshot directory');
    try { await fs.rm(profilePath, {recursive: true, force: true}); }
    catch (error) { console.warn(`temporary Chrome profile is still locked: ${error.message}`); }
  }
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
