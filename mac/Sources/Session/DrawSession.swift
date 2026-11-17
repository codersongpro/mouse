import AppKit

// 드로잉을 끄는 이유. 끄는 길은 모두 DrawSession.turnOff(_:) 하나를 지난다.
// (설계도 3절 표: architecture.md)
enum OffReason: String {
    case esc            // Esc: 그린 것과 칠판을 지우고 나간다 (⌘Z로 되살릴 수 있다)
    case widgetButton   // 위젯의 드로잉 버튼: Esc와 같다 (Windows와 같음)
    case hotkey         // F9·⌃⌥2: 그린 것을 그대로 남긴다 (Windows와 같음)
    case appSwitch      // 다른 앱이 앞으로 나옴 (⌘Tab 등): Esc처럼 끈다 (선생님 결정 ②)
    case spaceChange    // 다른 데스크톱으로 넘어감: Esc처럼 끈다 (결정 ②)
    case gesture        // 네 손가락 제스처(Mission Control·데스크톱 넘기기)가 시작됨: 알림보다 먼저 끈다
    case sleep          // 잠자기·화면 꺼짐: Esc처럼 끈다 (D7)
    case lock           // 화면 잠금·사용자 전환: Esc처럼 끈다 (D7)
    case settings       // 설정 창 열기: 남긴다 (우리 앱이 앞으로 나오므로 끈다)
    case quit           // 종료: 남긴다 (의미 없음)
    case hold           // 오른쪽 ⌥를 뗌: 그린 것을 화면에 남기고 클릭만 통과시킨다 (holdEnd)

    // 그린 것과 칠판을 지우고 나가는가
    var clearsInk: Bool { self != .hotkey && self != .settings && self != .quit && self != .hold }
}

// 드로잉 켜기·끄기의 순서를 지킨다. 그림·펜 상태는 DrawController가, 판(창)은 InkSurface가,
// 드로잉 키 단축키는 DrawKeys가 든다. "켜졌는가"는 AppState.drawOn이 유일한 출처다.
@MainActor final class DrawSession {
    let state: AppState
    let controller: DrawController
    let keys = DrawKeys()
    var surface: InkSurface { controller.surface }
    // 설정에서 복사본을 만들어 주는 곳 (AppDelegate가 채운다 — 그리기 코드는 Settings를 읽지 않는다)
    var makeConfig: () -> DrawConfig = { DrawConfig() }
    var onKeysFailed: (HotKeyGroupResult) -> Void = { _ in } // 드로잉 키를 못 잡아 켜지 못했을 때 (안내 창은 AppDelegate가)
    var willTurnOn: () -> Void = {} // 드로잉 키를 잡기 직전 (라이브 줌이 Esc를 내려놓는다)

    var isOn: Bool { state.drawOn }
    private var observers: [NSObjectProtocol] = []   // 드로잉 중에만 걸어 두는 시스템 알림 (앱·데스크톱·잠자기·잠금)
    var inkWindowNumbers: [Int] { surface.windowNumbers }

    init(state: AppState) {
        self.state = state
        controller = DrawController(state: state)
        controller.requestOff = { [weak self] reason in self?.turnOff(reason) }
        keys.isDrawing = { [weak self] in self?.state.drawOn == true }
        keys.onKey = { [weak self] code, flags, rep in self?.controller.handleKey(code, flags, isRepeat: rep, source: "hk") }
        keys.onKeyUp = { [weak self] code in self?.controller.handleKeyUp(code, source: "hk") }
    }

    func toggle() { isOn ? turnOff(.hotkey) : turnOn() }

    // ---------- 오른쪽 ⌥를 누르는 동안 드로잉 ----------
    // F9 없이 오른쪽 ⌥를 누르고 있는 동안만 드로잉이 켜진다. 그 사이 드로잉 키(V 강조 화살표, C 화살표, ⌃ 네모, 숫자 색 …)도
    // 그대로 쓴다. 떼면 드로잉이 꺼지지만 그린 것과 강조 화살표는 화면에 남고 클릭만 아래 앱으로 통과한다(pinned).
    // 지우기: 오른쪽 ⌥ + delete 또는 + esc. 왼쪽 ⌥는 그대로 지우개다. 설정 › 드로잉에서 끌 수 있다.
    // 판은 키 창이 아니라 수식키 알림이 오지 않으므로 15Hz로 키 상태만 읽는다 (권한 불필요, 거의 공짜).
    private(set) var holdActive = false
    private(set) var pinned = false
    private var holdWaitRelease = false
    private var holdTimer: Timer?

    func setHoldEnabled(_ on: Bool) {
        if on, holdTimer == nil {
            let t = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.holdTick() } }
            RunLoop.main.add(t, forMode: .common)
            holdTimer = t
        } else if !on {
            holdTimer?.invalidate(); holdTimer = nil
        }
    }

    private func holdTick() {
        let down = ModifierWatch.rightOptionDown()
        if holdWaitRelease { if !down { holdWaitRelease = false }; return }
        if down, !holdActive, !isOn {
            holdActive = true
            controller.holdRightOption = true
            turnOn()
            if !isOn { holdActive = false; controller.holdRightOption = false; holdWaitRelease = true }
        } else if !down, holdActive {
            if NSEvent.pressedMouseButtons & 1 != 0 { return } // 긋는 도중이면 손을 뗀 뒤에 끈다
            turnOff(.hold)
        }
    }

    func turnOn() {
        guard !isOn else { return }
        controller.config = makeConfig()
        // 오른쪽 ⌥로 이어 쓰는 동안(그림이 남아 있는 동안)은 고른 색·펜을 그대로 둔다
        if !(holdActive && pinned) { controller.resetTemporaries() }
        controller.expireUndoIfNeeded()
        surface.prepare()
        willTurnOn()
        // 드로잉 키는 하나라도 못 잡으면 등록부가 묶음 전체를 되돌린다 → 켜지 않고 알린다
        let r = keys.registerAll()
        guard r.ok else {
            Log.log("DRAW", "on refused: draw keys failed=\(r.failed.count) first=\(r.failed.first.map { "\($0.name) \(describeHotKeyStatus($0.status))" } ?? "-")")
            onKeysFailed(r)
            return
        }
        state.drawOn = true
        if pinned { surface.setPassThrough(false); pinned = false } // 남겨 둔 그림 위에 다시 그린다
        surface.show() // 앱을 앞으로 부르지 않는다 — 발표 앱이 앞에 그대로 있다
        controller.begin()
        startWatching()
        Log.log("DRAW", "on front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-") windows=\(surface.windows.count)")
    }

    func turnOff(_ reason: OffReason) {
        guard isOn else { return }
        stopWatching()
        controller.finishSession(clear: reason.clearsInk)
        // 드로잉·막기 키 단축키를 반드시 푼다 (안 풀리면 시스템 전체에서 그 글자를 못 친다)
        let freed = keys.unregisterAll(lingerEsc: reason == .esc)
        state.drawOn = false
        if reason == .hold {
            // 그린 것과 강조 화살표는 화면에 남기고 클릭만 아래 앱으로 통과
            surface.setPassThrough(true)
            pinned = true
            holdActive = false
            controller.end(keepPulse: true)
        } else {
            surface.hide()
            pinned = false
            if holdActive { holdActive = false; holdWaitRelease = true } // ⌥를 누른 채 Esc 등으로 껐으면 뗄 때까지 다시 켜지 않는다
            controller.end()
        }
        controller.holdRightOption = false
        SystemCursor.show(.board)
        NSCursor.arrow.set()
        Log.log("DRAW", "off reason=\(reason.rawValue) keysFreed=\(freed.removed) errors=\(freed.errors) "
                 + "left=\(keys.left) cursorHidden=\(SystemCursor.hidden) calls=\(SystemCursor.callSummary)")
    }

    // ---------- 끄는 이유를 지켜본다 (드로잉 중에만) ----------
    // 다른 앱이 앞으로 나오거나, 데스크톱이 바뀌거나, 잠자기·잠금이면 Esc처럼 끈다(선생님 결정 ②·D7).
    // 캡처(⌘⇧4·5)는 앞 앱이 바뀌지 않으므로 꺼지지 않는다.
    private func startWatching() {
        stopWatching()
        let nc = NSWorkspace.shared.notificationCenter
        func watch(_ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { n in
                MainActor.assumeIsolated { handler(n) }
            })
        }
        watch(NSWorkspace.didActivateApplicationNotification) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return } // 우리 앱(설정 창 등)은 제외
            Log.log("DRAW", "activated \(app.bundleIdentifier ?? "-")")
            self?.turnOff(.appSwitch)
        }
        watch(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in self?.turnOff(.spaceChange) }
        watch(NSWorkspace.willSleepNotification) { [weak self] _ in self?.turnOff(.sleep) }
        watch(NSWorkspace.screensDidSleepNotification) { [weak self] _ in self?.turnOff(.sleep) }
        watch(NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in self?.turnOff(.lock) }
    }

    private func stopWatching() {
        let nc = NSWorkspace.shared.notificationCenter
        for o in observers { nc.removeObserver(o) }
        observers = []
    }

    var isWatching: Bool { !observers.isEmpty }

    // 설정이 바뀌면: 새 복사본을 넘기고 다시 그린다
    func applySettings() {
        controller.config = makeConfig()
        surface.invalidateAll()
    }
}
