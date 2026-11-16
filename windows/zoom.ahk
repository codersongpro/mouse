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
;     - 확대 컨트롤은 커서를 그리지 않는다(MS_SHOWMAGNIFIEDCURSOR를 안 줌). 보이는 커서는
;       진짜 커서 하나뿐이다.
;     - **커서 기준 확대**: 원본 좌표 s = 원점 + (커서 - 모니터 왼쪽 위) / 배율 에서 원점을
;       커서(1 - 1/배율)로 잡으면, 커서가 가리키는 지점이 확대 후에도 **같은 자리**에 온다.
;       그래서 진짜 커서와 확대된 내용이 정확히 겹치고, **확대한 채로 클릭해도 정확히 맞는다.**
;     - 화면을 읽는 방식(Windows.Graphics.Capture)이 아니라서 Windows 11의 노란 캡처 테두리도
;       생기지 않는다(원작 NOTES.md 2026-09-21 참고).
;
; 드로잉과 함께 쓰기
;   드로잉을 켜면 화면이 **고정**된다(커서를 따라 움직이면 긋는 동안 그림이 미끄러진다).
;   고정된 동안 마우스·펜 좌표를 ZoomMapPoint로 원본 좌표로 바꿔 그리므로, 확대된 화면 위의
;   보이는 자리에 정확히 그려진다. 커서를 화면 가장자리로 밀면 그쪽으로 화면이 움직인다.
;   그린 내용은 원본 좌표에 남으므로 확대를 끄면 원래 크기로 그 자리에 있다.
;
; 창 순서(위 → 아래)
;   위젯·강조 원·클릭 링·단계 숫자   ← 확대하지 않고 진짜 커서 자리에 그대로 보인다
;   zoomHost (확대 화면, 클릭 통과)
;   판서·레이저·칠판·드로잉 커서 원   ← 확대되어 보인다 (원본 좌표에 있다)
;   일반 프로그램들

; ---------------- 조절용 숫자 ----------------
ZOOM_MIN_PCT := 125          ; 가장 작은 배율(%)
ZOOM_MAX_PCT := 800          ; 가장 큰 배율(%)
ZOOM_STEP_DEFAULTS := [150, 200, 300] ; 1·2·3단계 기본 배율(%)
ZOOM_BADGE_MS := 900         ; 단계가 바뀔 때 커서 옆에 뜨는 "2단계 · 200%" 표시 시간
ZOOM_TICK_MS := 15           ; 확대 화면을 다시 그리는 간격 (약 60fps). 확대 중에만 돈다
ZOOM_SMOOTH_FOLLOW := 0.45   ; 부드럽게: 한 번에 목표 위치로 다가가는 비율 (1 = 바로)
ZOOM_SMOOTH_LEVEL := 0.30    ; 부드럽게: 한 번에 목표 배율로 다가가는 비율
ZOOM_EDGE_PX := 3            ; 드로잉 중(고정) 화면 가장자리에서 이만큼 안이면 그쪽으로 이동
ZOOM_EDGE_SPEED := 24        ; 가장자리 이동 속도 (화면 픽셀/틱)

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
zoomStep := 0         ; 지금 단계 (0 = 꺼짐, 1~3)
zoomBadge := ""       ; 단계 표시 창
zoomBadgeText := ""

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
        zoomHost := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x8080020", "ClassZoom-Zoom")
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
    global zoomHost, zoomOX, zoomOY, zoomML, zoomMT, zoomFilterKey
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
        zoomOX := zoomML, zoomOY := zoomMT
        if !zoomSmooth ; 부드럽게가 꺼져 있으면 첫 화면부터 커서 기준 자리
            ZoomFollowTarget(cx, cy, zoomLevel, &zoomOX, &zoomOY)
        zoomFilterKey := ""
        ZoomTick()           ; 첫 화면을 먼저 그려두고
        zoomHost.Show("NA")  ; 그다음 보여야 옛 화면이 번쩍이지 않는다
        zoomVisible := true
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
    global zoomVisible, zoomClosing, zoomLevel, zoomHost
    SetTimer(ZoomTick, 0)
    try zoomHost.Hide()
    zoomVisible := false
    zoomClosing := false
    zoomLevel := 1.0
    RaiseWidget()
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
    global zoomBadge, zoomBadgeText, zoomStep, zoomSteps, ZOOM_BADGE_MS
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
    zoomBadge.Show("NA x" (mx + 26) " y" (my + 26) " AutoSize")
    DllCall("SetLayeredWindowAttributes", "ptr", zoomBadge.Hwnd, "uint", 0, "uchar", 235, "uint", 2)
    WinGetPos(, , &bw, &bh, zoomBadge)
    RoundRegion(zoomBadge.Hwnd, bw, bh, 14)
    ZoomKeepOrder(true)
    SetTimer(ZoomHideBadge, -ZOOM_BADGE_MS)
}

ZoomHideBadge() {
    global zoomBadge
    if IsObject(zoomBadge)
        zoomBadge.Hide()
}

; ---------------- 좌표 ----------------
; 커서가 (cx, cy)에 있을 때 "커서가 가리키는 지점이 제자리에 오는" 원본 영역의 왼쪽 위
ZoomFollowTarget(cx, cy, z, &ox, &oy) {
    global zoomML, zoomMT
    ox := zoomML + (cx - zoomML) * (1 - 1 / z)
    oy := zoomMT + (cy - zoomMT) * (1 - 1 / z)
}

; 화면 좌표(진짜 커서 자리) → 원본 좌표(그 자리에 보이는 내용이 실제로 있는 곳).
; 확대가 꺼져 있으면 그대로 둔다. 판서·지우개·드로잉 커서 원이 이 좌표를 쓴다.
ZoomMapPoint(&x, &y) {
    global zoomVisible, zoomML, zoomMT, zoomMW, zoomMH, zoomSrcL, zoomSrcT, zoomSrcW, zoomSrcH
    if !zoomVisible
        return
    x := Round(zoomSrcL + (x - zoomML) * zoomSrcW / zoomMW)
    y := Round(zoomSrcT + (y - zoomMT) * zoomSrcH / zoomMH)
}

ZoomMapPt(pt) {
    x := pt[1], y := pt[2]
    ZoomMapPoint(&x, &y)
    return [x, y]
}

; 커서가 있는 모니터로 확대 창을 옮긴다
ZoomUseMonitorAt(x, y) {
    global zoomML, zoomMT, zoomMW, zoomMH, zoomHost, zoomMag
    if !GetMonitorAt(x, y, &ml, &mt, &mr, &mb, &wl, &wt, &wr, &wb)
        ml := 0, mt := 0, mr := A_ScreenWidth, mb := A_ScreenHeight
    zoomML := ml, zoomMT := mt, zoomMW := mr - ml, zoomMH := mb - mt
    ; Gui.Move는 DPI 배율을 거치므로 창 크기는 실제 픽셀로 직접 정한다
    DllCall("SetWindowPos", "ptr", zoomHost.Hwnd, "ptr", 0, "int", ml, "int", mt
        , "int", zoomMW, "int", zoomMH, "uint", 0x14) ; SWP_NOZORDER | SWP_NOACTIVATE
    DllCall("MoveWindow", "ptr", zoomMag, "int", 0, "int", 0, "int", zoomMW, "int", zoomMH, "int", true)
}

; ---------------- 한 프레임 ----------------
ZoomTick() {
    global zoomOn, zoomClosing, zoomLevel, zoomTarget, zoomSmooth, zoomOX, zoomOY
    global zoomML, zoomMT, zoomMW, zoomMH, zoomSrcL, zoomSrcT, zoomSrcW, zoomSrcH, zoomMag
    global drawOn, penStroke, ZOOM_SMOOTH_FOLLOW, ZOOM_SMOOTH_LEVEL, ZOOM_EDGE_PX, ZOOM_EDGE_SPEED
    MouseGetPos(&cx, &cy)
    frozen := drawOn ; 드로잉 중에는 화면을 고정한다

    ; 따라가는 중에 커서가 다른 모니터로 넘어가면 확대 창도 따라간다
    if (!frozen && (cx < zoomML || cy < zoomMT || cx >= zoomML + zoomMW || cy >= zoomMT + zoomMH)) {
        ZoomUseMonitorAt(cx, cy)
        ZoomFollowTarget(cx, cy, zoomLevel, &zoomOX, &zoomOY)
    }

    ; 배율: 목표로 다가간다 (끄는 중이면 1로)
    target := zoomClosing ? 1.0 : zoomTarget
    z := zoomSmooth ? zoomLevel + (target - zoomLevel) * ZOOM_SMOOTH_LEVEL : target
    if (Abs(target - z) < 0.003)
        z := target

    if frozen {
        ; 배율이 바뀌어도 커서 아래 지점은 그대로 둔다
        if (z != zoomLevel) {
            sx := zoomOX + (cx - zoomML) / zoomLevel, sy := zoomOY + (cy - zoomMT) / zoomLevel
            zoomOX := sx - (cx - zoomML) / z, zoomOY := sy - (cy - zoomMT) / z
        }
        ; 버튼을 누르지 않은 채 가장자리로 밀면 그쪽으로 이동한다 (긋는 중에는 움직이지 않는다)
        if (!penStroke && !GetKeyState("LButton", "P") && !GetKeyState("RButton", "P")) {
            step := ZOOM_EDGE_SPEED / z
            if (cx <= zoomML + ZOOM_EDGE_PX)
                zoomOX -= step
            else if (cx >= zoomML + zoomMW - 1 - ZOOM_EDGE_PX)
                zoomOX += step
            if (cy <= zoomMT + ZOOM_EDGE_PX)
                zoomOY -= step
            else if (cy >= zoomMT + zoomMH - 1 - ZOOM_EDGE_PX)
                zoomOY += step
        }
    } else {
        ZoomFollowTarget(cx, cy, z, &tx, &ty)
        k := zoomSmooth ? ZOOM_SMOOTH_FOLLOW : 1
        zoomOX += (tx - zoomOX) * k
        zoomOY += (ty - zoomOY) * k
        if (Abs(tx - zoomOX) < 0.5 && Abs(ty - zoomOY) < 0.5)
            zoomOX := tx, zoomOY := ty
    }
    zoomLevel := z

    if (zoomClosing && z <= 1.0) {
        ZoomHide()
        return
    }

    ; 원본 영역 (모니터 밖으로 나가지 않게)
    srcW := Max(1, Round(zoomMW / z)), srcH := Max(1, Round(zoomMH / z))
    zoomOX := Max(zoomML, Min(zoomML + zoomMW - srcW, zoomOX))
    zoomOY := Max(zoomMT, Min(zoomMT + zoomMH - srcH, zoomOY))
    l := Round(zoomOX), t := Round(zoomOY)
    zoomSrcL := l, zoomSrcT := t, zoomSrcW := srcW, zoomSrcH := srcH

    ; 배율 행렬 (3x3 float). 가로세로를 따로 줘서 반올림 오차 없이 창을 꽉 채운다
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
    DllCall("InvalidateRect", "ptr", zoomMag, "ptr", 0, "int", true)

    ZoomUpdateFilter()
    ZoomKeepOrder()
}

; ---------------- 확대에서 뺄 창 / 창 순서 ----------------
; 확대 창 위에 그대로(확대하지 않고) 보여야 하는 우리 창들. 진짜 커서 자리에 그려지는 것들이다.
ZoomTopHwnds() {
    global widget, spotGui, clickAnim, stepGui, zoomBadge
    list := []
    if IsObject(zoomBadge)
        try list.Push(zoomBadge.Hwnd)
    try list.Push(spotGui.Hwnd)
    for side in ["L", "R"]
        try list.Push(clickAnim[side].gui.Hwnd)
    try list.Push(stepGui.Hwnd)
    if (IsSet(widget) && widget)
        try list.Push(widget.Hwnd)
    return list
}

; 확대 화면 안에 들어가야 하는 우리 창들 (확대 창보다 아래에 있어야 한다)
ZoomBelowHwnds() {
    global drawGui, laserGui, boardGui, brushGui
    m := Map()
    for g in [drawGui, laserGui, boardGui, brushGui]
        try m[g.Hwnd] := true
    return m
}

; 확대 컨트롤에 "이 창들은 키우지 말라"고 알린다. 자기 자신(zoomHost)을 빼지 않으면 거울 속
; 거울처럼 끝없이 겹친다. 위젯은 크기를 바꾸면 다시 만들어지므로 목록이 바뀔 때마다 다시 알린다.
ZoomUpdateFilter() {
    global zoomMag, zoomHost, zoomFilterKey
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
    if !zoomVisible && !force
        return
    if !force {
        below := ZoomBelowHwnds()
        h := zoomHost.Hwnd
        bad := false
        loop 64 {
            h := DllCall("GetWindow", "ptr", h, "uint", 3, "ptr") ; GW_HWNDPREV = 바로 위 창
            if !h
                break
            if below.Has(h) {
                bad := true
                break
            }
        }
        if !bad
            return
    }
    flags := 0x1 | 0x2 | 0x10 ; SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
    DllCall("SetWindowPos", "ptr", zoomHost.Hwnd, "ptr", -1, "int", 0, "int", 0, "int", 0, "int", 0, "uint", flags)
    for h in ZoomTopHwnds()
        DllCall("SetWindowPos", "ptr", h, "ptr", -1, "int", 0, "int", 0, "int", 0, "int", 0, "uint", flags)
}
