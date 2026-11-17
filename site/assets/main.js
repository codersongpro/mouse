// 다운로드 버튼을 최신 릴리스의 zip 파일로 바로 연결하고 버전을 표시한다.
// Windows: ClassZoom-<버전>.zip / macOS: ClassZoom-<버전>-mac.zip
// 실패하면(네트워크·API 제한) 그대로 릴리스 페이지로 간다. 맥 zip이 아직 없는 릴리스면 맥 버튼도 릴리스 페이지로 간다.
fetch("https://api.github.com/repos/codersongpro/mouse/releases/latest", { headers: { Accept: "application/vnd.github+json" } })
  .then(r => r.ok ? r.json() : Promise.reject(r.status))
  .then(rel => {
    const assets = rel.assets || [];
    const ok = a => a && /^https:\/\/github\.com\//.test(a.browser_download_url);
    const win = assets.find(a => /^ClassZoom-[\d.]+\.zip$/i.test(a.name));
    const mac = assets.find(a => /-mac\.zip$/i.test(a.name));
    if (ok(win)) document.querySelectorAll(".js-download-win").forEach(a => a.href = win.browser_download_url);
    if (ok(mac)) document.querySelectorAll(".js-download-mac").forEach(a => a.href = mac.browser_download_url);
    if (/^v[\d.]+$/.test(rel.tag_name || ""))
      document.querySelectorAll(".js-version").forEach(s => s.textContent = rel.tag_name);
  })
  .catch(() => {});
