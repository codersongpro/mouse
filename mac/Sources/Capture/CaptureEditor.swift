import AppKit
import UniformTypeIdentifiers

// ================= 캡처 편집 창 (ClassZoom) =================
// 펜 · 형광펜 · 네모 · 화살표 · 글자 · 모자이크 · 자르기, 색 7가지, 굵기 3단계, 되돌리기(⌘Z)
// 복사(⌘C) · 저장(⌘S, 사진 › ClassZoom 폴더에 PNG) · 다른 이름으로(⌘⇧S, PNG/JPG)
// Windows 판(capture.ahk)과 같은 도구·색·굵기를 쓴다. 좌표는 그림 픽셀, 위에서 아래로(y가 아래로 커짐).

let CAPTURE_COLORS: [UInt32] = [0xEF4444, 0xF97316, 0xFACC15, 0x22C55E, 0x2563EB, 0x111827, 0xFFFFFF]
let CAPTURE_COLOR_NAMES = ["빨강", "주황", "노랑", "초록", "파랑", "검정", "흰색"]
let CAPTURE_SIZES: [CGFloat] = [3, 6, 12]         // 화면에 보이는 굵기(pt)
let CAPTURE_TEXT_SIZES: [CGFloat] = [20, 32, 48]  // 화면에 보이는 글자 크기(pt)
let CAPTURE_MOSAIC_BLOCK: CGFloat = 12

struct CaptureMark {
    enum Kind: String { case pen, hl, rect, arrow, text, mosaic, crop }
    var kind: Kind
    var color: UInt32
    var width: CGFloat
    var points: [CGPoint] = []
    var a = CGPoint.zero, b = CGPoint.zero
    var text = ""
    var fontSize: CGFloat = 32
    var block: CGFloat = 12
    var box: CGRect { CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)) }
}

// 그림 하나를 그린다. ctx는 그림 픽셀 좌표, y가 아래로 커지는(뒤집힌) 상태여야 한다.
// target: 모자이크가 읽을 지금 그림 (미리보기에서는 nil — 점선 네모만 그린다)
func drawCaptureMark(_ m: CaptureMark, in ctx: CGContext, target: CGImage?) {
    let c = color(m.color)
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    switch m.kind {
    case .pen, .hl:
        ctx.setStrokeColor((m.kind == .hl ? c.withAlphaComponent(0.4) : c).cgColor)
        ctx.setLineWidth(m.width)
        var pts = m.points
        if pts.count == 1 { pts.append(CGPoint(x: pts[0].x + 0.5, y: pts[0].y)) }
        ctx.addLines(between: pts)
        ctx.strokePath()
    case .rect:
        ctx.setStrokeColor(c.cgColor)
        ctx.setLineWidth(m.width)
        ctx.setLineJoin(.miter)
        ctx.stroke(m.box)
    case .arrow:
        let dx = m.b.x - m.a.x, dy = m.b.y - m.a.y, len = hypot(dx, dy)
        guard len >= 1 else { return }
        let head = min(max(12, m.width * 4), len * 0.8), half = head * 0.55
        let ux = dx / len, uy = dy / len
        let bx = m.b.x - ux * head, by = m.b.y - uy * head
        ctx.setStrokeColor(c.cgColor)
        ctx.setLineWidth(m.width)
        ctx.move(to: m.a); ctx.addLine(to: CGPoint(x: bx + ux, y: by + uy)); ctx.strokePath()
        ctx.setFillColor(c.cgColor)
        ctx.move(to: m.b)
        ctx.addLine(to: CGPoint(x: bx - uy * half, y: by + ux * half))
        ctx.addLine(to: CGPoint(x: bx + uy * half, y: by - ux * half))
        ctx.closePath(); ctx.fillPath()
    case .text:
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: m.fontSize), .foregroundColor: c]
        NSAttributedString(string: m.text, attributes: attrs).draw(at: m.a)
        NSGraphicsContext.restoreGraphicsState()
    case .mosaic, .crop:
        guard m.kind == .mosaic, let src = target else {
            // 미리보기: 점선 네모
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(2 / max(0.01, ctx.ctm.a))
            ctx.setLineDash(phase: 0, lengths: [6 / max(0.01, ctx.ctm.a), 4 / max(0.01, ctx.ctm.a)])
            ctx.stroke(m.box)
            return
        }
        let r = m.box.integral.intersection(CGRect(x: 0, y: 0, width: src.width, height: src.height))
        guard r.width >= 2, r.height >= 2, let region = src.cropping(to: r) else { return }
        let sw = max(1, Int(ceil(r.width / m.block))), sh = max(1, Int(ceil(r.height / m.block)))
        guard let small = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        small.interpolationQuality = .high
        small.draw(region, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let tiny = small.makeImage() else { return }
        ctx.clip(to: r)
        ctx.interpolationQuality = .none
        // 뒤집힌 좌표에서 그림을 바로 세워 그린다
        ctx.translateBy(x: r.minX, y: r.minY + CGFloat(sh) * m.block)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(tiny, in: CGRect(x: 0, y: 0, width: CGFloat(sw) * m.block, height: CGFloat(sh) * m.block))
    }
}

// ---------- 그림판 ----------
final class CaptureCanvas: NSView {
    private(set) var base: CGImage
    private(set) var marks: [CaptureMark] = []
    private var history: [Any] = []          // "mark" 또는 (base, marks) — 자르기
    private(set) var composite: CGImage
    private var compositeImage: NSImage
    var current: CaptureMark?
    var tool: CaptureMark.Kind = .pen
    var colorIndex = 0
    var sizeIndex = 1
    var onChange: () -> Void = {}
    var askText: (@escaping (String) -> Void) -> Void = { _ in }

    init(image: CGImage) {
        base = image
        composite = image
        compositeImage = NSImage(cgImage: image, size: .zero)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var canUndo: Bool { !history.isEmpty }

    // 보이는 배율·자리 (그림 픽셀 → 뷰 pt)
    private var fit: (s: CGFloat, ox: CGFloat, oy: CGFloat) {
        let w = CGFloat(composite.width), h = CGFloat(composite.height)
        let one = 1 / (window?.backingScaleFactor ?? 2) // 그림 1픽셀 = 화면 1픽셀 (원래 크기)보다 키우지 않는다
        let s = max(0.01, min(one, (bounds.width - 16) / w, (bounds.height - 16) / h))
        return (s, ((bounds.width - w * s) / 2).rounded(), ((bounds.height - h * s) / 2).rounded())
    }

    private func imagePoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil), f = fit
        return CGPoint(x: max(0, min(CGFloat(composite.width), (p.x - f.ox) / f.s)),
                       y: max(0, min(CGFloat(composite.height), (p.y - f.oy) / f.s)))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0xE2 / 255, green: 0xE8 / 255, blue: 0xF0 / 255, alpha: 1).setFill()
        bounds.fill()
        let f = fit
        let r = NSRect(x: f.ox, y: f.oy, width: CGFloat(composite.width) * f.s, height: CGFloat(composite.height) * f.s)
        compositeImage.draw(in: r, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                            hints: [.interpolation: NSImageInterpolation.high.rawValue])
        guard let m = current, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        if m.kind == .crop { // 잘라낼 바깥을 어둡게
            let box = m.box.applying(CGAffineTransform(a: f.s, b: 0, c: 0, d: f.s, tx: f.ox, ty: f.oy))
            ctx.setFillColor(NSColor(white: 0, alpha: 0.45).cgColor)
            ctx.addRect(bounds); ctx.addRect(box)
            ctx.fillPath(using: .evenOdd)
        }
        ctx.translateBy(x: f.ox, y: f.oy)
        ctx.scaleBy(x: f.s, y: f.s)
        drawCaptureMark(m, in: ctx, target: nil)
        ctx.restoreGState()
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = imagePoint(e), f = fit
        let c = CAPTURE_COLORS[colorIndex]
        let w = CAPTURE_SIZES[sizeIndex] * (tool == .hl ? 3 : 1) + (tool == .hl ? 6 : 0)
        if tool == .text {
            let size = CAPTURE_TEXT_SIZES[sizeIndex] / f.s
            askText { [weak self] text in
                self?.commit(CaptureMark(kind: .text, color: c, width: 0, a: p, text: text, fontSize: size))
            }
            return
        }
        var m = CaptureMark(kind: tool, color: c, width: w / f.s, a: p, b: p, block: max(4, (CAPTURE_MOSAIC_BLOCK / f.s).rounded()))
        if tool == .pen || tool == .hl { m.points = [p] }
        current = m
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard var m = current else { return }
        let p = imagePoint(e)
        if m.kind == .pen || m.kind == .hl {
            if let last = m.points.last, abs(p.x - last.x) + abs(p.y - last.y) < 1.5 / fit.s { return }
            m.points.append(p)
        } else {
            m.b = p
        }
        current = m
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard let m = current else { return }
        current = nil
        if m.kind == .pen || m.kind == .hl || abs(m.b.x - m.a.x) >= 3 || abs(m.b.y - m.a.y) >= 3 { commit(m) }
        needsDisplay = true
    }

    // ---------- 확정 · 되돌리기 ----------
    func commit(_ m: CaptureMark) {
        if m.kind == .crop {
            let r = m.box.integral.intersection(CGRect(x: 0, y: 0, width: composite.width, height: composite.height))
            guard r.width >= 4, r.height >= 4, let cut = composite.cropping(to: r) else { return }
            history.append((base, marks))
            base = cut
            marks = []
            rebuild()
            tool = .pen
            window?.invalidateCursorRects(for: self)
        } else {
            marks.append(m)
            history.append("mark")
            composite = CaptureCanvas.render(base: base, marks: [m], onto: composite)
            compositeImage = NSImage(cgImage: composite, size: .zero)
        }
        needsDisplay = true
        onChange()
    }

    func undo() {
        guard let e = history.popLast() else { return }
        if let t = e as? (CGImage, [CaptureMark]) { base = t.0; marks = t.1 } else { _ = marks.popLast() }
        rebuild()
        needsDisplay = true
        onChange()
    }

    private func rebuild() {
        composite = CaptureCanvas.render(base: base, marks: marks, onto: base)
        compositeImage = NSImage(cgImage: composite, size: .zero)
    }

    // onto 위에 marks를 차례로 그린 새 그림
    static func render(base: CGImage, marks: [CaptureMark], onto: CGImage) -> CGImage {
        let w = onto.width, h = onto.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return onto }
        ctx.draw(onto, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        for m in marks {
            // 모자이크는 그 순간의 그림을 읽는다 (앞에 그린 것까지 가려진다)
            let target = m.kind == .mosaic ? ctx.makeImage() : nil
            drawCaptureMark(m, in: ctx, target: target)
        }
        return ctx.makeImage() ?? onto
    }
}

// ---------- 창 ----------
final class CaptureEditorWindow: NSWindow {
    var onKey: (String, NSEvent.ModifierFlags) -> Bool = { _, _ in false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if f.contains(.command), let k = event.charactersIgnoringModifiers?.lowercased(), onKey(k, f) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class CaptureEditor: NSObject, NSWindowDelegate {
    let window: CaptureEditorWindow
    let canvas: CaptureCanvas
    private let status = NSTextField(labelWithString: "")
    private let tools = NSSegmentedControl()
    private let colors = NSSegmentedControl()
    private let sizes = NSSegmentedControl()
    private(set) var dirty = false
    private var saved: URL?
    var onClose: () -> Void = {}
    private static let toolList: [(CaptureMark.Kind, String)] = [(.pen, "펜"), (.hl, "형광펜"), (.rect, "네모"), (.arrow, "화살표"),
                                                                 (.text, "글자"), (.mosaic, "모자이크"), (.crop, "자르기")]

    init(image: CGImage) {
        canvas = CaptureCanvas(image: image)
        // 그림이 원래 크기(pt)로 들어가게, 단 화면 작업 영역의 90%까지
        let m = NSEvent.mouseLocation
        let scr = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let pt = NSSize(width: CGFloat(image.width) / scr.backingScaleFactor, height: CGFloat(image.height) / scr.backingScaleFactor)
        let vf = scr.visibleFrame
        let size = NSSize(width: min(max(pt.width + 32, 860), vf.width * 0.9), height: min(max(pt.height + 140, 460), vf.height * 0.9))
        window = CaptureEditorWindow(contentRect: NSRect(origin: .zero, size: size),
                                     styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "ClassZoom 캡처 편집"
        window.minSize = NSSize(width: 860, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        buildUI()
        window.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2))
        window.onKey = { [weak self] k, f in
            guard let self else { return false }
            switch (k, f.contains(.shift)) {
            case ("z", false): self.canvas.undo(); return true
            case ("c", false): self.copyImage(); return true
            case ("s", false): self.save(); return true
            case ("s", true): self.saveAs(); return true
            default: return false
            }
        }
        canvas.onChange = { [weak self] in self?.dirty = true; self?.updateStatus() }
        canvas.askText = { [weak self] done in self?.askText(done) }
        setStatus("클립보드에 복사했습니다. 바로 붙여넣기(⌘V)할 수 있습니다.")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private func buildUI() {
        tools.segmentCount = Self.toolList.count
        for (i, t) in Self.toolList.enumerated() { tools.setLabel(t.1, forSegment: i); tools.setWidth(66, forSegment: i) }
        tools.trackingMode = .selectOne
        tools.selectedSegment = 0
        tools.target = self; tools.action = #selector(toolChanged)

        colors.segmentCount = CAPTURE_COLORS.count
        for (i, c) in CAPTURE_COLORS.enumerated() {
            let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
                color(c).setFill()
                let p = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
                p.fill(); NSColor.black.withAlphaComponent(0.35).setStroke(); p.lineWidth = 1; p.stroke()
                return true
            }
            colors.setImage(img, forSegment: i)
            colors.setToolTip(CAPTURE_COLOR_NAMES[i], forSegment: i)
            colors.setWidth(30, forSegment: i)
        }
        colors.trackingMode = .selectOne
        colors.selectedSegment = 0
        colors.target = self; colors.action = #selector(colorChanged)

        sizes.segmentCount = 3
        for (i, t) in ["가늘게", "보통", "굵게"].enumerated() { sizes.setLabel(t, forSegment: i) }
        sizes.trackingMode = .selectOne
        sizes.selectedSegment = 1
        sizes.target = self; sizes.action = #selector(sizeChanged)

        let row1 = NSStackView(views: [tools, button("되돌리기 (⌘Z)", #selector(undoClicked))])
        let row2 = NSStackView(views: [colors, sizes, NSView(), button("복사 (⌘C)", #selector(copyClicked)), button("저장 (⌘S)", #selector(saveClicked)),
                                       button("다른 이름으로…", #selector(saveAsClicked)), button("폴더 열기", #selector(folderClicked))])
        for r in [row1, row2] { r.orientation = .horizontal; r.spacing = 8; r.alignment = .centerY }
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        canvas.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        canvas.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        for v in [row1, row2, status] { v.setContentHuggingPriority(.defaultHigh, for: .vertical) }
        canvas.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [row1, row2, canvas, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12),
            canvas.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -12),
            row2.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -12),
            status.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -12),
        ])
        window.contentView = content
    }

    // ---------- 도구 ----------
    @objc private func toolChanged() {
        canvas.tool = Self.toolList[max(0, tools.selectedSegment)].0
        window.invalidateCursorRects(for: canvas)
        updateStatus()
    }
    @objc private func colorChanged() {
        canvas.colorIndex = max(0, colors.selectedSegment)
        if canvas.tool == .mosaic || canvas.tool == .crop { canvas.tool = .pen; tools.selectedSegment = 0 } // 색을 고르면 그리는 도구로
        updateStatus()
    }
    @objc private func sizeChanged() { canvas.sizeIndex = max(0, sizes.selectedSegment) }
    @objc private func undoClicked() { canvas.undo() }
    @objc private func copyClicked() { copyImage() }
    @objc private func saveClicked() { save() }
    @objc private func saveAsClicked() { saveAs() }
    @objc private func folderClicked() {
        if let u = saved, FileManager.default.fileExists(atPath: u.path) { NSWorkspace.shared.activateFileViewerSelecting([u]); return }
        let f = Self.folder()
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        NSWorkspace.shared.open(f)
    }

    private func updateStatus() {
        tools.selectedSegment = Self.toolList.firstIndex { $0.0 == canvas.tool } ?? 0 // 자르기 뒤에는 펜으로 돌아온다
        let name = Self.toolList.first { $0.0 == canvas.tool }?.1 ?? ""
        setStatus("\(name) · 그림 위를 \(canvas.tool == .text ? "클릭해 글자를 넣으세요." : "끌어서 쓰세요.")   ⌘Z 되돌리기 · ⌘C 복사 · ⌘S 저장")
    }
    private func setStatus(_ t: String) { status.stringValue = t }
    func showNote(_ t: String) { setStatus(t) } // 스크롤 캡처가 어떻게 끝났는지

    private func askText(_ done: @escaping (String) -> Void) {
        let a = NSAlert()
        a.messageText = "넣을 글자를 입력하세요"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "넣기")
        a.addButton(withTitle: "취소")
        a.window.initialFirstResponder = f
        a.beginSheetModal(for: window) { r in
            MainActor.assumeIsolated {
                let t = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if r == .alertFirstButtonReturn, !t.isEmpty { done(f.stringValue) }
            }
        }
    }

    // ---------- 복사 · 저장 ----------
    func copyImage() {
        if copyImageToPasteboard(canvas.composite) {
            dirty = false
            setStatus("클립보드에 복사했습니다. 붙여넣기(⌘V)로 쓰세요.")
        } else { setStatus("클립보드에 복사하지 못했습니다. 다시 눌러 주세요.") }
    }

    static func folder() -> URL {
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return base.appendingPathComponent("ClassZoom", isDirectory: true)
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "ClassZoom_\(f.string(from: Date()))"
    }

    @discardableResult
    func save() -> Bool {
        let dir = Self.folder()
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { setStatus("저장할 폴더를 만들 수 없습니다: \(dir.path)"); return false }
        var url = dir.appendingPathComponent(Self.stamp() + ".png"), n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("\(Self.stamp())_\(n).png"); n += 1 }
        return write(to: url)
    }

    func saveAs() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.png, .jpeg]
        p.nameFieldStringValue = Self.stamp() + ".png"
        let dir = Self.folder()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        p.directoryURL = dir
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let u = p.url else { return }
            MainActor.assumeIsolated { _ = self?.write(to: u) }
        }
    }

    private func write(to url: URL) -> Bool {
        let rep = NSBitmapImageRep(cgImage: canvas.composite)
        let jpg = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
        let props: [NSBitmapImageRep.PropertyKey: Any] = jpg ? [.compressionFactor: 0.92] : [:]
        guard let data = rep.representation(using: jpg ? .jpeg : .png, properties: props) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            saved = url
            dirty = false
            setStatus("저장했습니다: \(url.path)")
            Log.log("CAP", "saved")
            return true
        } catch {
            setStatus("저장하지 못했습니다: \(url.path)")
            return false
        }
    }

    // ---------- 닫기 ----------
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard dirty else { return true }
        let a = NSAlert()
        a.messageText = "편집한 내용을 저장하지 않았습니다"
        a.informativeText = "닫기 전에 사진 › ClassZoom 폴더에 저장할까요?"
        a.addButton(withTitle: "저장")
        a.addButton(withTitle: "저장 안 함")
        a.addButton(withTitle: "취소")
        switch a.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) { onClose() }

    // 새 캡처로 바꿀 때: 묻지 않고 닫는다 (이미 물어봤다)
    func closeQuietly() {
        dirty = false
        window.close()
    }
}
