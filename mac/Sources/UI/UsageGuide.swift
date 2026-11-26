import AppKit
import SwiftUI

// ================= 사용 방법 안내 창 (ClassZoom) =================
// 처음 실행하면 뜬다. "다음부터 보지 않기"를 켜고 닫으면 다음 실행부터 뜨지 않는다(UserDefaults showGuideOnStart).
// 메뉴 막대 아이콘 › 도움말 › 사용 방법, 설정 › 일반 › 사용 방법 보기로 언제든 다시 연다.
// 단축키는 지금 설정된 값을 읽어 보여 준다.

private func bundleImage(_ name: String) -> NSImage {
    if let url = Bundle.main.url(forResource: name, withExtension: "png"), let img = NSImage(contentsOf: url) { return img }
    return NSImage(size: NSSize(width: 1, height: 1))
}

// 만든 사람 (설정 창 정보 카드·이용 안내와 같이 쓴다)
enum Maker {
    static let name = "송동석 (Songpro / Dustin)"
    static let role = "AI Product Builder · Educator · Data Analyst"
    static let slogan = "즐거움은 더하고, 불편함은 덜고."
    static let copyright = "© 2026 송동석"
}

private func key(_ name: String) -> String {
    HotkeyDisplay.symbols(Settings.shared.hotkeys[name] ?? SettingsSchema.hotkeyDefaults[name] ?? "")
}

struct UsageGuideView: View {
    @State var dontShow: Bool
    var onClose: (Bool) -> Void
    var onShowKeyboard: () -> Void

    private let ink = Color(red: 0x1E / 255, green: 0x29 / 255, blue: 0x3B / 255)
    private let blue = Color(red: 0x1D / 255, green: 0x4E / 255, blue: 0xD8 / 255)

    // 내용이 화면보다 길면(작은 화면·큰 글씨) 이 높이로 자르고 스크롤한다 (nil = 내용 높이 그대로)
    var scrollHeight: CGFloat? = nil

    var body: some View {
        if let h = scrollHeight {
            ScrollView(.vertical) { content }.frame(width: 600, height: h)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ClassZoom 사용 방법").font(.system(size: 22, weight: .bold)).foregroundColor(ink)
                Text("화면 오른쪽 아래 위젯의 버튼이나 단축키로 켜고 끕니다. 맥북에서는 F키를 fn과 함께 누르세요.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                row("icon_capture_color", "화면 캡처", "\(key("Capture")) · \(key("CaptureAlt"))", "창을 클릭하거나 구역을 끌어서 찍고 펜·도형·글자·모자이크를 넣습니다. 바로 클립보드에 복사되고 사진 › ClassZoom에 저장합니다. 전체 화면 \(key("CaptureScreen")) · 구역 지정 \(key("CaptureArea")) · 스크롤 캡처 \(key("CaptureScroll"))")
                row("icon_zoom_color", "라이브 줌", "\(key("Zoom")) · \(key("ZoomAlt"))", "누를 때마다 1단계 → 2단계 → 3단계 → 끄기. 화면은 고정되고 커서만 움직입니다.")
                row("icon_spotlight_color", "마우스 하이라이트", "\(key("Spotlight")) · \(key("SpotlightAlt"))", "커서 주위를 원하는 색의 원으로 밝히고(색은 설정에서 고름), 클릭하면 원이 오므라듭니다.")
                row("icon_draw_color", "드로잉", "\(key("Draw")) · \(key("DrawAlt"))", "화면 위에 그립니다. 오른쪽 ⌥를 누르고 있는 동안에도 그려집니다. esc는 지우고 끄기.")
                row("icon_record_color", "화면 녹화", "\(key("Record")) · \(key("RecordAlt"))", "3·2·1 뒤 녹화하고 다시 누르면 동영상 › ClassZoom 폴더에 저장합니다.")
                row("icon_settings_color", "설정", "위젯 버튼", "색·굵기·확대 배율·녹화 소리를 바꿉니다. 단축키도 원하는 키로 바꿀 수 있습니다(단축키 탭).")
            }
            Divider()
            HStack(alignment: .top, spacing: 28) {
                section("라이브 줌 중", [("⌃ + 휠", "단계 올리기 · 내리기"), ("esc", "확대 끄기"), ("가장자리로", "그쪽으로 화면 이동")])
                section("녹화", [(key("RecordPause"), "일시정지 · 계속"), (key("RecordArea"), "영역 골라 녹화"), ("표시창", "일시정지 · 정지 버튼")])
            }
            section("드로잉 중", [("오른쪽 ⌥ + 끌기", "F9 없이 바로 (떼면 그림은 남음)"), ("⌃ / ⇧ + 끌기", "네모 / 원"), ("Z / X / C + 끌기", "직선 / 물결 / 화살표"), ("V + 끌기", "강조 화살표"), ("1 ~ 9, 0", "색 바꾸기, 기본 색"), ("⌥ + 끌기", "지우개"), ("⌘Z / delete", "되돌리기 / 전부 지우기")])
            Text("화면 캡처·라이브 줌·화면 녹화는 처음 쓸 때 화면 기록 권한을 묻습니다. 시스템 설정 › 개인정보 보호 및 보안 › 화면 및 시스템 오디오 녹화에서 ClassZoom을 켜 주세요.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("드로잉 단축키 전체 보기", action: onShowKeyboard)
                Spacer()
                Toggle("다음부터 보지 않기", isOn: $dontShow)
                Button("시작하기") { onClose(dontShow) }.keyboardShortcut(.defaultAction)
            }
            HStack {
                Text("만든 사람 \(Maker.name) · \(Maker.slogan)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("저작권 · 이용 약관") { Notice.show(Notice.terms()) }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(24)
        .frame(width: 600)
    }

    private func row(_ icon: String, _ title: String, _ keys: String, _ desc: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: bundleImage(icon)).resizable().interpolation(.high).frame(width: 34, height: 34)
                .padding(5).background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0xEF / 255, green: 0xF6 / 255, blue: 1)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .bold)).foregroundColor(ink)
                    Text(keys).font(.system(size: 12, weight: .bold)).foregroundColor(blue)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0xDB / 255, green: 0xEA / 255, blue: 0xFE / 255)))
                }
                Text(desc).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section(_ title: String, _ items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .bold)).foregroundColor(ink)
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                HStack(spacing: 10) {
                    Text(it.0).font(.system(size: 12, weight: .bold)).foregroundColor(blue).frame(width: 120, alignment: .leading)
                    Text(it.1).font(.callout)
                }
            }
        }
    }
}

@MainActor final class UsageGuideController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onShowKeyboard: () -> Void = {}

    static var showOnStart: Bool {
        get { UserDefaults.standard.object(forKey: "showGuideOnStart") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showGuideOnStart") }
    }

    func show() {
        window?.close()
        let view = UsageGuideView(dontShow: !UsageGuideController.showOnStart, onClose: { [weak self] dont in
            UsageGuideController.showOnStart = !dont
            self?.window?.close()
        }, onShowKeyboard: { [weak self] in self?.onShowKeyboard() })
        let hc = NSHostingController(rootView: view)
        // 화면보다 길면 아래("시작하기")가 잘려 누를 수 없었다 → 화면 높이에 맞추고 스크롤 (2026-11-25 제보)
        let vf = (NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main)?.visibleFrame
        let maxH = (vf?.height ?? 800) - 60 // 제목 막대·여유
        if hc.view.fittingSize.height > maxH {
            var v = view
            v.scrollHeight = maxH
            hc.rootView = v
        }
        let w = NSWindow(contentViewController: hc)
        w.title = "ClassZoom 사용 방법"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) { window = nil }
}
