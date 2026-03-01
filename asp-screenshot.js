/**
 * Auto-Seedbox-PT (ASP) Screenshot 前端扩展
 * 由 Nginx 底层动态注入（/asp-screenshot.js）
 * 依赖：SweetAlert2（脚本已在页面注入 /sweetalert2.all.min.js）
 */
(function() {
    console.log("📸 [ASP] Screenshot v1.0 已加载！");

    const SS_API = "/api/ss";
    const DEFAULT_N = 6;
    const DEFAULT_W = 1280;

    // 动态引入弹窗 UI 库（和 MediaInfo 一致）
    const script = document.createElement('script');
    script.src = "/sweetalert2.all.min.js";
    document.head.appendChild(script);

    // 当前目录（和 MediaInfo 一致：基于 pathname，而不是 hash）
    function getCurrentDir() {
        let path = window.location.pathname.replace(/^\/files/, '');
        return decodeURIComponent(path) || '/';
    }

    // 兼容剪贴板复制
    const copyText = (text) => {
        if (navigator.clipboard && window.isSecureContext) {
            return navigator.clipboard.writeText(text);
        } else {
            let textArea = document.createElement("textarea");
            textArea.value = text;
            textArea.style.position = "fixed";
            textArea.style.opacity = "0";
            document.body.appendChild(textArea);
            textArea.focus();
            textArea.select();
            return new Promise((res, rej) => {
                document.execCommand('copy') ? res() : rej();
                textArea.remove();
            });
        }
    };

    function escapeHtml(s) {
        return String(s).replace(/[&<>"']/g, (c) => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[c]));
    }

    let lastRightClickedFile = "";

    // 捕获右键选中目标（和 MediaInfo 一致）
    document.addEventListener('contextmenu', function(e) {
        let row = e.target.closest('.item');
        if (row) {
            let nameEl = row.querySelector('.name');
            if (nameEl) lastRightClickedFile = nameEl.innerText.trim();
        } else {
            lastRightClickedFile = "";
        }
    }, true);

    // 左键点击任意非按钮区域清空右键记忆，防止幽灵状态
    document.addEventListener('click', function(e) {
        if (!e.target.closest('.asp-ss-btn-class') && !e.target.closest('.item[aria-selected="true"]')) {
            lastRightClickedFile = "";
        }
    }, true);

    const isMedia = (file) => file && file.match(/\.(mp4|mkv|avi|ts|m2ts|mov|webm|mpg|mpeg|wmv|flv|vob|iso)$/i);

    const openScreenshot = (fileName) => {
        let fullPath = (getCurrentDir() + '/' + fileName).replace(/\/\//g, '/');

        if (typeof Swal === 'undefined') {
            alert('UI组件正在加载，请稍后再试...'); return;
        }

        Swal.fire({
            title: '生成截图中...',
            html: `默认 <b>${DEFAULT_N}</b> 张 / 宽度 <b>${DEFAULT_W}</b> / 输出到 <code>/tmp</code>`,
            allowOutsideClick: false,
            didOpen: () => Swal.showLoading()
        });

        fetch(`${SS_API}?file=${encodeURIComponent(fullPath)}&n=${DEFAULT_N}&width=${DEFAULT_W}&fmt=jpg`, { cache: 'no-store' })
        .then(r => r.json())
        .then(data => {
            if (data.error) throw new Error(data.error);
            if (!data.base || !data.files || !data.files.length) throw new Error("返回数据异常");

            const imgs = data.files.map(f => `${data.base}${f}`);
            const links = imgs.map(u => location.origin + u).join("\n");

            let html = `<style>
                .ss-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:12px;margin-top:12px}
                .ss-card{border-radius:14px;overflow:hidden;border:1px solid rgba(255,255,255,.12);background:rgba(0,0,0,.22)}
                .ss-bar{padding:7px 10px;display:flex;justify-content:space-between;align-items:center}
                .ss-idx{font-weight:800}
                .ss-tip{opacity:.7;font-size:12px}
                .ss-img{width:100%;display:block}
                .ss-foot{margin-top:10px;opacity:.75;text-align:left;font-size:12px}
                .ss-foot code{background:rgba(0,0,0,.25);padding:2px 6px;border-radius:6px}
            </style>`;

            html += `<div style="text-align:left;opacity:.9">文件：<code>${escapeHtml(fileName)}</code></div>`;
            html += `<div class="ss-grid">` + imgs.map((u,i)=>`
                <a href="${u}" target="_blank" style="text-decoration:none">
                  <div class="ss-card">
                    <div class="ss-bar"><div class="ss-idx">#${i+1}</div><div class="ss-tip">新标签打开</div></div>
                    <img class="ss-img" src="${u}" loading="lazy"/>
                  </div>
                </a>`).join("") + `</div>`;
            html += `<div class="ss-foot">截图存放：<code>/tmp/asp_screens/</code>（服务端会自动清理旧文件）</div>`;

            Swal.fire({
                title: '截图生成完成',
                html,
                width: '940px',
                showCancelButton: true,
                showDenyButton: true,
                confirmButtonText: '📋 复制链接',
                denyButtonText: '打开目录',
                cancelButtonText: '关闭'
            }).then((result) => {
                if (result.isConfirmed) {
                    copyText(links).then(() => {
                        Swal.fire({toast:true, position:'top-end', icon:'success', title:'截图链接已复制', showConfirmButton:false, timer:2000});
                    }).catch(() => Swal.fire('复制失败', '请手动复制弹窗中的链接', 'error'));
                } else if (result.isDenied) {
                    window.open(window.location.href, "_blank");
                }
            });
        })
        .catch(e => Swal.fire('截图失败', e.toString(), 'error'));
    };

    // 防抖注入按钮（仿 MediaInfo）
    let observerTimer = null;
    const observer = new MutationObserver(() => {
        if (observerTimer) clearTimeout(observerTimer);
        observerTimer = setTimeout(() => {
            let targetFile = "";
            if (lastRightClickedFile) {
                targetFile = lastRightClickedFile;
            } else {
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

                        // 位置：优先插在 MediaInfo 后面（倒数第二）
                        let miBtn = menu.querySelector('.asp-mi-btn-class');
                        if (miBtn) {
                            miBtn.insertAdjacentElement('afterend', btn);
                        } else {
                            let infoBtn = menu.querySelector('button[aria-label="Info"]');
                            if (infoBtn) {
                                infoBtn.insertAdjacentElement('afterend', btn);
                            } else {
                                menu.appendChild(btn);
                            }
                        }
                    } else {
                        // 若后来出现 MediaInfo，把截图按钮移到其后
                        let miBtn = menu.querySelector('.asp-mi-btn-class');
                        if (miBtn && existingBtn.previousElementSibling !== miBtn) {
                            miBtn.insertAdjacentElement('afterend', existingBtn);
                        }
                    }
                } else {
                    if (existingBtn) existingBtn.remove();
                }
            });
        }, 100);
    });

    observer.observe(document.body, { childList: true, subtree: true });
})();
