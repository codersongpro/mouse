import AppKit
import ScreenCaptureKit

// ================= 화면 캡처 (ClassZoom) =================
// F6(또는 위젯의 캡처 버튼): 마우스를 올린 창에 빨간 테두리가 뜨고, 클릭하면 그 창을, 누른 채 끌면 그 구역을 찍는다
// ⇧F6: 커서가 있는 화면 전체 / ⌃⇧F6: 마우스로 끌어 고른 구역 (Windows 판과 같은 키)
// 찍은 그림은 곧바로 클립보드에 넣고, 편집 창(CaptureEditor)을 띄운다.
//
//  - 늘 "보이는 화면" 그대로 찍는다: 화면 하나를 ScreenCaptureKit으로 찍고 고른 자리만 잘라 낸다.
//    그래서 라이브 줌 중이면 확대 화면이, 드로잉으로 그린 것도 그대로 찍힌다.
//    위젯·강조 원·클릭 링·확대 중 그린 커서·고르기 창은 찍지 않는다(excluded).
//  - 키 겹침: 고르는 동안 라이브 줌의 esc 단축키를 내려 둔다(esc = 취소). 드로잉 중이었으면 오른쪽 ⌥를 뗀 것처럼
//    그림은 화면에 남기고 드로잉 키만 푼다(esc가 드로잉을 지우지 않게).

@MainActor final class Capturer {
    enum Mode { case window, area, screen }

    var excluded: () -> [Int] = { [] }      // 찍지 않을 우리 창 번호
    var willPick: () -> Void = {}           // 고르기 시작 (드로잉 키·줌 esc를 내려 둔다)
    var didPick: () -> Void = {}            // 고르기 끝 (줌 esc를 되돌린다)
    var onCaptured: (CGImage) -> Void = { _ in }
    var onCancelled: () -> Void = {}        // 취소·실패 (감춰 둔 편집 창을 되살린다)

    private var busy = false
    private var windowPicker: WindowPicker?
    private var areaPicker: AreaPicker?
    var windowNumbers: [Int] { (windowPicker?.windowNumbers ?? []) + (areaPicker?.windowNumbers ?? []) }

    func capture(_ mode: Mode) {
        guard !busy else { return }
        busy = true
        willPick()
        Log.log("CAP", "start \(mode)")
        switch mode {
        case .screen:
            let m = NSEvent.mouseLocation
            guard let scr = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? NSScreen.main else { didPick(); finish(); onCancelled(); return }
            didPick()
            shoot(scr.frame)
        case .area:
            let p = AreaPicker()
            p.minSize = 8
            p.hint = "캡처할 구역을 마우스로 끌어 주세요  ·  esc 취소"
            areaPicker = p
            p.pick { [weak self] r in self?.picked(r) }
        case .window:
            let p = WindowPicker()
            windowPicker = p
            p.pick { [weak self] r in self?.picked(r) }
        }
    }

    private func picked(_ r: CGRect?) {
        areaPicker = nil
        windowPicker = nil
        didPick()
        guard let r else { finish(); onCancelled(); return }
        shoot(r)
    }

    private func finish() { busy = false }

    // rect: 전역 좌표(pt, 왼쪽 아래 원점) — 화면에 보이는 자리
    private func shoot(_ rect: CGRect) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000) // 고르기 창이 화면에서 빠질 때까지
            defer { self.finish() }
            do {
                let img = try await Capturer.grab(rect, excluding: self.excluded())
                Log.log("CAP", "shot \(img.width)x\(img.height)")
                self.onCaptured(img)
            } catch {
                Log.log("CAP", "failed \(error)")
                self.onCancelled()
                Notice.show(Notice.screenRecordingNeeded(feature: "화면 캡처"))
            }
        }
    }

    enum CaptureError: Error { case noScreen, noDisplay }

    static func grab(_ rect: CGRect, excluding ex: [Int]) async throws -> CGImage {
        func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
        guard let scr = NSScreen.screens.max(by: { area($0.frame.intersection(rect)) < area($1.frame.intersection(rect)) }) else {
            throw CaptureError.noScreen
        }
        let r = rect.intersection(scr.frame).integral
        guard r.width >= 2, r.height >= 2 else { throw CaptureError.noScreen }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let did = (scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == did }) else { throw CaptureError.noDisplay }
        let exSet = Set(ex)
        let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { exSet.contains(Int($0.windowID)) })
        let scale = scr.backingScaleFactor
        let cfg = SCStreamConfiguration()
        // sourceRect는 화면 안 좌표, 왼쪽 위 원점(pt)
        cfg.sourceRect = CGRect(x: r.minX - scr.frame.minX, y: scr.frame.maxY - r.maxY, width: r.width, height: r.height)
        cfg.width = Int(r.width * scale)
        cfg.height = Int(r.height * scale)
        cfg.showsCursor = false
        cfg.capturesAudio = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }
}

// 클립보드에 그림을 넣는다 (PNG와 TIFF 둘 다 — 한글·키노트·카카오톡 어디에나 붙는다)
@MainActor func copyImageToPasteboard(_ img: CGImage) -> Bool {
    let rep = NSBitmapImageRep(cgImage: img)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.declareTypes([.png, .tiff], owner: nil)
    pb.setData(png, forType: .png)
    if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    return true
}

// ---------- 창 고르기: 마우스를 올린 창에 빨간 테두리, 클릭 = 찍기, esc·오른쪽 클릭 = 취소 ----------
@MainActor final class WindowPicker {
    private var windows: [NSWindow] = []
    private var hintWindow: NSWindow?
    private var done: ((CGRect?) -> Void)?
    private var monitors: [Any] = []
    private var timer: Timer?
    private var current: CGRect?
    // 클릭하면 창, 누른 채 끌면 구역 (픽픽처럼 F6 하나로 둘 다). 이만큼(pt) 움직여야 끌기로 본다
    static let dragThreshold: CGFloat = 6
    private var pressAt: NSPoint?      // 누른 자리 (진짜 커서)
    private var dragStart: NSPoint?    // 끌기 시작 자리 (확대 중이면 보이는 자리)
    private var dragRect: CGRect?
    var windowNumbers: [Int] { windows.map(\.windowNumber) + [hintWindow?.windowNumber].compactMap { $0 } }

    final class PickView: NSView {
        var rect: CGRect?   // 이 창 안 좌표
        var onDown: () -> Void = {}
        var onDrag: () -> Void = {}
        var onUp: () -> Void = {}
        var onCancel: () -> Void = {}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with e: NSEvent) { onDown() }
        override func mouseDragged(with e: NSEvent) { onDrag() }
        override func mouseUp(with e: NSEvent) { onUp() }
        override func rightMouseDown(with e: NSEvent) { onCancel() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
        override func draw(_ dirtyRect: NSRect) {
            // 완전히 투명하면 클릭이 아래 창으로 지나가므로 거의 보이지 않을 만큼만 칠한다
            NSColor(white: 0, alpha: 0.01).setFill()
            bounds.fill()
            guard let r = rect else { return }
            let red = NSColor(calibratedRed: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1)
            red.withAlphaComponent(0.10).setFill()
            r.fill(using: .sourceOver)
            red.setStroke()
            let p = NSBezierPath(rect: r.insetBy(dx: 2, dy: 2))
            p.lineWidth = 4
            p.stroke()
        }
    }

    func pick(_ completion: @escaping (CGRect?) -> Void) {
        done = completion
        for scr in NSScreen.screens {
            let w = AreaPicker.KeyPanel(contentRect: scr.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.level = ZOOM_TOP_LEVEL
            w.collectionBehavior = EVERYWHERE
            w.isReleasedWhenClosed = false
            w.sharingType = .none
            let v = PickView(frame: NSRect(origin: .zero, size: scr.frame.size))
            v.onDown = { [weak self] in self?.pressAt = NSEvent.mouseLocation }
            v.onDrag = { [weak self] in self?.dragged() }
            v.onUp = { [weak self] in self?.released() }
            v.onCancel = { [weak self] in self?.finish(nil) }
            w.contentView = v
            w.setFrame(scr.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        hintWindow = showPickHint("클릭하면 창 · 끌면 구역을 캡처합니다  ·  esc 취소")
        windows.first?.makeKey()
        let esc: (NSEvent) -> Void = { [weak self] e in if e.keyCode == 53 { self?.finish(nil) } }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: esc) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { esc($0); return nil }) { monitors.append(l) }
        let t = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        update()
        Log.log("CAP", "pick window")
    }

    private func dragged() {
        guard let p = pressAt else { return }
        let m = NSEvent.mouseLocation
        if dragStart == nil {
            guard abs(m.x - p.x) >= Self.dragThreshold || abs(m.y - p.y) >= Self.dragThreshold else { return }
            dragStart = ZoomMap.screenPoint(p)
        }
        guard let a = dragStart else { return }
        let b = ZoomMap.screenPoint(m)
        dragRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        show(dragRect)
    }

    private func released() {
        defer { pressAt = nil }
        guard pressAt != nil else { return }
        if dragStart != nil {
            let r = dragRect
            finish(r.flatMap { $0.width >= 8 && $0.height >= 8 ? $0 : nil })
        } else {
            finish(current)
        }
    }

    private func update() {
        guard dragStart == nil else { return } // 끄는 동안은 창 테두리를 그리지 않는다
        current = WindowPicker.windowRect(at: NSEvent.mouseLocation)
        show(current)
    }

    private func show(_ global: CGRect?) {
        for w in windows {
            guard let v = w.contentView as? PickView else { continue }
            let local = global.map { CGRect(x: $0.minX - w.frame.minX, y: $0.minY - w.frame.minY, width: $0.width, height: $0.height) }
            if v.rect != local { v.rect = local; v.needsDisplay = true }
        }
    }

    // 커서 아래 맨 위 보통 창의 자리(전역 pt, 왼쪽 아래 원점). 확대 중이면 확대 화면에서 보이는 자리. 창이 없으면 그 화면 전체.
    static func windowRect(at p: NSPoint) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let top = primary.frame.maxY
        let cg = CGPoint(x: p.x, y: top - p.y)
        let me = ProcessInfo.processInfo.processIdentifier
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
            if (info[kCGWindowOwnerPID as String] as? Int32) == me { continue }
            if let a = info[kCGWindowAlpha as String] as? Double, a < 0.05 { continue }
            guard let bd = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd as CFDictionary), b.width >= 20, b.height >= 20, b.contains(cg) else { continue }
            var r = CGRect(x: b.minX, y: top - b.maxY, width: b.width, height: b.height)
            if ZoomMap.active {
                let a = ZoomMap.screenPoint(r.origin), c = ZoomMap.screenPoint(NSPoint(x: r.maxX, y: r.maxY))
                r = CGRect(x: a.x, y: a.y, width: c.x - a.x, height: c.y - a.y).intersection(ZoomMap.screenFrame)
                if r.isNull || r.width < 4 || r.height < 4 { return ZoomMap.screenFrame }
            }
            return r
        }
        return NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) })?.frame
    }

    private func finish(_ r: CGRect?) {
        guard let d = done else { return }
        done = nil
        timer?.invalidate(); timer = nil
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        windows.forEach { $0.orderOut(nil) }; windows = []
        hintWindow?.orderOut(nil); hintWindow = nil
        d(r)
    }
}

// 고르는 동안 화면 위쪽 가운데에 뜨는 안내 (찍히지 않는다)
@MainActor func showPickHint(_ text: String) -> NSWindow? {
    let m = NSEvent.mouseLocation
    guard let scr = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? NSScreen.main else { return nil }
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 15, weight: .semibold)
    label.textColor = .white
    label.sizeToFit()
    let size = NSSize(width: label.frame.width + 36, height: label.frame.height + 20)
    let w = GlassPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true
    w.level = NSWindow.Level(rawValue: ZOOM_TOP_LEVEL.rawValue + 1)
    w.collectionBehavior = EVERYWHERE
    w.ignoresMouseEvents = true
    w.sharingType = .none
    w.isReleasedWhenClosed = false
    let bg = NSView(frame: NSRect(origin: .zero, size: size))
    bg.wantsLayer = true
    bg.layer?.backgroundColor = NSColor(calibratedRed: 0x1E / 255, green: 0x29 / 255, blue: 0x3B / 255, alpha: 0.95).cgColor
    bg.layer?.cornerRadius = 10
    label.setFrameOrigin(NSPoint(x: 18, y: 10))
    bg.addSubview(label)
    w.contentView = bg
    w.setFrameOrigin(NSPoint(x: scr.frame.midX - size.width / 2, y: scr.visibleFrame.maxY - size.height - 16))
    w.orderFrontRegardless()
    return w
}
