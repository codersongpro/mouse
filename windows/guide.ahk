; ##########################################################################
; ## 사용 방법 안내 창 (classzoom.ahk가 #Include로 불러 쓴다)              ##
; ##########################################################################
;
; - 프로그램을 처음 켜면 뜬다. "다음부터 보지 않기"를 체크하고 닫으면 다음 실행부터 뜨지 않는다
;   (settings.ini [Common] ShowGuide). 저장 단추를 누르지 않아도 닫는 순간 바로 기록한다.
; - 트레이 메뉴 "사용 방법"과 설정 창 "일반" 탭의 "사용 방법 보기"로 언제든 다시 연다.
; - 단축키는 지금 설정된 값을 읽어 보여주므로, 단축키를 바꿔도 안내와 어긋나지 않는다.

showGuideOnStart := true
usageGui := ""

GuideLoadSettings() {
    global showGuideOnStart
    showGuideOnStart := ReadIniNum("Common", "ShowGuide", 0, 1, 1) = 1
}

GuideWriteSettings() {
    global SETTINGS_PATH, showGuideOnStart
    IniWrite(showGuideOnStart ? 1 : 0, SETTINGS_PATH, "Common", "ShowGuide")
}

; "^!z" → "Ctrl + Alt + Z", "F7" → "F7"
HotkeyText(combo) {
    if (combo = "")
        return "없음"
    mods := Map("^", "Ctrl + ", "!", "Alt + ", "+", "Shift + ", "#", "Win + ")
    t := "", i := 1
    while (i <= StrLen(combo) && mods.Has(SubStr(combo, i, 1))) {
        t .= mods[SubStr(combo, i, 1)]
        i++
    }
    return t StrUpper(SubStr(combo, i))
}

ShowUsageGuide(*) {
    global usageGui, showGuideOnStart, hotkeyCombos, MAKER_NAME, MAKER_SLOGAN
    global ICON_SPOT_DARK_PATH, ICON_DRAW_DARK_PATH, ICON_ZOOM_DARK_PATH, ICON_SETTINGS_PATH, ICON_REC_PATH, ICON_CAP_PATH
    if IsObject(usageGui)
        try usageGui.Destroy()

    ; 창 = [내용] + [아래 줄(다음부터 보지 않기·시작하기·만든 사람)].
    ; 내용이 화면보다 길면(노트북·높은 배율) 아래가 잘려 "시작하기"를 누를 수 없었다(2026-11-25 제보).
    ; 그래서 창 높이를 화면에 맞추고, 넘치면 내용 칸들만 위로 옮겨 스크롤한다(휠·스크롤 막대). 아래 줄은 늘 보인다.
    ; 창 안에 창을 넣는 방식(+Parent)은 내용이 아예 그려지지 않는 PC가 있어(같은 날 제보) 한 창 안에서 칸을 옮긴다.
    g := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", "ClassZoom 사용 방법")
    usageGui := g
    g.BackColor := "FFFFFF"
    g.MarginX := 24, g.MarginY := 20
    b := g ; 내용도 같은 창에 넣는다 (아래에서 내용 칸 목록을 모아 스크롤한다)

    b.SetFont("s17 bold c1E293B", "Malgun Gothic")
    b.AddText("x24 y18 w520", "ClassZoom 사용 방법")
    b.SetFont("s10 norm c475569")
    b.AddText("x24 y+4 w520", "화면 오른쪽 아래 위젯의 버튼이나 단축키로 켜고 끕니다.")

    ; ---- 위젯 버튼 (F6 → F10 순서) ----
    rows := [
        [ICON_CAP_PATH, "화면 캡처", HotkeyText(hotkeyCombos["Capture"])
            , "창을 클릭하거나 구역을 끌어서 찍고 편집 창에서 펜·도형·글자·모자이크를 넣습니다. 찍으면 바로 클립보드에 복사됩니다.`n"
            . "전체 화면 " HotkeyText(hotkeyCombos["CaptureScreen"]) " · 구역 지정 " HotkeyText(hotkeyCombos["CaptureArea"])
            . " · 저장 위치 사진\ClassZoom"],
        [ICON_ZOOM_DARK_PATH, "라이브 줌", HotkeyText(hotkeyCombos["Zoom"])
            , "누를 때마다 1단계 → 2단계 → 3단계 → 끄기. 영상도 그대로 움직입니다."],
        [ICON_SPOT_DARK_PATH, "마우스 하이라이트", HotkeyText(hotkeyCombos["Spotlight"])
            , "커서 주위를 원하는 색의 원으로 강조합니다(색은 설정에서 고름). 클릭하면 원이 오므라듭니다."],
        [ICON_DRAW_DARK_PATH, "드로잉", HotkeyText(hotkeyCombos["Draw"])
            , "드래그해서 그립니다. Caps Lock을 누르고 있는 동안에도 그려집니다. Esc는 지우고 끄기."],
        [ICON_REC_PATH, "화면 녹화", HotkeyText(hotkeyCombos["Record"])
            , "3·2·1 뒤 녹화를 시작하고 다시 누르면 MP4로 저장합니다. 마이크·컴퓨터 소리도 함께."],
        [ICON_SETTINGS_PATH, "설정", "위젯 버튼"
            , "색·굵기·확대 배율을 바꿉니다. 단축키도 원하는 키로 바꿀 수 있습니다(단축키 탭)."]]
    y := 84
    for r in rows {
        ; 위젯과 같은 모양의 버튼 그림(연한 하늘색 칩 + 컬러 아이콘)으로 보여준다
        ; 디스플레이 배율만큼 큰 그림으로 그려야 흐려지지 않는다
        d := A_ScreenDPI / 96
        hb := RenderButtonBitmap(0xEFF6FF, 0xFFFFFF, Round(44 * d), Round(14 * d), r[1], Round(32 * d), -1)
        b.AddPicture("x22 y" (y - 2) " w44 h44", "HBITMAP:" hb)
        b.SetFont("s11 bold c1E293B")
        b.AddText("x78 y" (y - 1) " w150", r[2])
        b.SetFont("s10 bold c1D4ED8")
        b.AddText("x232 y" (y - 1) " w120 h22 Center +0x200 BackgroundDBEAFE", r[3])
        b.SetFont("s9 norm c475569")
        b.AddText("x78 y" (y + 22) " w470", r[4])
        y += InStr(r[4], "`n") ? 72 : 56
    }

    ; ---- 확대 중 / 그리는 중 ----
    GuideSection(b, &y, "확대 중", [
        ["Ctrl + 마우스 휠", "확대 단계 올리기 / 내리기"],
        ["Esc", "확대 끄기"],
        ["가장자리로 이동", "확대 화면이 그쪽으로 움직입니다 (평소에는 화면 고정)"],
        [HotkeyText(hotkeyCombos["Draw"]) " (드로잉)", "확대된 화면 위에 그대로 그립니다"],
        ["화면 공유", "Zoom·Meet에서 '화면 전체'를 고르면 확대 화면이 그대로 보입니다"]])
    GuideSection(b, &y, "녹화", [
        [HotkeyText(hotkeyCombos["RecordPause"]), "일시정지 / 계속"],
        [HotkeyText(hotkeyCombos["RecordArea"]), "영역을 골라 그 부분만 녹화"],
        ["저장 위치", "동영상\ClassZoom 폴더 (설정 → 녹화에서 바꿈)"]])
    GuideSection(b, &y, "드로잉 중", [
        ["Caps Lock 누른 채 드래그", "드로잉 키 없이 바로 그리기 (떼면 그림은 남음)"],
        ["Ctrl / Shift + 드래그", "네모 / 원"],
        ["Z / X / C + 드래그", "직선 / 물결 / 화살표 (화살표 끝을 끌어 고침)"],
        ["V + 드래그", "움직이는 강조 화살표"],
        ["1 ~ 9,  0", "색 바꾸기,  기본 색"],
        ["오른쪽 버튼 드래그", "지우개"],
        ["Ctrl + Z  /  Delete", "되돌리기  /  전부 지우기"]])
    btnKeys := b.AddButton("x24 y" (y + 2) " w200 h30", "드로잉 단축키 전체 보기")
    btnKeys.OnEvent("Click", ShowShortcutGuide)
    y += 46
    contentH := y ; 내용 높이 (창 단위)
    ; 지금까지 만든 칸이 모두 "내용"이다 (아래 줄은 이 뒤에 만든다)
    items := []
    for hwnd, c in g {
        c.GetPos(&cx, &cy, &cw, &ch)
        items.Push({c: c, y: cy, h: ch})
    }

    ; ---- 화면에 들어가는 만큼만 보이게 (넘치면 스크롤) ----
    d := A_ScreenDPI / 96
    MouseGetPos(&mx, &my)
    if !GetMonitorAt(mx, my, &ml, &mt, &mr, &mb, &wl, &wt, &wr, &wb)
        wt := 0, wb := A_ScreenHeight
    avail := ((wb - wt) / d) - 80 - 48 - 16 ; 아래 줄 80 · 제목 막대 48 · 여유 16 (창 단위)
    vpH := Min(contentH, Floor(avail))
    scroll := contentH > vpH
    y := vpH ; 아래 줄은 내용 칸 바로 밑

    ; ---- 아래: 다음부터 보지 않기 / 시작하기 ----
    g.AddText("x24 y" y " w520 h1 0x10")
    g.SetFont("s10 norm c1E293B")
    chk := g.AddCheckbox("x24 y" (y + 16) " w300 h24 " (showGuideOnStart ? "" : "Checked"), "다음부터 보지 않기")
    btnOk := g.AddButton("x424 y" (y + 12) " w120 h32 Default", "시작하기")
    ; 만든 사람 (설정 창 일반 탭과 같은 MAKER_* 값)
    g.SetFont("s9 norm c94A3B8")
    g.AddText("x24 y" (y + 54) " w420", "만든 사람 " MAKER_NAME " · " MAKER_SLOGAN)
    g.SetFont("s9 norm c0066CC underline")
    lnkTerms := g.AddText("x444 y" (y + 54) " w100 Right", "저작권 · 이용 약관")
    lnkTerms.OnEvent("Click", (*) => ShowTermsNotice(g.Hwnd))
    close := (*) => GuideClose(g, chk)
    btnOk.OnEvent("Click", close)
    g.OnEvent("Close", close)
    g.OnEvent("Escape", close)
    if scroll
        g.Opt("+0x200000") ; WS_VSCROLL
    g.Show("Center w" (570 + (scroll ? Round(DllCall("GetSystemMetrics", "int", 2) / d) : 0)) " h" Round(y + 80))
    GuideScrollSetup(scroll ? g.Hwnd : 0, items, contentH, vpH)
}

; ---- 내용 칸 스크롤 (휠 · 스크롤 막대) ----
; 내용 칸들을 위로 옮기고, 내용 영역(0 ~ page)을 벗어나는 칸은 숨긴다 (아래 줄을 덮지 않게). 단위는 창 단위.
guideScroll := {hwnd: 0, items: [], max: 0, page: 0, pos: 0}
GuideScrollSetup(hwnd, items, total, page) {
    global guideScroll
    guideScroll := {hwnd: hwnd, items: items, max: total, page: page, pos: 0}
    if !hwnd
        return
    si := Buffer(28, 0)
    NumPut("UInt", 28, "UInt", 0x7, "Int", 0, "Int", Round(total) - 1, "UInt", Round(page), "Int", 0, si) ; SIF_RANGE|PAGE|POS
    DllCall("SetScrollInfo", "ptr", hwnd, "int", 1, "ptr", si, "int", true)
    GuideScrollTo(0)
}

GuideScrollTo(pos) {
    global guideScroll
    pos := Max(0, Min(guideScroll.max - guideScroll.page, Round(pos)))
    guideScroll.pos := pos
    DllCall("SendMessage", "ptr", guideScroll.hwnd, "uint", 0x000B, "ptr", 0, "ptr", 0) ; WM_SETREDRAW 끔 (옮기는 동안 깜빡이지 않게)
    for it in guideScroll.items {
        ny := it.y - pos
        try {
            it.c.Move(, ny)
            it.c.Visible := (ny >= 0 && ny + it.h <= guideScroll.page)
        }
    }
    DllCall("SendMessage", "ptr", guideScroll.hwnd, "uint", 0x000B, "ptr", 1, "ptr", 0)
    DllCall("RedrawWindow", "ptr", guideScroll.hwnd, "ptr", 0, "ptr", 0, "uint", 0x1 | 0x4 | 0x80 | 0x100) ; INVALIDATE|ERASE|ALLCHILDREN|UPDATENOW
    si := Buffer(28, 0)
    NumPut("UInt", 28, "UInt", 0x4, si) ; SIF_POS
    NumPut("Int", pos, si, 20)
    DllCall("SetScrollInfo", "ptr", guideScroll.hwnd, "int", 1, "ptr", si, "int", true)
}

GuideOnVScroll(wParam, lParam, msg, hwnd) {
    global guideScroll
    if (!guideScroll.hwnd || hwnd != guideScroll.hwnd)
        return
    line := 40, p := guideScroll.pos
    switch wParam & 0xFFFF {
    case 0: p -= line                      ; SB_LINEUP
    case 1: p += line                      ; SB_LINEDOWN
    case 2: p -= guideScroll.page          ; SB_PAGEUP
    case 3: p += guideScroll.page          ; SB_PAGEDOWN
    case 4, 5: p := (wParam >> 16) & 0xFFFF ; SB_THUMBPOSITION / SB_THUMBTRACK
    case 6: p := 0                         ; SB_TOP
    case 7: p := guideScroll.max           ; SB_BOTTOM
    default: return 0
    }
    GuideScrollTo(p)
    return 0
}
OnMessage(0x0115, GuideOnVScroll) ; WM_VSCROLL

GuideOnWheel(wParam, lParam, msg, hwnd) {
    global guideScroll, usageGui
    if (!guideScroll.hwnd || !IsObject(usageGui))
        return
    if (DllCall("GetAncestor", "ptr", hwnd, "uint", 2, "ptr") != usageGui.Hwnd)
        return
    delta := (wParam >> 16) & 0xFFFF
    if (delta > 0x7FFF)
        delta -= 0x10000
    GuideScrollTo(guideScroll.pos - delta / 120 * 60)
    return 0
}
OnMessage(0x020A, GuideOnWheel) ; WM_MOUSEWHEEL

; 제목 한 줄 + "키 | 설명" 줄들
GuideSection(g, &y, title, items) {
    y += 6
    g.SetFont("s11 bold c1E293B")
    g.AddText("x24 y" y " w520", title)
    y += 26
    for it in items {
        g.SetFont("s10 bold c1D4ED8")
        g.AddText("x36 y" y " w180", it[1])
        g.SetFont("s10 norm c334155")
        g.AddText("x220 y" y " w330", it[2])
        y += 23
    }
    y += 4
}

GuideClose(g, chk) {
    global usageGui, showGuideOnStart, SETTINGS_PATH
    showGuideOnStart := !chk.Value
    ; 저장 단추와 상관없이 바로 기록한다. 쓰기가 막힌 폴더면 조용히 넘어간다(다음에도 뜰 뿐이다).
    try IniWrite(showGuideOnStart ? 1 : 0, SETTINGS_PATH, "Common", "ShowGuide")
    try g.Destroy()
    usageGui := ""
    GuideScrollSetup(0, [], 0, 0)
}
