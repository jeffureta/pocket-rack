import Foundation

public enum AdminConsole {
    public static func htmlDocument() -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <title>PocketRack Console</title>
          <style>
            :root { --bg:#0d1117; --card:#161b22; --border:#30363d; --text:#e6edf3; --muted:#8b949e; --accent:#58a6ff; --ok:#3fb950; --warn:#d29922; --bad:#f85149; }
            * { box-sizing:border-box; }
            body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif; background:var(--bg); color:var(--text); }
            header { display:flex; align-items:center; justify-content:space-between; padding:14px 20px; border-bottom:1px solid var(--border); background:var(--card); }
            .brand { font-weight:700; font-size:17px; display:flex; gap:10px; align-items:center; }
            .pill { font-size:12px; padding:3px 9px; border-radius:999px; border:1px solid var(--border); color:var(--muted); }
            .wrap { max-width:1100px; margin:20px auto; padding:0 16px; }
            .tabs { display:flex; gap:8px; margin-bottom:16px; flex-wrap:wrap; }
            .tab { background:var(--card); color:var(--muted); border:1px solid var(--border); padding:8px 14px; border-radius:8px; cursor:pointer; font-weight:600; }
            .tab.active { color:var(--text); border-color:var(--accent); }
            .card { background:var(--card); border:1px solid var(--border); border-radius:10px; padding:16px; margin-bottom:16px; }
            .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(210px,1fr)); gap:12px; }
            .stat-label { font-size:12px; color:var(--muted); }
            .stat-val { font-size:22px; font-weight:700; margin-top:4px; }
            input, textarea, select, button { font:inherit; }
            input, textarea { width:100%; background:#0b0f14; color:var(--text); border:1px solid var(--border); border-radius:8px; padding:9px 11px; }
            button.primary { background:var(--accent); color:#04111f; border:none; border-radius:8px; padding:9px 14px; font-weight:700; cursor:pointer; }
            button.ghost { background:transparent; color:var(--text); border:1px solid var(--border); border-radius:8px; padding:7px 12px; cursor:pointer; }
            table { width:100%; border-collapse:collapse; font-size:13px; }
            th, td { text-align:left; padding:8px; border-bottom:1px solid var(--border); }
            .dropzone { border:2px dashed var(--border); border-radius:10px; padding:22px; text-align:center; color:var(--muted); margin-bottom:12px; }
            .dropzone.drag { border-color:var(--accent); color:var(--text); }
            .hidden { display:none; }
            code, pre { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12px; }
            pre { background:#0b0f14; padding:10px; border-radius:8px; overflow:auto; max-height:240px; }
          </style>
        </head>
        <body>
          <header>
            <div class="brand">PocketRack <span class="pill" id="ver-pill">M2 Server</span></div>
            <button class="ghost hidden" id="logout-btn" onclick="logout()">Log out</button>
          </header>
          <div class="wrap">
            <div class="card" id="login-card">
              <h3>Sign In</h3>
              <p style="color:var(--muted);font-size:14px;">Enter the Bearer token shown on your iPad PocketRack dashboard.</p>
              <div style="display:flex;gap:8px;max-width:460px;">
                <input id="token-input" type="password" placeholder="Access Token" />
                <button class="primary" onclick="login()">Unlock</button>
              </div>
              <p id="login-err" style="color:var(--bad);font-size:13px;"></p>
            </div>

            <div id="console-app" class="hidden">
              <div class="tabs">
                <button class="tab active" onclick="showTab('overview', this)">Overview &amp; Capacity</button>
                <button class="tab" onclick="showTab('files', this)">Files</button>
                <button class="tab" onclick="showTab('data', this)">Collections &amp; KV</button>
                <button class="tab" onclick="showTab('webhooks', this)">Webhooks</button>
                <button class="tab" onclick="showTab('logs', this)">Logs</button>
              </div>

              <section id="tab-overview" class="tab-panel">
                <div class="grid" id="health-grid"></div>
              </section>

              <section id="tab-files" class="tab-panel hidden">
                <div class="card">
                  <div class="dropzone" id="dropzone">Drag &amp; drop files here to stream-upload to <code id="cwd-label">/</code> or <input type="file" id="file-picker" multiple style="width:auto;border:none;" /></div>
                  <div style="display:flex;gap:8px;margin-bottom:12px;">
                    <input id="mkdir-input" placeholder="New folder name" style="max-width:260px;" />
                    <button class="ghost" onclick="createFolder()">Create Folder</button>
                    <button class="ghost" onclick="loadFiles('')">Root</button>
                    <button class="ghost" onclick="refreshFiles()">Refresh</button>
                  </div>
                  <table><thead><tr><th>Name</th><th>Size</th><th>Actions</th></tr></thead><tbody id="files-body"></tbody></table>
                </div>
              </section>

              <section id="tab-data" class="tab-panel hidden">
                <div class="card">
                  <h4>Collections</h4>
                  <div style="display:flex;gap:8px;margin-bottom:8px;">
                    <input id="col-name" placeholder="Collection (e.g. notes)" style="max-width:220px;" />
                    <button class="ghost" onclick="loadCollection()">Load</button>
                  </div>
                  <textarea id="col-json" rows="3" placeholder='{"title":"Hello iPad"}'></textarea>
                  <button class="primary" style="margin-top:8px;" onclick="createDoc()">Create Document</button>
                  <pre id="col-output">[]</pre>
                </div>
                <div class="card">
                  <h4>KV Store</h4>
                  <div style="display:flex;gap:8px;margin-bottom:8px;">
                    <input id="kv-key" placeholder="Key" />
                    <input id="kv-val" placeholder="Value" />
                    <input id="kv-ttl" placeholder="TTL sec (opt)" style="max-width:140px;" />
                    <button class="primary" onclick="setKV()">Save</button>
                  </div>
                  <pre id="kv-output">[]</pre>
                </div>
              </section>

              <section id="tab-webhooks" class="tab-panel hidden">
                <div class="card">
                  <div style="display:flex;justify-content:space-between;align-items:center;">
                    <span>POST any payload to <code>/api/v1/webhooks/&lt;hook&gt;</code></span>
                    <div>
                      <button class="ghost" onclick="loadWebhooks()">Refresh</button>
                      <button class="ghost" onclick="clearWebhooks()">Clear</button>
                    </div>
                  </div>
                  <pre id="webhooks-output">[]</pre>
                </div>
              </section>

              <section id="tab-logs" class="tab-panel hidden">
                <div class="card">
                  <button class="ghost" onclick="loadLogs()" style="margin-bottom:8px;">Refresh Logs</button>
                  <pre id="logs-output">[]</pre>
                </div>
              </section>
            </div>
          </div>

          <script>
            let cwd = '';
            const fmtBytes = b => {
              if (b < 1024) return b + ' B';
              const u = ['KB','MB','GB','TB']; let i = -1;
              do { b /= 1024; i++; } while (b >= 1024 && i < u.length - 1);
              return b.toFixed(1) + ' ' + u[i];
            };
            async function api(url, opts = {}) {
              const res = await fetch(url, { credentials: 'same-origin', ...opts });
              if (res.status === 401) { showLogin(); throw new Error('Unauthorized'); }
              return res;
            }
            function showLogin() {
              document.getElementById('login-card').classList.remove('hidden');
              document.getElementById('console-app').classList.add('hidden');
              document.getElementById('logout-btn').classList.add('hidden');
            }
            function showApp() {
              document.getElementById('login-card').classList.add('hidden');
              document.getElementById('console-app').classList.remove('hidden');
              document.getElementById('logout-btn').classList.remove('hidden');
              refreshOverview(); loadFiles(''); loadKV(); loadWebhooks(); loadLogs();
            }
            async function login() {
              const token = document.getElementById('token-input').value.trim();
              const res = await fetch('/_admin/auth/login', {
                method: 'POST', credentials: 'same-origin',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ token })
              });
              if (res.ok) { document.getElementById('login-err').textContent = ''; showApp(); }
              else { document.getElementById('login-err').textContent = 'Invalid token'; }
            }
            async function logout() {
              await fetch('/_admin/auth/logout', { method: 'POST', credentials: 'same-origin' });
              showLogin();
            }
            function showTab(name, btn) {
              document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
              document.querySelectorAll('.tab-panel').forEach(p => p.classList.add('hidden'));
              btn.classList.add('active');
              document.getElementById('tab-' + name).classList.remove('hidden');
            }
            async function refreshOverview() {
              const res = await api('/api/v1/health');
              const h = await res.json();
              if (!('effectiveConnectionLimit' in h)) { showLogin(); return; }
              document.getElementById('ver-pill').textContent = 'v' + h.version;
              const stats = [
                ['Thermal State', h.thermalState],
                ['Sockets', h.activeConnections + ' / ' + h.effectiveConnectionLimit],
                ['RAM Headroom', fmtBytes(h.availableMemoryBytes)],
                ['Storage Used / Quota', fmtBytes(h.storageUsedBytes) + ' / ' + fmtBytes(h.storageQuotaBytes)],
                ['Volume Free / Floor', fmtBytes(h.volumeFreeBytes) + ' / ' + fmtBytes(h.minFreeFloorBytes)]
              ];
              document.getElementById('health-grid').innerHTML = stats.map(([k,v]) =>
                `<div class="card"><div class="stat-label">${k}</div><div class="stat-val">${v}</div></div>`).join('');
            }
            async function loadFiles(path) {
              cwd = path;
              document.getElementById('cwd-label').textContent = '/' + cwd;
              const res = await api('/api/v1/files?path=' + encodeURIComponent(cwd));
              const data = await res.json();
              const rows = data.items.map(it => `<tr>
                <td>${it.isDirectory ? '📁 ' : '📄 '}<a href="#" style="color:var(--accent)" onclick="${it.isDirectory ? `loadFiles('${it.path}')` : `downloadFile('${it.path}')`};return false;">${it.name}</a></td>
                <td>${it.isDirectory ? '-' : fmtBytes(it.size)}</td>
                <td><button class="ghost" onclick="deleteFile('${it.path}')">Delete</button></td>
              </tr>`).join('');
              document.getElementById('files-body').innerHTML = rows || '<tr><td colspan="3" style="color:var(--muted)">Empty folder</td></tr>';
            }
            function refreshFiles() { loadFiles(cwd); }
            function downloadFile(p) { window.open('/api/v1/files/' + p, '_blank'); }
            async function deleteFile(p) { await api('/api/v1/files/' + p, { method: 'DELETE' }); refreshFiles(); }
            async function createFolder() {
              const name = document.getElementById('mkdir-input').value.trim();
              if (!name) return;
              const full = cwd ? cwd + '/' + name : name;
              await api('/api/v1/files/mkdir', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({path:full}) });
              document.getElementById('mkdir-input').value = '';
              refreshFiles();
            }
            async function uploadFiles(fileList) {
              for (const f of fileList) {
                const target = cwd ? cwd + '/' + f.name : f.name;
                await api('/api/v1/files/' + target, { method:'PUT', body:f });
              }
              refreshFiles(); refreshOverview();
            }
            const dz = document.getElementById('dropzone');
            dz.addEventListener('dragover', e => { e.preventDefault(); dz.classList.add('drag'); });
            dz.addEventListener('dragleave', () => dz.classList.remove('drag'));
            dz.addEventListener('drop', e => { e.preventDefault(); dz.classList.remove('drag'); uploadFiles(e.dataTransfer.files); });
            document.getElementById('file-picker').addEventListener('change', e => uploadFiles(e.target.files));
            async function loadCollection() {
              const name = document.getElementById('col-name').value.trim() || 'notes';
              const res = await api('/api/v1/collections/' + encodeURIComponent(name));
              document.getElementById('col-output').textContent = JSON.stringify(await res.json(), null, 2);
            }
            async function createDoc() {
              const name = document.getElementById('col-name').value.trim() || 'notes';
              const body = document.getElementById('col-json').value.trim();
              await api('/api/v1/collections/' + encodeURIComponent(name), { method:'POST', headers:{'Content-Type':'application/json'}, body });
              loadCollection();
            }
            async function loadKV() {
              const res = await api('/api/v1/kv');
              document.getElementById('kv-output').textContent = JSON.stringify(await res.json(), null, 2);
            }
            async function setKV() {
              const k = document.getElementById('kv-key').value.trim();
              const v = document.getElementById('kv-val').value;
              const ttl = parseInt(document.getElementById('kv-ttl').value, 10);
              const payload = Number.isFinite(ttl) ? { value:v, ttlSeconds:ttl } : { value:v };
              await api('/api/v1/kv/' + encodeURIComponent(k), { method:'PUT', headers:{'Content-Type':'application/json'}, body:JSON.stringify(payload) });
              loadKV();
            }
            async function loadWebhooks() {
              const res = await api('/api/v1/admin/webhooks');
              document.getElementById('webhooks-output').textContent = JSON.stringify(await res.json(), null, 2);
            }
            async function clearWebhooks() { await api('/api/v1/admin/webhooks', { method:'DELETE' }); loadWebhooks(); }
            async function loadLogs() {
              const res = await api('/api/v1/admin/logs');
              document.getElementById('logs-output').textContent = JSON.stringify(await res.json(), null, 2);
            }
            fetch('/api/v1/health', { credentials:'same-origin' }).then(r => r.json()).then(d => {
              if ('effectiveConnectionLimit' in d) showApp();
            }).catch(() => {});
          </script>
        </body>
        </html>
        """
    }
}
