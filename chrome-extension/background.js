// Glance for Mac Chrome extension, service worker: relays state to Glance through native messaging and,
// for videos the page doesn't let us read (cross-origin, some DRM), samples a tab snapshot
// cropped to the video, about twice a second, discarding each image immediately.
const HOST = 'app.glanceformac.glance';
let port = null, connected = false;
const status = { method: 'none', domain: '', state: 'idle', audio: 'no-audio', island: false, updated: 0 };
let snap = null;          // { tabId, windowId, frameId, rect, dpr, top, frameUrl, t }
let snapColors = null, snapBlack = 0, capturing = false;
let best = { key: '', area: 0, t: 0 };   // command target (the followed source)
let sendTitles = false;   // Glance's "Title card" setting (off by default)
// Snapshot diagnostics: errors, retries and stalls (shown in the popup/status, never sent anywhere else).
const snapLog = [];
function logSnap(msg) {
  snapLog.push(new Date().toISOString().slice(11, 19) + ' ' + msg);
  if (snapLog.length > 20) snapLog.shift();
  console.info('[island snapshot]', msg);
}

function connect() {
  try {
    port = chrome.runtime.connectNative(HOST);
    connected = true;
    port.onMessage.addListener(m => {
      if (m && m.type === 'pong') status.island = !!m.island;
      if (m && m.type === 'command') {
        // Glance tells us whether it shows titles; otherwise titles are never sent (less data).
        if (m.cmd === 'titles-on' || m.cmd === 'titles-off') { sendTitles = m.cmd === 'titles-on'; return; }
        runCommand(m.cmd);
      }
    });
    port.onDisconnect.addListener(() => { connected = false; port = null; status.island = false; setTimeout(connect, 3000); });
    port.postMessage({ type: 'ping' });
  } catch (e) { connected = false; setTimeout(connect, 5000); }
}
connect();

function post(m) {
  if (!port) return;
  try { port.postMessage(m); } catch (e) {}
}

async function enabled() {
  const v = await chrome.storage.local.get({ enabled: true });
  return v.enabled;
}

chrome.runtime.onMessage.addListener((m, sender, reply) => {
  if (m && m.type === 'status') { reply({ ...status, connected, snapLog: snapLog.slice(-8) }); return; }
  if (!m || m.type !== 'frame' || !sender.tab) return;
  handleFrame(m, sender);
});

// ---- Source selection: ONE video at a time -------------------------------------------
// Preferred: the playing, visible, active tab in the last-focused window. Playing tabs in other
// windows are used only when the focused window has none. Switching needs ~1.5 s of stability.
let focusedWindow = chrome.windows.WINDOW_ID_NONE;
chrome.windows.getLastFocused({}).then(w => { if (w) focusedWindow = w.id; }).catch(() => {});
chrome.windows.onFocusChanged.addListener(id => { if (id !== chrome.windows.WINDOW_ID_NONE) focusedWindow = id; reselect(); });
chrome.tabs.onActivated.addListener(({ tabId, windowId }) => {
  for (const c of candidates.values()) if (c.windowId === windowId) c.active = (c.tabId === tabId);
  // The followed tab is no longer the active one: stop now (no 30 s timeout).
  if (source && source.windowId === windowId && source.tabId !== tabId) dropSource('tab-switch');
  reselect();
});
chrome.tabs.onRemoved.addListener(tabId => {
  for (const [k, c] of candidates) if (c.tabId === tabId) candidates.delete(k);
  if (source && source.tabId === tabId) dropSource('tab-closed');
  if (pausedTab && pausedTab.tabId === tabId) pausedGone('tab-closed');
});

const candidates = new Map();     // key -> { tabId, windowId, frameId, active, playing, area, t }
let source = null;                // the followed candidate
let pending = null, pendingSince = 0;

function score(c) {
  const fresh = Date.now() - c.t < 6000;   // covered windows send slowly; still fresh
  if (!c.playing || !c.active || !fresh) return -1;
  return (c.windowId === focusedWindow ? 1e9 : 0) + c.area;
}

function reselect() {
  let best = null, bestS = -1;
  for (const c of candidates.values()) { const s = score(c); if (s > bestS) { best = c; bestS = s; } }
  if (!best) { pending = null; return; }
  if (source && candidates.get(source.key) === best) { pending = null; return; }
  const sourceOK = source && score(candidates.get(source.key) || {}) >= 0;
  if (!sourceOK) { source = best; pending = null; return; }           // nothing playing: take it now
  if (!pending || pending.key !== best.key) { pending = best; pendingSince = Date.now(); return; }
  if (Date.now() - pendingSince >= 1500) { source = best; pending = null; }  // stable for 1.5 s
}

// The paused video Glance shows as "Intermission" (kept when its tab goes to the background).
let pausedTab = null;   // { tabId, url }
function dropSource(reason) {
  if (!source) return;
  const wasPaused = !source.playing && pausedTab && pausedTab.tabId === source.tabId;
  // Playing tab switched away: Cinema stops. Paused video: keep the reminder ("away").
  const gone = reason === 'tab-closed' || reason === 'navigated';
  post({ type: 'frame', state: wasPaused && !gone ? 'away' : (gone ? 'closed' : 'background'), domain: status.domain || '' });
  source = null;
  status.state = 'idle';
}
function pausedGone(reason) {
  if (!pausedTab) return;
  pausedTab = null;
  post({ type: 'frame', state: 'closed', domain: status.domain || '' });
}
chrome.tabs.onUpdated.addListener((tabId, info) => {
  // The followed (playing) tab went to another page: Cinema stops now, not after a timeout.
  if (source && tabId === source.tabId && info.url && info.url.split('#')[0] !== source.url) {
    for (const [k, c] of candidates) if (c.tabId === tabId) candidates.delete(k);
    dropSource('navigated');
  }
  // Navigated away (new URL) from the paused video's page.
  if (pausedTab && tabId === pausedTab.tabId && info.url && info.url.split('#')[0] !== pausedTab.url) pausedGone('navigated');
});

async function handleFrame(m, sender) {
  if (!(await enabled())) return;
  const tab = sender.tab;
  const key = tab.id + ':' + sender.frameId;
  const now = Date.now();
  if (m.state === 'hidden') {
    // Tab switched away -> stop now. Window merely covered (tab still active) -> keep playing.
    const t = await chrome.tabs.get(tab.id).catch(() => null);
    if (t && t.active) m.state = 'playing';
    else { if (source && source.key === key) dropSource('hidden'); return; }
  }
  const c = candidates.get(key) || { key, tabId: tab.id, windowId: tab.windowId, frameId: sender.frameId };
  Object.assign(c, { active: tab.active, playing: m.state === 'playing', area: m.area || 0, t: now, windowId: tab.windowId, url: (tab.url || '').split('#')[0] });
  candidates.set(key, c);
  reselect();
  if (!source || source.key !== key) {
    // Not the followed video. If it is the followed tab but inactive, report background.
    return;
  }
  if (!tab.active && m.state === 'playing') { dropSource('inactive'); return; }

  const out = { type: 'frame', state: m.state, method: m.method, audio: m.audio, fullscreen: !!m.fullscreen, domain: m.domain,
                title: sendTitles ? (m.title || m.og || cleanTitle(tab.title || '', m.fileTitle) || m.fileTitle || '') : '',
                mediaId: tab.id + '-' + (m.mediaId || ''), time: m.time, duration: m.duration, rate: m.rate, live: m.live };
  best.tabId = tab.id; best.frameId = sender.frameId; best.windowId = tab.windowId;
  if (m.colors) out.colors = m.colors;
  if (m.bands) out.bands = m.bands;
  if (m.spectrum) out.spectrum = m.spectrum;
  if (m.beats != null) out.beats = m.beats;
  if (m.state === 'playing' && m.method === 'snapshot' && m.rect) {
    snap = { tabId: tab.id, windowId: tab.windowId, frameId: sender.frameId, rect: m.rect, dpr: m.dpr || 1, top: m.top, frameUrl: m.frameUrl, t: now };
    if (!capturing) captureLoop();
    if (snapBlack > 3) out.method = 'protected';
    else if (snapColors) out.colors = snapColors;
  }
  if (m.state !== 'playing' && snap && snap.tabId === tab.id) snap = null;
  if (m.state === 'paused') pausedTab = { tabId: tab.id, url: (tab.url || '').split('#')[0] };
  else if (m.state === 'playing' || m.state === 'ended' || m.state === 'closed') pausedTab = null;
  Object.assign(status, { method: out.method, domain: m.domain, state: m.state, audio: m.audio, updated: now });
  post(out);
}

// " - YouTube", " | Netflix", "(3) " notification counters, etc.
function cleanTitle(t, fileTitle) {
  t = String(t).replace(/^\(\d+\)\s*/, '').trim();
  if (/\.(mp4|m4v|webm|ogv|ogg|mkv|mov)$/i.test(t) || (fileTitle && t.startsWith(fileTitle))) return '';  // just a file name
  if (/^(https?:\/\/)?[\w.-]+(:\d+)?\/\S*$/.test(t) || /^[\w-]+(\.[\w-]+)+(:\d+)?$/.test(t)) return '';    // a URL, not a title: never send it
  t = t.replace(/\s[-|–—·:]\s(YouTube|Netflix|Vimeo|Twitch|Prime Video|Disney\+|Dailymotion|BBC iPlayer|[^-|–—·]{2,24})$/u, '').trim();
  return t.slice(0, 120);
}

// Glance -> extension: control the video Glance is following.
async function runCommand(cmd) {
  if (best.tabId == null) return;
  if (cmd === 'focus') {   // bring the followed video's tab and window to the front
    try { await chrome.tabs.update(best.tabId, { active: true }); await chrome.windows.update(best.windowId, { focused: true }); } catch (e) {}
    return;
  }
  if (cmd === 'fullscreen-window') {
    const w = await chrome.windows.get(best.windowId);
    chrome.windows.update(best.windowId, { state: w.state === 'fullscreen' ? 'normal' : 'fullscreen' });
    return;
  }
  try {
    const r = await chrome.tabs.sendMessage(best.tabId, { type: 'command', cmd }, { frameId: best.frameId });
    // Full screen needs a user gesture on most pages; fall back to a full-screen window.
    if (cmd === 'fullscreen' && r && !r.ok) {
      const w = await chrome.windows.get(best.windowId);
      chrome.windows.update(best.windowId, { state: w.state === 'fullscreen' ? 'normal' : 'fullscreen' });
      post({ type: 'result', cmd, result: 'window-fullscreen' });
      return;
    }
    post({ type: 'result', cmd, result: r ? r.result : 'no-reply' });
  } catch (e) { post({ type: 'result', cmd, result: 'error' }); }
}

async function videoRectInTab(s) {
  if (s.top || s.frameId === 0) return s.rect;
  // Child frame: add the iframe's offset in the top page.
  try {
    const frames = await chrome.tabs.sendMessage(s.tabId, { type: 'iframeRects' }, { frameId: 0 });
    if (frames && frames.length) {
      let f = frames.find(fr => fr.src && s.frameUrl && (s.frameUrl.startsWith(fr.src) || fr.src.startsWith(s.frameUrl)));
      if (!f) f = frames.reduce((a, b) => (a.w * a.h > b.w * b.h ? a : b));
      return { x: f.x + s.rect.x, y: f.y + s.rect.y, w: s.rect.w, h: s.rect.h };
    }
  } catch (e) {}
  return s.rect;
}

async function captureLoop() {
  capturing = true;
  let delay = 520, errors = 0, lastOK = Date.now(), stallLogged = false;
  logSnap('loop start');
  while (snap && Date.now() - snap.t < 1500) {
    let ok = false;
    try {
      const tab = await chrome.tabs.get(snap.tabId);
      const win = await chrome.windows.get(snap.windowId);
      if (tab.active && win.state !== 'minimized') {
        const url = await chrome.tabs.captureVisibleTab(snap.windowId, { format: 'jpeg', quality: 35 });
        const r = await videoRectInTab(snap);
        const blob = await (await fetch(url)).blob();
        const bmp = await createImageBitmap(blob);
        const scale = bmp.width / (tab.width || bmp.width / snap.dpr);
        const sx = Math.max(0, r.x * scale), sy = Math.max(0, r.y * scale);
        const sw = Math.min(bmp.width - sx, r.w * scale), sh = Math.min(bmp.height - sy, r.h * scale);
        if (sw > 4 && sh > 4) {
          const c = new OffscreenCanvas(32, 18);
          const g = c.getContext('2d', { willReadFrequently: true });
          g.drawImage(bmp, sx, sy, sw, sh, 0, 0, 32, 18);
          const res = regionsOf(g.getImageData(0, 0, 32, 18).data);
          snapColors = res.colors;
          snapBlack = res.black ? snapBlack + 1 : 0;   // black video area every time: DRM-protected
          ok = true;
        } else if (!stallLogged) { logSnap('video rect off-screen ' + JSON.stringify(r)); }
        bmp.close();  // image discarded; nothing stored
      }
    } catch (e) {
      // Usually the 2-captures-per-second quota or a page that can't be captured: back off, retry.
      errors++;
      delay = Math.min(delay * 2, 2000);
      if (errors <= 3 || errors % 10 === 0) logSnap('capture error #' + errors + ': ' + String(e && e.message || e).slice(0, 80) + ' (retry in ' + delay + ' ms)');
    }
    if (ok) {
      if (errors || stallLogged) logSnap('recovered after ' + Math.round((Date.now() - lastOK) / 100) / 10 + ' s');
      errors = 0; delay = 520; lastOK = Date.now(); stallLogged = false;
    } else if (Date.now() - lastOK > 3000 && !stallLogged) {
      stallLogged = true;
      snapColors = null;            // never keep sending frozen colours
      logSnap('stalled > 3 s');
    }
    await new Promise(res => setTimeout(res, delay));   // Chrome allows ~2 captures/s
  }
  logSnap('loop end (' + (snap ? 'no fresh rect for 1.5 s' : 'source stopped') + ')');
  capturing = false;
  snapColors = null;
}

function dominant(d, W, x0, x1, y0, y1) {
  // Dominant VIVID colour of a region: 12 hue bins weighted by s^2 * v; near-grey and
  // near-black pixels are ignored unless the whole region is grey.
  const bins = Array.from({ length: 12 }, () => [0, 0, 0, 0]); // r, g, b, weight
  let ar = 0, ag = 0, ab = 0, an = 0;
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
    const o = (y * W + x) * 4, R = d[o], G = d[o + 1], B = d[o + 2];
    const mx = Math.max(R, G, B), mn = Math.min(R, G, B);
    const v = mx / 255, s = mx ? (mx - mn) / mx : 0;
    if (v >= 0.12) { ar += R; ag += G; ab += B; an++; }
    if (s < 0.15 || v < 0.12) continue;
    let h;
    if (mx === R) h = ((G - B) / (mx - mn)) % 6; else if (mx === G) h = (B - R) / (mx - mn) + 2; else h = (R - G) / (mx - mn) + 4;
    const bin = Math.floor(((h * 60 + 360) % 360) / 30);
    const w = s * s * v;
    const b = bins[bin]; b[0] += R * w; b[1] += G * w; b[2] += B * w; b[3] += w;
  }
  let best = null;
  for (const b of bins) if (b[3] > 0 && (!best || b[3] > best[3])) best = b;
  if (best && best[3] > 0.02) return [Math.round(best[0] / best[3]), Math.round(best[1] / best[3]), Math.round(best[2] / best[3])];
  return an ? [Math.round(ar / an), Math.round(ag / an), Math.round(ab / an)] : [0, 0, 0];
}

function regionsOf(d) {
  const W = 32, H = 18;
  const boxes = [[0, 8, 0, H], [24, W, 0, H], [0, W, 0, 5], [0, W, 13, H], [8, 24, 4, 14]];
  let total = 0;
  const colors = boxes.map(([x0, x1, y0, y1]) => {
      for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) { const o = (y * W + x) * 4; total += d[o] + d[o + 1] + d[o + 2]; }
      return dominant(d, W, x0, x1, y0, y1);
    });
  return { colors, black: total < W * H * 3 * 6 };
}
