import AppKit
import SwiftUI

// 안내 창: 화면을 막지 않는 작은 창(모달이 아님). 드로잉·단축키는 창이 떠 있어도 그대로 동작한다.
// 오류 안내는 원인 → 할 일 → 안심 문구 순서로 쓰고, 경로와 오류 글은 맨 아래 작은 글씨로 둔다.
struct NoticeContent {
    var title: String
    var body: [String]
    var detail: String? = nil
    var buttons: [(title: String, action: () -> Void)] = []
}

private struct NoticeView: View {
    let n: NoticeContent
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(n.title).font(.headline)
            ForEach(Array(n.body.enumerated()), id: \.offset) { _, p in
                Text(p).fixedSize(horizontal: false, vertical: true)
            }
            if let d = n.detail {
                Text(d).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                ForEach(Array(n.buttons.enumerated()), id: \.offset) { _, b in
                    Button(b.title) { b.action(); close() }
                }
                Button("확인", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

enum Notice {
    private static var open: [NSWindow] = []

    static func show(_ n: NoticeContent) {
        var win: NSWindow?
        let host = NSHostingView(rootView: NoticeView(n: n, close: { win?.close() }))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win = w
        w.title = "ClassZoom"
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.setContentSize(host.fittingSize)
        w.center()
        if let last = open.last { w.setFrameOrigin(NSPoint(x: last.frame.minX + 24, y: last.frame.minY - 24)) }
        open.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            open.removeAll { $0 === w }
        }
        NSApp.activate(ignoringOtherApps: true) // 안내는 사용자가 방금 한 일(실행·저장·메뉴)의 답이므로 앞으로 나온다
        w.makeKeyAndOrderFront(nil)
    }

    static func tilde(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

    // ---------- 안내 문구 ----------
    static func saveFailed(_ e: Settings.SaveError) -> NoticeContent {
        let ns = e.underlying as NSError?
        var cause = "저장할 폴더나 파일에 쓸 수 없었습니다."
        switch ns?.code {
        case NSFileWriteOutOfSpaceError: cause = "저장 공간(디스크)이 부족해서 쓸 수 없었습니다."
        case NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError:
            cause = "이 폴더에 쓸 권한이 없거나 읽기 전용이라 쓸 수 없었습니다."
        default: break
        }
        if case .blocked = e {
            cause = "설정 파일이 읽을 수 없는 상태인데 복사본을 만들지 못해서, 원래 파일을 지키려고 저장하지 않았습니다."
        }
        var detail = "설정 파일: \(tilde(Settings.path))"
        if let ns { detail += "\n오류: \(ns.localizedDescription) (\(ns.domain) \(ns.code))" }
        return NoticeContent(
            title: "설정을 저장하지 못했습니다",
            body: [cause,
                   "저장 공간을 확인한 뒤 [저장]을 다시 눌러 보세요. 계속 안 되면 메뉴 막대 아이콘 › 도움말 › 진단 정보 복사로 복사해서 보내 주세요.",
                   "지금 화면에 보이는 설정은 앱을 끌 때까지 그대로 쓰입니다. 이전에 저장해 둔 설정 파일은 바뀌지 않았습니다."],
            detail: DiagReport.sanitize(detail),
            buttons: [("설정 폴더 열기", { revealSettingsFolder() })])
    }

    // 드로잉 키를 하나라도 못 잡으면 드로잉을 켜지 않는다 (일부만 잡힌 채 그리면 어떤 키는 먹고 어떤 키는 발표 앱으로 간다)
    static func drawKeysFailed(_ r: HotKeyGroupResult) -> NoticeContent {
        let f = r.failed.first
        return NoticeContent(
            title: "드로잉을 켜지 못했습니다",
            body: ["드로잉에 쓰는 키를 잡지 못했습니다. 다른 앱이 같은 키를 쓰고 있을 수 있습니다.",
                   "다른 앱(단축키를 바꿔 주는 앱, 화면 캡처·번역 앱 등)을 잠시 끄고 다시 F9를 눌러 보세요. 그리던 그림과 설정은 그대로입니다."],
            detail: f.map { "\($0.name): \(describeHotKeyStatus($0.status))" })
    }

    static func unreadable(reason: String, backup: URL?) -> NoticeContent {
        let reassure = backup != nil
            ? "원래 파일은 지우지 않았고, 복사본(\(backup!.lastPathComponent))을 같은 폴더에 남겼습니다. 설정 창에서 [저장]을 누르기 전까지는 원래 파일을 건드리지 않습니다."
            : "복사본을 만들지 못해서, 원래 파일은 그대로 두고 [저장]도 막아 두었습니다."
        return NoticeContent(
            title: "설정 파일을 읽지 못했습니다",
            body: ["설정 파일(settings.ini)이 손상됐거나 알 수 없는 형식이라 읽을 수 없었습니다.",
                   "이번에는 기본 설정으로 시작했습니다. 필요하면 설정 창에서 다시 맞추세요. 파일을 살펴보려면 아래 버튼으로 폴더를 열 수 있습니다.",
                   reassure],
            detail: DiagReport.sanitize("설정 파일: \(tilde(Settings.path))\n이유: \(reason)"),
            buttons: [("설정 폴더 열기", { revealSettingsFolder() })])
    }

    static func translocated() -> NoticeContent {
        NoticeContent(
            title: "응용 프로그램 폴더로 옮겨 주세요",
            body: ["지금은 다운로드 폴더 같은 곳에서 바로 실행 중입니다. 이 상태에서는 맥이 앱을 임시 자리에서 실행해서, 로그인 시 실행이나 업데이트가 제대로 되지 않을 수 있습니다.",
                   "압축을 풀면 나오는 폴더째가 아니라, 폴더 안의 ClassZoom 앱 아이콘만 Finder의 '응용 프로그램' 폴더로 끌어다 놓은 뒤 다시 열어 주세요. (다운로드 폴더에 남은 옛 사본은 지워야 Spotlight가 그것을 열지 않습니다.)",
                   "옮기지 않아도 단축키와 드로잉은 지금 그대로 쓸 수 있습니다."],
            buttons: [("Finder에서 보기", { revealOriginalApp() })])
    }

    static func firstRun() -> NoticeContent {
        NoticeContent(
            title: "ClassZoom을 시작했습니다",
            body: ["• 위젯은 화면 오른쪽 아래에 있습니다. 잡고 끌어서 옮길 수 있습니다.",
                   "• 화면 맨 위 메뉴 막대에 아이콘이 있습니다. 설정, 도움말, 종료는 여기서 합니다.",
                   "• 강조는 F8, 드로잉은 F9입니다. 맥북에서는 fn 키와 함께(fn+F8, fn+F9) 누르세요.",
                   "• fn 없이 쓰려면 ⌃⌥1(강조), ⌃⌥2(드로잉)을 누르세요.",
                   "이 안내는 메뉴 막대 아이콘 › 도움말 › 처음 안내 다시 보기에서 다시 볼 수 있습니다."])
    }

    // ---------- 저작권 및 이용 약관 (랜딩페이지 /terms, Windows 판과 같은 내용) ----------
    static let termsURL = URL(string: "https://songpro.app/terms")!
    static func terms() -> NoticeContent {
        NoticeContent(
            title: "저작권 및 이용 약관",
            body: ["ClassZoom © 2026 \(Maker.name) · 시행일 2026년 11월 25일",
                   "저작권: ClassZoom(Windows 판·macOS 판·홈페이지)의 저작권은 만든 사람 \(Maker.name)에게 있습니다.",
                   "라이선스: MIT 라이선스로 배포하는 무료 프로그램입니다. 개인·학교·기관 누구나 비용 없이 사용·복사·수정·배포합니다. 다시 배포하거나 고친 판을 배포할 때는 저작권 표시와 LICENSE 파일을 함께 넣어야 합니다.",
                   "이용 조건: 쓰는 목적에 제한이 없습니다. 캡처·녹화로 만든 그림과 영상의 권리와 책임은 만든 사용자에게 있습니다. 다른 사람의 저작물이나 학생 개인정보가 담긴 화면을 공유할 때는 관련 법과 학교·기관 규정을 지켜 주세요(편집 창의 모자이크로 가리기를 권합니다).",
                   "책임의 한계: 있는 그대로 제공되며 어떤 보증도 하지 않습니다. 쓰다 생긴 손해에 대해 만든 사람은 책임지지 않습니다.",
                   "개인정보: 수집하거나 외부로 보내지 않습니다. 인터넷은 설정 창을 열 때 새 버전을 확인하는 데에만 씁니다(버전 파일 1개 읽기). 캡처·녹화·설정은 이 맥에만 저장됩니다."],
            buttons: [("웹에서 보기", { NSWorkspace.shared.open(Notice.termsURL) })])
    }

    // ---------- 화면 기록 권한 (라이브 줌·화면 녹화) ----------
    static func screenRecordingNeeded(feature: String) -> NoticeContent {
        NoticeContent(
            title: "\(feature)에는 화면 기록 권한이 필요합니다",
            body: ["시스템 설정 › 개인정보 보호 및 보안 › 화면 및 시스템 오디오 녹화에서 ClassZoom을 켜 주세요.",
                   "켠 뒤에는 ClassZoom을 한 번 종료했다가 다시 열어야 적용됩니다.",
                   "서명하지 않은 앱이라 새 버전으로 바꾼 뒤에는 이 권한을 다시 켜야 할 수 있습니다."],
            buttons: [("시스템 설정 열기", {
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
            })])
    }

    // ---------- 손쉬운 사용 권한 (스크롤 캡처가 휠을 대신 굴린다) ----------
    static func accessibilityNeeded(feature: String) -> NoticeContent {
        NoticeContent(
            title: "\(feature)에는 손쉬운 사용 권한이 필요합니다",
            body: ["ClassZoom이 화면을 대신 스크롤하려면 시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용에서 ClassZoom을 켜 주세요.",
                   "켠 뒤 다시 시도해 주세요. 바로 되지 않으면 ClassZoom을 한 번 종료했다가 다시 여세요.",
                   "서명하지 않은 앱이라 새 버전으로 바꾼 뒤에는 이 권한을 다시 켜야 할 수 있습니다."],
            buttons: [("시스템 설정 열기", {
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) }
            })])
    }

    static func microphoneDenied() -> NoticeContent {
        NoticeContent(
            title: "마이크를 쓸 수 없어 목소리 없이 녹화합니다",
            body: ["시스템 설정 › 개인정보 보호 및 보안 › 마이크에서 ClassZoom을 켜면 다음 녹화부터 목소리가 함께 녹음됩니다."],
            buttons: [("시스템 설정 열기", {
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) }
            })])
    }

    // ---------- 로그인 시 실행·초기화 ----------
    static func loginNeedsInstall() -> NoticeContent {
        NoticeContent(
            title: "응용 프로그램 폴더로 옮긴 뒤에 켤 수 있습니다",
            body: ["지금은 응용 프로그램 폴더가 아닌 곳(다운로드 폴더 등)에서 실행 중이라 로그인 시 실행을 켜지 않았습니다. 이 상태로 켜면 앱을 옮기거나 지웠을 때 로그인 항목이 엉킵니다.",
                   "Finder의 '응용 프로그램' 폴더로 ClassZoom 앱 아이콘만 끌어다 놓고 그 앱을 다시 연 뒤에 켜 주세요."],
            buttons: [("Finder에서 보기", { revealOriginalApp() })])
    }

    static func loginNeedsApproval() -> NoticeContent {
        NoticeContent(
            title: "시스템 설정에서 한 번 허용해 주세요",
            body: ["로그인 시 실행을 등록했지만, macOS가 사용자의 허용을 기다리고 있습니다.",
                   "시스템 설정 › 일반 › 로그인 항목에서 ClassZoom을 켜 주세요."],
            buttons: [("로그인 항목 열기", { LoginItem.openSystemSettings() })])
    }

    static func loginFailed(_ error: Error) -> NoticeContent {
        let ns = error as NSError
        return NoticeContent(
            title: "로그인 시 실행을 바꾸지 못했습니다",
            body: ["macOS가 로그인 항목 변경을 받아들이지 않았습니다. 시스템 설정 › 일반 › 로그인 항목에서 직접 켜거나 끌 수 있습니다.",
                   "다른 설정은 그대로입니다."],
            detail: DiagReport.sanitize("오류: \(ns.localizedDescription) (\(ns.domain) \(ns.code))"),
            buttons: [("로그인 항목 열기", { LoginItem.openSystemSettings() })])
    }

    static func resetFailed(_ error: Error) -> NoticeContent {
        let ns = error as NSError
        return NoticeContent(
            title: "설정을 초기화하지 못했습니다",
            body: ["설정 파일을 지울 수 없었습니다. 폴더가 읽기 전용이거나 다른 프로그램이 파일을 쓰고 있을 수 있습니다.",
                   "아무것도 바뀌지 않았습니다. 설정 폴더를 열어 settings.ini를 직접 지운 뒤 앱을 다시 켜도 같은 효과입니다."],
            detail: DiagReport.sanitize("설정 파일: \(tilde(Settings.path))\n오류: \(ns.localizedDescription) (\(ns.domain) \(ns.code))"),
            buttons: [("설정 폴더 열기", { revealSettingsFolder() })])
    }

    // ---------- 동작 ----------
    static func revealSettingsFolder() {
        try? FileManager.default.createDirectory(at: Settings.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Settings.folder)
    }

    // 임시 자리(AppTranslocation)에서 실행 중이면 원래 앱이 있는 폴더를 보여 준다. 못 찾으면 다운로드 폴더.
    static func revealOriginalApp() {
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        if let h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
           let sym = dlsym(h, "SecTranslocateCreateOriginalPathForURL") {
            let fn = unsafeBitCast(sym, to: Fn.self)
            if let orig = fn(Bundle.main.bundleURL as CFURL, nil)?.takeRetainedValue() {
                NSWorkspace.shared.activateFileViewerSelecting([orig as URL])
                return
            }
        }
        if let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first { NSWorkspace.shared.open(dl) }
    }

    static func isTranslocated(_ path: String = Bundle.main.bundlePath) -> Bool { path.contains("/AppTranslocation/") }
}
