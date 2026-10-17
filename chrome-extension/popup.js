const en = document.getElementById('en');
chrome.storage.local.get({ enabled: true }, v => { en.checked = v.enabled; });
en.addEventListener('change', () => chrome.storage.local.set({ enabled: en.checked }));
function refresh() {
  chrome.runtime.sendMessage({ type: 'status' }, s => {
    if (!s) return;
    const fresh = Date.now() - s.updated < 3000;
    const names = { direct: 'direct (reading the video)', snapshot: 'tab snapshot', protected: 'protected (DRM): Glance uses its accent', none: 'no video' };
    document.getElementById('status').textContent = 'Status: ' + (fresh && s.state === 'playing' ? (names[s.method] || s.method) + (s.audio === 'ok' ? ' · sound bars on' : '') : 'no video playing');
    document.getElementById('island').textContent = s.island ? 'Glance connected' : 'Glance not reachable';
    document.getElementById('dot').className = 'dot' + (s.island ? ' on' : '');
  });
}
refresh(); setInterval(refresh, 1000);
