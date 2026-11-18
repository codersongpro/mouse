import Carbon

// 단축키를 바꿀 때 받아들일 조합인지 정하는 규칙. 화면 없이 순수하게 판단하므로 자체 점검이 조합 20여 개를 넣어 본다.
// 거절하면 한국어 이유를 돌려준다 (설정 창이 그 글을 그대로 보인다).
//   · 드로잉 중에 쓰는 키(⌘Z, delete, 숫자, Z/X/C …)는 바꿀 수 없다
//   · 글자·숫자: ⌃가 있거나, ⌘와 ⌥가 함께 있어야 한다. ⌥·⌥⇧만은 글자가 입력되고 macOS 15.0~15.1이 거절(-9868)한다. ⌘+글자만은 앱 단축키와 겹친다
//   · F1~F19는 단독도 허용 (맥북은 fn과 함께). ⌘만 더한 F키는 거절
//   · 스페이스·탭·화살표 같은 그 밖의 키는 ⌃ 또는 ⌥가 있어야 한다
//   · macOS가 쓰는 조합(⌘Space, ⌃Space, ⌘Tab, ⌃방향키, ⌘⇧3/4/5)과 다른 기능이 쓰는 조합은 거절
enum HotkeyRules {
    enum Verdict: Equatable {
        case ok
        case rejected(String)
    }

    static func label(_ name: String) -> String {
        switch name {
        case "Spotlight": return "하이라이트 켜기/끄기"
        case "SpotlightAlt": return "하이라이트 (대체 키)"
        case "Draw": return "드로잉 켜기/끄기"
        case "DrawAlt": return "드로잉 (대체 키)"
        case "Zoom": return "라이브 줌 단계"
        case "ZoomAlt": return "라이브 줌 (대체 키)"
        case "Record": return "녹화 시작/정지"
        case "RecordAlt": return "녹화 (대체 키)"
        case "RecordPause": return "녹화 일시정지/계속"
        case "RecordArea": return "영역 지정 녹화"
        default: return name
        }
    }

    static func show(_ c: HotkeyNotation.Combo) -> String { HotkeyDisplay.symbols(HotkeyNotation.format(c) ?? "?") }

    static func check(_ c: HotkeyNotation.Combo, name: String, others: [String: HotkeyNotation.Combo]) -> Verdict {
        let ctrl = c.mods & controlKey != 0, opt = c.mods & optionKey != 0, cmd = c.mods & cmdKey != 0, shift = c.mods & shiftKey != 0
        let shown = show(c)
        guard let key = HotkeyNotation.keyName(c.code) else { return .rejected("지원하지 않는 키입니다.") }

        if KeyMap.drawKeys.contains(where: { $0.combo == c }) {
            return .rejected("\(shown)는 드로잉 중에 쓰는 키라서 바꿀 수 없습니다.")
        }
        if let other = others.first(where: { $0.value == c && $0.key != name }) {
            return .rejected("\(shown)는 이미 '\(label(other.key))'에 쓰고 있습니다. 두 기능이 같은 키를 쓸 수 없습니다.")
        }
        // macOS가 이미 쓰는 조합
        let only = c.mods
        if (key == "space" && (only == cmdKey || only == controlKey)) {
            return .rejected("\(shown)는 macOS가 입력 소스·Spotlight를 여는 데 쓰는 조합입니다.")
        }
        if key == "tab" && only == cmdKey { return .rejected("⌘Tab은 macOS가 앱을 바꾸는 데 쓰는 조합입니다.") }
        if ["left", "right", "up", "down"].contains(key) && only == controlKey {
            return .rejected("\(shown)는 macOS가 데스크톱·Mission Control을 바꾸는 데 쓰는 조합입니다.")
        }
        if ["3", "4", "5"].contains(key) && only == cmdKey | shiftKey {
            return .rejected("\(shown)는 macOS 화면 캡처 조합입니다.")
        }
        if key == "q" && only == controlKey | cmdKey { return .rejected("⌃⌘Q는 macOS가 화면을 잠그는 데 쓰는 조합입니다.") }
        if key == "f" && only == controlKey | cmdKey { return .rejected("⌃⌘F는 macOS가 전체 화면을 켜고 끄는 데 쓰는 조합입니다.") }
        if key == "space" && only == controlKey | cmdKey { return .rejected("⌃⌘Space는 macOS가 이모지 창을 여는 데 쓰는 조합입니다.") }

        if key.hasPrefix("f"), let n = Int(key.dropFirst()) {
            if n > 19 { return .rejected("F키는 F1~F19만 쓸 수 있습니다.") }
            if cmd && !ctrl && !opt { return .rejected("\(shown): ⌘만 더한 F키는 앱 단축키와 겹칠 수 있어 쓸 수 없습니다. ⌃나 ⌥를 함께 누르거나 F키 하나만 누르세요.") }
            return .ok
        }
        let isLetterOrDigit = key.count == 1
        if isLetterOrDigit {
            if ctrl || (cmd && opt) { return .ok }
            if cmd { return .rejected("\(shown): ⌘와 글자만으로는 앱 단축키(복사·붙여넣기 등)와 겹칩니다. ⌃를 함께 누르세요.") }
            if opt { return .rejected("\(shown): ⌥와 글자만으로는 특수 문자가 입력되고, macOS 15.0~15.1에서는 등록이 거절됩니다. ⌃를 함께 누르세요.") }
            _ = shift
            return .rejected("\(shown): 글자나 숫자는 ⌃, ⌥ 같은 보조 키와 함께 눌러야 합니다 (⌃⌥와 함께를 권합니다).")
        }
        if ctrl || opt { return .ok }
        return .rejected("\(shown): ⌃ 또는 ⌥를 함께 눌러야 합니다.")
    }

    // 받아들일 수는 있지만 다른 앱이나 macOS 기능과 겹치는 조합이면 안내 글을 돌려준다 (설정 창이 주황색으로 보인다).
    // ClassZoom이 키를 먼저 잡으므로, 겹치는 앱에서는 그 키의 원래 기능이 동작하지 않는다.
    static func caution(_ c: HotkeyNotation.Combo) -> String? {
        guard let key = HotkeyNotation.keyName(c.code) else { return nil }
        let shown = show(c), only = c.mods
        var use: String?
        if only == 0 {
            switch key {
            case "f1", "f2": use = "화면 밝기 조절(fn 없이 누를 때)"
            case "f3": use = "Mission Control"
            case "f5": use = "Keynote·PowerPoint 슬라이드 쇼"
            case "f11": use = "데스크톱 보기"
            case "f12": use = "브라우저 개발자 도구"
            default: break
            }
        } else if only == controlKey, key.count == 1 {
            switch key {
            case "a", "e": use = "글 입력 중 줄 처음·끝으로 이동"
            case "k": use = "글 입력 중 줄 끝까지 지우기"
            case "c": use = "터미널에서 실행 중단"
            case "d": use = "글 입력 중 한 글자 지우기·터미널 끝내기"
            default: break
            }
        } else if only == controlKey | cmdKey, key == "d" {
            use = "사전에서 단어 찾기"
        }
        guard let u = use else { return nil }
        return "\(shown)는 \(u)에도 쓰는 키입니다. ClassZoom 단축키로 정했기 때문에 그 기능은 동작하지 않을 수 있습니다. 불편하면 다른 키를 눌러 주세요."
    }
}
