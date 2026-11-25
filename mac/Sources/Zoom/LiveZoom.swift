import AppKit
import CoreMedia
import CoreVideo
import QuartzCore
import ScreenCaptureKit

// ================= 라이브 줌 (ClassZoom) =================
// F7(또는 위젯 돋보기)을 누를 때마다 1단계 → 2단계 → 3단계 → 끄기. 확대 중 ⌃+휠 = 단계, Esc = 끄기.
//
// 어떻게 하나 (Windows 판과 같은 생각)
//  - ScreenCaptureKit으로 커서가 있는 화면을 실시간으로 받아, 화면 맨 위의 보통 창(zoomWindow)에 키워 그린다.
//    보통 창이라 화면 공유·녹화에 그대로 찍힌다. 받은 그림에는 커서를 넣지 않는다(showsCursor = false).
//  - 화면은 고정, 커서만 움직인다. 진짜 커서는 숨기고(SystemCursor .zoom) 확대 화면 속 커서 자리에
//    우리가 그린 화살표(cursorWindow) 하나만 보인다. 진짜 커서 자리 = 그 화살표가 가리키는 내용의 실제 자리라서
//    클릭과 드로잉이 보이는 곳에 그대로 떨어진다. 커서가 가장자리 쪽으로 가면 그쪽으로 화면을 옮긴다.
//  - 확대 창·그린 커서·강조 원·클릭 링·단계 표시·녹화 표시는 받는 그림에서 뺀다(키워 그리면 겹친다).
//    판·위젯·설정 창은 그대로 받아 확대되어 보인다 — 보이는 자리 그대로 누를 수 있다.
//  - "화면 및 시스템 오디오 녹화" 권한이 필요하다. 없으면 시스템 설정을 여는 안내를 띄운다.

// 다른 곳(강조 원·클릭 링·녹화 영역 고르기)이 "확대 화면에서 보이는 자리"를 구할 때 쓴다
enum ZoomMap {
    static var active = false
    static var screenFrame = CGRect.zero   // 확대 중인 화면 (전역 pt, 왼쪽 아래 원점)
    static var source = CGRect.zero        // 지금 보여 주는 원본 영역 (전역 pt)
    static func screenPoint(_ p: NSPoint) -> NSPoint {
        guard active, source.width > 0, source.height > 0 else { return p }
        return NSPoint(x: screenFrame.minX + (p.x - source.minX) * screenFrame.width / source.width,
                       y: screenFrame.minY + (p.y - source.minY) * screenFrame.height / source.height)
    }
}

// ScreenCaptureKit이 그림을 넘겨주는 곳 (메인 스레드 밖)
final class ZoomFrameSink: NSObject, SCStreamOutput {
    var onSurface: (IOSurface) -> Void = { _ in }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attach = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attach.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb),
              let surf = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        let s = surf as IOSurface
        DispatchQueue.main.async { self.onSurface(s) }
    }
}

// 확대 중 그리는 흰 화살표 (끝이 왼쪽 위)
final class ZoomCursorView: NSView {
    static let size: CGFloat = 32, pad: CGFloat = 3
    override func draw(_ dirtyRect: NSRect) {
        let k: CGFloat = 23, p = ZoomCursorView.pad, top = bounds.height - p
        let shape: [(CGFloat, CGFloat)] = [(0, 0), (0, 1.0), (0.27, 0.76), (0.46, 1.16), (0.62, 1.08), (0.44, 0.69), (0.78, 0.69)]
        let path = NSBezierPath()
        for (i, q) in shape.enumerated() {
            let pt = NSPoint(x: p + q.0 * k, y: top - q.1 * k)
            if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
        }
        path.close()
        path.lineJoinStyle = .round
        path.lineWidth = 1.6
        NSColor.white.setFill(); path.fill()
        NSColor.black.setStroke(); path.stroke()
    }
}

@MainActor final class LiveZoom {
    private(set) var step = 0            // 0 = 꺼짐, 1~3
    var isOn: Bool { step > 0 }
    var onChange: () -> Void = {}
    var isDrawing: () -> Bool = { false }
    var brushVisible: () -> Bool = { false }   // 드로잉 붓 동그라미가 커서 노릇을 하는 중인가
    var extraExcluded: () -> [Int] = { [] }    // 받는 그림에서 뺄 창 번호 (강조 원·클릭 링·녹화 표시 등)

    private var levels: [Double] { let s = Settings.shared; return [s.zoomLevel1, s.zoomLevel2, s.zoomLevel3] }

    private var window: NSWindow?
    private let imageLayer = CALayer()
    private var cursorWindow: NSWindow?
    private var badgeWindow: NSWindow?
    // 화면 캡처에서 뺄 창 (확대 중 그린 커서·단계 표시). 확대 화면 자체는 찍힌다 — "확대한 채로 캡처"
    var overlayWindowNumbers: [Int] { [cursorWindow, badgeWindow].compactMap { $0?.windowNumber } }
    private var badgeLabel: NSTextField?
    private var badgeUntil: CFTimeInterval = 0
    private var stream: SCStream?
    private let sink = ZoomFrameSink()
    private let queue = DispatchQueue(label: "classzoom.zoom")
    private var screen: NSScreen?
    private var timer: Timer?
    private var excludedKey = ""
    private var scrollMonitors: [Any] = []

    private var level: CGFloat = 1          // 지금 보이는 배율
    private var target: CGFloat = 1
    private var animFrom: CGFloat = 1, animTo: CGFloat = 1, animStart: CFTimeInterval = 0
    private var closing = false
    private var origin = CGPoint.zero       // 원본 영역 왼쪽 아래 (화면 안 pt)
    private var srcSize = CGSize.zero

    static let animSeconds: CFTimeInterval = 0.22
    static let edgeFraction: CGFloat = 0.15

    // ---------- 켜기·끄기 ----------
    func cycle() {
        if !isOn { start(step: 1) }
        else if step < 3 { setStep(step + 1) }
        else { stop() }
    }

    func setStep(_ n: Int) {
        guard isOn else { return }
        step = max(1, min(3, n))
        target = CGFloat(levels[step - 1] / 100)
        showBadge()
        onChange()
    }

    func start(step n: Int) {
        if isOn { setStep(n); return }
        if closing { closing = false; step = n; target = CGFloat(levels[n - 1] / 100); showBadge(); onChange(); return }
        let m = NSEvent.mouseLocation
        guard let scr = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? NSScreen.main else { return }
        screen = scr
        step = n
        target = CGFloat(levels[n - 1] / 100)
        level = Settings.shared.zoomSmooth ? 1 : target
        animFrom = level; animTo = level
        origin = .zero
        srcSize = scr.frame.size
        makeWindows(on: scr)
        onChange()
        Task { @MainActor in await self.startCapture() }
    }

    func stop() {
        guard isOn else { return }
        step = 0
        unregisterKeys()
        if window != nil && Settings.shared.zoomSmooth { closing = true } else { hide() }
        hideBadge()
        onChange()
    }

    private func hide() {
        timer?.invalidate(); timer = nil
        closing = false
        level = 1
        ZoomMap.active = false
        if let s = stream { stream = nil; Task { try? await s.stopCapture() } }
        window?.orderOut(nil); window = nil
        cursorWindow?.orderOut(nil); cursorWindow = nil
        imageLayer.contents = nil
        scrollMonitors.forEach(NSEvent.removeMonitor); scrollMonitors = []
        SystemCursor.show(.zoom)
        excludedKey = ""
        onChange()
    }

    // ---------- 창 ----------
    private func makeWindows(on scr: NSScreen) {
        let w = NSWindow(contentRect: scr.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = true
        w.backgroundColor = .black
        w.hasShadow = false
        w.ignoresMouseEvents = true              // 클릭은 아래로 그대로 간다
        w.level = ZOOM_LEVEL
        w.collectionBehavior = EVERYWHERE
        w.isReleasedWhenClosed = false
        w.alphaValue = 0                         // 첫 그림이 오기 전에는 보이지 않게
        let v = NSView(frame: NSRect(origin: .zero, size: scr.frame.size))
        v.wantsLayer = true
        v.layer?.masksToBounds = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.anchorPoint = .zero
        imageLayer.bounds = CGRect(origin: .zero, size: scr.frame.size)
        imageLayer.position = .zero
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.actions = ["contents": NSNull(), "position": NSNull(), "transform": NSNull(), "bounds": NSNull()]
        v.layer?.addSublayer(imageLayer)
        w.contentView = v
        w.setFrame(scr.frame, display: false)
        w.orderFrontRegardless()
        window = w

        let c = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ZoomCursorView.size, height: ZoomCursorView.size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        c.isOpaque = false; c.backgroundColor = .clear; c.hasShadow = false
        c.ignoresMouseEvents = true
        c.level = ZOOM_TOP_LEVEL
        c.collectionBehavior = EVERYWHERE
        c.isReleasedWhenClosed = false
        c.contentView = ZoomCursorView(frame: NSRect(x: 0, y: 0, width: ZoomCursorView.size, height: ZoomCursorView.size))
        cursorWindow = c

        sink.onSurface = { [weak self] s in self?.show(surface: s) }
        // 확대 중 ⌃+휠 = 단계 (앞 앱의 스크롤도 함께 일어난다 — 맥은 다른 앱의 이벤트를 막을 수 없다)
        let onScroll: (NSEvent) -> Void = { [weak self] e in
            guard let self, self.isOn, e.modifierFlags.contains(.control), abs(e.scrollingDeltaY) > 0.5 else { return }
            self.setStep(self.step + (e.scrollingDeltaY > 0 ? 1 : -1))
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: onScroll) { scrollMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { onScroll($0); return $0 }) { scrollMonitors.append(l) }
        updateKeys()
    }

    private func show(surface: IOSurface) {
        guard window != nil else { return }
        imageLayer.contents = surface
        if window?.alphaValue == 0 {
            window?.alphaValue = 1
            SystemCursor.hide(.zoom)
            ZoomMap.active = true
            if timer == nil { tick() }
        }
    }

    // ---------- 받기 ----------
    private func excludedNumbers() -> [Int] {
        var n = extraExcluded()
        for w in [window, cursorWindow, badgeWindow] { if let w { n.append(w.windowNumber) } }
        return n
    }

    private func startCapture() async {
        guard let scr = screen else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let did = (scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
            guard isOn, let display = content.displays.first(where: { $0.displayID == did }) else { hide(); return }
            let ex = Set(excludedNumbers())
            excludedKey = ex.sorted().map(String.init).joined(separator: ",")
            let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { ex.contains(Int($0.windowID)) })
            let cfg = SCStreamConfiguration()
            cfg.width = Int(scr.frame.width * scr.backingScaleFactor)
            cfg.height = Int(scr.frame.height * scr.backingScaleFactor)
            cfg.showsCursor = false
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            cfg.queueDepth = 5
            let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
            try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            guard isOn || closing else { try? await s.stopCapture(); return }
            stream = s
            Log.log("ZOOM", "capture started display=\(did)")
            if timer == nil {
                let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        } catch {
            Log.log("ZOOM", "capture failed \(error)")
            step = 0
            hide()
            Notice.show(Notice.screenRecordingNeeded(feature: "라이브 줌"))
        }
    }

    // 강조 원·클릭 링처럼 나중에 생긴 창도 받는 그림에서 빼야 한다 (1초에 한 번 본다)
    private var lastFilterCheck: CFTimeInterval = 0
    private func refreshFilterIfNeeded() {
        let now = CACurrentMediaTime()
        guard now - lastFilterCheck > 1, let scr = screen, let s = stream else { return }
        lastFilterCheck = now
        let ex = Set(excludedNumbers())
        let key = ex.sorted().map(String.init).joined(separator: ",")
        guard key != excludedKey else { return }
        excludedKey = key
        Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
            let did = (scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == did }) else { return }
            try? await s.updateContentFilter(SCContentFilter(display: display, excludingWindows: content.windows.filter { ex.contains(Int($0.windowID)) }))
        }
    }

    // ---------- 한 프레임 ----------
    private func tick() {
        guard let scr = screen, window != nil else { return }
        let F = scr.frame
        let m = NSEvent.mouseLocation

        // 배율: 시간 기준 애니메이션 (끝으로 갈수록 느려진다)
        let goal: CGFloat = closing ? 1 : target
        if goal != animTo { animFrom = level; animTo = goal; animStart = CACurrentMediaTime() }
        if !Settings.shared.zoomSmooth || animFrom == animTo { level = animTo }
        else {
            let p = min(1, (CACurrentMediaTime() - animStart) / LiveZoom.animSeconds)
            level = animFrom + (animTo - animFrom) * CGFloat(1 - pow(1 - p, 3))
        }
        if closing && level <= 1.0001 { hide(); return }

        let newSize = CGSize(width: F.width / level, height: F.height / level)
        let local = CGPoint(x: m.x - F.minX, y: m.y - F.minY)
        // 배율이 바뀌는 동안은 "화면에 보이는 커서 자리"를 그대로 둔 채 커지고 작아진다
        if newSize != srcSize, srcSize.width > 0 {
            let sx = (local.x - origin.x) * F.width / srcSize.width, sy = (local.y - origin.y) * F.height / srcSize.height
            origin = CGPoint(x: local.x - sx * newSize.width / F.width, y: local.y - sy * newSize.height / F.height)
        }
        srcSize = newSize
        // 화면 고정: 커서가 가장자리 쪽으로 갈 때만 옮긴다
        let ex = newSize.width * LiveZoom.edgeFraction, ey = newSize.height * LiveZoom.edgeFraction
        if local.x < origin.x + ex { origin.x = local.x - ex } else if local.x > origin.x + newSize.width - ex { origin.x = local.x + ex - newSize.width }
        if local.y < origin.y + ey { origin.y = local.y - ey } else if local.y > origin.y + newSize.height - ey { origin.y = local.y + ey - newSize.height }
        origin.x = max(0, min(F.width - newSize.width, origin.x))
        origin.y = max(0, min(F.height - newSize.height, origin.y))

        // 원본 영역을 창에 꽉 차게: 점 p(화면 안 pt) → (p - origin) × 배율
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.position = CGPoint(x: -origin.x * level, y: -origin.y * level)
        imageLayer.transform = CATransform3DMakeScale(level, level, 1)
        CATransaction.commit()

        ZoomMap.screenFrame = F
        ZoomMap.source = CGRect(x: F.minX + origin.x, y: F.minY + origin.y, width: newSize.width, height: newSize.height)

        // 그린 화살표 (드로잉 붓 동그라미가 커서 노릇을 하면 감춘다)
        if let c = cursorWindow {
            if isDrawing() && brushVisible() { c.orderOut(nil) }
            else {
                let s = ZoomMap.screenPoint(m)
                c.setFrameOrigin(NSPoint(x: (s.x - ZoomCursorView.pad).rounded(), y: (s.y - ZoomCursorView.size + ZoomCursorView.pad).rounded()))
                if !c.isVisible { c.orderFrontRegardless() }
            }
        }
        SystemCursor.reassert()
        if badgeUntil > 0, CACurrentMediaTime() > badgeUntil { hideBadge() }
        refreshFilterIfNeeded()
    }

    // ---------- 단계 표시 ("확대 2단계 · 200%") ----------
    private func showBadge() {
        guard step > 0 else { return }
        if badgeWindow == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 190, height: 36), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.ignoresMouseEvents = true
            p.level = ZOOM_TOP_LEVEL
            p.collectionBehavior = EVERYWHERE
            p.isReleasedWhenClosed = false
            let bg = NSView(frame: p.contentRect(forFrameRect: p.frame))
            bg.wantsLayer = true
            bg.layer?.backgroundColor = NSColor(calibratedRed: 0x1E / 255, green: 0x29 / 255, blue: 0x3B / 255, alpha: 0.94).cgColor
            bg.layer?.cornerRadius = 10
            let l = NSTextField(labelWithString: "")
            l.font = .systemFont(ofSize: 15, weight: .bold)
            l.textColor = .white
            l.alignment = .center
            l.frame = bg.bounds.insetBy(dx: 8, dy: 8)
            bg.addSubview(l)
            p.contentView = bg
            badgeWindow = p
            badgeLabel = l
        }
        badgeLabel?.stringValue = "확대 \(step)단계 · \(Int(levels[step - 1]))%"
        let s = ZoomMap.screenPoint(NSEvent.mouseLocation)
        badgeWindow?.setFrameOrigin(NSPoint(x: s.x + 24, y: s.y - 60))
        badgeWindow?.orderFrontRegardless()
        badgeUntil = CACurrentMediaTime() + 0.9
    }

    private func hideBadge() {
        badgeUntil = 0
        badgeWindow?.orderOut(nil)
    }

    // ---------- Esc ----------
    // 확대 중이고 드로잉이 아닐 때만 Esc로 끈다 (드로잉 중 Esc는 드로잉을 끈다)
    func updateKeys() {
        HotKeyRegistry.shared.unregisterGroup(.zoom)
        guard isOn, !isDrawing() else { return }
        let esc = HotkeyNotation.Combo(code: 53, mods: 0) // kVK_Escape
        HotKeyRegistry.shared.registerGroup(.zoom, [HotKeyEntry(name: "ZoomEsc", combo: esc, press: { [weak self] _ in self?.stop() })], policy: .skipFailures)
    }
    private func unregisterKeys() { HotKeyRegistry.shared.unregisterGroup(.zoom) }

    var windowNumbers: [Int] { [window, cursorWindow, badgeWindow].compactMap { $0?.windowNumber } }
}
