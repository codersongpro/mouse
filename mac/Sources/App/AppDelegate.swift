import AppKit
import Combine

// 조립만 한다. "무엇이 켜져 있는가"는 AppState가, 설정값은 Settings가 든다.
// 상태가 바뀌면 applyState() 하나가 강조·클릭 링·위젯·설정 창의 보임을 다시 정하고,
// 설정이 바뀌면 applySettings()가 바뀐 묶음만 다시 적용한다.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state = AppState.shared
    let spotlight = Spotlight()
    let clicks = ClickEffect()
    let draw = DrawSession(state: AppState.shared)
    let settingsWindow = SettingsWindowController()
    let keyboardWindow = KeyboardWindowController()
    let zoom = LiveZoom()                 // 라이브 줌 (Zoom/LiveZoom.swift)
    let recorder = Recorder()             // 화면 녹화 (Record/Recorder.swift)
    let guide = UsageGuideController()    // 사용 방법 안내 창 (UI/UsageGuide.swift)
    let capturer = Capturer()             // 화면 캡처 (Capture/Capture.swift)
    var captureEditor: CaptureEditor?     // 캡처 편집 창 (하나만)
    var zoomResumeStep = 0                // 편집 창을 닫으면 다시 켤 확대 단계
    var widget: Widget!
    var statusItem: NSStatusItem!
    var statusMenu: NSMenu?       // 메뉴 막대 메뉴 (합친 아이콘 모드에서는 누를 때마다 꺼내 보인다)
    var changes: AnyCancellable?
    var statusVisibility: NSKeyValueObservation?

    // 마지막으로 적용한 설정 묶음 (바뀐 묶음만 다시 적용하려고)
    private struct Applied: Equatable {
        var spot: [Double]
        var widget: [Double]
        var draw: DrawConfig
        var tray: Bool
        init(_ s: Settings) {
            spot = [s.spotSize, s.spotOpacity, Double(s.spotColor)]
            widget = [s.widgetScale, s.widgetOpacity, Double(s.widgetColor), s.widgetOnTop ? 1 : 0]
            draw = DrawConfig(s)
            tray = s.showTrayIcons
        }
    }
    private var applied = Applied(Settings.shared)

    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        func arg(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let selftest = arg("--selftest"), bench = arg("--bench"), soak = arg("--soak"), laserpic = arg("--laserpic")
        // 자체 점검·속도 측정은 사용자가 고른 실험 스위치와 진단 기록을 건드리지 않는다
        let normalRun = selftest == nil && bench == nil && soak == nil && laserpic == nil
        // 점검·측정·진단 실행은 로그인 항목(SMAppService)을 건드리지 않는다
        if !normalRun || args.contains("--diag") { LoginItem.allowed = false }
        if !normalRun {
            AppLog.folder = nil // 사용자 기록에는 적지 않는다
            Experiments.memoryOnly = [:]
        } else {
            Log.forgetMenuSwitch()
            if args.contains("--diag") { Log.start(reason: "--diag") }
        }
        Log.appState = { [weak self] in self?.diagState ?? "" }
        Log.inkWindowNumbers = { [weak self] in self?.draw.inkWindowNumbers ?? [] }
        Log.otherWindows = { [weak self] in
            guard let self else { return [] }
            var list: [(String, Int)] = []
            if self.state.highlightVisible, let n = self.spotlight.windowNumber { list.append(("spot", n)) }
            if let w = self.widget?.window { list.append(("widget", w.windowNumber)) }
            return list
        }
        Experiments.onChange = { [weak self] in self?.updateSpotCursor() }

        // 자체 점검·속도 측정은 사용자 settings.ini를 읽지 않는다 (기본값, 또는 --settings <고정 파일>)
        var loadResult = Settings.LoadResult.missing
        if let f = arg("--settings") { Settings.overridePath = URL(fileURLWithPath: f); loadResult = Settings.shared.load() }
        else if normalRun { loadResult = Settings.shared.load() }
        applied = Applied(Settings.shared)
        AppLog.write("SESSION", "start version=\(AppInfo.version) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString) app=\((Bundle.main.bundlePath as NSString).abbreviatingWithTildeInPath)")
        widget = Widget(state: state)
        draw.controller.statusItemFrame = { [weak self] in self?.statusItem?.button?.window?.frame }
        draw.controller.statusClick = { [weak self] menuClick in self?.handleClickOverStatusItem(menuClick: menuClick) ?? false }
        widget.view.onAction = { [weak self] part in self?.widgetAction(part) }
        widget.view.contextMenu = { [weak self] in
            let m = NSMenu()
            self?.fillMenu(m)
            return m
        }

        clicks.enabledNow = { [weak self] in self?.state.highlightVisible ?? false } // 드로잉 중에는 강조와 함께 쉰다

        // 라이브 줌·녹화·안내 창 (ClassZoom)
        zoom.isDrawing = { [weak self] in self?.state.drawOn ?? false }
        zoom.brushVisible = { true } // 드로잉 중에는 붓 동그라미가 커서 노릇을 한다
        zoom.extraExcluded = { [weak self] in
            guard let self else { return [] }
            return [self.spotlight.windowNumber].compactMap { $0 } + self.clicks.windowNumbers + self.recorder.windowNumbers
        }
        zoom.onChange = { [weak self] in
            guard let self else { return }
            self.state.zoomOn = self.zoom.isOn
            self.recorder.updateCursorCapture()
        }
        recorder.onChange = { [weak self] in
            guard let self else { return }
            self.state.recording = self.recorder.isActive
        }
        recorder.cursorDrawnByUs = { [weak self] in (self?.zoom.isOn ?? false) || (self?.state.drawOn ?? false) }
        // 영역을 고르는 동안 esc는 "취소" — 라이브 줌의 esc(확대 끄기)를 내려 두었다가 되돌린다
        recorder.willPick = { HotKeyRegistry.shared.unregisterGroup(.zoom) }
        recorder.didPick = { [weak self] in self?.zoom.updateKeys() }
        setupCapture()
        draw.willTurnOn = { HotKeyRegistry.shared.unregisterGroup(.zoom) } // 드로잉의 esc와 겹치지 않게
        guide.onShowKeyboard = { [weak self] in self?.keyboardWindow.show() }
        clicks.start()
        draw.makeConfig = { DrawConfig(Settings.shared) }

        state.widgetVisible = Settings.shared.showWidget
        state.onChange = { [weak self] in self?.applyState() }
        applyState()

        settingsWindow.onSave = {
            if let e = Settings.shared.save() {
                Notice.show(Notice.saveFailed(e))
                return false
            }
            return true
        }
        settingsWindow.onResetWidget = { [weak self] in
            self?.widget.moveToDefault()
            if let o = self?.widget.window.frame.origin { Settings.shared.saveWidgetPosition(o) }
        }
        settingsWindow.onShowKeyboard = { [weak self] in self?.keyboardWindow.show() }
        settingsWindow.onShowGuide = { [weak self] in self?.guide.show() }
        HotkeyCaptureView.onRecording = { [weak self] on in self?.setHotkeyRecording(on) }
        settingsWindow.onHotkey = { [weak self] name, combo in self?.changeHotkey(name, to: combo) }
        settingsWindow.onResetAll = { [weak self] in self?.confirmResetAll() }
        settingsWindow.onQuit = { NSApp.terminate(nil) }
        installMainMenu()

        // 설정 창에서 값을 움직이면 바로 반영
        changes = Settings.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applySettings() }
        }

        // 앱이 도는 동안 늘 있는 단축키 (묶음 app): settings.ini [Hotkeys]의 Spotlight·Draw(기본 F8·F9)와,
        // fn 없이 누를 수 있는 맥 전용 SpotlightAlt·DrawAlt(기본 ⌃⌥1·⌃⌥2). 못 잡은 것은 기록에만 남긴다.
        draw.keys.blockExcluding = {
            Set(SettingsSchema.hotkeys.compactMap { HotkeyNotation.parse(Settings.shared.hotkeys[$0.name] ?? $0.def) })
        }
        draw.onKeysFailed = { r in Notice.show(Notice.drawKeysFailed(r)) }
        registerAppHotkeys()
        appHotkeyCount = HotKeyRegistry.shared.count(.app)

        // 화면 구성이 바뀌면 잉크는 InkSurface가 옮기고, 위젯은 여기서 같이 옮긴 뒤 화면 안으로 들인다
        draw.surface.onScreensChanged = { [weak self] shift in
            self?.widget.shift(by: shift)
            self?.widget.clampIntoScreen()
        }
        // 잠자기에서 깨면 앱 단축키(F8·F9 등)가 살아 있는지 보고, 풀렸으면 다시 잡는다 (진단 기록에 한 줄)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.checkAfterWake() }
        }

        setupStatusItem()
        updateTrayIcons()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.logStatusItems() }
        if normalRun { showStartupNotices(loadResult) }

        if let out = selftest { DispatchQueue.main.async { SelfTest.run(self, out: out) } }
        if let out = bench { DispatchQueue.main.async { Bench.run(self, out: out) } }
        if let out = soak { DispatchQueue.main.async { Soak.run(self, out: out) } }
        if let out = laserpic { DispatchQueue.main.async { LaserPic.run(out: out) } }
    }

    var appHotkeyCount = 0

    // 설정 창의 단축키 녹화 칸이 키를 기다리는 동안은 앱 단축키(F8·F9 등)를 내려 둔다 (눌러도 강조·드로잉이 켜지지 않고 그 키가 녹화되게)
    func setHotkeyRecording(_ on: Bool) {
        HotKeyRegistry.shared.unregisterGroup(.app)
        if on { return }
        registerAppHotkeys()
        appHotkeyCount = HotKeyRegistry.shared.count(.app)
    }

    // 깨어난 뒤: 앱 단축키가 그대로인지 확인한다. 드로잉·강조는 잠자기 때 꺼졌으므로 쉬는 상태여야 한다.
    @discardableResult
    func checkAfterWake() -> Bool {
        var have = HotKeyRegistry.shared.count(.app)
        var redone = false
        if have < appHotkeyCount {
            HotKeyRegistry.shared.unregisterGroup(.app)
            registerAppHotkeys()
            have = HotKeyRegistry.shared.count(.app)
            redone = true
        }
        Log.log("WAKE", "appkeys=\(have)/\(appHotkeyCount)\(redone ? " reregistered" : "") draw=\(state.drawOn ? 1 : 0) spot=\(state.spotOn ? 1 : 0) "
                + "drawkeys=\(draw.keys.ids.count) blockkeys=\(draw.keys.blockIDs.count)")
        return have >= appHotkeyCount
    }

    @discardableResult
    func registerAppHotkeys() -> HotKeyGroupResult {
        let actions: [String: () -> Void] = [
            "Spotlight": { [weak self] in self?.toggleSpotlight() }, "SpotlightAlt": { [weak self] in self?.toggleSpotlight() },
            "Draw": { [weak self] in self?.draw.toggle() }, "DrawAlt": { [weak self] in self?.draw.toggle() },
            "Zoom": { [weak self] in self?.zoom.cycle() }, "ZoomAlt": { [weak self] in self?.zoom.cycle() },
            "Record": { [weak self] in self?.recorder.toggle(area: false) }, "RecordAlt": { [weak self] in self?.recorder.toggle(area: false) },
            "RecordPause": { [weak self] in self?.recorder.pauseToggle() },
            "RecordArea": { [weak self] in self?.recorder.toggle(area: true) },
            "Capture": { [weak self] in self?.startCapture(.window) }, "CaptureAlt": { [weak self] in self?.startCapture(.window) },
            "CaptureArea": { [weak self] in self?.startCapture(.area) },
            "CaptureScreen": { [weak self] in self?.startCapture(.screen) },
        ]
        let entries: [HotKeyEntry] = SettingsSchema.hotkeys.compactMap { h in
            guard let combo = HotkeyNotation.parse(Settings.shared.hotkeys[h.name] ?? h.def), let action = actions[h.name] else { return nil }
            return HotKeyEntry(name: h.name, combo: combo, press: { _ in Log.log("HK", "press \(h.name)"); action() })
        }
        return HotKeyRegistry.shared.registerGroup(.app, entries, policy: .skipFailures)
    }

    // 설정 창에서 단축키를 바꾼다 (combo가 nil이면 기본값으로). 성공하면 nil, 거절·실패면 한국어 이유 — 그 경우 원래 키 그대로.
    func changeHotkey(_ name: String, to combo: HotkeyNotation.Combo?) -> String? {
        let s = Settings.shared
        guard let h = SettingsSchema.hotkeys.first(where: { $0.name == name }) else { return nil }
        guard let target = combo ?? HotkeyNotation.parse(h.def) else { return nil }
        var others: [String: HotkeyNotation.Combo] = [:]
        for o in SettingsSchema.hotkeys where o.name != name {
            if let c = HotkeyNotation.parse(s.hotkeys[o.name] ?? o.def) { others[o.name] = c }
        }
        if case .rejected(let why) = HotkeyRules.check(target, name: name, others: others) {
            AppLog.write("HOTKEY", "rejected \(name) \(HotkeyNotation.format(target) ?? "?"): \(why)")
            return why
        }
        guard let text = HotkeyNotation.format(target) else { return "지원하지 않는 키입니다." }
        let old = s.hotkeys[name] ?? h.def
        if text == old { return nil }
        s.hotkeys[name] = text
        HotKeyRegistry.shared.unregisterGroup(.app)
        let r = registerAppHotkeys()
        if let f = r.failed.first(where: { $0.name == name }) {
            s.hotkeys[name] = old
            HotKeyRegistry.shared.unregisterGroup(.app)
            registerAppHotkeys()
            appHotkeyCount = HotKeyRegistry.shared.count(.app)
            AppLog.write("HOTKEY", "register failed \(name) \(text): \(describeHotKeyStatus(f.status))")
            let shown = HotkeyRules.show(target)
            switch f.status {
            case hotKeyExistsStatus: return "\(shown)는 이미 다른 앱이 사용 중입니다. 다른 조합을 눌러 주세요. 원래 키(\(HotkeyDisplay.symbols(old)))로 돌려 두었습니다."
            case hotKeyRejectedStatus: return "\(shown)는 macOS가 단축키로 받아 주지 않습니다. 다른 조합을 눌러 주세요. 원래 키(\(HotkeyDisplay.symbols(old)))로 돌려 두었습니다."
            default: return "\(shown)를 등록하지 못했습니다(\(f.status)). 원래 키(\(HotkeyDisplay.symbols(old)))로 돌려 두었습니다."
            }
        }
        appHotkeyCount = HotKeyRegistry.shared.count(.app)
        s.objectWillChange.send()
        AppLog.write("HOTKEY", "changed \(name) \(old) -> \(text)")
        return nil
    }

    // 처음 열었을 때·문제가 있을 때만 안내 창을 띄운다 (자체 점검·측정 실행에서는 부르지 않는다)
    func showStartupNotices(_ load: Settings.LoadResult) {
        if case .unreadable(let reason, let backup) = load {
            Notice.show(Notice.unreadable(reason: reason, backup: backup))
        }
        if !Settings.shared.blankedHotkeys.isEmpty {
            let names = Settings.shared.blankedHotkeys.map(HotkeyRules.label).joined(separator: ", ")
            Notice.show(NoticeContent(title: "캡처 단축키를 비워 두었습니다",
                                      body: ["다른 기능이 이미 쓰는 키라서 \(names) 단축키를 비워 두었습니다. 설정 › 단축키에서 정해 주세요."]))
        }
        if Notice.isTranslocated() {
            AppLog.write("SESSION", "translocated")
            Notice.show(Notice.translocated())
        }
        // 사용 방법 안내 창: "다음부터 보지 않기"를 켜기 전까지 켤 때마다 뜬다
        if UsageGuideController.showOnStart {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.guide.show() }
        }
    }

    // 앱을 Finder·Spotlight·Launchpad로 다시 열면: 위젯이 숨겨져 있으면 위젯을 보이고, 이미 보이면 설정을 연다
    // (메뉴 막대 아이콘을 치웠거나 위젯을 숨겨 둔 채 앱을 잊었을 때 다시 찾는 길)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppLog.write("REOPEN", "widget=\(Settings.shared.showWidget ? "shown" : "hidden")")
        if Settings.shared.showWidget {
            openSettings()
        } else {
            Settings.shared.showWidget = true
            state.widgetVisible = true
        }
        return false
    }

    // 진단 기록 1초마다 한 줄에 들어가는 앱 상태
    var diagState: String {
        "draw=\(state.drawOn ? 1 : 0) spot=\(state.spotOn ? 1 : 0) "
            + "hidden=\(SystemCursor.hidden ? 1 : 0) drawkeys=\(draw.keys.ids.count) blockkeys=\(draw.keys.blockIDs.count)"
    }

    // ---------- 상태가 바뀌면 보임을 한 곳에서 다시 정한다 ----------
    func applyState() {
        spotlight.visible = state.highlightVisible
        widget.setVisible(state.widgetVisible)
        widget.view.needsDisplay = true
        updateSpotCursor()
        if Settings.shared.showTrayIcons { updateTrayIcons() }
        // 라이브 줌의 esc는 드로잉이 아닐 때만 (드로잉의 esc가 잠깐 남아 있을 수 있어 조금 뒤에 한 번 더)
        zoom.updateKeys()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.zoom.updateKeys() }
        recorder.updateCursorCapture()
        Log.setActive(state.drawOn || state.spotOn)
        // 드로잉 판이 설정 창을 덮으므로 드로잉 동안만 숨겼다가, 끝나면 되돌린다
        if state.drawOn {
            if !state.settingsHiddenByDraw, settingsWindow.hideForDraw() { state.settingsHiddenByDraw = true }
        } else if state.settingsHiddenByDraw {
            state.settingsHiddenByDraw = false
            settingsWindow.restoreAfterDraw()
        }
    }

    // 실험: 강조 중에는 화살표를 숨긴다 (드로잉 중에는 드로잉 쪽이 커서를 맡는다)
    func updateSpotCursor() {
        if Experiments.hideSpotCursor && state.highlightVisible {
            SystemCursor.hide(.spot)
        } else {
            SystemCursor.show(.spot)
        }
    }

    // 바뀐 묶음만 다시 적용한다
    func applySettings() {
        let now = Applied(Settings.shared)
        if now.spot != applied.spot { spotlight.applySettings() }
        if now.widget != applied.widget { widget.applySettings() }
        if now.tray != applied.tray { updateTrayIcons() }
        if now.draw != applied.draw { draw.applySettings() }
        applied = now
        state.widgetVisible = Settings.shared.showWidget
        draw.setHoldEnabled(Settings.shared.drawRightOptionHold) // 오른쪽 ⌥를 누르는 동안 드로잉
    }

    func toggleSpotlightOffIfOn() { if state.spotOn { toggleSpotlight() } }

    func toggleSpotlight() {
        state.spotOn.toggle()
        Log.log("SPOT", state.spotOn ? "on" : "off")
    }

    func widgetAction(_ part: WidgetView.Part) {
        switch part {
        case .spot: toggleSpotlight()
        case .draw: draw.isOn ? draw.turnOff(.widgetButton) : draw.turnOn() // 위젯으로 끄면 정리하고 나간다 (Esc와 같음)
        case .zoom: zoom.cycle()
        case .record: recorder.toggle(area: false)
        case .capture: startCapture(.window)
        case .settings: openSettings()
        case .close:
            Settings.shared.showWidget = false
        case .grip: break
        }
    }

    // "모든 설정 초기화": 기본 선택이 "아니요"인 확인 뒤, 설정 파일을 지우고 기본값으로 돌린다.
    // 단축키를 다시 잡고 위젯을 처음 자리로 보낸다. 로그인 항목은 그대로 둔다.
    func confirmResetAll() {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "모든 설정을 처음 상태로 되돌릴까요?"
        a.informativeText = "색, 크기, 단축키, 위젯 자리 등 저장해 둔 설정이 모두 지워지고 기본값이 됩니다. 이미 그린 그림과 로그인 시 실행 설정은 그대로입니다."
        a.addButton(withTitle: "아니요")
        a.addButton(withTitle: "예, 모두 초기화")
        a.buttons[0].keyEquivalent = "\r"
        a.buttons[1].keyEquivalent = ""
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertSecondButtonReturn else { return }
        if let e = Settings.shared.resetAll() {
            Notice.show(Notice.resetFailed(e))
            return
        }
        HotKeyRegistry.shared.unregisterGroup(.app)
        registerAppHotkeys()
        appHotkeyCount = HotKeyRegistry.shared.count(.app)
        widget.moveToDefault()
        applySettings()
        AppLog.write("SETTINGS", "reset all")
    }

    // 메뉴 막대가 없는 앱이라도 설정 창이 앞에 있는 동안은 ⌘C·⌘V·⌘X·⌘A와 ⌘W(창 닫기)가 먹어야 한다
    func installMainMenu() {
        func item(_ title: String, _ action: Selector?, _ key: String = "") -> NSMenuItem {
            NSMenuItem(title: title, action: action, keyEquivalent: key)
        }
        let main = NSMenu()
        let appItem = NSMenuItem(), editItem = NSMenuItem(), winItem = NSMenuItem()
        let appMenu = NSMenu(title: "ClassZoom")
        appMenu.addItem(item("설정...", #selector(openSettings), ","))
        appMenu.items.last?.target = self
        appMenu.addItem(item("ClassZoom 종료", #selector(menuQuit), "q"))
        appMenu.items.last?.target = self
        appItem.submenu = appMenu
        let edit = NSMenu(title: "편집")
        edit.addItem(item("오려두기", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("복사", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("붙여넣기", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("전체 선택", #selector(NSText.selectAll(_:)), "a"))
        editItem.submenu = edit
        let win = NSMenu(title: "윈도우")
        win.addItem(item("닫기", #selector(NSWindow.performClose(_:)), "w"))
        winItem.submenu = win
        for i in [appItem, editItem, winItem] { main.addItem(i) }
        NSApp.mainMenu = main
    }

    // 드로잉 판이 화면을 덮고 있으면 설정 창을 누를 수 없으므로 드로잉을 먼저 끈다 (그린 것은 남긴다)
    @objc func openSettings() {
        if draw.isOn { draw.turnOff(.settings) }
        settingsWindow.show()
    }

    // 수업 중 메뉴 막대에서 종료해도: 그린 것은 그대로 둔 채 드로잉만 끄고(판을 닫고, 커서를 되돌리고,
    // 드로잉 키 단축키를 풀고) 앱이 죽는다. 숨겨 둔 커서도 반드시 되돌린다.
    func applicationWillTerminate(_ n: Notification) {
        recorder.finishBeforeQuit() // 녹화 중이면 영상을 마무리한다
        zoom.stop()
        draw.turnOff(.quit)
        HotKeyRegistry.shared.unregisterAll()
        SystemCursor.showAll()
        AppLog.write("SESSION", "quit")
        Log.log("SESSION", "quit")
        Log.stop()
    }
}

// ---------- 화면 캡처 (F6) ----------
extension AppDelegate {
    func setupCapture() {
        // 찍지 않을 우리 창: 위젯·강조 원·클릭 링·녹화 표시·확대 중 그린 커서·고르기 창. 확대 화면과 드로잉 판은 찍힌다.
        capturer.excluded = { [weak self] in
            guard let self else { return [] }
            return [self.widget?.window.windowNumber, self.spotlight.windowNumber].compactMap { $0 }
                + self.clicks.windowNumbers + self.recorder.windowNumbers + self.zoom.overlayWindowNumbers + self.capturer.windowNumbers
        }
        capturer.willPick = { [weak self] in
            guard let self else { return }
            // 드로잉 중이면 오른쪽 ⌥를 뗀 것처럼: 그림은 화면에 남고(찍힌다) 드로잉 키(esc 등)는 풀린다
            if self.draw.isOn { self.draw.turnOff(.hold) }
            HotKeyRegistry.shared.unregisterGroup(.zoom) // esc = 고르기 취소 (확대를 끄지 않게)
        }
        capturer.didPick = { [weak self] in self?.zoom.updateKeys() }
        capturer.onCaptured = { [weak self] img in self?.openCaptureEditor(img) }
        capturer.onCancelled = { [weak self] in self?.captureEditor?.window.orderFront(nil) }
    }

    func startCapture(_ mode: Capturer.Mode) {
        // 저장하지 않은 편집 창이 있으면 먼저 묻는다
        if let e = captureEditor, e.dirty {
            let a = NSAlert()
            a.messageText = "편집한 캡처를 저장하지 않았습니다"
            a.informativeText = "새로 캡처하면 지금 편집 창은 닫힙니다. 계속할까요?"
            a.addButton(withTitle: "아니요")
            a.addButton(withTitle: "새로 캡처")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertSecondButtonReturn else { return }
        }
        captureEditor?.window.orderOut(nil) // 찍히지 않게
        capturer.capture(mode)
    }

    func openCaptureEditor(_ img: CGImage) {
        _ = copyImageToPasteboard(img) // 찍자마자 붙여넣기할 수 있게
        if let old = captureEditor {
            old.onClose = {}
            old.closeQuietly()
        }
        // 확대 위에서는 편집 창을 누르는 자리가 어긋난다 → 잠시 끄고, 닫으면 같은 단계로 다시 켠다
        if zoom.isOn {
            zoomResumeStep = zoom.step
            zoom.stop()
        }
        let e = CaptureEditor(image: img)
        e.onClose = { [weak self] in
            guard let self else { return }
            self.captureEditor = nil
            if self.zoomResumeStep > 0 {
                let step = self.zoomResumeStep
                self.zoomResumeStep = 0
                self.zoom.start(step: step)
            }
        }
        captureEditor = e
        e.show()
    }
}
