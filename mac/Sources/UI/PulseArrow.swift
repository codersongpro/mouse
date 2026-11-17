import AppKit
import QuartzCore

// ================= 움직이는 강조 화살표 (드로잉 중 V + 끌기) =================
// 끈 방향으로 화살표가 생기고, 손을 떼면 머리(끝점)를 중심으로 커졌다 작아졌다를 되풀이해 눈길을 끈다.
// 판서 그림(InkModel)이 아니라 따로 뜬 투명 창의 레이어라 지우개·실행 취소와 상관없고,
// delete(전부 지우기)·드로잉 끄기로 모두 사라진다. 여러 개를 둘 수 있다 (maxCount개, 넘으면 오래된 것부터).
// 움직임은 Core Animation이 맡아서(GPU) 앱은 CPU를 거의 쓰지 않는다. Windows판과 같은 크기·빠르기.

@MainActor final class PulseArrow {
    static let periodS: CFTimeInterval = 1.0   // 한 번 커졌다 작아지는 시간
    static let amount: CGFloat = 0.25          // 가장 클 때 늘어나는 비율
    static let maxCount = 12

    private var panels: [String: NSPanel] = [:]  // 화면마다 투명 창 하나 (키: 화면 자리)
    private var arrows: [CALayer] = []           // 움직이는 화살표들 (오래된 것부터)
    private var group: CALayer?                  // 지금 끌고 있는 것

    var isShown: Bool { !panels.isEmpty }

    // 끄는 동안 (움직이지 않음): tail → tip 화살표를 그린다. 점은 전역 좌표(왼쪽 아래 원점).
    func set(tail: CGPoint, tip: CGPoint, width: CGFloat, rgb: UInt32) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(tip) }) ?? NSScreen.main
        guard let screen else { return }
        let p = ensurePanel(on: screen)
        let o = screen.frame.origin
        let a = CGPoint(x: tail.x - o.x, y: tail.y - o.y), b = CGPoint(x: tip.x - o.x, y: tip.y - o.y)
        let w = max(6, width * 1.5)

        group?.removeFromSuperlayer()
        let g = CALayer()
        // 머리를 중심으로 커지고 작아지도록 레이어의 기준점을 머리에 둔다
        g.bounds = p.contentView!.bounds
        g.anchorPoint = CGPoint(x: b.x / max(1, g.bounds.width), y: b.y / max(1, g.bounds.height))
        g.position = b
        let parts = arrowParts(a, b, width: w)
        // 흰 테두리를 먼저 굵게 그려 어떤 배경에서도 잘 보이게 한다
        for (color, extra) in [(NSColor.white.cgColor, CGFloat(6)), (cgColor(rgb), CGFloat(0))] {
            let shaft = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: parts.shaft[0]); path.addLine(to: parts.shaft[parts.shaft.count - 1])
            shaft.path = path
            shaft.strokeColor = color; shaft.fillColor = nil
            shaft.lineWidth = w + extra; shaft.lineCap = .round
            g.addSublayer(shaft)
            if let h = parts.head, h.count == 3 {
                let head = CAShapeLayer()
                let hp = CGMutablePath(); hp.addLines(between: h); hp.closeSubpath()
                head.path = hp
                head.fillColor = color
                head.strokeColor = extra > 0 ? color : nil
                head.lineWidth = extra; head.lineJoin = .round
                g.addSublayer(head)
            }
        }
        p.contentView!.layer!.addSublayer(g)
        group = g
        p.orderFrontRegardless()
    }

    // 손을 뗐을 때: 커졌다 작아지기를 되풀이
    func start() {
        guard let g = group else { return }
        group = nil
        arrows.append(g)
        if arrows.count > PulseArrow.maxCount { arrows.removeFirst().removeFromSuperlayer() }
        let an = CABasicAnimation(keyPath: "transform.scale")
        an.fromValue = 1.0
        an.toValue = 1.0 + PulseArrow.amount
        an.duration = PulseArrow.periodS / 2
        an.autoreverses = true
        an.repeatCount = .infinity
        an.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        g.add(an, forKey: "pulse")
    }

    // 거의 움직이지 않고 손을 뗐을 때: 지금 것만 버린다
    func cancel() {
        group?.removeFromSuperlayer()
        group = nil
    }

    func clear() {
        group?.removeFromSuperlayer(); group = nil
        for a in arrows { a.removeAllAnimations(); a.removeFromSuperlayer() }
        arrows = []
        for p in panels.values { p.orderOut(nil) }
        panels = [:]
    }

    private func ensurePanel(on screen: NSScreen) -> NSPanel {
        if let p = panels[NSStringFromRect(screen.frame)] { return p }
        let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true // 클릭은 아래 판으로 그대로 간다
        p.level = NSWindow.Level(rawValue: OVERLAY_LEVEL.rawValue + 1) // 판서 판보다 위
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        let v = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        v.wantsLayer = true
        p.contentView = v
        p.setFrame(screen.frame, display: false)
        panels[NSStringFromRect(screen.frame)] = p
        return p
    }

    private func cgColor(_ rgb: UInt32) -> CGColor {
        CGColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
