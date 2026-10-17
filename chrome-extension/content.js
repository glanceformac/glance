// Glance for Mac Chrome extension, content script (every frame). Finds the playing video and sends only
// region colours, sound band levels and play state. Never sends images or page content.
(() => {
  if (window.__islandAmbilight) return;
  window.__islandAmbilight = true;

  let enabled = true;
  try {
    chrome.storage.local.get({ enabled: true }, v => { enabled = v.enabled; });
    chrome.storage.onChanged.addListener(c => { if (c.enabled) enabled = c.enabled.newValue; });
  } catch (e) {}

  const W = 32, H = 18;
  const canvas = new OffscreenCanvas(W, H);
  const g = canvas.getContext('2d', { willReadFrequently: true });
  let video = null, method = 'direct', audio = 'no-audio', tick = 0, loop = null, lastState = '';
  let blackFrames = 0, lastTime = -1, directOK = false;
  let actx = null, analyser = null, freq = null, attachedTo = null, peak = 0.05;
  const smooth = [0, 0, 0, 0];
  const floors = [0, 0, 0, 0], peaks = [0.1, 0.1, 0.1, 0.1];

  function domain() {
    try {
      const a = location.ancestorOrigins;
      if (a && a.length) return new URL(a[a.length - 1]).hostname;
    } catch (e) {}
    return location.hostname;
  }

  function area(v) {
    const r = v.getBoundingClientRect();
    const w = Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0));
    const h = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));
    return w * h;
  }

  // Videos in the page, including inside open shadow roots (e.g. archive.org's <play-av>).
  let shadowHosts = new Set();
  function collectShadowHosts(root) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    for (let n = walker.currentNode; n; n = walker.nextNode()) {
      if (n.shadowRoot) { shadowHosts.add(n); collectShadowHosts(n.shadowRoot); }
    }
  }
  let shadowScanAt = 0;
  function allVideos() {
    const vids = [...document.querySelectorAll('video')];
    // Shadow scan at most every 5 s, or when nothing was found in the light DOM.
    if (Date.now() - shadowScanAt > 5000 || (!vids.length && Date.now() - shadowScanAt > 1500)) {
      shadowScanAt = Date.now();
      shadowHosts = new Set();
      if (document.body) collectShadowHosts(document.body);
    }
    for (const h of shadowHosts) if (h.isConnected && h.shadowRoot) vids.push(...h.shadowRoot.querySelectorAll('video'));
    return vids;
  }
  new MutationObserver(() => { shadowScanAt = 0; }).observe(document.documentElement, { childList: true, subtree: true });

  // Only a real "watching" video counts: unmuted, reasonably large, not a hover/inline preview
  // (YouTube home autoplays muted previews), and only after 1.5 s of real playback.
  const PREVIEW = 'ytd-video-preview, #inline-player, #inline-preview-player, ytd-moving-thumbnail-renderer, .ytp-inline-preview-mode, ytd-thumbnail';
  function candidate(v) {
    if (v.muted || v.volume === 0) return false;
    const r = v.getBoundingClientRect();
    const inFrame = window !== window.top;
    if (!(r.width >= 480 || r.width >= innerWidth * 0.4 || (inFrame && r.width >= innerWidth * 0.8 && r.width >= 300))) return false;
    try { if (v.closest(PREVIEW)) return false; } catch (e) {}
    if (/(^|\.)youtube\.com$/.test(location.hostname)) {
      const main = v.closest('#movie_player, #shorts-player, .html5-video-player');
      if (!main || main.classList.contains('ytp-inline-preview-mode')) return false;
      // Adverts play in the main player first: never count them (they also delayed Cinema, as the
      // real video then had to start its count again).
      if (main.classList.contains('ad-showing') || main.classList.contains('ad-interrupting')) return false;
      if (!/^\/(watch|live|shorts|embed)/.test(location.pathname)) return false;
    }
    return true;
  }
  const playedFor = new WeakMap(), lastCT = new WeakMap();
  function noteProgress(v) {
    const ct = v.currentTime, p = lastCT.get(v);
    if (p !== undefined) { const d = ct - p; if (d > 0 && d < 1.5) playedFor.set(v, (playedFor.get(v) || 0) + d); }
    lastCT.set(v, ct);
  }
  // 1.5 s of real playback (was 5 s, which with page start-up made Cinema feel ~10 s late). The
  // guards above (unmuted, >= 480 pt, main player on a watch page, no ad, no preview) do the filtering.
  const QUALIFY_S = 1.5;
  const qualified = (v) => (playedFor.get(v) || 0) >= QUALIFY_S;
  let engagedSent = false;   // this video was reported as playing (Cinema-qualified)

  function pick() {
    let best = null, bestA = 0;
    for (const v of allVideos()) {
      if (v.paused || v.ended || v.readyState < 2 || !candidate(v)) continue;
      const a = area(v);
      if (a > bestA && a > 120 * 70) { best = v; bestA = a; }
    }
    return best;
  }

  function send(msg) {
    try { chrome.runtime.sendMessage(msg); } catch (e) { stop(); }
  }

function dominant(d, W, x0, x1, y0, y1) {
    // Dominant VIVID colour of a region: 12 hue bins weighted by s^2 * v; near-grey and
    // near-black pixels are ignored unless the whole region is grey.
    const bins = Array.from({ length: 12 }, () => [0, 0, 0, 0]); // r, g, b, weight
    let ar = 0, ag = 0, ab = 0, an = 0;
    const sats = [];
    for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
      const o = (y * W + x) * 4, R = d[o], G = d[o + 1], B = d[o + 2];
      const mx = Math.max(R, G, B), mn = Math.min(R, G, B);
      const v = mx / 255, s = mx ? (mx - mn) / mx : 0;
      if (v >= 0.12) { ar += R; ag += G; ab += B; an++; sats.push(s); }
      if (s < 0.15 || v < 0.12) continue;
      let h;
      if (mx === R) h = ((G - B) / (mx - mn)) % 6; else if (mx === G) h = (B - R) / (mx - mn) + 2; else h = (R - G) / (mx - mn) + 4;
      const bin = Math.floor(((h * 60 + 360) % 360) / 30);
      const w = s * s * v;
      const b = bins[bin]; b[0] += R * w; b[1] += G * w; b[2] += B * w; b[3] += w;
    }
    // Pale/cream/grey regions (median saturation < 0.2): keep their real average colour;
    // picking the most saturated bin would turn cream into mustard.
    if (sats.length) { sats.sort((p, q) => p - q); if (sats[sats.length >> 1] < 0.2) return an ? [Math.round(ar / an), Math.round(ag / an), Math.round(ab / an)] : [0, 0, 0]; }
    let best = null;
    for (const b of bins) if (b[3] > 0 && (!best || b[3] > best[3])) best = b;
    if (best && best[3] > 0.02) return [Math.round(best[0] / best[3]), Math.round(best[1] / best[3]), Math.round(best[2] / best[3])];
    return an ? [Math.round(ar / an), Math.round(ag / an), Math.round(ab / an)] : [0, 0, 0];
  }

  function regions(d) {
    // [left, right, top, bottom, centre] average colours, ignoring near-black (letterbox).
    const boxes = [[0, 8, 0, H], [24, W, 0, H], [0, W, 0, 5], [0, W, 13, H], [8, 24, 4, 14]];
    let total = 0;
    const out = boxes.map(([x0, x1, y0, y1]) => {
      for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) { const o = (y * W + x) * 4; total += d[o] + d[o + 1] + d[o + 2]; }
      return dominant(d, W, x0, x1, y0, y1);
    });
    return { colors: out, black: total < W * H * 3 * 6 };
  }

  function tryAttachAudio(v) {
    // Only for CORS-clean media (the canvas read worked, so Web Audio won't output silence)
    // and only when the AudioContext is really running, so page audio can never break.
    if (attachedTo === v || !directOK || v.muted) return;
    if (attachedTo) return; // one element per page; keep it simple and safe
    try {
      actx = actx || new AudioContext();
      if (actx.state !== 'running') { actx.resume(); if (actx.state !== 'running') return; }
      const src = actx.createMediaElementSource(v);
      analyser = actx.createAnalyser();
      // Fine low-end resolution (about 5.9 Hz per bin at 48 kHz) so every bass bar is distinct.
      analyser.fftSize = 8192;
      analyser.smoothingTimeConstant = 0;   // our own attack/release below
      analyser.minDecibels = -100; analyser.maxDecibels = -10;
      src.connect(analyser);
      analyser.connect(actx.destination); // audio keeps playing through
      freq = new Float32Array(analyser.frequencyBinCount);
      attachedTo = v;
      audio = 'ok';
    } catch (e) {
      audio = 'no-audio';
    }
  }

  // A real analyser (the usual approach of audio visualisers such as audioMotion-analyzer,
  // re-implemented here): 28 log-spaced bands from 40 Hz to 16 kHz (about 1/3 octave), each the
  // peak dB of its bins (interpolated where a band is narrower than one bin), mapped from
  // -85 dB..-25 dB to 0..1. Fast attack, ~200 ms release. Silence -> bars drop to zero.
  const SPEC = 28, F0 = 40, F1 = 16000, DB_MIN = -85, DB_MAX = -25;
  const sOut = new Array(SPEC).fill(0), bOut = [0, 0, 0, 0];
  let lastAnalysis = 0;
  function dbAt(f, binHz) {
    const x = f / binHz, k = Math.floor(x), t = x - k;
    const a = freq[Math.min(k, freq.length - 1)], b = freq[Math.min(k + 1, freq.length - 1)];
    if (!isFinite(a) || !isFinite(b)) return Math.max(a, b);   // silence reports -Infinity
    return a + (b - a) * t;
  }
  function bandDb(lo, hi, binHz) {
    const a = Math.ceil(lo / binHz), b = Math.floor(hi / binHz);
    let mx = -Infinity;
    for (let k = a; k <= b && k < freq.length; k++) if (freq[k] > mx) mx = freq[k];
    const c = dbAt(Math.sqrt(lo * hi), binHz);       // centre, interpolated
    return Math.max(mx, c);
  }
  const norm = (db) => Math.min(1, Math.max(0, (db - DB_MIN) / (DB_MAX - DB_MIN)));
  function release(prev, v, dt) {
    // Exponential (ease-out) glide: ~30 ms attack, ~210 ms release. No jitter, no flicker.
    const k = Math.exp(-dt / (v >= prev ? 0.03 : 0.21));
    return v + (prev - v) * k;
  }

  // Dynamic range: a slow-moving loudness reference (fast up, ~6 s down) so quiet passages sit
  // low and peaks reach the top on any track. Beat punch: a bass transient (energy well above
  // its recent average) gives the bass bars a short extra kick.
  let ref = 0.5, bassAvg = 0, lastKick = 0, beats = 0, punch = 0;
  function bands() {
    if (audio !== 'ok' || !analyser) return null;
    analyser.getFloatFrequencyData(freq);
    const now = performance.now(), dt = lastAnalysis ? Math.min((now - lastAnalysis) / 1000, 0.25) : 0.04;
    lastAnalysis = now;
    const binHz = actx.sampleRate / analyser.fftSize;
    const raw = new Array(SPEC);
    let loud = 0;
    for (let i = 0; i < SPEC; i++) {
      const lo = F0 * Math.pow(F1 / F0, i / SPEC), hi = F0 * Math.pow(F1 / F0, (i + 1) / SPEC);
      raw[i] = norm(bandDb(lo, hi, binHz));
      if (raw[i] > loud) loud = raw[i];
    }
    ref = loud > ref ? loud : ref + (loud - ref) * (1 - Math.exp(-dt / 6));
    const r = Math.max(ref, 0.35);
    // Bass transient detection (40-160 Hz bands).
    let bass = 0; for (let i = 0; i < 6; i++) bass += raw[i]; bass /= 6;
    bassAvg = bassAvg + (bass - bassAvg) * (1 - Math.exp(-dt / 0.6));
    if (bass > bassAvg * 1.25 + 0.04 && bass > 0.35 && now - lastKick > 180) { lastKick = now; beats++; punch = 1; }
    punch *= Math.exp(-dt / 0.09);
    for (let i = 0; i < SPEC; i++) {
      let v = Math.min(1, Math.max(0, (raw[i] - 0.08) / (r - 0.08)));
      v = Math.pow(v, 1.6);                                     // more contrast: quiet low, peaks tall
      if (i < 8) v = Math.min(1, v + punch * 0.35 * (1 - i / 8));   // beat punch on the bass bars
      sOut[i] = release(sOut[i], v, dt);
    }
    const edges = [40, 250, 800, 2800, 12000];
    for (let i = 0; i < 4; i++) {
      let v = Math.min(1, Math.max(0, (norm(bandDb(edges[i], edges[i + 1], binHz)) - 0.08) / (r - 0.08)));
      v = Math.pow(v, 1.6); if (i === 0) v = Math.min(1, v + punch * 0.3);
      bOut[i] = release(bOut[i], v, dt);
    }
    lastSpectrum = sOut.map(x => Math.round(x * 100) / 100);
    return bOut.map(x => Math.round(x * 100) / 100);
  }

  let lastSpectrum = null;

  function step() {
    // The followed element stopped being a real "watching" video (YouTube reuses one <video> for
    // search-page previews and the main player): stop following it at once.
    if (enabled && video && !video.paused && !video.ended && video.isConnected && !candidate(video)) { leave('not-a-candidate'); return; }
    if (!enabled || !video || video.paused || video.ended || !video.isConnected) {
      if (lastState === 'playing' && engagedSent) send({ type: 'frame', state: video && video.ended ? 'ended' : 'paused', method, audio, domain: domain(), area: 0, ...(video ? mediaInfo(video) : {}) });
      lastState = 'paused';
      stop();
      return;
    }
    noteProgress(video);
    if (!qualified(video)) return;            // not yet 1.5 s of real playback: stay silent
    engagedSent = true;
    tick++;
    const now = Date.now();
    const msg = { type: 'frame', state: 'playing', method, audio, domain: domain(),
                  fullscreen: !!document.fullscreenElement, area: area(video), ...mediaInfo(video) };
    // Hidden page (covered window): no sampling at all, just a 1 s heartbeat.
    if (document.hidden) {
      if (now - lastSent > 1000) { lastSent = now; send(msg); }
      lastState = 'playing';
      return;
    }
    // Colours at 5 Hz (every 5th 40 ms tick).
    if (tick % 5 === 0) {
      if (method === 'direct') {
        try {
          g.drawImage(video, 0, 0, W, H);
          const res = regions(g.getImageData(0, 0, W, H).data);
          directOK = true;
          // All black while time advances: DRM (or a black scene). After ~2 s try the tab snapshot.
          if (res.black && video.currentTime !== lastTime) blackFrames++; else blackFrames = 0;
          lastTime = video.currentTime;
          if (blackFrames > 20) { method = 'snapshot'; }
          else msg.colors = res.colors;
        } catch (e) {
          method = 'snapshot'; // tainted canvas: cross-origin video without CORS
        }
      }
      if (method === 'snapshot') {
        const r = video.getBoundingClientRect();
        msg.rect = { x: r.left, y: r.top, w: r.width, h: r.height };
        msg.dpr = devicePixelRatio;
        msg.top = window === window.top;
        msg.frameUrl = location.href.split('#')[0];
      }
      tryAttachAudio(video);
    }
    {   // sound targets at 25 Hz (every 40 ms tick), only when they changed; Glance tweens at 60 fps
      const b = bands();
      if (b && (changed(b, lastSentBands, 0.03) || changed(lastSpectrum, lastSentSpec, 0.02))) {
        msg.bands = b; lastSentBands = b; msg.spectrum = lastSpectrum; lastSentSpec = lastSpectrum; msg.beats = beats;
      }
    }
    if (msg.colors) {
      const flat = msg.colors.flat();
      // Unchanged scene: skip, but refresh every 2 s so a restarted Glance gets colours too.
      if (changed(flat, lastSentColours, 4) || now - lastColoursAt > 2000) { lastSentColours = flat; lastColoursAt = now; } else delete msg.colors;
    }
    msg.method = method;
    msg.audio = audio;
    // Send only deltas; otherwise a 1 s heartbeat keeps the state alive.
    if (msg.colors || msg.bands || msg.rect || lastState !== 'playing' || now - lastSent > 1000) { lastSent = now; send(msg); }
    lastState = 'playing';
  }

  function stop() { if (loop) { clearInterval(loop); loop = null; } }
  let lastSent = 0, lastSentBands = null, lastSentColours = null, lastSentSpec = null, lastColoursAt = 0;
  function changed(a, b, eps) {
    if (!b || a.length !== b.length) return true;
    for (let i = 0; i < a.length; i++) if (Math.abs(a[i] - b[i]) > eps) return true;
    return false;
  }

  // Title + progress (sent only to Glance on this Mac).
  const fileLike = (t) => /\.(mp4|m4v|webm|ogv|ogg|mkv|mov|avi|m3u8|mpd)(\?|$)/i.test(t) || /^[\w.-]+_\d+[\w.-]*$/.test(t);
  function hash(s) { let h = 2166136261; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return (h >>> 0).toString(16); }

  function pageKey() {
    try {
      const canon = (document.querySelector('link[rel="canonical"]') || {}).href || '';
      const u = new URL(canon || location.href);
      const id = u.searchParams.get('v') || u.searchParams.get('id') || '';
      return u.hostname + u.pathname + (id ? '?' + id : '');
    } catch (e) { return location.hostname + location.pathname; }
  }

  function mediaInfo(v) {
    // Title preference: mediaSession (unless it's just a file name), og:title, then (in the
    // background) the cleaned tab title, and a file name only as a last resort.
    let ms = '';
    try { ms = (navigator.mediaSession && navigator.mediaSession.metadata && navigator.mediaSession.metadata.title) || ''; } catch (e) {}
    const og = (document.querySelector('meta[property="og:title"]') || {}).content || '';
    let file = '';
    try { file = decodeURIComponent((v.currentSrc || '').split('/').pop().split('?')[0]); } catch (e) {}
    const d = v.duration;
    const live = !isFinite(d) || d <= 0 || d > 6 * 3600;
    return {
      title: (ms && !fileLike(ms) ? ms : '').slice(0, 120),
      og: (og && !fileLike(og) ? og : '').slice(0, 120),
      fileTitle: file.replace(/\.[a-z0-9]{2,4}$/i, '').replace(/[_]+/g, ' ').slice(0, 80),
      // Stable media identity for "new video?" decisions: a hash only, never the URL itself.
      // blob: sources change on every load, so use the page identity instead (hashed here, in the page).
      // Title and duration are left out on purpose: both can arrive late and would change the id.
      mediaId: hash(pageKey() + '|' + (/^(blob|data|mediasource):/.test(v.currentSrc || '') ? '' : (v.currentSrc || '').split('?')[0])),
      time: Math.round(v.currentTime * 10) / 10, duration: live ? null : Math.round(d * 10) / 10, rate: v.playbackRate, live };
  }

  // While paused, a heartbeat every ~5 s so Glance can show the intermission.
  let lastBeat = 0;
  setInterval(() => {
    if (enabled && engagedSent && video && video.paused && !video.ended && video.isConnected && lastState === 'paused' && Date.now() - lastBeat > 5000) {
      lastBeat = Date.now();
      send({ type: 'frame', state: 'paused', method, audio, domain: domain(), area: 0, ...mediaInfo(video) });
    }
  }, 1500);

  // Commands from Glance (via the native host and background): only act on our video.
  chrome.runtime.onMessage.addListener((m, _s, reply) => {
    if (!m || m.type !== 'command' || !video) return;
    const v = video;
    const ok = (r) => reply({ ok: true, result: r || 'ok' });
    const fail = (e) => reply({ ok: false, result: String(e && e.name || e) });
    try {
      switch (m.cmd) {
        case 'toggle': (v.paused ? v.play() : (v.pause(), Promise.resolve())).then(() => ok(v.paused ? 'paused' : 'playing')).catch(fail); return true;
        case 'play': (v.paused ? v.play() : Promise.resolve()).then(() => ok('playing')).catch(fail); return true;
        case 'back': v.currentTime = Math.max(0, v.currentTime - 10); ok(); return;
        case 'forward': v.currentTime = Math.min(isFinite(v.duration) ? v.duration : v.currentTime + 10, v.currentTime + 10); ok(); return;
        case 'pip':
          if (document.pictureInPictureElement) { document.exitPictureInPicture().then(() => ok('pip-off')).catch(fail); return true; }
          if (v.requestPictureInPicture) { v.disablePictureInPicture = false; v.requestPictureInPicture().then(() => ok('pip-on')).catch(fail); return true; }
          fail('unsupported'); return;
        case 'fullscreen': {
          if (document.fullscreenElement) { document.exitFullscreen().then(() => ok('fs-off')).catch(fail); return true; }
          const target = v.closest('.html5-video-player') || v.parentElement || v;
          (target.requestFullscreen ? target.requestFullscreen() : Promise.reject('unsupported')).then(() => ok('fs-on')).catch(fail);
          return true;
        }
      }
    } catch (e) { fail(e); }
  });

  function check() {
    if (!enabled) { stop(); return; }
    const v = pick();
    if (v && v !== video) {
      // A different video: a paused, engaged one is replaced, so its intermission ends.
      if (video && engagedSent && video.paused) send({ type: 'frame', state: 'closed', domain: domain() });
      video = v; blackFrames = 0; method = 'direct'; directOK = false; engagedSent = false; lastState = '';
      if (attachedTo && attachedTo !== v) audio = 'no-audio';
    }
    if (v && !loop) loop = setInterval(step, 40);   // colours ~12 fps, bands ~25 Hz
    if (!v && video && loop) step();                 // sends paused once, then stops
  }

  // Hidden page: tell the background straight away; it decides tab-switch (stop) vs covered window (hold).
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden' && engagedSent && video && !video.paused && lastState === 'playing') {
      send({ type: 'frame', state: 'hidden', method, audio, domain: domain(), area: area(video), ...mediaInfo(video) });
    } else if (document.visibilityState === 'visible') { check(); }
  });
  document.addEventListener('play', check, true);
  // The element may not be ready at 'play' (readyState < 2): look again as soon as it is, instead
  // of waiting for the 1.5 s poll.
  const soon = () => { if (!loop) check(); };
  document.addEventListener('loadeddata', soon, true);
  document.addEventListener('canplay', soon, true);
  document.addEventListener('timeupdate', soon, true);
  document.addEventListener('playing', check, true);
  document.addEventListener('pause', () => setTimeout(check, 50), true);
  document.addEventListener('ended', () => setTimeout(check, 50), true);
  setInterval(check, 1500);
  check();

  // Leaving the followed video (navigation, page hidden for good, element reused): tell Glance
  // straight away and start from zero, so the next video must play 1.5 s again before Cinema.
  function leave(why) {
    if (engagedSent) send({ type: 'frame', state: 'closed', domain: domain() });
    if (video) { playedFor.delete(video); lastCT.delete(video); }
    video = null; engagedSent = false; lastState = ''; blackFrames = 0; stop();
  }

  // Single-page navigation (YouTube search -> watch, watch -> next video): new page, new count.
  let lastPath = location.pathname + location.search;
  function navigated() {
    const now = location.pathname + location.search;
    if (now === lastPath) return;
    lastPath = now;
    leave('navigated');
    setTimeout(check, 300);
  }
  window.addEventListener('yt-navigate-finish', navigated);
  document.addEventListener('yt-navigate-finish', navigated);
  window.addEventListener('popstate', navigated);
  setInterval(navigated, 500);
  // A new source in the same element (YouTube autoplay of the next video): the 1.5 s rule again.
  document.addEventListener('loadstart', e => {
    if (e.target !== video) return;
    if (engagedSent && lastState === 'playing') send({ type: 'frame', state: 'closed', domain: domain() });
    playedFor.delete(video); lastCT.delete(video); engagedSent = false; lastState = '';
  }, true);
  // Page going away (navigation, tab closed, bfcache): Glance stops at once, not after a timeout.
  window.addEventListener('pagehide', () => { if (engagedSent) send({ type: 'frame', state: 'closed', domain: domain() }); });

  // The top frame tells the background where its iframes are (for videos inside iframes).
  chrome.runtime.onMessage.addListener((m, _s, reply) => {
    if (m && m.type === 'iframeRects' && window === window.top) {
      reply([...document.querySelectorAll('iframe')].map(f => {
        const r = f.getBoundingClientRect();
        return { src: f.src || '', x: r.left, y: r.top, w: r.width, h: r.height };
      }).filter(f => f.w > 50 && f.h > 30));
    }
  });
})();
