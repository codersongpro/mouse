import AppKit

// 화면 구석의 작은 조작판: ⋮(옮기기) · 캡처 · 라이브 줌 · 하이라이트 · 드로잉 · 녹화 · 설정 · ✕(숨기기)
// 기본 단축키 순서(F6 → F10)와 같은 차례다 (Windows 판·안내문·랜딩페이지와 같음).
// 아이콘은 컬러 그림을 그대로 쓰고, 켜진 칸은 바탕을 하늘색(녹화 중은 연한 빨강)으로 칠한다 (Windows 판과 같음).
// Windows 판과 같은 크기 비율(칩 32, 모서리 12, 아이콘 22)을 쓴다.

let ON_COLOR: UInt32 = 0x0A84FF
// 위젯 기본색: 연노랑 (눈에 띄고 아이콘도 또렷하다, 1.3.5부터). 예전 기본은 연회색(1.3.3까지)·진한 파랑(1.3.4)
let WIDGET_DEFAULT_COLOR: UInt32 = 0xFEF08A
let WIDGET_OLD_DEFAULT_COLORS: Set<UInt32> = [0xF2F2F2, 0x2563EB]

func tintedIcon(_ name: String, _ tint: NSColor) -> NSImage? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
          let src = NSImage(contentsOf: url),
          let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    // 원본 그림 크기 그대로 색만 입힌다 — 화면 배율(Retina 여부)에 따라 결과가 달라지지 않게 화면 그림을 거치지 않는다
    let r = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
    ctx.draw(cg, in: r)
    ctx.setBlendMode(.sourceAtop) // 모양(알파)은 두고 색만 바꾼다
    ctx.setFillColor(tint.cgColor)
    ctx.fill(r)
    return ctx.makeImage().map { NSImage(cgImage: $0, size: src.size) }
}

final class WidgetPartElement: NSAccessibilityElement {
    var press: () -> Void = {}
    override func accessibilityPerformPress() -> Bool { press(); return true }
}

// 칸마다 설명 글을 돌려주는 도우미 (NSView의 툴팁 주인)
final class WidgetTipOwner: NSObject, NSViewToolTipOwner {
    weak var view: WidgetView?
    init(view: WidgetView) { self.view = view }
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        self.view?.tip(at: point) ?? ""
    }
}

final class WidgetView: NSView {
    enum Part { case grip, capture, zoom, spot, draw, record, settings, close }
    static let allParts: [Part] = [.grip, .capture, .zoom, .spot, .draw, .record, .settings, .close]

    // 강조·드로잉이 켜져 있는지는 AppState가 든다 (위젯이 따로 기억하지 않는다). 바뀌면 AppDelegate가 다시 그리게 한다.
    let state: AppState
    var spotOn: Bool { state.spotOn }
    var drawOn: Bool { state.drawOn }
    var zoomOn: Bool { state.zoomOn }
    var recOn: Bool { state.recording }
    var onAction: (Part) -> Void = { _ in }
    var onMoved: (NSPoint) -> Void = { _ in }
    // 오른쪽 클릭(⌃ 클릭)하면 메뉴 막대 아이콘과 같은 메뉴 — 노치 뒤로 아이콘이 숨었을 때를 위해
    var contextMenu: () -> NSMenu? = { nil }

    init(state: AppState) {
        self.state = state
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func rightMouseDown(with event: NSEvent) {
        guard let m = contextMenu() else { return }
        NSMenu.popUpContextMenu(m, with: event, for: self)
    }

    private var icons: [String: NSImage] = [:]
    private var dragStart: NSPoint?
    private var grab = CGVector.zero // 끌기 시작할 때 커서가 위젯 왼쪽 아래에서 떨어진 거리
    private var pressed: Part?

    static func px(_ base: CGFloat) -> CGFloat { max(1, (base * CGFloat(Settings.shared.widgetScale) / 100).rounded()) }
    static var chip: CGFloat { px(32) }
    static var pad: CGFloat { px(6) }
    static var top: CGFloat { px(4) }
    static var narrow: CGFloat { px(14) }
    static var gap: CGFloat { px(4) }
    static var size: NSSize {
        NSSize(width: pad * 2 + narrow * 2 + chip * 6 + gap * 7, height: chip + top * 2)
    }

    private var isDark: Bool {
        let c = Settings.shared.widgetColor
        let lum = 0.299 * Double((c >> 16) & 0xFF) + 0.587 * Double((c >> 8) & 0xFF) + 0.114 * Double(c & 0xFF)
        return lum < 128
    }

    private func rect(_ part: Part) -> NSRect {
        let chip = WidgetView.chip, gap = WidgetView.gap, narrow = WidgetView.narrow
        var x = WidgetView.pad
        let y = WidgetView.top
        let order: [(Part, CGFloat)] = [(.grip, narrow), (.capture, chip), (.zoom, chip), (.spot, chip), (.draw, chip), (.record, chip), (.settings, chip), (.close, narrow)]
        for (p, w) in order {
            if p == part { return NSRect(x: x, y: y, width: w, height: chip) }
            x += w + gap
        }
        return .zero
    }

    private func part(at p: NSPoint) -> Part? {
        for part in WidgetView.allParts where rect(part).insetBy(dx: -2, dy: -WidgetView.top).contains(p) {
            return part
        }
        return nil
    }

    func reloadIcons() {
        icons = [:]
        for (k, f) in [("capture", "icon_capture_color"), ("spot", "icon_spotlight_color"), ("draw", "icon_draw_color"), ("zoom", "icon_zoom_color"),
                       ("record", "icon_record_color"), ("settings", "icon_settings_color")] {
            if let url = Bundle.main.url(forResource: f, withExtension: "png"), let img = NSImage(contentsOf: url) { icons[k] = img }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let s = Settings.shared
        color(s.widgetColor).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: WidgetView.px(8), yRadius: WidgetView.px(8)).fill()

        let corner = WidgetView.px(12) / 2
        let iconSize = WidgetView.px(24)
        let onFill = NSColor(calibratedRed: 0x93 / 255, green: 0xC5 / 255, blue: 0xFD / 255, alpha: 1) // 켜짐: 하늘색 (Windows와 같음)
        let recFill = NSColor(calibratedRed: 0xFE / 255, green: 0xCA / 255, blue: 0xCA / 255, alpha: 1)
        for (part, key, on) in [(Part.capture, "capture", false), (.zoom, "zoom", zoomOn), (.spot, "spot", spotOn), (.draw, "draw", drawOn), (.record, "record", recOn), (.settings, "settings", false)] {
            let r = rect(part)
            // 칸: 흰 바탕(켜지면 하늘색, 녹화 중은 연한 빨강) + 얇은 테두리. 누르는 동안은 옅게 어둡게.
            let edge = color(s.widgetColor).blended(withFraction: 0.5, of: isDark ? .white : .black) ?? .gray
            let chip = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: corner, yRadius: corner)
            (on ? (part == .record ? recFill : onFill) : NSColor.white).setFill()
            chip.fill()
            if pressed == part { edge.withAlphaComponent(0.18).setFill(); chip.fill() }
            edge.setStroke()
            chip.lineWidth = 1 // 위젯 크기와 상관없이 1px
            chip.stroke()
            let ir = NSRect(x: r.midX - iconSize / 2, y: r.midY - iconSize / 2, width: iconSize, height: iconSize)
            icons[key]?.draw(in: ir, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }

        let textColor = isDark ? NSColor(white: 0.9, alpha: 1) : NSColor.black
        let font = NSFont.systemFont(ofSize: max(8, WidgetView.px(13)), weight: .medium)
        for (part, text) in [(Part.grip, "⋮"), (.close, "✕")] {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            let str = NSAttributedString(string: text, attributes: attrs)
            let sz = str.size()
            let r = rect(part)
            str.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // VoiceOver: 그려진 칸마다 이름 있는 버튼을 단다 (눌러서 실행 = 마우스로 누른 것과 같은 동작)
    static func accessibilityName(_ part: Part, spotOn: Bool, drawOn: Bool, zoomOn: Bool = false, recOn: Bool = false) -> String {
        switch part {
        case .grip: return "위젯 옮기기"
        case .capture: return "화면 캡처"
        case .spot: return spotOn ? "하이라이트 끄기" : "하이라이트 켜기"
        case .draw: return drawOn ? "드로잉 끄기" : "드로잉 켜기"
        case .zoom: return zoomOn ? "라이브 줌 다음 단계" : "라이브 줌 켜기"
        case .record: return recOn ? "녹화 끝내기" : "화면 녹화 시작"
        case .settings: return "설정 열기"
        case .close: return "위젯 숨기기"
        }
    }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? {
        WidgetView.allParts.map { part in
            let e = WidgetPartElement()
            e.press = { [weak self] in if part != .grip { self?.onAction(part) } }
            e.setAccessibilityRole(part == .grip ? .handle : .button)
            e.setAccessibilityLabel(WidgetView.accessibilityName(part, spotOn: spotOn, drawOn: drawOn, zoomOn: zoomOn, recOn: recOn))
            e.setAccessibilityParent(self)
            e.setAccessibilityFrameInParentSpace(rect(part))
            return e
        }
    }

    // 마우스를 올리면 뜨는 설명 (지금 단축키를 함께 보여 준다)
    static func tipText(_ part: Part) -> String {
        func key(_ name: String) -> String {
            " (" + HotkeyDisplay.symbols(Settings.shared.hotkeys[name] ?? SettingsSchema.hotkeyDefaults[name] ?? "") + ")"
        }
        switch part {
        case .grip: return "끌어서 옮기기"
        case .capture: return "화면 캡처" + key("Capture") + " · 창을 클릭해 찍기 · 오른쪽 클릭: 메뉴"
        case .spot: return "마우스 하이라이트" + key("Spotlight")
        case .draw: return "드로잉" + key("Draw")
        case .zoom: return "라이브 줌" + key("Zoom") + " · 누를 때마다 1 → 2 → 3단계 → 끄기"
        case .record: return "화면 녹화" + key("Record") + " · 오른쪽 클릭: 메뉴"
        case .settings: return "설정"
        case .close: return "위젯 숨기기 (메뉴 막대 아이콘에서 다시 켬)"
        }
    }
    func tip(at point: NSPoint) -> String { part(at: point).map(WidgetView.tipText) ?? "" }
    private lazy var tipOwner = WidgetTipOwner(view: self) // addToolTip은 주인을 붙들지 않으므로 여기서 붙든다

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeAllToolTips()
        for p in WidgetView.allParts { addToolTip(rect(p), owner: tipOwner, userData: nil) }
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    // 드로잉 중에도 위젯 위에서는 평소 화살표가 보여야 어디를 누르는지 안다
    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        let hit = part(at: p)
        if hit == .grip || hit == nil {
            dragStart = NSEvent.mouseLocation
            let o = window?.frame.origin ?? .zero
            grab = CGVector(dx: dragStart!.x - o.x, dy: dragStart!.y - o.y)
        } else {
            pressed = hit
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil, let w = window else { return }
        let m = NSEvent.mouseLocation
        // 화면 밖으로는 나가지 않게. 모니터가 여럿이면 커서가 있는 화면을 따른다.
        // 메뉴 막대·노치 아래까지만, Dock 쪽 가장자리에서는 15pt 안이면 붙는다 (계산은 widgetDragPlace)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(m) }) ?? NSScreen.screens.first else { return }
        let r = widgetDragPlace(cursor: m, grab: grab, size: w.frame.size, frame: screen.frame, visible: screen.visibleFrame)
        grab = r.grab
        w.setFrameOrigin(r.origin)
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil {
            dragStart = nil
            if let o = window?.frame.origin { onMoved(o) }
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if let pr = pressed, part(at: p) == pr { onAction(pr) }
        pressed = nil
        needsDisplay = true
    }
}

@MainActor final class Widget {
    let view: WidgetView
    let state: AppState
    private(set) var window: GlassPanel!

    init(state: AppState) {
        self.state = state
        view = WidgetView(state: state)
        window = Widget.makeWindow(view)
        view.reloadIcons()
        view.onMoved = { Settings.shared.saveWidgetPosition($0) }
        applySettings()
        let s = Settings.shared
        if let x = s.widgetX, let y = s.widgetY {
            window.setFrameOrigin(NSPoint(x: x, y: y))
            clampIntoScreen()
        } else {
            moveToDefault()
        }
        // 다른 데스크톱으로 넘어갔는데 위젯이 따라오지 않았으면 새로 만든다 (판·강조 원과 같은 까닭)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            guard let self, self.state.widgetVisible, isOffActiveSpace(self.window) else { return }
            self.setVisible(true)
        }
    }

    private static func makeWindow(_ view: WidgetView) -> GlassPanel {
        let w = GlassPanel(contentRect: NSRect(origin: .zero, size: WidgetView.size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = WIDGET_LEVEL
        w.collectionBehavior = EVERYWHERE
        w.hidesOnDeactivate = false
        w.becomesKeyOnlyIfNeeded = true
        w.isReleasedWhenClosed = false
        w.contentView = view
        return w
    }

    func applySettings() {
        let s = Settings.shared
        let o = window.frame.origin
        window.setFrame(NSRect(origin: o, size: WidgetView.size), display: true)
        window.alphaValue = CGFloat(s.widgetOpacity) / 100
        updateLevel()
        view.needsDisplay = true
        window.invalidateShadow() // 크기·색이 바뀌면 그림자도 새 모양으로
        clampIntoScreen()
    }

    // "항상 다른 창 위에 표시"를 껐으면 보통 창 높이로. 드로잉·라이브 줌·녹화 중에는 판 위에서 눌러 끌 수 있게 그래도 위로
    func updateLevel() {
        let top = Settings.shared.widgetOnTop || state.drawOn || state.zoomOn || state.recording
        let level = top ? WIDGET_LEVEL : .normal
        if window.level != level { window.level = level }
    }

    func setVisible(_ on: Bool) {
        guard on else { window.orderOut(nil); return }
        if isOffActiveSpace(window) {
            // 숨겼던 위젯을 전체 화면 데스크톱에서 다시 띄우면 나타나지 않으므로, 새 창으로 옮겨 띄운다
            let old: GlassPanel = window
            let w = Widget.makeWindow(view) // view가 새 창으로 옮겨 간다 (높이는 아래 updateLevel이 다시 맞춘다)
            w.setFrame(old.frame, display: false)
            w.alphaValue = old.alphaValue
            old.orderOut(nil); old.close()
            window = w
            Log.log("WIDGET", "rebuilt reason=offSpace")
        }
        updateLevel()
        window.orderFrontRegardless()
    }

    // 늘 주 화면(메뉴 막대가 있는 화면) 오른쪽 아래(Dock 위)로. NSScreen.main은 "지금 포커스가 있는 화면"이라 쓰지 않는다.
    func moveToDefault() {
        guard let f = NSScreen.screens.first?.visibleFrame else { return }
        let sz = WidgetView.size
        window.setFrameOrigin(NSPoint(x: f.maxX - sz.width - 20, y: f.minY + 20))
    }

    // 주 화면이 바뀌어 전역 좌표 원점이 옮겨 갔으면 위젯도 같은 화면의 같은 자리에 있게 옮긴다 (잉크와 같은 까닭)
    func shift(by v: CGVector) {
        guard v != .zero else { return }
        let o = window.frame.origin
        window.setFrameOrigin(NSPoint(x: o.x + v.dx, y: o.y + v.dy))
        view.onMoved(window.frame.origin)
    }

    // 모니터 구성이 바뀌어 저장된 자리가 화면 밖이면 들여놓는다
    func clampIntoScreen() {
        let fr = window.frame
        if NSScreen.screens.contains(where: { $0.frame.intersects(fr.insetBy(dx: fr.width / 3, dy: fr.height / 3)) }) {
            return
        }
        moveToDefault()
    }
}
