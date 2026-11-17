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

// 히어로 그림: 전자칠판 수업 장면을 0→1→2→3 순서로 돌린다 (단계 버튼을 누르면 그 장면부터).
// 움직임 줄이기를 켠 기기에서는 마지막 장면(녹화까지 다 보이는 상태)에 멈춰 둔다.
(() => {
  const board = document.querySelector(".js-demo");
  if (!board) return;
  const btns = document.querySelectorAll(".demo-steps [data-go]");
  const time = board.querySelector(".js-rec-time");
  const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const HOLD = [2600, 2800, 2600, 3200]; // 장면마다 머무는 시간(ms)
  let step = 0, timer = 0, recTimer = 0, sec = 0;

  function show(n) {
    step = n;
    board.dataset.step = String(n);
    btns.forEach(b => b.setAttribute("aria-pressed", String(Number(b.dataset.go) === n)));
    clearInterval(recTimer);
    if (n === 3) {
      sec = 0;
      const tick = () => { time.textContent = "녹화 중 00:" + String(sec++).padStart(2, "0"); };
      tick();
      if (!still) recTimer = setInterval(tick, 1000);
    }
    clearTimeout(timer);
    if (!still) timer = setTimeout(() => show((step + 1) % 4), HOLD[n]);
  }
  btns.forEach(b => b.addEventListener("click", () => show(Number(b.dataset.go))));
  // 화면 밖에 있을 때는 멈춘다 (배터리·성능)
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) { clearTimeout(timer); clearInterval(recTimer); } else show(step);
  });
  show(still ? 3 : 0);
})();
