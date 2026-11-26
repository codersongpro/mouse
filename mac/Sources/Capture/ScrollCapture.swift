import AppKit
import ScreenCaptureKit

// ================= 스크롤 캡처 (⌃F6, Windows 판과 같은 키) =================
// 창을 클릭하거나 구역을 끌면, 그 자리에서 휠을 조금씩 굴려 내리며 찍고 새로 드러난 줄만 이어 붙인다.
//   - 겹치는 자리 찾기: 줄마다 지문(해시)을 만들고, 앞 장과 새 장에서 같은 지문이 몇 줄 차이로 나타나는지
//     표를 던져 가장 많이 나온 차이(= 스크롤한 거리, 픽셀)를 고른다. 안 되면 줄 밝기 합으로 한 번 더 찾는다.
//   - 머리·바닥 고정 줄: 처음 두 장에서 위·아래에 그대로 있는 줄(도구 막대·고정 메뉴)은 맞추기에서 빼고,
//     머리는 첫 장에서, 바닥은 마지막 장에서 한 번만 넣는다.
//   - 멈추는 때: 휠을 굴려도 화면이 그대로면(끝에 닿음) · esc · [멈춤] 버튼 · ⌃F6 한 번 더 · 최대 높이.
//     멈추면 거기까지 이은 그림을 편집 창에 띄운다.
//   - 휠은 CGEvent로 보낸다 → 손쉬운 사용 권한이 필요하다 (없으면 안내 창).
//   - 드로잉 판은 찍지 않는다(그림이 따라 움직이지 않아 이어 붙이기를 망친다). 확대는 시작 전에 끈다(AppDelegate).

@MainActor final class ScrollShooter: NSObject {
    enum Ending { case end, stop, max, lost }

    static let maxPixelHeight = 40_000   // 이어 붙인 그림의 최대 높이(픽셀, 레티나 2배 기준 2만 pt)
    static let maxSteps = 300

    private(set) var running = false
    private var stopFlag = false
    private var panel: NSPanel?
    private var info: NSTextField?
    private var frameWindow: NSWindow?
    private var monitors: [Any] = []
    var windowNumbers: [Int] { [panel?.windowNumber, frameWindow?.windowNumber].compactMap { $0 } }

    @objc func stop() { stopFlag = true }

    // 휠 이벤트를 보낼 수 있는가 (없으면 시스템에 한 번 묻는다)
    static func canPostEvents() -> Bool {
        if CGPreflightPostEventAccess() { return true }
        _ = CGRequestPostEventAccess()
        return false
    }

    // rect: 전역 pt(왼쪽 아래 원점), p: 휠을 굴릴 자리(전역 pt). 찍기에 실패하면(권한) nil
    func run(_ rect: CGRect, at p: NSPoint, excluding: @escaping () -> [Int]) async -> (CGImage, String)? {
        running = true
        stopFlag = false
        showUI(rect)
        defer { hideUI(); running = false }
        try? await Task.sleep(nanoseconds: 150_000_000) // 표시창이 자리 잡을 때까지

        guard let firstImg = try? await Capturer.grab(rect, excluding: excluding()) else { return nil }
        // 찍은 그림의 색 공간 그대로 픽셀을 읽는다. 그 공간으로 그릴 수 없으면 sRGB로
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        var space: CGColorSpace = (firstImg.colorSpace?.model == .rgb ? firstImg.colorSpace : nil) ?? srgb
        var first = ScrollFrame(firstImg, space: space)
        if first == nil { space = srgb; first = ScrollFrame(firstImg, space: space) }
        guard var prev = first else { return nil }
        let w = prev.w, h = prev.h
        let scale = max(1, CGFloat(h) / max(1, rect.height))
        var out: [UInt32] = []
        var total = 0, steps = 0
        var top = -1, bot = 0
        var request = max(20, Double(rect.height) * 0.3) // 한 번에 굴릴 거리(pt). 잰 결과로 맞춰 간다
        var why = Ending.end
        Log.log("CAP", "scroll start \(w)x\(h)")

        for _ in 0..<Self.maxSteps {
            if stopFlag { why = .stop; break }
            await Self.wheel(at: p, points: request)
            // 화면이 바뀔 때까지 (부드러운 스크롤·늦게 그리는 페이지는 조금 더 기다린다)
            var cur: ScrollFrame?
            for t in 1...3 {
                try? await Task.sleep(nanoseconds: UInt64(250_000_000 * t))
                if stopFlag { break }
                guard let img = try? await Capturer.grab(rect, excluding: excluding()),
                      let f = ScrollFrame(img, space: space), f.w == w, f.h == h else { break }
                if f.keys != prev.keys { cur = f; break }
            }
            guard let c = cur else { why = stopFlag ? .stop : .end; break }
            if top < 0 { (top, bot) = Self.staticBands(prev, c) }
            let d = Self.findShift(prev, c, top: top, bot: bot)
            guard d > 0 else { why = .lost; break }
            if out.isEmpty { // 첫 장: 머리부터 바닥 고정 줄 위까지
                out.reserveCapacity(w * h * 4)
                out.append(contentsOf: prev.px[0 ..< (h - bot) * w])
                total = h - bot
            }
            out.append(contentsOf: c.px[(h - bot - d) * w ..< (h - bot) * w]) // 새로 드러난 줄
            total += d
            steps += 1
            // 다음 휠: 보이는 높이의 60%쯤 움직이게 (겹치는 줄이 남아야 맞출 수 있다)
            let perPoint = Double(d) / request
            request = min(3000, max(10, Double(h - top - bot) * 0.6 / max(0.1, perPoint)))
            prev = c
            info?.stringValue = "스크롤하며 캡처하는 중…  \(steps)번 내림 · 높이 \(Int(CGFloat(total) / scale))pt"
            if total >= Self.maxPixelHeight { why = .max; break }
        }
        Log.log("CAP", "scroll end \(why) steps=\(steps) h=\(total)")

        if out.isEmpty { // 한 번도 내려가지 않았다 → 그 화면 한 장
            return (firstImg, "스크롤할 내용이 없어 보이는 화면 한 장만 찍었습니다. 클립보드에 복사했습니다.")
        }
        if bot > 0 { // 바닥 고정 줄은 마지막 장에서
            out.append(contentsOf: prev.px[(h - bot) * w ..< h * w])
            total += bot
        }
        guard let img = Self.makeImage(out, w: w, h: total, space: space) else { return (firstImg, "이어 붙인 그림을 만들지 못해 첫 화면만 담았습니다.") }
        let msg: String
        switch why {
        case .end: msg = "끝까지 스크롤해 이어 붙였습니다."
        case .stop: msg = "멈춘 곳까지 이어 붙였습니다."
        case .max: msg = "최대 길이에 닿아 멈췄습니다."
        case .lost: msg = "화면이 이어지는 자리를 찾지 못해 거기서 멈췄습니다 (움직이는 그림·고정된 배경이 많은 화면)."
        }
        return (img, "스크롤 캡처: \(msg) 높이 \(Int(CGFloat(total) / scale))pt · 클립보드에 복사했습니다.")
    }

    // ---------- 휠 ----------
    // p 자리로 커서를 옮기고 아래로 굴린다 (그 자리의 창이 받는다). 큰 거리는 나눠 보낸다
    static func wheel(at p: NSPoint, points: Double) async {
        guard let primary = NSScreen.screens.first else { return }
        let cg = CGPoint(x: p.x, y: primary.frame.maxY - p.y)
        var left = Int32(points.rounded())
        while left > 0 {
            let n = min(left, 120)
            left -= n
            CGWarpMouseCursorPosition(cg) // 사용자가 마우스를 움직였어도 그 자리로
            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -n, wheel2: 0, wheel3: 0) {
                e.location = cg
                e.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 12_000_000)
        }
    }

    // ---------- 맞추기 ----------
    // 위·아래에서 두 장이 그대로인 줄 수 (각각 높이의 1/3까지)
    static func staticBands(_ a: ScrollFrame, _ b: ScrollFrame) -> (Int, Int) {
        let h = a.h, lim = h / 3
        var top = 0, bot = 0
        while top < lim && a.keys[top] == b.keys[top] { top += 1 }
        while bot < lim && a.keys[h - 1 - bot] == b.keys[h - 1 - bot] { bot += 1 }
        return (top, bot)
    }

    // 새 장의 y줄 = 앞 장의 y+d줄이 되는 d(픽셀). 못 찾으면 0
    static func findShift(_ a: ScrollFrame, _ b: ScrollFrame, top: Int, bot: Int) -> Int {
        let lo = top, hi = a.h - 1 - bot
        guard hi - lo >= 8 else { return 0 }
        // 1) 지문 표 던지기: 앞 장에 드물게(3번 이하) 나오는 지문만 쓴다 (반복 무늬에 속지 않게)
        var pos: [Int64: [Int]] = [:]
        for y in lo...hi where a.keys[y] > 0 { pos[a.keys[y], default: []].append(y) }
        var votes: [Int: Int] = [:]
        for y in lo...hi where b.keys[y] > 0 {
            guard let list = pos[b.keys[y]], list.count <= 3 else { continue }
            for py in list where py > y { votes[py - y, default: 0] += 1 }
        }
        if let best = votes.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }), best.value >= 3 {
            let d = best.key
            var cmp = 0, ok = 0
            for y in lo...(hi - d) where b.keys[y] > 0 || a.keys[y + d] > 0 {
                cmp += 1
                if b.keys[y] == a.keys[y + d] { ok += 1 }
            }
            if cmp >= 3 && Double(ok) / Double(cmp) >= 0.7 { return d }
        }
        // 2) 밝기 합으로 찾기 (글자가 반 픽셀씩 다르게 그려지는 화면). 겹침이 16줄 이상인 d 가운데 차이가 가장 작은 것
        let n = hi - lo + 1
        guard n > 17 else { return 0 }
        var bestD = 0, bestE = Double.infinity
        for d in 1...(n - 16) {
            var e = 0, c = 0, varSum = 0
            var y = lo
            while y <= hi - d {
                e += abs(b.sums[y] - a.sums[y + d])
                varSum += abs(b.sums[y] - b.sums[lo])
                c += 1
                y += 2
            }
            guard c > 0, varSum > 0 else { continue }
            let m = Double(e) / Double(c)
            if m < bestE { bestE = m; bestD = d }
        }
        return bestE <= Double(a.w) * 3 * 1.5 ? bestD : 0 // 픽셀 하나·색 하나에 평균 1.5단계 차이까지
    }

    static func makeImage(_ px: [UInt32], w: Int, h: Int, space: CGColorSpace) -> CGImage? {
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: ScrollFrame.bitmapInfo), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // ---------- 찍는 동안의 표시 (찍히지 않는다) ----------
    private func showUI(_ r: CGRect) {
        let red = NSColor(calibratedRed: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1)
        // 구역 바깥 빨간 테두리 (클릭·휠은 그대로 지나간다)
        let b: CGFloat = 3
        let fw = NSWindow(contentRect: r.insetBy(dx: -b, dy: -b), styleMask: .borderless, backing: .buffered, defer: false)
        fw.isOpaque = false; fw.backgroundColor = .clear; fw.hasShadow = false
        fw.ignoresMouseEvents = true
        fw.level = ZOOM_TOP_LEVEL
        fw.collectionBehavior = EVERYWHERE
        fw.sharingType = .none
        fw.isReleasedWhenClosed = false
        let fv = NSView(frame: NSRect(origin: .zero, size: fw.frame.size))
        fv.wantsLayer = true
        fv.layer?.borderColor = red.cgColor
        fv.layer?.borderWidth = b
        fw.contentView = fv
        fw.orderFrontRegardless()
        frameWindow = fw

        // 안내 + [멈춤] 버튼
        let label = NSTextField(labelWithString: "스크롤하며 캡처하는 중…")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.frame = NSRect(x: 16, y: 13, width: 300, height: 20)
        info = label
        let btn = NSButton(title: "멈춤 (esc)", target: self, action: #selector(stop))
        btn.bezelStyle = .rounded
        btn.frame = NSRect(x: 326, y: 8, width: 110, height: 30)
        let size = NSSize(width: 450, height: 46)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = NSWindow.Level(rawValue: ZOOM_TOP_LEVEL.rawValue + 1)
        p.collectionBehavior = EVERYWHERE
        p.sharingType = .none
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        let bg = NSView(frame: NSRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(calibratedRed: 0x1E / 255, green: 0x29 / 255, blue: 0x3B / 255, alpha: 0.95).cgColor
        bg.layer?.cornerRadius = 10
        bg.addSubview(label)
        bg.addSubview(btn)
        p.contentView = bg
        // 구역 위에 자리가 있으면 위, 없으면 아래, 둘 다 없으면 구역 안 위쪽
        let vf = (NSScreen.screens.first(where: { $0.frame.intersects(r) }) ?? NSScreen.main)?.visibleFrame ?? r
        let x = min(max(vf.minX, r.midX - size.width / 2), vf.maxX - size.width)
        let y: CGFloat
        if r.maxY + 10 + size.height <= vf.maxY { y = r.maxY + 10 }
        else if r.minY - 10 - size.height >= vf.minY { y = r.minY - 10 - size.height }
        else { y = r.maxY - size.height - 10 }
        p.setFrameOrigin(NSPoint(x: x, y: y))
        p.orderFrontRegardless()
        panel = p

        let esc: (NSEvent) -> Void = { [weak self] e in if e.keyCode == 53 { self?.stop() } }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: esc) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in
            if e.keyCode == 53 { esc(e); return nil }
            return e
        }) { monitors.append(l) }
    }

    private func hideUI() {
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        panel?.orderOut(nil); panel = nil
        frameWindow?.orderOut(nil); frameWindow = nil
        info = nil
    }
}

// 찍은 한 장: 픽셀(RGBA)과 줄마다의 지문·밝기 합
struct ScrollFrame {
    static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    let w: Int, h: Int
    let px: [UInt32]
    let keys: [Int64]   // 한 색으로만 된 줄(여백)은 음수 — 맞추기 표에 쓰지 않는다
    let sums: [Int]

    init?(_ img: CGImage, space: CGColorSpace) {
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt32](repeating: 0, count: w * h)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: ScrollFrame.bitmapInfo) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var keys = [Int64](repeating: 0, count: h)
        var sums = [Int](repeating: 0, count: h)
        px.withUnsafeBufferPointer { p in
            for y in 0..<h {
                let row = y * w
                let first = p[row] & 0x00FF_FFFF
                var hv: UInt64 = 1469598103934665603
                var uni = true
                var s = 0
                for x in 0..<w {
                    let v = p[row + x] & 0x00FF_FFFF
                    if v != first { uni = false }
                    hv = (hv ^ UInt64(v)) &* 1099511628211
                    s += Int(v & 0xFF) + Int((v >> 8) & 0xFF) + Int(v >> 16)
                }
                keys[y] = uni ? -Int64(first) - 1 : Int64(hv & 0x3FFF_FFFF_FFFF_FFFF) + 1
                sums[y] = s
            }
        }
        self.w = w; self.h = h; self.px = px; self.keys = keys; self.sums = sums
    }
}
