/**
 * Auto-Seedbox-PT (ASP) Screenshot 前端扩展
 * 由 Nginx 动态注入：/asp-screenshot.js
 */
(function() {
  console.log("📸 [ASP] Screenshot v1.3 已加载！");

  const SS_API = "/api/ss";

  const script = document.createElement('script');
  script.src = "/sweetalert2.all.min.js";
  document.head.appendChild(script);

  function getCurrentDir() {
    let path = window.location.pathname.replace(/^\/files/, '');
    return decodeURIComponent(path) || '/';
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[c]));
  }

  let lastRightClickedFile = "";
  document.addEventListener('contextmenu', function(e) {
    let row = e.target.closest('.item');
    if (row) {
      let nameEl = row.querySelector('.name');
      if (nameEl) lastRightClickedFile = nameEl.innerText.trim();
    } else lastRightClickedFile = "";
  }, true);

  document.addEventListener('click', function(e) {
    if (!e.target.closest('.asp-ss-btn-class') && !e.target.closest('.item[aria-selected="true"]')) lastRightClickedFile = "";
  }, true);

  const isMedia = (file) => file && file.match(/\.(mp4|mkv|avi|ts|m2ts|mov|webm|mpg|mpeg|wmv|flv|vob|iso)$/i);

  async function probeVideo(fullPath) {
    try {
      const r = await fetch(`${SS_API}?file=${encodeURIComponent(fullPath)}&probe=1`, { cache: 'no-store' });
      const j = await r.json().catch(() => ({}));
      if (r.ok && j && j.meta) return j.meta;
    } catch (e) {}
    return { width: null, height: null, duration: null };
  }

  function clamp(v, lo, hi, fallback) {
    v = parseInt(v, 10);
    if (!Number.isFinite(v)) return fallback;
    return Math.max(lo, Math.min(hi, v));
  }

  async function promptSettings(fileName) {
    if (typeof Swal === 'undefined') {
      alert('UI组件正在加载，请稍后再试...');
      return null;
    }

    const fullPath = (getCurrentDir() + '/' + fileName).replace(/\/\//g, '/');

    // Probe first (so default width = original width)
    Swal.fire({
      title: "读取视频信息...",
      html: "正在探测原始分辨率用于默认宽度",
      allowOutsideClick: false,
      didOpen: () => Swal.showLoading()
    });

    const meta = await probeVideo(fullPath);
    const origW = clamp(meta.width, 320, 3840, 1280);
    const origH = meta.height ? clamp(meta.height, 240, 2160, null) : null;

    const presetWs = [origW, 3840, 2560, 1920, 1280, 960, 720]
      .filter((v, i, a) => a.indexOf(v) === i) // unique
      .filter(v => v >= 320 && v <= 3840);

    const presetNs = [6, 8, 10, 12, 16];

    const html = `
      <style>
        .ss-form{display:grid;grid-template-columns:140px 1fr;gap:10px 12px;text-align:left}
        .ss-form label{opacity:.85}
        .ss-form input[type="number"]{width:100%;padding:8px 10px;border-radius:10px;border:1px solid rgba(255,255,255,.14);background:rgba(0,0,0,.22);color:#fff;outline:none}
        .ss-form input[type="range"]{width:100%}
        .ss-help{grid-column:1/-1;opacity:.7;font-size:12px;line-height:1.5}
        .ss-chiprow{display:flex;flex-wrap:wrap;gap:8px}
        .ss-chip{cursor:pointer;user-select:none;padding:6px 10px;border-radius:999px;border:1px solid rgba(255,255,255,.14);background:rgba(0,0,0,.18);font-size:12px;opacity:.92}
        .ss-chip:hover{background:rgba(0,0,0,.28)}
        .ss-badge{display:inline-block;padding:2px 8px;border:1px solid rgba(255,255,255,.14);border-radius:999px;font-size:12px;opacity:.9}
      </style>

      <div style="text-align:left;opacity:.9;margin-bottom:10px">
        文件：<code>${escapeHtml(fileName)}</code>
        <div class="ss-help">默认宽度 = 原始宽度 ${origW}${origH ? "×"+origH : ""}；输出到 <code>/tmp/asp_screens/</code></div>
      </div>

      <div class="ss-form">
        <label>截图数量</label>
        <div>
          <input id="ss_n" type="number" min="1" max="20" value="6"/>
          <div class="ss-help ss-chiprow" id="ss_n_chips">
            ${presetNs.map(n => `<span class="ss-chip" data-n="${n}">${n} 张</span>`).join("")}
          </div>
        </div>

        <label>宽度</label>
        <div>
          <input id="ss_w" type="number" min="320" max="3840" value="${origW}"/>
          <div class="ss-help ss-chiprow" id="ss_w_chips">
            ${presetWs.map(w => `<span class="ss-chip" data-w="${w}">${w} (${w === origW ? "原始" : ""})</span>`).join("")}
          </div>
        </div>

        <label>跳过片头(%)</label>
        <div>
          <input id="ss_head" type="range" min="0" max="20" value="5"/>
          <div class="ss-help">当前：<span class="ss-badge"><span id="ss_head_v">5</span>%</span></div>
        </div>

        <label>跳过片尾(%)</label>
        <div>
          <input id="ss_tail" type="range" min="0" max="20" value="5"/>
          <div class="ss-help">当前：<span class="ss-badge"><span id="ss_tail_v">5</span>%</span></div>
        </div>

        <div class="ss-help">说明：百分比用于避开 OP/ED/片尾字幕；需要更完整内容可调为 0。</div>
      </div>
    `;

    const result = await Swal.fire({
      title: "Screenshot 设置",
      html,
      width: 760,
      showCancelButton: true,
      confirmButtonText: "开始截图",
      cancelButtonText: "取消",
      didOpen: () => {
        const head = document.getElementById("ss_head");
        const tail = document.getElementById("ss_tail");
        const hv = document.getElementById("ss_head_v");
        const tv = document.getElementById("ss_tail_v");
        head.addEventListener("input", ()=> hv.textContent = head.value);
        tail.addEventListener("input", ()=> tv.textContent = tail.value);

        // chips
        const nInput = document.getElementById("ss_n");
        const wInput = document.getElementById("ss_w");

        document.getElementById("ss_n_chips").addEventListener("click", (e) => {
          const t = e.target.closest(".ss-chip");
          if (!t) return;
          const n = t.getAttribute("data-n");
          if (n) nInput.value = n;
        });

        document.getElementById("ss_w_chips").addEventListener("click", (e) => {
          const t = e.target.closest(".ss-chip");
          if (!t) return;
          const w = t.getAttribute("data-w");
          if (w) wInput.value = w;
        });
      },
      preConfirm: () => {
        const n = clamp(document.getElementById("ss_n").value, 1, 20, 6);
        const w = clamp(document.getElementById("ss_w").value, 320, 3840, origW);
        const head = clamp(document.getElementById("ss_head").value, 0, 20, 5);
        const tail = clamp(document.getElementById("ss_tail").value, 0, 20, 5);
        return { n, width: w, head, tail, fullPath, meta };
      }
    });

    if (!result.isConfirmed) return null;
    return result.value;
  }

  function openScreenshot(fileName) {
    promptSettings(fileName).then((opt) => {
      if (!opt) return;

      Swal.fire({
        title: '生成截图中...',
        html: `数量 <b>${opt.n}</b> / 宽度 <b>${opt.width}</b> / 跳过片头 <b>${opt.head}%</b> / 片尾 <b>${opt.tail}%</b>`,
        allowOutsideClick: false,
        didOpen: () => Swal.showLoading()
      });

      const url = `${SS_API}?file=${encodeURIComponent(opt.fullPath)}&n=${opt.n}&width=${opt.width}&head=${opt.head}&tail=${opt.tail}&fmt=jpg&zip=1`;

      fetch(url, { cache: 'no-store' })
        .then(r => r.json().then(j => ({ ok: r.ok, status: r.status, json: j })))
        .then(({ ok, status, json }) => {
          if (!ok || !json || !json.base || !Array.isArray(json.files) || json.files.length === 0) {
            const msg = (json && json.error) ? json.error : `请求失败 (HTTP ${status})`;
            throw new Error(msg);
          }

          const base = json.base;
          const imgs = json.files.map(f => `${base}${f}`);
          const zipUrl = json.zip ? `${base}${json.zip}` : null;

          let html = `<style>
            .ss-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:12px;margin-top:12px}
            .ss-card{border-radius:14px;overflow:hidden;border:1px solid rgba(255,255,255,.12);background:rgba(0,0,0,.22)}
            .ss-bar{padding:7px 10px;display:flex;justify-content:space-between;align-items:center}
            .ss-idx{font-weight:800}
            .ss-tip{opacity:.7;font-size:12px}
            .ss-img{width:100%;display:block}
            .ss-foot{margin-top:10px;opacity:.75;text-align:left;font-size:12px}
            .ss-foot code{background:rgba(0,0,0,.25);padding:2px 6px;border-radius:6px}
            .ss-actions{margin-top:10px;text-align:left;opacity:.85}
            .ss-actions a{color:#9cdcfe;text-decoration:none}
          </style>`;

          html += `<div style="text-align:left;opacity:.9">文件：<code>${escapeHtml(fileName)}</code></div>`;
          html += `<div class="ss-grid">` + imgs.map((u,i)=>`
              <a href="${u}" target="_blank" style="text-decoration:none">
                <div class="ss-card">
                  <div class="ss-bar"><div class="ss-idx">#${i+1}</div><div class="ss-tip">新标签打开</div></div>
                  <img class="ss-img" src="${u}" loading="lazy"/>
                </div>
              </a>`).join("") + `</div>`;

          html += `<div class="ss-foot">截图目录：<code>${base}</code> &nbsp; ZIP：<code>${json.zip || "未生成"}</code></div>`;
          html += `<div class="ss-actions">目录：<a href="${base}" target="_blank">${base}</a>${zipUrl ? ` &nbsp;|&nbsp; ZIP：<a href="${zipUrl}" target="_blank">${json.zip}</a>` : ""}</div>`;

          Swal.fire({
            title: '截图生成完成',
            html,
            width: '940px',
            showCancelButton: true,
            showDenyButton: true,
            confirmButtonText: '📦 一键打包下载',
            denyButtonText: '📁 打开截图目录',
            cancelButtonText: '关闭'
          }).then((result) => {
            if (result.isConfirmed) {
              if (zipUrl) window.open(zipUrl, "_blank");
              else window.open(base, "_blank");
            } else if (result.isDenied) {
              window.open(base, "_blank");
            }
          });
        })
        .catch(e => Swal.fire('截图失败', e.toString(), 'error'));
    });
  }

  // 注入按钮（仿 MediaInfo）
  let observerTimer = null;
  const observer = new MutationObserver(() => {
    if (observerTimer) clearTimeout(observerTimer);
    observerTimer = setTimeout(() => {
      let targetFile = "";
      if (lastRightClickedFile) targetFile = lastRightClickedFile;
      else {
        let selectedRows = document.querySelectorAll('.item[aria-selected="true"], .item.selected');
        if (selectedRows.length === 1) {
          let nameEl = selectedRows[0].querySelector('.name');
          if (nameEl) targetFile = nameEl.innerText.trim();
        }
      }

      let ok = isMedia(targetFile);

      let menus = new Set();
      document.querySelectorAll('button[aria-label="Info"]').forEach(btn => {
        if (btn.parentElement) menus.add(btn.parentElement);
      });

      menus.forEach(menu => {
        let existingBtn = menu.querySelector('.asp-ss-btn-class');
        if (ok) {
          if (!existingBtn) {
            let btn = document.createElement('button');
            btn.className = 'action asp-ss-btn-class';
            btn.setAttribute('title', 'Screenshot');
            btn.setAttribute('aria-label', 'Screenshot');
            btn.innerHTML = '<i class="material-icons">photo_camera</i><span>Screenshot</span>';

            btn.onclick = function(ev) {
              ev.preventDefault();
              ev.stopPropagation();
              document.body.click();
              openScreenshot(targetFile);
            };

            let miBtn = menu.querySelector('.asp-mi-btn-class');
            if (miBtn) miBtn.insertAdjacentElement('afterend', btn);
            else {
              let infoBtn = menu.querySelector('button[aria-label="Info"]');
              if (infoBtn) infoBtn.insertAdjacentElement('afterend', btn);
              else menu.appendChild(btn);
            }
          } else {
            let miBtn = menu.querySelector('.asp-mi-btn-class');
            if (miBtn && existingBtn.previousElementSibling !== miBtn) miBtn.insertAdjacentElement('afterend', existingBtn);
          }
        } else {
          if (existingBtn) existingBtn.remove();
        }
      });
    }, 100);
  });

  observer.observe(document.body, { childList: true, subtree: true });
})();
