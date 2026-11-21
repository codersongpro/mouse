; ##########################################################################
; ## 라이브 확대 (classzoom.ahk가 #Include로 불러 쓴다)                   ##
; ##########################################################################
;
; 무엇을 하나
;   커서가 있는 모니터를 **실시간으로** 확대해 보여준다(정지 화면 캡처가 아니다 — 영상도 움직인다).
;   3단계: 단축키(기본 F7)나 위젯의 돋보기 버튼을 누를 때마다 1단계 → 2단계 → 3단계 → 끄기.
;   확대 중 Ctrl+휠 = 단계 오르내리기, Esc = 끄기. 단계별 배율은 설정 창 "확대" 탭에서 정한다.
;
; 왜 이렇게 만들었나 — ZoomIt의 "커서 두 개" 문제
;   ZoomIt·Windows 돋보기는 화면 전체를 시스템 단계에서 키운다. 그러면 녹화·화면 공유 프로그램이
;   ① 확대된 화면 속 커서 그림과 ② 자기가 실제 좌표에 따로 그리는 커서를 **둘 다** 찍어서
;   커서가 두 개로 보인다.
;   여기서는 화면 맨 위에 **보통 창 하나(zoomHost)**를 띄우고, 그 안의 Magnification API 확대
;   컨트롤이 아래 화면을 키워 그린다.
;     - 일반 창이라 Zoom·Google Meet 화면 공유와 녹화에 **그대로 찍힌다.**
;     - 확대 컨트롤은 커서를 그리지 않는다(MS_SHOWMAGNIFIEDCURSOR를 안 줌).
;     - **화면은 고정, 커서만 움직인다.** 확대 중에는 진짜 커서를 투명하게 숨기고(SetSystemCursor),
;       확대 화면 위에 우리가 그린 화살표 커서(zoomCursorGui) 하나만 보인다. 그래서 녹화·공유에도
;       커서가 하나만 찍힌다.
;     - 진짜 커서 자리(c)는 늘 "확대 화면에서 그 커서가 가리키는 내용"의 실제 자리다. 그래서 클릭은
;       보이는 곳에 정확히 떨어지고, 판서도 좌표를 바꿀 필요 없이 c에 그으면 된다.
;     - 화면은 커서가 가장자리 쪽(ZOOM_EDGE_FRAC)으로 갈 때만 그쪽으로 이동한다. 예전처럼 커서를
;       움직일 때마다 화면 전체가 따라 미끄러지지 않으므로 흔들려 보이지 않는다.
;     - 화면을 읽는 방식(Windows.Graphics.Capture)이 아니라서 Windows 11의 노란 캡처 테두리도
;       생기지 않는다.
;
; 드로잉과 함께 쓰기
;   그린 내용은 원본 화면 좌표에 남는다. 확대 중 그리다가 가장자리로 가서 화면이 움직여도 선은
;   내용에 붙어 있고, 확대를 끄면 원래 크기로 그 자리에 있다. 터치·펜은 손가락이 닿은 화면 자리를
;   원본 좌표로 바꿔 긋는다(ZoomMapPt).
;
; 창 순서(위 → 아래)
;   그린 커서·강조 원·클릭 링·단계 숫자·단계 표시  ← 확대하지 않고, 확대 화면 속 커서 자리에 그린다
;   zoomHost (확대 화면, 클릭 통과)
;   위젯·판서·레이저·칠판·드로잉 커서 원·안내 창 ← 확대되어 보인다 (보이는 자리 그대로 누를 수 있다)
;   일반 프로그램들

; ---------------- 조절용 숫자 ----------------
ZOOM_MIN_PCT := 125          ; 가장 작은 배율(%)
ZOOM_MAX_PCT := 800          ; 가장 큰 배율(%)
ZOOM_STEP_DEFAULTS := [150, 200, 300] ; 1·2·3단계 기본 배율(%)
ZOOM_BADGE_MS := 900         ; 단계가 바뀔 때 커서 옆에 뜨는 "2단계 · 200%" 표시 시간
ZOOM_TICK_MS := 15           ; 커서·배율을 확인하는 간격 (약 60fps). 확대 중에만 돈다
ZOOM_REDRAW_EVERY := 2       ; 화면이 그대로일 때 확대 화면 내용(영상 등)은 이 틱마다 한 번 다시 그린다 (약 30fps, CPU 절반)
ZOOM_RELEASE_MS := 20000     ; 확대를 끄고 이만큼 지나면 확대용 창·자원을 돌려준다 (메모리 절약, 다시 켜면 새로 만든다)
ZOOM_ANIM_MS := 220          ; 부드럽게: 단계가 바뀔 때 확대·축소에 걸리는 시간 (점점 느려지며 멈춤)
ZOOM_EDGE_FRAC := 0.15       ; 커서가 확대 화면 가장자리에서 이 비율 안으로 들어오면 그쪽으로 화면을 옮긴다

; ---------------- 상태 ----------------
zoomOn := false       ; 사용자가 확대를 켜 둔 상태인가
zoomVisible := false  ; 확대 창이 실제로 떠 있는가 (끄는 애니메이션 동안에도 참)
zoomClosing := false  ; 끄는 애니메이션 중인가
zoomReady := false    ; Magnification API 준비가 끝났는가
zoomFailed := false   ; 준비에 실패했는가 (다시 시도하지 않는다)
zoomHost := ""        ; 확대 화면을 담는 창
zoomMag := 0          ; 확대 컨트롤(자식 창) 핸들
zoomLevel := 1.0      ; 지금 보이는 배율
zoomTarget := 2.0     ; 가려는 배율
zoomOX := 0.0, zoomOY := 0.0               ; 원본 영역의 왼쪽 위 (화면 좌표, 실수)
zoomML := 0, zoomMT := 0, zoomMW := 0, zoomMH := 0  ; 확대 중인 모니터
zoomSrcL := 0, zoomSrcT := 0, zoomSrcW := 1, zoomSrcH := 1 ; 마지막으로 보여준 원본 영역
zoomFilterKey := ""   ; 확대에서 뺀 창 목록 (바뀌었을 때만 다시 알린다)
zoomLastKey := ""     ; 마지막으로 확대 컨트롤에 넘긴 영역 (바뀌었을 때만 다시 넘긴다)
zoomAnimFrom := 1.0, zoomAnimTo := 1.0, zoomAnimT0 := 0 ; 배율 애니메이션
zoomStep := 0         ; 지금 단계 (0 = 꺼짐, 1~3)
zoomBadge := ""       ; 단계 표시 창
zoomBadgeText := ""
zoomBadgeUntil := 0   ; 단계 표시를 감출 시각 (ZoomTick도 확인해서 확실히 감춘다)
zoomCursorGui := "", zoomCursorCanvas := "", zoomCursorPad := 0 ; 확대 중 그리는 화살표 커서

; settings.ini [Zoom] — LoadSettings()/WriteSettings()가 부른다.
; 이 파일은 LoadSettings()보다 위에서 #Include되므로 위 숫자들이 이미 정해져 있다.
zoomSteps := ZOOM_STEP_DEFAULTS.Clone() ; 1·2·3단계 배율(%) — [Zoom] Level1·Level2·Level3
zoomSmooth := true
ZoomLoadSettings() {
    global zoomSteps, zoomSmooth, ZOOM_MIN_PCT, ZOOM_MAX_PCT, ZOOM_STEP_DEFAULTS
    loop 3
        zoomSteps[A_Index] := ReadIniNum("Zoom", "Level" A_Index, ZOOM_MIN_PCT, ZOOM_MAX_PCT, ZOOM_STEP_DEFAULTS[A_Index])
    zoomSmooth := ReadIniNum("Zoom", "Smooth", 0, 1, 1) = 1
}

ZoomWriteSettings() {
    global SETTINGS_PATH, zoomSteps, zoomSmooth
    loop 3
        IniWrite(zoomSteps[A_Index], SETTINGS_PATH, "Zoom", "Level" A_Index)
    IniWrite(zoomSmooth ? 1 : 0, SETTINGS_PATH, "Zoom", "Smooth")
}

; ---------------- 준비 ----------------
; 처음 켤 때 한 번만. Magnification.dll은 Windows 7 이후 기본으로 들어 있다.
ZoomInit() {
    global zoomReady, zoomFailed, zoomHost, zoomMag
    if zoomReady
        return true
    if zoomFailed
        return false
    try {
        if !DllCall("LoadLibrary", "str", "Magnification.dll", "ptr")
            throw Error("Magnification.dll을 불러오지 못했습니다.")
        if !DllCall("Magnification\MagInitialize", "int")
            throw Error("MagInitialize 실패")
        ; E0x80000 레이어드 + E0x20 클릭 통과 + E0x8000000 활성화 안 됨.
        ; 클릭 통과라 확대 중에도 클릭은 아래 프로그램(또는 판서 층)으로 그대로 간다.
        ; MouseGetPos도 이 창을 건너뛰므로 DrawPoll의 "커서 아래 창" 판정을 가리지 않는다.
        zoomHost := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +0x2000000 +E0x8080020", "ClassZoom-Zoom") ; 0x2000000 = WS_CLIPCHILDREN (확대 화면 위에 바탕을 덧칠하지 않게)
        zoomHost.BackColor := "000000"
        zoomHost.Show("x0 y0 w8 h8 Hide")
        ; 레이어드 창은 투명도를 한 번 정해줘야 화면에 그려진다 (255 = 불투명, 2 = LWA_ALPHA)
        DllCall("SetLayeredWindowAttributes", "ptr", zoomHost.Hwnd, "uint", 0, "uchar", 255, "uint", 2)
        hInst := DllCall("GetModuleHandle", "ptr", 0, "ptr")
        ; WC_MAGNIFIER("Magnifier") 클래스는 MagInitialize가 등록한다. 0x50000000 = WS_CHILD | WS_VISIBLE
        zoomMag := DllCall("CreateWindowEx", "uint", 0, "str", "Magnifier", "str", "ClassZoomMagnifier"
            , "uint", 0x50000000, "int", 0, "int", 0, "int", 8, "int", 8
            , "ptr", zoomHost.Hwnd, "ptr", 0, "ptr", hInst, "ptr", 0, "ptr")
        if !zoomMag
            throw Error("확대 컨트롤을 만들지 못했습니다.")
        zoomReady := true
        OnExit(ZoomShutdown)
        return true
    } catch as err {
        zoomFailed := true
        MsgBox("확대 기능을 시작하지 못했습니다.`n`n(" err.Message ")`n`n"
            . "Windows 기본 돋보기(Win + +)는 계속 쓰실 수 있습니다.", "ClassZoom — 확대", "Icon!")
        return false
    }
}

ZoomShutdown(*) {
    global zoomReady
    if zoomReady
        try DllCall("Magnification\MagUninitialize")
    zoomReady := false
}

; ---------------- 켜기 / 끄기 ----------------
; 누를 때마다 1단계 → 2단계 → 3단계 → 끄기 (위젯 돋보기 버튼과 단축키가 같이 쓴다)
ToggleZoom(*) {
    global zoomOn, zoomStep
    if !zoomOn
        ZoomStart(1)
    else if (zoomStep < 3)
        ZoomSetStep(zoomStep + 1)
    else
        ZoomStop()
}

ZoomSetStep(n) {
    global zoomStep, zoomTarget, zoomSteps, zoomOn
    if !zoomOn
        return
    zoomStep := Max(1, Min(3, n))
    zoomTarget := zoomSteps[zoomStep] / 100
    ZoomShowBadge()
}

ZoomStart(step := 1) {
    global zoomOn, zoomVisible, zoomClosing, zoomLevel, zoomTarget, zoomSteps, zoomSmooth, zoomStep
    global zoomHost, zoomOX, zoomOY, zoomML, zoomMT, zoomFilterKey, zoomAnimFrom, zoomAnimTo
    SetTimer(ZoomRelease, 0) ; 정리하려던 참이면 그만둔다
    if !ZoomInit()
        return
    zoomOn := true
    zoomStep := step
    if zoomClosing { ; 끄는 중에 다시 켜면 그 자리에서 되돌아간다
        zoomClosing := false
        zoomTarget := zoomSteps[step] / 100
    } else if !zoomVisible {
        zoomTarget := zoomSteps[step] / 100
        MouseGetPos(&cx, &cy)
        ZoomUseMonitorAt(cx, cy)
        zoomLevel := zoomSmooth ? 1.0 : zoomTarget
        zoomAnimFrom := zoomLevel, zoomAnimTo := zoomLevel ; ZoomTick이 목표가 바뀐 것을 보고 애니메이션을 시작한다
        zoomOX := zoomML, zoomOY := zoomMT
        zoomFilterKey := ""
        ZoomTick()           ; 첫 화면을 먼저 그려두고
        zoomHost.Show("NA")  ; 그다음 보여야 옛 화면이 번쩍이지 않는다
        zoomVisible := true
        UpdateCursorHiddenState() ; 진짜 커서를 숨기고 그린 커서 하나만 보이게 한다
        ZoomKeepOrder(true)
        SetTimer(ZoomTick, ZOOM_TICK_MS)
    }
    ZoomSetHotkeys(true)
    UpdateWidgetState()
    ZoomShowBadge()
}

ZoomStop() {
    global zoomOn, zoomVisible, zoomClosing, zoomSmooth, zoomStep
    if !zoomOn
        return
    zoomOn := false
    zoomStep := 0
    ZoomHideBadge()
    ZoomSetHotkeys(false)
    if (zoomVisible && zoomSmooth)
        zoomClosing := true ; ZoomTick이 배율을 1까지 줄인 뒤 ZoomHide를 부른다
    else
        ZoomHide()
    UpdateWidgetState()
}

ZoomHide() {
    global zoomVisible, zoomClosing, zoomLevel, zoomHost, zoomCursorGui
    SetTimer(ZoomTick, 0)
    try zoomHost.Hide()
    if IsObject(zoomCursorGui)
        zoomCursorGui.Hide()
    ZoomHideBadge()
    zoomVisible := false
    zoomClosing := false
    zoomLevel := 1.0
    UpdateCursorHiddenState() ; 숨겨 둔 진짜 커서를 돌려준다
    RaiseWidget()
    SetTimer(ZoomRelease, -ZOOM_RELEASE_MS)
}

; 한동안 확대를 안 쓰면 확대 창·확대 컨트롤·Magnification API를 정리해 메모리를 돌려준다.
ZoomRelease() {
    global zoomReady, zoomVisible, zoomHost, zoomMag, zoomCursorGui, zoomCursorCanvas, zoomFilterKey, zoomLastKey
    if (zoomVisible || !zoomReady)
        return
    try DllCall("DestroyWindow", "ptr", zoomMag)
    try zoomHost.Destroy()
    try DllCall("Magnification\MagUninitialize")
    if IsObject(zoomCursorGui)
        try zoomCursorGui.Destroy()
    try DestroyAlphaCanvas(zoomCursorCanvas)
    zoomHost := "", zoomMag := 0, zoomCursorGui := "", zoomCursorCanvas := ""
    zoomFilterKey := "", zoomLastKey := ""
    zoomReady := false
    TrimMemory()
}

; 확대 중에만 켜는 키. 드로잉 모드의 Esc(지우고 끄기)와 겹치지 않게, Esc는 "확대 중이고
; 드로잉은 꺼져 있을 때"만 확대를 끈다(HotIf). 드로잉 중 Esc는 원래대로 드로잉을 끈다.
ZoomEscAllowed(*) {
    global zoomOn, drawOn
    return zoomOn && !drawOn
}

ZoomSetHotkeys(on) {
    static made := false
    state := on ? "On" : "Off"
    if !made {
        HotIf()
        Hotkey("^WheelUp", (*) => ZoomWheel(1), "Off")
        Hotkey("^WheelDown", (*) => ZoomWheel(-1), "Off")
        HotIf(ZoomEscAllowed)
        Hotkey("Esc", (*) => ZoomStop(), "Off")
        HotIf()
        made := true
    }
    HotIf()
    Hotkey("^WheelUp", state)
    Hotkey("^WheelDown", state)
    HotIf(ZoomEscAllowed)
    Hotkey("Esc", state)
    HotIf() ; 다른 곳의 Hotkey() 호출이 이 조건에 묶이지 않게 되돌린다
}

; Ctrl+휠: 단계를 한 칸씩 오르내린다 (1~3단계). 커서가 가리키는 지점은 그대로 둔 채 커지고 작아진다.
ZoomWheel(dir) {
    global zoomOn, zoomStep
    if zoomOn
        ZoomSetStep(zoomStep + (dir > 0 ? 1 : -1))
}

; 설정 창에서 단계 배율을 바꾸면, 지금 그 단계로 확대 중이면 화면에도 바로 보여준다
ZoomApplyStepLevel(i, pct) {
    global zoomSteps, zoomTarget, zoomOn, zoomStep
    zoomSteps[i] := pct
    if (zoomOn && zoomStep = i)
        zoomTarget := pct / 100
}

; ---------------- 단계 표시 ("2단계 · 200%") ----------------
; 커서 오른쪽 아래에 잠깐 띄운다. 확대하지 않는 창(ZoomTopHwnds)이라 늘 진짜 커서 옆, 원래 크기로 보인다.
ZoomShowBadge() {
    global zoomBadge, zoomBadgeText, zoomBadgeUntil, zoomStep, zoomSteps, ZOOM_BADGE_MS
    if (zoomStep < 1)
        return
    if !IsObject(zoomBadge) {
        ; 0x80000 레이어드 + 0x20 클릭 통과 + 0x8000000 활성화 안 됨
        zoomBadge := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x8080020", "ClassZoom-ZoomBadge")
        zoomBadge.BackColor := "1E293B"
        zoomBadge.MarginX := 14, zoomBadge.MarginY := 8
        zoomBadge.SetFont("s13 bold cFFFFFF", "Malgun Gothic")
        zoomBadgeText := zoomBadge.AddText("w170 Center", "")
    }
    zoomBadgeText.Value := "확대 " zoomStep "단계 · " zoomSteps[zoomStep] "%"
    MouseGetPos(&mx, &my)
    ZoomScreenPos(&mx, &my) ; 확대 화면 속 커서 옆에
    zoomBadge.Show("NA x" (mx + 26) " y" (my + 26) " AutoSize")
    DllCall("SetLayeredWindowAttributes", "ptr", zoomBadge.Hwnd, "uint", 0, "uchar", 235, "uint", 2)
    WinGetPos(, , &bw, &bh, zoomBadge)
    RoundRegion(zoomBadge.Hwnd, bw, bh, 14)
    ZoomUpdateFilter() ; 새로 만든 창이면 바로 확대 대상에서 뺀다 (확대된 사본이 남지 않게)
    ZoomKeepOrder(true)
    ; 연속으로 누를 때마다 시계를 새로 건다. 타이머가 밀려도 ZoomTick이 zoomBadgeUntil을 보고 감춘다.
    zoomBadgeUntil := A_TickCount + ZOOM_BADGE_MS
    SetTimer(ZoomHideBadge, -ZOOM_BADGE_MS)
}

ZoomHideBadge() {
    global zoomBadge, zoomBadgeUntil
    zoomBadgeUntil := 0
    SetTimer(ZoomHideBadge, 0)
    if IsObject(zoomBadge)
        try zoomBadge.Hide()
}

; ---------------- 좌표 ----------------
; 터치·펜이 닿은 화면 자리 → 그 자리에 보이는 내용의 실제 좌표. 확대가 꺼져 있으면 그대로.
; (마우스는 바꿀 필요가 없다 — 진짜 커서 자리가 곧 실제 좌표다)
ZoomMapPt(pt) {
    global zoomVisible, zoomML, zoomMT, zoomMW, zoomMH, zoomSrcL, zoomSrcT, zoomSrcW, zoomSrcH
    if !zoomVisible
        return pt
    return [Round(zoomSrcL + (pt[1] - zoomML) * zoomSrcW / zoomMW)
        , Round(zoomSrcT + (pt[2] - zoomMT) * zoomSrcH / zoomMH)]
}

; 실제 자리(진짜 커서·원본 좌표) → 확대 화면에서 보이는 자리. 확대가 꺼져 있으면 그대로.
; 그린 커서·강조 원·클릭 링·단계 숫자가 이 자리에 그려진다.
ZoomScreenPos(&x, &y) {
    global zoomVisible, zoomML, zoomMT, zoomMW, zoomMH, zoomSrcL, zoomSrcT, zoomSrcW, zoomSrcH
    if !zoomVisible
        return
    x := Round(zoomML + (x - zoomSrcL) * zoomMW / zoomSrcW)
    y := Round(zoomMT + (y - zoomSrcT) * zoomMH / zoomSrcH)
}


; 커서가 있는 모니터로 확대 창을 옮긴다
ZoomUseMonitorAt(x, y) {
    global zoomML, zoomMT, zoomMW, zoomMH, zoomHost, zoomMag
    global zoomLastKey, zoomSrcW, zoomSrcH, zoomOX, zoomOY
    if !GetMonitorAt(x, y, &ml, &mt, &mr, &mb, &wl, &wt, &wr, &wb)
        ml := 0, mt := 0, mr := A_ScreenWidth, mb := A_ScreenHeight
    zoomML := ml, zoomMT := mt, zoomMW := mr - ml, zoomMH := mb - mt
    zoomLastKey := "", zoomSrcW := zoomMW, zoomSrcH := zoomMH, zoomOX := ml, zoomOY := mt
    ; Gui.Move는 DPI 배율을 거치므로 창 크기는 실제 픽셀로 직접 정한다
    DllCall("SetWindowPos", "ptr", zoomHost.Hwnd, "ptr", 0, "int", ml, "int", mt
        , "int", zoomMW, "int", zoomMH, "uint", 0x14) ; SWP_NOZORDER | SWP_NOACTIVATE
    DllCall("MoveWindow", "ptr", zoomMag, "int", 0, "int", 0, "int", zoomMW, "int", zoomMH, "int", true)
}

; ---------------- 한 프레임 ----------------
ZoomTick() {
    global zoomOn, zoomClosing, zoomLevel, zoomTarget, zoomSmooth, zoomOX, zoomOY, zoomLastKey
    global zoomML, zoomMT, zoomMW, zoomMH, zoomSrcL, zoomSrcT, zoomSrcW, zoomSrcH, zoomMag
    global zoomAnimFrom, zoomAnimTo, zoomAnimT0, zoomBadgeUntil, ZOOM_ANIM_MS, ZOOM_EDGE_FRAC, ZOOM_REDRAW_EVERY
    static n := 0, lastCur := ""
    n++
    MouseGetPos(&cx, &cy)

    ; 커서가 다른 모니터로 넘어가면 확대 창도 따라간다
    if (cx < zoomML || cy < zoomMT || cx >= zoomML + zoomMW || cy >= zoomMT + zoomMH)
        ZoomUseMonitorAt(cx, cy)

    ; ---- 배율: 시간 기준 애니메이션 (끝으로 갈수록 느려지는 ease-out) ----
    target := zoomClosing ? 1.0 : zoomTarget
    if (target != zoomAnimTo)
        zoomAnimFrom := zoomLevel, zoomAnimTo := target, zoomAnimT0 := A_TickCount
    if (!zoomSmooth || zoomAnimFrom = zoomAnimTo)
        z := zoomAnimTo
    else {
        p := Min(1, (A_TickCount - zoomAnimT0) / ZOOM_ANIM_MS)
        z := zoomAnimFrom + (zoomAnimTo - zoomAnimFrom) * (1 - (1 - p) ** 3)
    }
    zoomLevel := z
    if (zoomClosing && z <= 1.0) {
        ZoomHide()
        return
    }

    ; ---- 원본 영역 크기: 가로를 정수로, 세로는 같은 배율에서 ----
    srcW := Max(1, Round(zoomMW / z))
    srcH := Max(1, Min(zoomMH, Round(zoomMH * srcW / zoomMW)))

    ; 배율이 바뀌는 동안에는 "화면에 보이는 커서 자리"를 그대로 둔 채 커지고 작아진다
    if (srcW != zoomSrcW || srcH != zoomSrcH) {
        sx := (cx - zoomOX) * zoomMW / zoomSrcW, sy := (cy - zoomOY) * zoomMH / zoomSrcH
        zoomOX := cx - sx * srcW / zoomMW, zoomOY := cy - sy * srcH / zoomMH
    }
    ; ---- 화면 고정: 커서가 가장자리 쪽으로 갈 때만 그쪽으로 옮긴다 ----
    ex := srcW * ZOOM_EDGE_FRAC, ey := srcH * ZOOM_EDGE_FRAC
    if (cx < zoomOX + ex)
        zoomOX := cx - ex
    else if (cx > zoomOX + srcW - ex)
        zoomOX := cx + ex - srcW
    if (cy < zoomOY + ey)
        zoomOY := cy - ey
    else if (cy > zoomOY + srcH - ey)
        zoomOY := cy + ey - srcH
    zoomOX := Max(zoomML, Min(zoomML + zoomMW - srcW, zoomOX))
    zoomOY := Max(zoomMT, Min(zoomMT + zoomMH - srcH, zoomOY))
    l := Round(zoomOX), t := Round(zoomOY)

    ; ---- 바뀐 것이 있을 때만 확대 컨트롤에 넘긴다 ----
    key := l "," t "," srcW "," srcH
    changed := (key != zoomLastKey)
    if changed {
        static m := Buffer(36, 0), rc := Buffer(16, 0)
        NumPut("float", zoomMW / srcW, m, 0)
        NumPut("float", zoomMH / srcH, m, 16)
        NumPut("float", 1.0, m, 32)
        DllCall("Magnification\MagSetWindowTransform", "ptr", zoomMag, "ptr", m, "int")
        ; RECT를 값으로 넘기는 함수다. 64비트에서는 16바이트 구조체가 포인터로 넘어간다
        if (A_PtrSize = 8) {
            NumPut("int", l, "int", t, "int", l + srcW, "int", t + srcH, rc)
            DllCall("Magnification\MagSetWindowSource", "ptr", zoomMag, "ptr", rc, "int")
        } else
            DllCall("Magnification\MagSetWindowSource", "ptr", zoomMag, "int", l, "int", t, "int", l + srcW, "int", t + srcH, "int")
        zoomLastKey := key
    }
    zoomSrcL := l, zoomSrcT := t, zoomSrcW := srcW, zoomSrcH := srcH
    ; 화면 내용(영상 등)은 계속 바뀌므로 다시 그리게 한다. 배경 지우기는 하지 않는다(false).
    ; 보는 영역이 바뀐 틱(이동·확대 애니메이션)은 바로, 그대로면 ZOOM_REDRAW_EVERY 틱마다 한 번 (약 30fps).
    if (changed || Mod(n, ZOOM_REDRAW_EVERY) = 0)
        DllCall("InvalidateRect", "ptr", zoomMag, "ptr", 0, "int", false)

    ; 그린 커서는 커서나 보는 영역이 움직였을 때만 옮긴다
    cur := cx "," cy "," key
    if (cur != lastCur || Mod(n, 30) = 0) {
        ZoomUpdateCursor(cx, cy)
        lastCur := cur
    }
    if (zoomBadgeUntil && A_TickCount >= zoomBadgeUntil)
        ZoomHideBadge()
    ; 창 목록·순서 확인은 가끔만 (단계 표시·녹화 표시창은 띄울 때 직접 부른다)
    if (Mod(n, 20) = 0)
        ZoomUpdateFilter()
    if (Mod(n, 6) = 0)
        ZoomKeepOrder()
}

; ---------------- 확대에서 뺄 창 / 창 순서 ----------------
; 확대 창 위에 그대로(확대하지 않고) 보여야 하는 우리 창들. 진짜 커서 자리에 그려지는 것들이다.
ZoomTopHwnds() {
    global spotGui, clickAnim, stepGui, zoomBadge, zoomCursorGui
    list := []
    if IsObject(zoomBadge)
        try list.Push(zoomBadge.Hwnd)
    try list.Push(spotGui.Hwnd)
    for side in ["L", "R"]
        try list.Push(clickAnim[side].gui.Hwnd)
    try list.Push(stepGui.Hwnd)
    for h in RecTopHwnds() ; 녹화 표시창·카운트다운·영역 테두리 (record.ahk)
        list.Push(h)
    if IsObject(zoomCursorGui)
        try list.Push(zoomCursorGui.Hwnd) ; 맨 위 — 다른 것에 가려지지 않게 마지막에 올린다
    return list
}

; 확대 화면 안에 들어가야 하는 우리 창들 (확대 창보다 아래에 있어야 한다)
ZoomBelowHwnds() {
    global drawGui, laserGui, boardGui, brushGui, widget, boardPalette
    m := Map()
    for g in [drawGui, laserGui, boardGui, brushGui]
        try m[g.Hwnd] := true
    for h in PulseArrowHwnds() ; 강조 화살표들
        m[h] := true
    if (IsSet(widget) && widget) ; 위젯도 확대 화면 안에 — 보이는 자리 그대로 누를 수 있게
        try m[widget.Hwnd] := true
    if (IsSet(boardPalette) && IsObject(boardPalette)) ; 전자칠판 모드 팔레트도 위젯과 같이
        try m[boardPalette.Hwnd] := true
    return m
}

; 확대 컨트롤에 "이 창들은 키우지 말라"고 알린다. 자기 자신(zoomHost)을 빼지 않으면 거울 속
; 거울처럼 끝없이 겹친다. 위젯은 크기를 바꾸면 다시 만들어지므로 목록이 바뀔 때마다 다시 알린다.
ZoomUpdateFilter() {
    global zoomMag, zoomHost, zoomFilterKey
    if (!IsObject(zoomHost) || !zoomMag)
        return
    list := ZoomTopHwnds()
    list.InsertAt(1, zoomHost.Hwnd)
    key := ""
    for h in list
        key .= h ","
    if (key = zoomFilterKey)
        return
    buf := Buffer(A_PtrSize * list.Length, 0)
    for h in list
        NumPut("ptr", h, buf, (A_Index - 1) * A_PtrSize)
    DllCall("Magnification\MagSetWindowFilterList", "ptr", zoomMag, "uint", 0, "int", list.Length, "ptr", buf, "int") ; 0 = MW_FILTERMODE_EXCLUDE
    zoomFilterKey := key
}

; 판서 층·드로잉 커서 원은 보였다 숨었다 할 때마다 "항상 위" 무리의 맨 위로 올라온다. 그러면
; 확대 화면을 덮어 버리므로, 확대 창 위에 그런 창이 올라와 있으면 순서를 다시 맞춘다.
; force가 참이면 확인 없이 맞춘다. 확인은 위쪽 창 몇 개만 훑으므로 매 프레임 해도 가볍다.
ZoomKeepOrder(force := false) {
    global zoomHost, zoomVisible
    ; 확대 창이 아직 없거나(한 번도 확대하지 않음) 꺼져 있으면 맞출 순서가 없다.
    ; 녹화 표시창·카운트다운·영역 선택 창이 확대와 상관없이 부르므로 꼭 먼저 본다.
    if (!IsObject(zoomHost) || !zoomVisible)
        return
    if !force {
        ; 확대 창 위에 "확대돼야 할 우리 창"(판서 층·위젯·안내 창 등)이 올라와 있으면 순서를 다시 맞춘다.
        ; 다른 프로그램 창은 건드리지 않는다 (작업표시줄 등과 다투지 않게).
        below := ZoomBelowHwnds()
        top := Map()
        for h in ZoomTopHwnds()
            top[h] := true
        myPid := DllCall("GetCurrentProcessId", "uint")
        h := zoomHost.Hwnd
        bad := false
        loop 64 {
            h := DllCall("GetWindow", "ptr", h, "uint", 3, "ptr") ; GW_HWNDPREV = 바로 위 창
            if !h
                break
            if (top.Has(h) || !DllCall("IsWindowVisible", "ptr", h)) ; 숨은 창은 순서가 상관없다
                continue
            pid := 0
            DllCall("GetWindowThreadProcessId", "ptr", h, "uint*", &pid)
            if (below.Has(h) || pid = myPid) {
                bad := true
                break
            }
        }
        if !bad
            return
    }
    if force
        ZoomUpdateFilter() ; 새로 띄운 우리 창(녹화 표시창 등)을 바로 확대 대상에서 뺀다
    flags := 0x1 | 0x2 | 0x10 ; SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
    DllCall("SetWindowPos", "ptr", zoomHost.Hwnd, "ptr", -1, "int", 0, "int", 0, "int", 0, "int", 0, "uint", flags)
    for h in ZoomTopHwnds()
        DllCall("SetWindowPos", "ptr", h, "ptr", -1, "int", 0, "int", 0, "int", 0, "int", 0, "uint", flags)
}

; ---------------- 확대 중 그리는 화살표 커서 ----------------
; 진짜 커서는 숨겨 두고(UpdateCursorHiddenState), 확대 화면 속 커서 자리에 이 화살표를 그린다.
; 드로잉 중 판서 층 위에서는 드로잉 커서 원이 커서 노릇을 하므로 감춘다.
ZoomCursorInit() {
    global zoomCursorGui, zoomCursorCanvas, zoomCursorPad
    k := A_ScreenDPI / 96
    size := Round(34 * k)
    zoomCursorPad := Round(3 * k)
    zoomCursorGui := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x8080020", "ClassZoom-Cursor")
    zoomCursorGui.Show("w" size " h" size " Hide")
    c := CreateAlphaCanvas(size, size)
    zoomCursorCanvas := c
    if !c.graphics
        return
    DllCall("gdiplus\GdipGraphicsClear", "ptr", c.graphics, "uint", 0)
    shape := [[0, 0], [0, 1.0], [0.27, 0.76], [0.46, 1.16], [0.62, 1.08], [0.44, 0.69], [0.78, 0.69]]
    s := 24 * k, p := zoomCursorPad
    pts := Buffer(8 * shape.Length, 0)
    for i, q in shape
        NumPut("float", p + q[1] * s, "float", p + q[2] * s, pts, (i - 1) * 8)
    brush := 0, pen := 0
    DllCall("gdiplus\GdipCreateSolidFill", "uint", 0xFFFFFFFF, "ptr*", &brush)
    DllCall("gdiplus\GdipFillPolygon", "ptr", c.graphics, "ptr", brush, "ptr", pts, "int", shape.Length, "int", 0)
    DllCall("gdiplus\GdipCreatePen1", "uint", 0xFF000000, "float", 1.6 * k, "int", 2, "ptr*", &pen)
    DllCall("gdiplus\GdipSetPenLineJoin", "ptr", pen, "int", 2) ; 둥근 모서리
    DllCall("gdiplus\GdipDrawPolygon", "ptr", c.graphics, "ptr", pen, "ptr", pts, "int", shape.Length)
    DllCall("gdiplus\GdipDeleteBrush", "ptr", brush)
    DllCall("gdiplus\GdipDeletePen", "ptr", pen)
    DllCall("gdiplus\GdipFlush", "ptr", c.graphics, "int", 0)
}

ZoomUpdateCursor(cx, cy) {
    global zoomCursorGui, zoomCursorCanvas, zoomCursorPad, drawOn, brushGui
    ; 드로잉 커서 원이 떠 있으면(판서 층 위) 그 원이 커서다
    if (drawOn && DllCall("IsWindowVisible", "ptr", brushGui.Hwnd)) {
        if IsObject(zoomCursorGui)
            zoomCursorGui.Hide()
        return
    }
    if !IsObject(zoomCursorGui)
        ZoomCursorInit()
    if !IsObject(zoomCursorCanvas) || !zoomCursorCanvas.graphics
        return
    x := cx, y := cy
    ZoomScreenPos(&x, &y)
    PushCanvasToWindow(zoomCursorGui.Hwnd, zoomCursorCanvas, x - zoomCursorPad, y - zoomCursorPad)
    if !DllCall("IsWindowVisible", "ptr", zoomCursorGui.Hwnd)
        DllCall("ShowWindow", "ptr", zoomCursorGui.Hwnd, "int", 8) ; SW_SHOWNA
}
