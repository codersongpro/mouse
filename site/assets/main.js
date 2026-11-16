// 다운로드 버튼을 최신 릴리스의 zip 파일로 바로 연결하고 버전을 표시한다.
// 실패하면(네트워크·API 제한) 그대로 릴리스 페이지로 간다.
fetch("https://api.github.com/repos/codersongpro/mouse/releases/latest", { headers: { Accept: "application/vnd.github+json" } })
  .then(r => r.ok ? r.json() : Promise.reject(r.status))
  .then(rel => {
    const zip = (rel.assets || []).find(a => /\.zip$/i.test(a.name));
    if (zip && /^https:\/\/github\.com\//.test(zip.browser_download_url))
      document.querySelectorAll(".js-download").forEach(a => a.href = zip.browser_download_url);
    if (/^v[\d.]+$/.test(rel.tag_name || ""))
      document.querySelectorAll(".js-version").forEach(s => s.textContent = rel.tag_name);
  })
  .catch(() => {});
