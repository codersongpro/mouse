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
    global ICON_SPOT_DARK_PATH, ICON_DRAW_DARK_PATH, ICON_ZOOM_DARK_PATH, ICON_SETTINGS_PATH, ICON_REC_PATH
    if IsObject(usageGui)
        try usageGui.Destroy()

    g := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", "ClassZoom 사용 방법")
    usageGui := g
    g.BackColor := "FFFFFF"
    g.MarginX := 24, g.MarginY := 20

    g.SetFont("s17 bold c1E293B", "Malgun Gothic")
    g.AddText("x24 y18 w520", "ClassZoom 사용 방법")
    g.SetFont("s10 norm c475569")
    g.AddText("x24 y+4 w520", "화면 오른쪽 아래 위젯의 버튼이나 단축키로 켜고 끕니다.")

    ; ---- 위젯 버튼 네 개 ----
    rows := [
        [ICON_SPOT_DARK_PATH, "마우스 하이라이트", HotkeyText(hotkeyCombos["Spotlight"])
            , "커서 주위를 노란 원으로 강조합니다. 클릭하면 원이 오므라듭니다."],
        [ICON_DRAW_DARK_PATH, "드로잉", HotkeyText(hotkeyCombos["Draw"])
            , "드래그해서 그립니다. Caps Lock을 누르고 있는 동안에도 그려집니다. Esc는 지우고 끄기."],
        [ICON_ZOOM_DARK_PATH, "라이브 줌", HotkeyText(hotkeyCombos["Zoom"])
            , "누를 때마다 1단계 → 2단계 → 3단계 → 끄기. 영상도 그대로 움직입니다."],
        [ICON_REC_PATH, "화면 녹화", HotkeyText(hotkeyCombos["Record"])
            , "3·2·1 뒤 녹화를 시작하고 다시 누르면 MP4로 저장합니다. 마이크·컴퓨터 소리도 함께."],
        [ICON_SETTINGS_PATH, "설정", "위젯 버튼"
            , "색·굵기·확대 배율·단축키를 바꿉니다."]]
    y := 84
    for r in rows {
        ; 위젯과 같은 모양의 버튼 그림(연한 하늘색 칩 + 컬러 아이콘)으로 보여준다
        hb := RenderButtonBitmap(0xEFF6FF, 0xFFFFFF, 44, 14, r[1], 32, -1)
        g.AddPicture("x22 y" (y - 2) " w44 h44", "HBITMAP:" hb)
        g.SetFont("s11 bold c1E293B")
        g.AddText("x78 y" (y - 1) " w150", r[2])
        g.SetFont("s10 bold c1D4ED8")
        g.AddText("x232 y" (y - 1) " w120 h22 Center +0x200 BackgroundDBEAFE", r[3])
        g.SetFont("s9 norm c475569")
        g.AddText("x78 y" (y + 22) " w470", r[4])
        y += 56
    }

    ; ---- 확대 중 / 그리는 중 ----
    GuideSection(g, &y, "확대 중", [
        ["Ctrl + 마우스 휠", "확대 단계 올리기 / 내리기"],
        ["Esc", "확대 끄기"],
        ["가장자리로 이동", "확대 화면이 그쪽으로 움직입니다 (평소에는 화면 고정)"],
        [HotkeyText(hotkeyCombos["Draw"]) " (드로잉)", "확대된 화면 위에 그대로 그립니다"],
        ["화면 공유", "Zoom·Meet에서 '화면 전체'를 고르면 확대 화면이 그대로 보입니다"]])
    GuideSection(g, &y, "녹화", [
        [HotkeyText(hotkeyCombos["RecordPause"]), "일시정지 / 계속"],
        [HotkeyText(hotkeyCombos["RecordArea"]), "영역을 골라 그 부분만 녹화"],
        ["저장 위치", "동영상\ClassZoom 폴더 (설정 → 녹화에서 바꿈)"]])
    GuideSection(g, &y, "드로잉 중", [
        ["Caps Lock 누른 채 드래그", "F9 없이 바로 그리기 (떼면 그림은 남음)"],
        ["Ctrl / Shift + 드래그", "네모 / 원"],
        ["Z / X / C + 드래그", "직선 / 물결 / 화살표 (화살표 끝을 끌어 고침)"],
        ["V + 드래그", "움직이는 강조 화살표"],
        ["1 ~ 9,  0", "색 바꾸기,  기본 색"],
        ["오른쪽 버튼 드래그", "지우개"],
        ["Ctrl + Z  /  Delete", "되돌리기  /  전부 지우기"]])
    btnKeys := g.AddButton("x24 y" (y + 2) " w200 h30", "드로잉 단축키 전체 보기")
    btnKeys.OnEvent("Click", ShowShortcutGuide)
    y += 46

    ; ---- 아래: 다음부터 보지 않기 / 시작하기 ----
    g.AddText("x24 y" y " w520 h1 0x10")
    g.SetFont("s10 norm c1E293B")
    chk := g.AddCheckbox("x24 y" (y + 16) " w300 h24 " (showGuideOnStart ? "" : "Checked"), "다음부터 보지 않기")
    btnOk := g.AddButton("x424 y" (y + 12) " w120 h32 Default", "시작하기")
    ; 만든 사람 (설정 창 일반 탭과 같은 MAKER_* 값)
    g.SetFont("s9 norm c94A3B8")
    g.AddText("x24 y" (y + 54) " w520 Center", "만든 사람 " MAKER_NAME " · " MAKER_SLOGAN)
    close := (*) => GuideClose(g, chk)
    btnOk.OnEvent("Click", close)
    g.OnEvent("Close", close)
    g.OnEvent("Escape", close)
    g.Show("Center AutoSize")
}

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
}
