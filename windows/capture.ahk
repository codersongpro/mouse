; ##########################################################################
; ## 화면 캡처 + 편집 창 (classzoom.ahk가 #Include로 불러 쓴다)            ##
; ##########################################################################
;
; 무엇을 하나
;   F6(또는 위젯의 캡처 버튼): 마우스를 올린 창에 빨간 테두리가 뜨고, 클릭하면 그 창을, 누른 채 끌면 그 구역을 찍는다
;   Shift+F6: 커서가 있는 모니터 전체 / Ctrl+Shift+F6: 마우스로 끌어 고른 구역
;   Ctrl+F6: 스크롤 캡처 — 창을 클릭하거나 구역을 끌면 ClassZoom이 휠을 굴려 내리며 찍고 한 장으로 이어 붙인다.
;            끝에 닿으면 저절로 멈추고, Esc나 [멈춤] 버튼으로 중간에 멈추면 거기까지 이어 붙인 그림을 편집 창에 띄운다.
;   찍은 그림은 곧바로 클립보드에 복사하고, 편집 창(펜·형광펜·네모·화살표·글자·모자이크·자르기)을 띄운다.
;   편집 창에서 [복사]·[저장](사진\ClassZoom 폴더에 PNG)·[다른 이름으로]를 고른다.
;
; 키 겹침을 막은 자리 (2026-11-25 점검)
;   - 캡처 키는 녹화 키처럼 앞 프로그램에 넘기지 않는다(HOTKEY_NO_PASS). 넘기면 한글 F6(스타일) 창이 떠서 함께 찍힌다.
;   - 고르는 동안 Esc는 "취소"로만 쓴다(CapPicking 조건의 Esc). 라이브 줌의 Esc(확대 끄기)보다 먼저 만들어서 이쪽이 이긴다.
;   - 고르는 동안 클릭은 화면을 덮는 투명한 덮개 창이 받는다(뒤 프로그램의 링크·버튼이 눌리지 않게). 오류가 나도 finally에서 치운다.
;   - 드로잉 중이면 고르는 동안 드로잉 입력을 멈추고(클릭이 선으로 그려지지 않게) 그린 그림은 캡처에 그대로 넣는다.
;   - 편집 창의 Ctrl+C·S·Z는 편집 창이 앞에 있고 드로잉이 꺼져 있을 때만 (Caps Lock 드로잉의 Ctrl+Z와 겹치지 않게).
;   - 확대 중에도 캡처한다: 확대 화면에 보이는 그대로 찍는다. 편집 창이 열리면 확대를 잠시 끄고(확대 위에서는 누르는
;     자리가 어긋난다) 편집 창을 닫으면 같은 단계로 다시 켠다.

CAP_COLORS := [0xEF4444, 0xF97316, 0xFACC15, 0x22C55E, 0x2563EB, 0x111827, 0xFFFFFF]
CAP_COLOR_NAMES := ["빨강", "주황", "노랑", "초록", "파랑", "검정", "흰색"]
CAP_SIZES := [3, 6, 12]         ; 펜·도형 굵기(화면에 보이는 px): 가늘게 · 보통 · 굵게
CAP_TEXT_SIZES := [20, 32, 48]  ; 글자 크기(화면에 보이는 px)
CAP_MOSAIC_BLOCK := 12          ; 모자이크 칸 크기(화면에 보이는 px)
CAP_TOOLS := [["pen", "펜"], ["hl", "형광펜"], ["rect", "네모"], ["arrow", "화살표"]
    , ["text", "글자"], ["mosaic", "모자이크"], ["crop", "자르기"]]
CAP_FRAME_PX := 3               ; 창 고르기 테두리 두께

capBusy := false                ; 고르기·찍기 중 (단축키를 연달아 눌러도 한 번만)
capPicking := false             ; 창·구역을 고르는 중 (Esc = 취소)
capCancel := false
capHint := "", capDim := "", capFrames := [], capCatch := ""
cap := ""                       ; 편집 창 상태 (열려 있지 않으면 "")
capZoomResume := 0              ; 편집 창을 닫으면 다시 켤 확대 단계 (0 = 없음)
capPickPt := ""                 ; 창 고르기에서 누른 자리 (스크롤 캡처는 그 자리에서 휠을 굴린다)
capScrolling := false           ; 스크롤 캡처로 찍는 중 (Esc = 멈춤)
capScrollPanel := "", capScrollInfo := "", capScrollNote := ""

; 스크롤 캡처 조절값
CAP_SCROLL_WAIT_MS := 280       ; 휠을 굴린 뒤 화면이 멈출 때까지 기다리는 시간 (부드러운 스크롤 포함)
CAP_SCROLL_MAX_H := 20000       ; 이어 붙인 그림의 최대 높이(px). 넘으면 거기서 멈춘다
CAP_SCROLL_MAX_STEPS := 300     ; 휠을 굴리는 최대 횟수

; ---------------- 단축키가 부르는 것 ----------------
CapWindow(*) => CapStart("window")
CapScreen(*) => CapStart("screen")
CapArea(*) => CapStart("area")
CapScroll(*) => CapStart("scroll")

CapStart(mode) {
    global capBusy
    if capBusy
        return
    capBusy := true
    try
        CapRun(mode)
    finally
        capBusy := false
}

CapRun(mode) {
    global cap, capScrollNote, zoomOn, zoomStep, zoomVisible, capZoomResume, drawOn
    ; 편집 창이 떠 있으면 찍는 동안 감춘다 (새로 찍으면 그 창은 닫는다)
    hadEditor := IsObject(cap)
    if hadEditor {
        if (cap.dirty && MsgBox("편집한 캡처를 저장하지 않았습니다.`n새로 캡처하면 지금 편집 창은 닫힙니다. 계속할까요?"
            , "ClassZoom — 캡처", "YesNo Icon? Default2") != "Yes")
            return
        cap.gui.Hide()
    }
    ; 스크롤 캡처는 확대를 끄고(휠·찍는 자리가 어긋난다) 드로잉도 끈다. 확대는 편집 창을 닫으면 다시 켠다.
    ; DPI 인식을 바꾸기 전에 해야 확대 창 좌표가 어긋나지 않는다.
    scrollZoom := 0
    if (mode = "scroll") {
        if zoomOn {
            scrollZoom := zoomStep, capZoomResume := zoomStep
            ZoomStop()
            t0 := A_TickCount
            while (zoomVisible && A_TickCount - t0 < 1500) ; 부드럽게 줄어드는 동안 기다린다
                Sleep(20)
        }
        if drawOn
            ToggleDraw()
    }
    ; 고르기·찍기는 "모니터마다 DPI 인식" 상태로 한다 (아래 CapDpiBegin 설명). 편집 창은 원래 상태로 띄운다.
    oldDpi := CapDpiBegin()
    try {
        if (mode = "scroll")
            pBmp := CapScrollShot(&rect)
        else if (mode = "window")
            rect := CapPickWindow()
        else if (mode = "area")
            rect := CapPickArea()
        else
            rect := RecMonitorRect() ; 커서가 있는 모니터 (확대 중이면 확대 화면 그대로)
        if (mode != "scroll")
            pBmp := IsObject(rect) ? CapGrab(rect) : 0
    } finally
        CapDpiEnd(oldDpi)
    if (!IsObject(rect) || !pBmp) {
        if IsObject(rect)
            MsgBox("화면을 캡처하지 못했습니다.", "ClassZoom — 캡처", "Icon!")
        if (hadEditor && IsObject(cap))
            cap.gui.Show()
        if (scrollZoom && !zoomOn) { ; 스크롤 캡처를 취소했다 → 껐던 확대를 되돌린다
            capZoomResume := 0
            ZoomStart(scrollZoom)
        }
        return
    }
    CapToClipboard(pBmp) ; 찍자마자 붙여넣기할 수 있게
    if IsObject(cap)
        CapCloseEditor(true)
    CapOpenEditor(pBmp)
    if (mode = "scroll" && capScrollNote != "")
        try cap.status.Value := capScrollNote
}

; ---------------- 화질: 실제 화면 픽셀 그대로 찍기 ----------------
; ClassZoom(AutoHotkey)은 "시스템 DPI 인식" 프로그램이다. 로그인한 뒤 디스플레이 배율(125%·150%)을 바꿨거나
; 모니터마다 배율이 다르면, Windows가 이런 프로그램에는 화면을 **줄인 좌표·줄인 그림**으로 보여 주고 다시 늘린다.
; 그 상태로 찍으면 글자가 뿌옇게 번진다(2026-11-25 제보: 캡처 화질 저하). 찍는 동안만 이 스레드를
; "모니터마다 DPI 인식 v2"로 바꿔 좌표·창 크기·화면 그림을 모두 실제 픽셀로 받는다. (Windows 10 1607 이상)
CapDpiBegin() {
    try return DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr") ; DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    return 0
}
CapDpiEnd(old) {
    if old
        try DllCall("SetThreadDpiAwarenessContext", "ptr", old, "ptr")
}

; 가상 화면(모든 모니터) — 지금 스레드의 DPI 상태 기준으로 다시 읽는다 (시작할 때 읽어 둔 vx 등은 시스템 DPI 기준)
CapVirtualScreen(&x, &y, &w, &h) {
    x := DllCall("GetSystemMetrics", "int", 76), y := DllCall("GetSystemMetrics", "int", 77)
    w := DllCall("GetSystemMetrics", "int", 78), h := DllCall("GetSystemMetrics", "int", 79)
}

; ---------------- 고르는 동안의 키·클릭 ----------------
CapPickingNow(*) {
    global capPicking, capScrolling
    return capPicking || capScrolling
}
CapEscCancel(*) {
    global capCancel
    capCancel := true
}
HotIf(CapPickingNow)
Hotkey("Esc", CapEscCancel, "On") ; 고르기 취소 · 스크롤 캡처 멈춤. 라이브 줌 Esc(실행 중 처음 확대할 때 만든다)보다 먼저 만들어 이쪽이 이긴다
HotIf()

; 고르기 시작: 화면 전체에 거의 투명한 덮개 창을 깔아 클릭·끌기를 받는다.
; 예전에는 마우스 버튼을 단축키로 삼켜(*LButton) 막았는데, 그 방식에서는 누른 채 끌어 구역을 고르는 것이
; 동작하지 않았다(2026-11-25 제보). 녹화 영역 고르기와 같은 덮개 방식이면 클릭이 뒤 프로그램·드로잉 판으로
; 가지 않으면서 끌기도 그대로 받는다. 덮개는 ClassZoom 창이라 CapWindowAt이 건너뛰고, 캡처에는 찍히지 않는다.
CapPickBegin() {
    global capPicking, capCancel, drawOn, drawGui, capCatch
    KeyWait("LButton"), KeyWait("RButton") ; 위젯 버튼을 누른 손을 뗀 뒤부터
    capCancel := false
    capPicking := true
    if drawOn {
        SetTimer(DrawPoll, 0)
        try WinSetExStyle("+0x20", drawGui) ; 터치·펜 입력도 판서 층으로 가지 않게
    }
    CapVirtualScreen(&x, &y, &w, &h)
    capCatch := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000000", "ClassZoom-CapCatch")
    capCatch.BackColor := "000000"
    capCatch.Show("NA x" x " y" y " w" w " h" h)
    WinSetTransparent(1, capCatch) ; 눈에는 안 보이지만(1/255) 클릭은 받는다
    RecExclude(capCatch.Hwnd)
    ZoomKeepOrder(true)
}

CapPickEnd() {
    global capPicking, drawOn, drawGui, inkPinned, capCatch
    ; 버튼을 뗀 뒤에 덮개를 치워야 뗀 것이 뒤 프로그램에 가지 않는다
    t0 := A_TickCount
    while ((GetKeyState("LButton", "P") || GetKeyState("RButton", "P")) && A_TickCount - t0 < 3000)
        Sleep(10)
    if IsObject(capCatch)
        try capCatch.Destroy()
    capCatch := ""
    capPicking := false
    if drawOn {
        if !inkPinned
            try WinSetExStyle("-0x20", drawGui)
        SetTimer(DrawPoll, 10)
    }
    CapHideHint()
    CapHideFrame()
}

CapPickCancelled() {
    global capCancel
    return capCancel || GetKeyState("Esc", "P") || GetKeyState("RButton", "P")
}

; ---------------- 창 고르기 (끌면 구역) ----------------
; 클릭하면 마우스 아래 창, 누른 채 끌면 그 구역을 찍는다 (픽픽처럼 F6 하나로 둘 다).
CAP_DRAG_PX := 6 ; 이만큼 움직여야 "끌기"로 본다 (손떨림으로 클릭이 구역이 되지 않게)
CapPickWindow(hint := "클릭하면 창 · 끌면 구역을 캡처합니다   ·   Esc 취소") {
    global CAP_DRAG_PX, capPickPt
    rect := "", capPickPt := ""
    CapPickBegin()
    try {
        CapShowHint(hint)
        lastKey := "-"
        loop {
            if CapPickCancelled()
                break
            MouseGetPos(&mx, &my)
            h := CapWindowAt(mx, my)
            r := h ? CapWindowRect(h) : ""
            key := IsObject(r) ? r.x "," r.y "," r.w "," r.h : ""
            if (key != lastKey) {
                lastKey := key
                IsObject(r) ? CapShowFrame(r) : CapHideFrame()
            }
            if GetKeyState("LButton", "P") {
                ; 누른 자리 (확대 중이면 확대 화면에 보이는 자리)
                MouseGetPos(&rx1, &ry1)
                capPickPt := {x: rx1, y: ry1}
                x1 := rx1, y1 := ry1
                ZoomScreenPos(&x1, &y1)
                x2 := x1, y2 := y1, dragging := false
                while GetKeyState("LButton", "P") {
                    if CapPickCancelled() {
                        RecHideFrame()
                        break 2
                    }
                    MouseGetPos(&rx2, &ry2)
                    x2 := rx2, y2 := ry2
                    ZoomScreenPos(&x2, &y2)
                    if (!dragging && (Abs(rx2 - rx1) >= CAP_DRAG_PX || Abs(ry2 - ry1) >= CAP_DRAG_PX)) {
                        dragging := true
                        CapHideFrame() ; 창 테두리 대신 끄는 구역 테두리
                        CapShowHint(InStr(hint, "스크롤") ? "놓으면 이 구역을 스크롤하며 캡처합니다   ·   Esc 취소" : "놓으면 이 구역을 캡처합니다   ·   Esc 취소")
                    }
                    if dragging
                        RecShowFrame({x: Min(x1, x2), y: Min(y1, y2), w: Abs(x2 - x1), h: Abs(y2 - y1)})
                    Sleep(10)
                }
                if dragging {
                    RecHideFrame()
                    w := Abs(x2 - x1), hh := Abs(y2 - y1)
                    if (w >= 8 && hh >= 8)
                        rect := {x: Min(x1, x2), y: Min(y1, y2), w: w, h: hh}
                } else
                    rect := r
                break
            }
            Sleep(25)
        }
    } finally {
        RecHideFrame()
        CapPickEnd()
    }
    return rect
}

; 화면 좌표 (x, y)에 보이는 맨 위 창. ClassZoom 자신의 창(위젯·드로잉 판·안내 등)은 건너뛴다.
CapWindowAt(x, y) {
    myPid := ProcessExist()
    for h in WinGetList() { ; 위에서 아래 순서, 보이는 창만
        try {
            if (WinGetPID(h) = myPid || WinGetMinMax(h) = -1)
                continue
            ex := WinGetExStyle(h)
            if ((ex & 0x20) && (ex & 0x80000)) ; 클릭이 통과하는 투명 창 (다른 프로그램의 덧그림)
                continue
            cloaked := 0
            DllCall("dwmapi\DwmGetWindowAttribute", "ptr", h, "uint", 14, "uint*", &cloaked, "uint", 4) ; DWMWA_CLOAKED (다른 데스크톱·숨은 앱)
            if cloaked
                continue
            CapRawRect(h, &l, &t, &r, &b)
            if (x >= l && x < r && y >= t && y < b && r - l > 1 && b - t > 1)
                return h
        }
    }
    return 0
}

; 창의 보이는 테두리 (Windows 10/11 창의 투명한 바깥 여백은 뺀다)
CapRawRect(h, &l, &t, &r, &b) {
    rc := Buffer(16, 0)
    if DllCall("dwmapi\DwmGetWindowAttribute", "ptr", h, "uint", 9, "ptr", rc, "uint", 16) != 0 ; DWMWA_EXTENDED_FRAME_BOUNDS
        DllCall("GetWindowRect", "ptr", h, "ptr", rc)
    l := NumGet(rc, 0, "Int"), t := NumGet(rc, 4, "Int"), r := NumGet(rc, 8, "Int"), b := NumGet(rc, 12, "Int")
}

; 찍을 범위. 바탕화면이면 모니터 전체. 확대 중이면 확대 화면에서 그 창이 보이는 자리로 옮긴다.
CapWindowRect(h) {
    global zoomVisible, zoomML, zoomMT, zoomMW, zoomMH
    CapVirtualScreen(&vx, &vy, &vw, &vh)
    cls := ""
    try cls := WinGetClass(h)
    if (cls = "Progman" || cls = "WorkerW")
        return RecMonitorRect()
    CapRawRect(h, &l, &t, &r, &b)
    if zoomVisible {
        ZoomScreenPos(&l, &t), ZoomScreenPos(&r, &b)
        l := Max(l, zoomML), t := Max(t, zoomMT), r := Min(r, zoomML + zoomMW), b := Min(b, zoomMT + zoomMH)
    }
    l := Max(l, vx), t := Max(t, vy), r := Min(r, vx + vw), b := Min(b, vy + vh)
    if (r - l < 4 || b - t < 4)
        return ""
    return {x: l, y: t, w: r - l, h: b - t}
}

; ---------------- 구역 고르기 ----------------
; 화면을 살짝 어둡게 덮고 끌어서 고른다 (녹화 영역 고르기와 같은 방식). 확대 중이면 보이는 자리 기준.
CapPickArea() {
    global capDim
    CapVirtualScreen(&vx, &vy, &vw, &vh)
    rect := ""
    CapPickBegin()
    try {
        capDim := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000000", "ClassZoom-CapPick")
        capDim.BackColor := "000000"
        capDim.Show("NA x" vx " y" vy " w" vw " h" vh)
        WinSetTransparent(60, capDim)
        RecExclude(capDim.Hwnd)
        CapShowHint("캡처할 구역을 마우스로 끌어 주세요   ·   Esc 취소")
        DllCall("SetCursor", "ptr", DllCall("LoadCursor", "ptr", 0, "ptr", 32515, "ptr")) ; 십자
        loop {
            if CapPickCancelled()
                break
            if GetKeyState("LButton", "P") {
                MouseGetPos(&x1, &y1)
                ZoomScreenPos(&x1, &y1)
                x2 := x1, y2 := y1
                while GetKeyState("LButton", "P") {
                    if CapPickCancelled()
                        break 2
                    MouseGetPos(&x2, &y2)
                    ZoomScreenPos(&x2, &y2)
                    RecShowFrame({x: Min(x1, x2), y: Min(y1, y2), w: Abs(x2 - x1), h: Abs(y2 - y1)})
                    Sleep(10)
                }
                w := Abs(x2 - x1), h := Abs(y2 - y1)
                if (w >= 8 && h >= 8)
                    rect := {x: Min(x1, x2), y: Min(y1, y2), w: w, h: h}
                break
            }
            Sleep(10)
        }
    } finally {
        if IsObject(capDim)
            try capDim.Destroy()
        capDim := ""
        RecHideFrame()
        CapPickEnd()
    }
    return rect
}

; ---------------- 안내 · 테두리 (캡처·녹화에 찍히지 않는다) ----------------
CapShowHint(text) {
    global capHint
    CapHideHint()
    MouseGetPos(&mx, &my)
    if !GetMonitorAt(mx, my, &ml, &mt, &mr, &mb, &wl, &wt, &wr, &wb)
        ml := 0, mt := 0, mr := A_ScreenWidth
    capHint := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000020", "ClassZoom-CapHint")
    capHint.BackColor := "1E293B"
    capHint.MarginX := 18, capHint.MarginY := 10
    capHint.SetFont("s12 bold cFFFFFF", "Malgun Gothic")
    capHint.AddText("", text)
    capHint.Show("AutoSize Hide")
    capHint.GetPos(, , &hw)
    capHint.Show("NA x" (ml + (mr - ml - hw) // 2) " y" (mt + 24))
    RecExclude(capHint.Hwnd)
    ZoomKeepOrder(true)
}

CapHideHint() {
    global capHint
    if IsObject(capHint)
        try capHint.Destroy()
    capHint := ""
}

; 고른 창 **안쪽**에 빨간 테두리 (최대화한 창도 보이게)
CapShowFrame(r) {
    global capFrames, CAP_FRAME_PX
    b := CAP_FRAME_PX
    if (capFrames.Length = 0)
        loop 4 {
            g := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08080020", "ClassZoom-CapFrame")
            g.BackColor := "EF4444"
            g.Show("NA x0 y0 w1 h1")
            DllCall("SetLayeredWindowAttributes", "ptr", g.Hwnd, "uint", 0, "uchar", 255, "uint", 2)
            RecExclude(g.Hwnd)
            capFrames.Push(g)
        }
    pos := [[r.x, r.y, r.w, b], [r.x, r.y + r.h - b, r.w, b], [r.x, r.y, b, r.h], [r.x + r.w - b, r.y, b, r.h]]
    for i, p in pos
        DllCall("SetWindowPos", "ptr", capFrames[i].Hwnd, "ptr", -1, "int", p[1], "int", p[2]
            , "int", Max(1, p[3]), "int", Max(1, p[4]), "uint", 0x10 | 0x40) ; NOACTIVATE | SHOWWINDOW
    ZoomKeepOrder(true)
}

CapHideFrame() {
    global capFrames
    for g in capFrames
        try g.Destroy()
    capFrames := []
}

; 확대 중에도 확대 화면 위(확대하지 않고)에 보여야 하는 캡처 창들 (zoom.ahk ZoomTopHwnds가 부른다)
CapTopHwnds() {
    global capHint, capDim, capFrames, capCatch, capScrollPanel
    list := []
    for g in [capCatch, capDim, capHint, capScrollPanel]
        if IsObject(g)
            try list.Push(g.Hwnd)
    for g in capFrames
        try list.Push(g.Hwnd)
    return list
}

; ---------------- 찍기 ----------------
; 보이는 화면 그대로 찍는다(확대 화면·그린 그림 포함). 위젯·강조 원·커서 노릇을 하는 원은 잠깐 감춘다.
CapGrab(r) {
    hidden := CapHideOurs()
    Sleep(hidden.Length ? 150 : 60) ; 감춘 것이 화면(확대 화면 포함)에서 빠질 때까지
    pBmp := 0
    try pBmp := CapGrabRaw(r)
    CapShowOurs(hidden)
    return pBmp
}

; 찍을 때 빼는 우리 창을 감춘다 (withInk = 드로잉 판도: 스크롤 캡처는 그린 그림이 따라 움직이지 않아 이어 붙이기를 망친다)
CapHideOurs(withInk := false) {
    global widget, spotGui, brushGui, zoomCursorGui, drawGui
    hidden := []
    list := [IsSet(widget) ? widget : "", spotGui, brushGui, zoomCursorGui]
    if withInk
        list.Push(drawGui)
    for g in list
        if (IsObject(g) && DllCall("IsWindowVisible", "ptr", g.Hwnd)) {
            DllCall("ShowWindow", "ptr", g.Hwnd, "int", 0)
            hidden.Push(g.Hwnd)
        }
    ToolTip(, , , 19) ; 위젯 설명 풍선
    return hidden
}

CapShowOurs(hidden) {
    for h in hidden
        DllCall("ShowWindow", "ptr", h, "int", 8) ; SW_SHOWNA
    RaiseWidget()
}

; 화면의 r 자리를 그대로 GDI+ 그림(32비트 ARGB)으로 찍는다. 실패하면 0
CapGrabRaw(r) {
    hdcS := DllCall("GetDC", "ptr", 0, "ptr")
    hdcM := DllCall("CreateCompatibleDC", "ptr", hdcS, "ptr")
    hbm := DllCall("CreateCompatibleBitmap", "ptr", hdcS, "int", r.w, "int", r.h, "ptr")
    old := DllCall("SelectObject", "ptr", hdcM, "ptr", hbm, "ptr")
    DllCall("BitBlt", "ptr", hdcM, "int", 0, "int", 0, "int", r.w, "int", r.h
        , "ptr", hdcS, "int", r.x, "int", r.y, "uint", 0x40CC0020) ; SRCCOPY | CAPTUREBLT (투명 창까지)
    DllCall("SelectObject", "ptr", hdcM, "ptr", old)
    DllCall("DeleteDC", "ptr", hdcM)
    DllCall("ReleaseDC", "ptr", 0, "ptr", hdcS)
    pTmp := 0, pBmp := 0
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "ptr", hbm, "ptr", 0, "ptr*", &pTmp)
    DllCall("DeleteObject", "ptr", hbm)
    if pTmp {
        pBmp := CapCloneArea(pTmp, 0, 0, r.w, r.h)
        DllCall("gdiplus\GdipDisposeImage", "ptr", pTmp)
    }
    return pBmp
}

; ================= 스크롤 캡처 (Ctrl+F6) =================
; 창을 클릭하거나 구역을 끌면, 그 자리에서 휠을 조금씩 굴려 내리며 찍고 새로 드러난 줄만 이어 붙인다.
;   - 겹치는 자리 찾기: 줄마다 지문(표본 픽셀의 해시)을 만들고, 앞 장과 새 장에서 같은 지문이 몇 줄 차이로
;     나타나는지 표를 던져 가장 많이 나온 차이(= 스크롤한 거리)를 고른다. 안 되면 줄 밝기 합으로 한 번 더 찾는다.
;   - 머리·바닥 고정 줄: 처음 두 장에서 위·아래에 그대로 있는 줄(창 제목·도구 막대·고정 메뉴)은 맞추기에서 빼고,
;     머리는 첫 장에서, 바닥은 마지막 장에서 한 번만 넣는다.
;   - 멈추는 때: 휠을 굴려도 화면이 그대로면(끝에 닿음) · Esc · [멈춤] 버튼 · 최대 높이. 멈추면 거기까지 이은 그림을 쓴다.
;   - 키 겹침: 찍는 동안 Esc는 "멈춤"으로만 쓴다(CapPickingNow). 확대·드로잉은 CapRun이 먼저 끈다.
;     화면에 남겨 둔 그림은 찍는 동안 감춘다(따라 움직이지 않아 이어 붙이기를 망친다).
CapScrollShot(&rect) {
    global capPickPt, capScrolling, capCancel, capScrollNote
    rect := "", capScrollNote := ""
    rect := CapPickWindow("스크롤할 창을 클릭하거나 구역을 끌어 주세요   ·   Esc 취소")
    if (IsObject(rect) && (rect.w < 40 || rect.h < 80)) {
        MsgBox("스크롤 캡처는 높이 80px 이상인 구역에서만 됩니다.", "ClassZoom — 스크롤 캡처", "Icon!")
        rect := ""
    }
    if !IsObject(rect)
        return 0
    ; 휠을 굴릴 자리: 창을 클릭했으면 누른 자리, 구역이면 가운데
    r := rect
    pt := {x: r.x + r.w // 2, y: r.y + r.h // 2}
    if (IsObject(capPickPt) && capPickPt.x >= r.x && capPickPt.x < r.x + r.w && capPickPt.y >= r.y && capPickPt.y < r.y + r.h)
        pt := capPickPt
    MouseGetPos(&ox, &oy)
    hidden := CapHideOurs(true)
    capCancel := false, capScrolling := true
    pBmp := 0
    try {
        RecShowFrame(r)
        CapScrollShowPanel(r)
        Sleep(150)
        pBmp := CapScrollRun(r, pt)
    } finally {
        capScrolling := false
        CapScrollHidePanel()
        RecHideFrame()
        CapShowOurs(hidden)
        DllCall("SetCursorPos", "int", ox, "int", oy)
    }
    return pBmp
}

; 휠을 굴리고 찍고 이어 붙이기를 되풀이한다. 다 이은 그림(GDI+)을 돌려준다
CapScrollRun(r, pt) {
    global capCancel, capScrollNote, CAP_SCROLL_WAIT_MS, CAP_SCROLL_MAX_H, CAP_SCROLL_MAX_STEPS
    w := r.w, h := r.h
    prev := CapGrabRaw(r)
    if !prev
        return 0
    ph := CapRowSigs(prev, w, h)
    strips := [], total := 0
    top := -1, bot := 0
    notches := 1, why := "end"
    loop CAP_SCROLL_MAX_STEPS {
        if capCancel {
            why := "stop"
            break
        }
        CapWheel(pt, notches)
        ; 화면이 바뀔 때까지 (부드러운 스크롤·늦게 그리는 페이지는 조금 더 기다린다)
        cur := 0
        loop 3 {
            Sleep(CAP_SCROLL_WAIT_MS * A_Index)
            if capCancel
                break
            c := CapGrabRaw(r)
            if !c
                break
            chs := CapRowSigs(c, w, h)
            if !CapSigsEqual(ph, chs) {
                cur := c
                break
            }
            DllCall("gdiplus\GdipDisposeImage", "ptr", c)
        }
        if !cur {
            why := capCancel ? "stop" : "end"
            break
        }
        if (top < 0)
            CapStaticBands(ph, chs, h, &top, &bot)
        d := CapFindShift(ph, chs, h, top, bot)
        if (d <= 0) {
            DllCall("gdiplus\GdipDisposeImage", "ptr", cur)
            why := "lost"
            break
        }
        if (strips.Length = 0) { ; 첫 장: 머리부터 바닥 고정 줄 위까지
            strips.Push(CapCloneArea(prev, 0, 0, w, h - bot))
            total := h - bot
        }
        strips.Push(CapCloneArea(cur, 0, h - bot - d, w, d)) ; 새로 드러난 줄
        total += d
        DllCall("gdiplus\GdipDisposeImage", "ptr", prev)
        prev := cur, ph := chs
        ; 다음 휠: 한 번에 보이는 높이의 60%쯤 움직이게 (겹치는 줄이 남아야 맞출 수 있다)
        band := h - top - bot
        notches := Max(1, Min(15, Floor(band * 0.6 / Max(1, d / notches))))
        CapScrollUpdatePanel(strips.Length, total)
        if (total >= CAP_SCROLL_MAX_H) {
            why := "max"
            break
        }
    }
    if (strips.Length = 0) { ; 한 번도 내려가지 않았다 → 그 화면 한 장
        capScrollNote := "스크롤할 내용이 없어 보이는 화면 한 장만 찍었습니다. 클립보드에 복사했습니다."
        return prev
    }
    if (bot > 0) {
        strips.Push(CapCloneArea(prev, 0, h - bot, w, bot)) ; 바닥 고정 줄은 마지막 장에서
        total += bot
    }
    DllCall("gdiplus\GdipDisposeImage", "ptr", prev)
    out := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", w, "int", total, "int", 0, "int", 0x26200A, "ptr", 0, "ptr*", &out)
    if out {
        G := 0
        DllCall("gdiplus\GdipGetImageGraphicsContext", "ptr", out, "ptr*", &G)
        DllCall("gdiplus\GdipSetCompositingMode", "ptr", G, "int", 1)
        y := 0
        for p in strips {
            CapImageSize(p, &sw, &sh)
            DllCall("gdiplus\GdipDrawImageRectRectI", "ptr", G, "ptr", p, "int", 0, "int", y, "int", sw, "int", sh
                , "int", 0, "int", 0, "int", sw, "int", sh, "int", 2, "ptr", 0, "ptr", 0, "ptr", 0) ; UnitPixel
            y += sh
        }
        DllCall("gdiplus\GdipDeleteGraphics", "ptr", G)
    }
    for p in strips
        DllCall("gdiplus\GdipDisposeImage", "ptr", p)
    msg := Map("end", "끝까지 스크롤해 이어 붙였습니다."
        , "stop", "멈춘 곳까지 이어 붙였습니다."
        , "max", "최대 길이(" CAP_SCROLL_MAX_H "px)에 닿아 멈췄습니다."
        , "lost", "화면이 이어지는 자리를 찾지 못해 거기서 멈췄습니다 (움직이는 그림·고정된 배경이 많은 화면).")[why]
    capScrollNote := "스크롤 캡처: " msg " 높이 " total "px · 클립보드에 복사했습니다."
    return out
}

; 휠을 n칸 아래로 굴린다 (그 자리의 창이 받는다: Windows 10/11은 앞 창이 아니어도 휠을 받는다)
CapWheel(pt, n) {
    loop n {
        DllCall("SetCursorPos", "int", pt.x, "int", pt.y) ; 사용자가 마우스를 움직였어도 그 자리로
        DllCall("mouse_event", "uint", 0x0800, "uint", 0, "uint", 0, "int", -120, "uptr", 0) ; MOUSEEVENTF_WHEEL
        Sleep(15)
    }
}

; 줄마다 지문: 한 줄에서 표본 픽셀 128개쯤을 골라 해시한다. 한 색으로만 된 줄(여백)은 맞추기에 쓰지 않도록 음수로 둔다.
; 돌려주는 것: {k: 지문 배열(1부터), s: 밝기 합 배열, n: 한 줄의 표본 수}
CapRowSigs(p, w, h) {
    rc := Buffer(16, 0)
    NumPut("int", 0, "int", 0, "int", w, "int", h, rc)
    bd := Buffer(16 + 2 * A_PtrSize, 0)
    if DllCall("gdiplus\GdipBitmapLockBits", "ptr", p, "ptr", rc, "uint", 1, "int", 0x26200A, "ptr", bd) != 0 ; ReadOnly
        return {k: [], s: [], n: 1}
    stride := NumGet(bd, 8, "int"), scan := NumGet(bd, 16, "ptr")
    step := Max(1, w // 128), x0 := step // 2
    ks := [], ss := []
    ks.Capacity := h, ss.Capacity := h
    loop h {
        row := scan + (A_Index - 1) * stride
        first := NumGet(row, x0 * 4, "uint") & 0xFFFFFF
        hv := 2166136261, uni := true, sum := 0, x := x0
        while (x < w) {
            px := NumGet(row, x * 4, "uint") & 0xFFFFFF
            if (px != first)
                uni := false
            hv := ((hv ^ px) * 16777619) & 0xFFFFFFFF
            sum += (px & 0xFF) + ((px >> 8) & 0xFF) + (px >> 16)
            x += step
        }
        ks.Push(uni ? -(first + 1) : hv + 1)
        ss.Push(sum)
    }
    DllCall("gdiplus\GdipBitmapUnlockBits", "ptr", p, "ptr", bd)
    return {k: ks, s: ss, n: Max(1, Ceil((w - x0) / step))}
}

CapSigsEqual(a, b) {
    if (a.k.Length != b.k.Length)
        return false
    for i, v in a.k
        if (v != b.k[i])
            return false
    return true
}

; 위·아래에서 두 장이 그대로인 줄 수 (각각 높이의 1/3까지)
CapStaticBands(a, b, h, &top, &bot) {
    lim := h // 3
    top := 0, bot := 0
    while (top < lim && a.k[top + 1] = b.k[top + 1])
        top++
    while (bot < lim && a.k[h - bot] = b.k[h - bot])
        bot++
}

; 새 장의 y줄 = 앞 장의 y+d줄이 되는 d(스크롤한 거리, px). 못 찾으면 0
CapFindShift(a, b, h, top, bot) {
    lo := top + 1, hi := h - bot
    if (hi - lo < 8)
        return 0
    ; 1) 지문 표 던지기: 앞 장에 드물게(3번 이하) 나오는 지문만 쓴다 (반복 무늬에 속지 않게)
    pos := Map()
    y := lo
    while (y <= hi) {
        v := a.k[y]
        if (v > 0)
            pos.Has(v) ? pos[v].Push(y) : pos[v] := [y]
        y++
    }
    votes := Map()
    y := lo
    while (y <= hi) {
        v := b.k[y]
        if (v > 0 && pos.Has(v) && pos[v].Length <= 3)
            for py in pos[v]
                if (py > y)
                    votes[py - y] := votes.Get(py - y, 0) + 1
        y++
    }
    best := 0, bestN := 0
    for d, n in votes
        if (n > bestN || (n = bestN && d < best))
            best := d, bestN := n
    if (best && bestN >= 3) {
        cmp := 0, ok := 0, y := lo
        while (y <= hi - best) {
            if (b.k[y] > 0 || a.k[y + best] > 0) {
                cmp++
                ok += (b.k[y] = a.k[y + best])
            }
            y++
        }
        if (cmp >= 3 && ok / cmp >= 0.7)
            return best
    }
    ; 2) 밝기 합으로 찾기 (글자가 반 픽셀씩 다르게 그려지는 화면). 겹침이 16줄 이상인 d 가운데 차이가 가장 작은 것
    bestD := 0, bestE := -1, n := hi - lo + 1
    d := 1
    while (d <= n - 16) {
        e := 0, c := 0, vsum := 0, y := lo
        while (y <= hi - d) {
            e += Abs(b.s[y] - a.s[y + d])
            vsum += Abs(b.s[y] - b.s[lo])
            c++
            y += 2
        }
        if (c && vsum > 0) {
            e := e / c
            if (bestE < 0 || e < bestE)
                bestE := e, bestD := d
        }
        d++
    }
    return (bestD && bestE <= a.n * 3 * 1.5) ? bestD : 0 ; 표본 하나·색 하나에 평균 1.5단계 차이까지
}

; ---------------- 스크롤 캡처 중 표시창 (멈춤 버튼, 캡처에 찍히지 않는다) ----------------
CapScrollShowPanel(r) {
    global capScrollPanel, capScrollInfo
    CapScrollHidePanel()
    g := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000000", "ClassZoom-CapScroll")
    g.BackColor := "1E293B"
    g.MarginX := 14, g.MarginY := 10
    g.SetFont("s11 bold cFFFFFF", "Malgun Gothic")
    capScrollInfo := g.AddText("w300 h24 +0x200", "스크롤하며 캡처하는 중…")
    g.SetFont("s10 norm c1E293B", "Malgun Gothic")
    b := g.AddButton("x+10 yp-2 w110 h28", "멈춤 (Esc)")
    b.OnEvent("Click", (*) => CapEscCancel())
    g.Show("AutoSize Hide")
    g.GetPos(, , &pw, &ph)
    ; 구역 위에 둘 자리가 있으면 위, 없으면 아래, 둘 다 없으면 구역 안 위쪽 (어디든 캡처에는 찍히지 않는다)
    if !GetMonitorAt(r.x + r.w // 2, r.y + r.h // 2, &ml, &mt, &mr, &mb, &wl, &wt, &wr, &wb)
        ml := 0, mt := 0, mr := A_ScreenWidth, mb := A_ScreenHeight
    x := Max(ml, Min(mr - pw, r.x + (r.w - pw) // 2))
    y := (r.y - ph - 10 >= mt) ? r.y - ph - 10 : (r.y + r.h + ph + 10 <= mb) ? r.y + r.h + 10 : r.y + 10
    g.Show("NA x" x " y" y)
    RecExclude(g.Hwnd)
    capScrollPanel := g
}

CapScrollUpdatePanel(n, total) {
    global capScrollInfo
    try capScrollInfo.Value := "스크롤하며 캡처하는 중…  " (n - 1) "번 내림 · 높이 " total "px"
}

CapScrollHidePanel() {
    global capScrollPanel, capScrollInfo
    if IsObject(capScrollPanel)
        try capScrollPanel.Destroy()
    capScrollPanel := "", capScrollInfo := ""
}

; 32비트 ARGB로 잘라 복사한다 (편집할 때 그 위에 그린다)
CapCloneArea(p, x, y, w, h) {
    out := 0
    DllCall("gdiplus\GdipCloneBitmapAreaI", "int", x, "int", y, "int", w, "int", h, "int", 0x26200A, "ptr", p, "ptr*", &out)
    return out
}

CapImageSize(p, &w, &h) {
    w := 0, h := 0
    DllCall("gdiplus\GdipGetImageWidth", "ptr", p, "uint*", &w)
    DllCall("gdiplus\GdipGetImageHeight", "ptr", p, "uint*", &h)
}

CapGraphics(p) {
    G := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "ptr", p, "ptr*", &G)
    DllCall("gdiplus\GdipSetSmoothingMode", "ptr", G, "int", 4)      ; 안티앨리어스
    DllCall("gdiplus\GdipSetTextRenderingHint", "ptr", G, "int", 4)  ; 글자 매끄럽게
    return G
}

; ---------------- 클립보드 · 파일 ----------------
; 그림을 CF_DIB로 클립보드에 넣는다 (한글·파워포인트·카카오톡·그림판 어디에나 붙는다)
CapToClipboard(pBmp) {
    hbm := 0
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "ptr", pBmp, "ptr*", &hbm, "uint", 0xFFFFFFFF)
    if !hbm
        return false
    ds := Buffer(A_PtrSize = 8 ? 104 : 84, 0) ; DIBSECTION
    DllCall("GetObject", "ptr", hbm, "int", ds.Size, "ptr", ds)
    bits := NumGet(ds, A_PtrSize = 8 ? 24 : 20, "ptr")
    size := NumGet(ds, 12, "Int") * Abs(NumGet(ds, 8, "Int")) ; 한 줄 바이트 × 높이
    hdr := A_PtrSize = 8 ? 32 : 24                              ; BITMAPINFOHEADER 자리
    hMem := DllCall("GlobalAlloc", "uint", 0x42, "uptr", 40 + size, "ptr")
    p := DllCall("GlobalLock", "ptr", hMem, "ptr")
    DllCall("RtlMoveMemory", "ptr", p, "ptr", ds.Ptr + hdr, "uptr", 40)
    NumPut("UInt", 0, p, 16)    ; BI_RGB
    NumPut("UInt", size, p, 20) ; biSizeImage
    DllCall("RtlMoveMemory", "ptr", p + 40, "ptr", bits, "uptr", size)
    DllCall("GlobalUnlock", "ptr", hMem)
    DllCall("DeleteObject", "ptr", hbm)
    ok := false
    ; PNG도 함께 넣는다. 오피스·한글·브라우저·포토샵은 PNG를 먼저 집어 가서 색·글자가 그대로 붙는다
    ; (32비트 DIB만 있으면 일부 프로그램이 다시 변환하면서 흐려지거나 배경이 검게 붙는다)
    hPng := CapPngHGlobal(pBmp)
    ok := false
    loop 20 { ; 다른 프로그램이 클립보드를 잠깐 쥐고 있을 수 있다
        if DllCall("OpenClipboard", "ptr", A_ScriptHwnd) {
            DllCall("EmptyClipboard")
            ok := DllCall("SetClipboardData", "uint", 8, "ptr", hMem, "ptr") != 0 ; CF_DIB
            if (hPng && !DllCall("SetClipboardData", "uint", DllCall("RegisterClipboardFormat", "str", "PNG", "uint"), "ptr", hPng, "ptr"))
                DllCall("GlobalFree", "ptr", hPng)
            hPng := 0
            DllCall("CloseClipboard")
            break
        }
        Sleep(25)
    }
    if !ok
        DllCall("GlobalFree", "ptr", hMem)
    if hPng
        DllCall("GlobalFree", "ptr", hPng)
    return ok
}

; 그림을 PNG 파일 내용 그대로 메모리(HGLOBAL)에 담는다 (클립보드 "PNG" 형식). 실패하면 0
CapPngHGlobal(pBmp) {
    pStream := 0, hMem := 0
    if DllCall("ole32\CreateStreamOnHGlobal", "ptr", 0, "int", false, "ptr*", &pStream) != 0
        return 0
    clsid := Buffer(16, 0)
    DllCall("ole32\CLSIDFromString", "wstr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "ptr", clsid)
    if (DllCall("gdiplus\GdipSaveImageToStream", "ptr", pBmp, "ptr", pStream, "ptr", clsid, "ptr", 0) = 0)
        DllCall("ole32\GetHGlobalFromStream", "ptr", pStream, "ptr*", &hMem)
    ObjRelease(pStream) ; fDeleteOnRelease = false 라서 메모리는 남는다
    return hMem
}

; 저장 폴더: 사진\ClassZoom
CapSaveFolder() {
    p := ""
    try p := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders", "My Pictures")
    if (p = "")
        p := EnvGet("USERPROFILE") "\Pictures"
    return p "\ClassZoom"
}

CapSaveBitmap(pBmp, path) {
    ext := StrLower(RegExReplace(path, ".*\."))
    clsid := Buffer(16, 0)
    DllCall("ole32\CLSIDFromString", "wstr", (ext = "jpg" || ext = "jpeg")
        ? "{557CF401-1A04-11D3-9A73-0000F81EF32E}" : "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "ptr", clsid)
    return DllCall("gdiplus\GdipSaveImageToFile", "ptr", pBmp, "wstr", path, "ptr", clsid, "ptr", 0) = 0
}

; ================= 편집 창 =================
CapOpenEditor(pBmp) {
    global cap, CAP_TOOLS, CAP_COLORS, CAP_COLOR_NAMES, drawOn, zoomOn, zoomStep, capZoomResume, drawGui, inkPinned
    ; 드로잉 판이 화면을 덮고 있으면 편집 창을 누를 수 없다 → 끈다 (그린 것은 남아 F9로 다시 보인다)
    if drawOn
        ToggleDraw()
    ; 확대 위에서는 편집 창을 누르는 자리가 어긋난다 → 잠시 끄고, 닫으면 같은 단계로 다시 켠다
    if zoomOn {
        capZoomResume := zoomStep
        ZoomStop()
    }
    dpi := A_ScreenDPI / 96
    CapImageSize(pBmp, &iw, &ih)
    ; 주의: AutoHotkey v2에서 base는 객체의 원형을 가리키는 예약 속성이라 그림 이름으로 쓰면 오류가 난다 (orig로 쓴다)
    cap := {orig: pBmp, comp: 0, view: 0, cache: 0, cacheOk: false, imgW: iw, imgH: ih
        , annots: [], history: [], tool: "pen", color: 1, size: 2, cur: "", dirty: false, saved: ""
        , cw: 0, ch: 0, s: 1, ox: 0, oy: 0, dpi: dpi}
    CapRebuild()

    g := Gui("+Resize +MinSize840x420 +0x2000000", "ClassZoom 캡처 편집") ; 0x2000000 = WS_CLIPCHILDREN (창이 그림판 위를 덧칠하지 않게 — 깜빡임 방지)
    cap.gui := g
    g.BackColor := "F1F5F9"
    g.SetFont("s10 c1E293B", "Malgun Gothic")
    ; ---- 1줄: 도구 · 되돌리기 ----
    cap.toolCtrls := Map()
    x := 10
    for t in CAP_TOOLS {
        c := g.AddText("x" x " y8 w70 h30 Center +0x200 +Border BackgroundFFFFFF", t[2])
        c.OnEvent("Click", CapSetTool.Bind(t[1]))
        cap.toolCtrls[t[1]] := c
        x += 74
    }
    btnUndo := g.AddButton("x" (x + 8) " y8 w110 h30", "되돌리기 (Ctrl+Z)")
    btnUndo.OnEvent("Click", (*) => CapUndo())
    ; ---- 2줄: 색 · 굵기 · 복사·저장 ----
    cap.colorCtrls := []
    x := 10
    for i, c in CAP_COLORS {
        light := ((c >> 16 & 0xFF) * 299 + (c >> 8 & 0xFF) * 587 + (c & 0xFF) * 114) / 1000 > 160
        sw := g.AddText("x" x " y46 w28 h28 Center +0x200 +Border Background" Format("{:06X}", c), "")
        sw.SetFont("s11 bold c" (light ? "000000" : "FFFFFF"))
        sw.OnEvent("Click", CapSetColor.Bind(i))
        cap.colorCtrls.Push(sw)
        x += 32
    }
    cap.sizeCtrls := []
    x += 10
    for i, label in ["가늘게", "보통", "굵게"] {
        c := g.AddText("x" x " y46 w54 h28 Center +0x200 +Border BackgroundFFFFFF", label)
        c.OnEvent("Click", CapSetSize.Bind(i))
        cap.sizeCtrls.Push(c)
        x += 58
    }
    x += 16
    btnCopy := g.AddButton("x" x " y45 w90 h30", "복사 (Ctrl+C)")
    btnSave := g.AddButton("x" (x + 94) " y45 w90 h30", "저장 (Ctrl+S)")
    btnSaveAs := g.AddButton("x" (x + 188) " y45 w100 h30", "다른 이름으로…")
    btnFolder := g.AddButton("x" (x + 292) " y45 w80 h30", "폴더 열기")
    btnCopy.OnEvent("Click", (*) => CapCopy())
    btnSave.OnEvent("Click", (*) => CapSave())
    btnSaveAs.OnEvent("Click", (*) => CapSaveAs())
    btnFolder.OnEvent("Click", (*) => CapOpenFolder())
    ; ---- 그림판 (static + SS_BITMAP 0xE + SS_NOTIFY 0x100: 마우스를 받는다) ----
    cap.canvas := g.AddText("x10 y84 w200 h200 +0x10E")
    cap.status := g.AddText("x10 y300 w600 h20 c475569", "클립보드에 복사했습니다. 바로 붙여넣기(Ctrl+V)할 수 있습니다.")
    g.OnEvent("Size", CapOnSize)
    g.OnEvent("Close", (*) => CapCloseEditor())
    CapUpdateToolbar()

    ; 창 크기: 그림이 원래 크기로 들어가게, 단 커서가 있는 모니터 작업 영역의 90%까지
    MouseGetPos(&mx, &my)
    if !GetMonitorAt(mx, my, &ml, &mt, &mr, &mb, &wl, &wt, &wr, &wb)
        wl := 0, wt := 0, wr := A_ScreenWidth, wb := A_ScreenHeight
    cwPx := Min(Max(iw + 20 * dpi, 860 * dpi), (wr - wl) * 0.9)
    chPx := Min(Max(ih + 120 * dpi, 440 * dpi), (wb - wt) * 0.9)
    g.Show("w" Round(cwPx / dpi) " h" Round(chPx / dpi) " Hide")
    WinGetPos(, , &ww, &wh, g)
    WinMove(wl + ((wr - wl) - ww) // 2, wt + ((wb - wt) - wh) // 2, , , g)
    g.Show()
    CapLayout()
}

CapEditorActive(*) {
    global cap, drawOn
    return IsObject(cap) && cap.HasOwnProp("gui") && !drawOn && WinActive("ahk_id " cap.gui.Hwnd)
}
HotIf(CapEditorActive)
Hotkey("^c", (*) => CapCopy(), "On")
Hotkey("^s", (*) => CapSave(), "On")
Hotkey("^+s", (*) => CapSaveAs(), "On")
Hotkey("^z", (*) => CapUndo(), "On")
HotIf()

CapOnSize(g, minMax, *) {
    global cap
    if (minMax = -1 || !IsObject(cap) || !cap.HasOwnProp("status")) ; 그림판·상태줄을 다 만들기 전에는 건너뛴다
        return
    rc := Buffer(16, 0)
    DllCall("GetClientRect", "ptr", g.Hwnd, "ptr", rc)
    d := cap.dpi
    w := NumGet(rc, 8, "Int") / d, h := NumGet(rc, 12, "Int") / d
    cap.canvas.Move(10, 84, Max(50, w - 20), Max(50, h - 84 - 30))
    cap.status.Move(10, h - 26, Max(50, w - 20), 20)
    CapLayout()
}

; 그림판 크기에 맞춰 보이는 배율·자리를 다시 정한다
CapLayout() {
    global cap
    if !CapCanvasHwnd()
        return
    rc := Buffer(16, 0)
    DllCall("GetClientRect", "ptr", cap.canvas.Hwnd, "ptr", rc)
    cw := NumGet(rc, 8, "Int"), ch := NumGet(rc, 12, "Int")
    if (cw < 10 || ch < 10)
        return
    if (cw != cap.cw || ch != cap.ch) {
        for k in ["view", "cache"]
            if cap.%k%
                DllCall("gdiplus\GdipDisposeImage", "ptr", cap.%k%)
        ; 화면에 보이는 그림(view)은 그림판(static)에 **한 번만** 붙여 둔 24비트 DIB의 메모리에 바로 그린다.
        ; 예전처럼 그릴 때마다 새 비트맵을 STM_SETIMAGE로 바꿔 끼우면 그때마다 바탕을 지웠다 다시 그려서
        ; 끌 때 깜빡였다(2026-11-25 제보). 24비트(알파 없음)라야 static이 복사본을 만들지 않고 이 메모리를 그대로 쓴다.
        stride := (cw * 3 + 3) & ~3
        bi := Buffer(40, 0)
        NumPut("UInt", 40, "Int", cw, "Int", -ch, "UShort", 1, "UShort", 24, bi) ; 위에서 아래로 (GDI+와 같은 순서)
        bits := 0
        hbm := DllCall("CreateDIBSection", "ptr", 0, "ptr", bi, "uint", 0, "ptr*", &bits, "ptr", 0, "uint", 0, "ptr")
        p := 0
        DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", cw, "int", ch, "int", stride, "int", 0x21808, "ptr", bits, "ptr*", &p) ; 24bppRGB
        cap.view := p
        old := SendMessage(0x172, 0, hbm, cap.canvas) ; STM_SETIMAGE
        if (old && old != hbm)
            DllCall("DeleteObject", "ptr", old)
        p := 0
        DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", cw, "int", ch, "int", 0, "int", 0x26200A, "ptr", 0, "ptr*", &p)
        cap.cache := p
        cap.cw := cw, cap.ch := ch
    }
    cap.s := Min(1, (cw - 16) / cap.imgW, (ch - 16) / cap.imgH)
    cap.s := Max(0.01, cap.s) ; 스크롤 캡처처럼 아주 긴 그림도 한눈에 들어오게
    cap.ox := Round((cw - cap.imgW * cap.s) / 2), cap.oy := Round((ch - cap.imgH * cap.s) / 2)
    cap.cacheOk := false
    CapRender()
}

; orig(찍은 그림 또는 자른 그림) + 확정한 그림들로 comp를 다시 만든다 (되돌리기·자르기 뒤)
CapRebuild() {
    global cap
    if cap.comp
        DllCall("gdiplus\GdipDisposeImage", "ptr", cap.comp)
    CapImageSize(cap.orig, &w, &h)
    cap.imgW := w, cap.imgH := h
    cap.comp := CapCloneArea(cap.orig, 0, 0, w, h)
    G := CapGraphics(cap.comp)
    for a in cap.annots
        CapDrawAnnot(G, cap.comp, a)
    DllCall("gdiplus\GdipDeleteGraphics", "ptr", G)
    cap.cacheOk := false
}

; 화면에 그린다: (그림을 그림판 크기로 줄여 둔 cache) + 지금 끌고 있는 것
CapRender() {
    global cap
    if !cap.view
        return
    if !cap.cacheOk {
        G := CapGraphics(cap.cache)
        DllCall("gdiplus\GdipGraphicsClear", "ptr", G, "uint", 0xFFE2E8F0)
        DllCall("gdiplus\GdipSetInterpolationMode", "ptr", G, "int", cap.s < 1 ? 7 : 5)
        DllCall("gdiplus\GdipSetPixelOffsetMode", "ptr", G, "int", 4)
        DllCall("gdiplus\GdipDrawImageRectI", "ptr", G, "ptr", cap.comp, "int", cap.ox, "int", cap.oy
            , "int", Round(cap.imgW * cap.s), "int", Round(cap.imgH * cap.s))
        DllCall("gdiplus\GdipDeleteGraphics", "ptr", G)
        cap.cacheOk := true
    }
    G := CapGraphics(cap.view)
    DllCall("gdiplus\GdipSetCompositingMode", "ptr", G, "int", 1) ; 덮어쓰기 (빠르게)
    DllCall("gdiplus\GdipDrawImageRectI", "ptr", G, "ptr", cap.cache, "int", 0, "int", 0, "int", cap.cw, "int", cap.ch)
    DllCall("gdiplus\GdipSetCompositingMode", "ptr", G, "int", 0)
    a := cap.cur
    if IsObject(a) {
        if (a.t = "mosaic" || a.t = "crop") {
            x1 := cap.ox + Min(a.x1, a.x2) * cap.s, y1 := cap.oy + Min(a.y1, a.y2) * cap.s
            w := Abs(a.x2 - a.x1) * cap.s, h := Abs(a.y2 - a.y1) * cap.s
            if (a.t = "crop") { ; 잘라낼 바깥을 어둡게
                br := 0
                DllCall("gdiplus\GdipCreateSolidFill", "uint", 0x88000000, "ptr*", &br)
                for rr in [[0, 0, cap.cw, y1], [0, y1 + h, cap.cw, cap.ch - y1 - h], [0, y1, x1, h], [x1 + w, y1, cap.cw - x1 - w, h]]
                    if (rr[3] > 0 && rr[4] > 0)
                        DllCall("gdiplus\GdipFillRectangle", "ptr", G, "ptr", br, "float", rr[1], "float", rr[2], "float", rr[3], "float", rr[4])
                DllCall("gdiplus\GdipDeleteBrush", "ptr", br)
            }
            pen := 0
            DllCall("gdiplus\GdipCreatePen1", "uint", 0xFF2563EB, "float", 2, "int", 2, "ptr*", &pen)
            DllCall("gdiplus\GdipSetPenDashStyle", "ptr", pen, "int", 1)
            DllCall("gdiplus\GdipDrawRectangle", "ptr", G, "ptr", pen, "float", x1, "float", y1, "float", w, "float", h)
            DllCall("gdiplus\GdipDeletePen", "ptr", pen)
        } else {
            DllCall("gdiplus\GdipTranslateWorldTransform", "ptr", G, "float", cap.ox, "float", cap.oy, "int", 0)
            DllCall("gdiplus\GdipScaleWorldTransform", "ptr", G, "float", cap.s, "float", cap.s, "int", 0)
            CapDrawAnnot(G, 0, a)
            DllCall("gdiplus\GdipResetWorldTransform", "ptr", G)
        }
    }
    DllCall("gdiplus\GdipDeleteGraphics", "ptr", G)
    ; view는 그림판에 붙은 DIB의 메모리 그 자체라 새로 넘길 것이 없다. 바탕을 지우지 않고(RDW_ERASE 없음) 바로 다시 칠한다
    DllCall("GdiFlush")
    DllCall("RedrawWindow", "ptr", cap.canvas.Hwnd, "ptr", 0, "ptr", 0, "uint", 0x1 | 0x100) ; RDW_INVALIDATE | RDW_UPDATENOW
}

; 그림 하나를 그린다 (좌표는 그림 픽셀 기준). pTarget은 모자이크가 읽을 그림 (미리보기에서는 0)
CapDrawAnnot(G, pTarget, a) {
    argb := 0xFF000000 | a.c
    switch a.t {
    case "pen", "hl":
        if (a.t = "hl")
            argb := 0x66000000 | a.c
        pen := 0
        DllCall("gdiplus\GdipCreatePen1", "uint", argb, "float", a.w, "int", 2, "ptr*", &pen)
        DllCall("gdiplus\GdipSetPenLineJoin", "ptr", pen, "int", 2)
        DllCall("gdiplus\GdipSetPenStartCap", "ptr", pen, "int", 2)
        DllCall("gdiplus\GdipSetPenEndCap", "ptr", pen, "int", 2)
        pts := a.pts.Clone()
        if (pts.Length = 2) ; 한 번 찍기 = 점
            pts.Push(pts[1] + 0.5, pts[2])
        n := pts.Length // 2
        buf := Buffer(8 * n)
        loop pts.Length
            NumPut("float", pts[A_Index], buf, (A_Index - 1) * 4)
        DllCall("gdiplus\GdipDrawLines", "ptr", G, "ptr", pen, "ptr", buf, "int", n)
        DllCall("gdiplus\GdipDeletePen", "ptr", pen)
    case "rect":
        pen := 0
        DllCall("gdiplus\GdipCreatePen1", "uint", argb, "float", a.w, "int", 2, "ptr*", &pen)
        DllCall("gdiplus\GdipSetPenLineJoin", "ptr", pen, "int", 0)
        DllCall("gdiplus\GdipDrawRectangle", "ptr", G, "ptr", pen, "float", Min(a.x1, a.x2), "float", Min(a.y1, a.y2)
            , "float", Abs(a.x2 - a.x1), "float", Abs(a.y2 - a.y1))
        DllCall("gdiplus\GdipDeletePen", "ptr", pen)
    case "arrow":
        CapDrawArrow(G, argb, a.w, a.x1, a.y1, a.x2, a.y2)
    case "text":
        fam := 0, font := 0, br := 0
        DllCall("gdiplus\GdipCreateFontFamilyFromName", "wstr", "Malgun Gothic", "ptr", 0, "ptr*", &fam)
        DllCall("gdiplus\GdipCreateFont", "ptr", fam, "float", a.size, "int", 1, "int", 2, "ptr*", &font) ; 굵게, 픽셀 단위
        DllCall("gdiplus\GdipCreateSolidFill", "uint", argb, "ptr*", &br)
        rc := Buffer(16, 0)
        NumPut("float", a.x1, "float", a.y1, rc)
        DllCall("gdiplus\GdipDrawString", "ptr", G, "wstr", a.text, "int", -1, "ptr", font, "ptr", rc, "ptr", 0, "ptr", br)
        DllCall("gdiplus\GdipDeleteBrush", "ptr", br)
        DllCall("gdiplus\GdipDeleteFont", "ptr", font)
        DllCall("gdiplus\GdipDeleteFontFamily", "ptr", fam)
    case "mosaic":
        if pTarget
            CapMosaic(G, pTarget, a)
    }
}

CapDrawArrow(G, argb, w, x1, y1, x2, y2) {
    len := Sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2)
    if (len < 1)
        return
    head := Min(Max(12, w * 4), len * 0.8), half := head * 0.55
    ux := (x2 - x1) / len, uy := (y2 - y1) / len
    bx := x2 - ux * head, by := y2 - uy * head
    pen := 0
    DllCall("gdiplus\GdipCreatePen1", "uint", argb, "float", w, "int", 2, "ptr*", &pen)
    DllCall("gdiplus\GdipSetPenStartCap", "ptr", pen, "int", 2)
    DllCall("gdiplus\GdipDrawLine", "ptr", G, "ptr", pen, "float", x1, "float", y1, "float", bx + ux, "float", by + uy)
    DllCall("gdiplus\GdipDeletePen", "ptr", pen)
    buf := Buffer(24)
    NumPut("float", x2, "float", y2, "float", bx - uy * half, "float", by + ux * half
        , "float", bx + uy * half, "float", by - ux * half, buf)
    br := 0
    DllCall("gdiplus\GdipCreateSolidFill", "uint", argb, "ptr*", &br)
    DllCall("gdiplus\GdipFillPolygon", "ptr", G, "ptr", br, "ptr", buf, "int", 3, "int", 0)
    DllCall("gdiplus\GdipDeleteBrush", "ptr", br)
}

; 모자이크: 그 자리를 작게 줄였다가 칸이 보이게(가장 가까운 픽셀로) 다시 키운다
CapMosaic(G, pTarget, a) {
    CapImageSize(pTarget, &iw, &ih)
    x := Max(0, Round(Min(a.x1, a.x2))), y := Max(0, Round(Min(a.y1, a.y2)))
    w := Min(iw - x, Round(Abs(a.x2 - a.x1))), h := Min(ih - y, Round(Abs(a.y2 - a.y1)))
    if (w < 2 || h < 2)
        return
    b := a.b
    sw := Max(1, Ceil(w / b)), sh := Max(1, Ceil(h / b))
    pReg := CapCloneArea(pTarget, x, y, w, h)
    pSmall := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", sw, "int", sh, "int", 0, "int", 0x26200A, "ptr", 0, "ptr*", &pSmall)
    Gs := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "ptr", pSmall, "ptr*", &Gs)
    DllCall("gdiplus\GdipSetInterpolationMode", "ptr", Gs, "int", 7)
    DllCall("gdiplus\GdipDrawImageRectI", "ptr", Gs, "ptr", pReg, "int", 0, "int", 0, "int", sw, "int", sh)
    DllCall("gdiplus\GdipDeleteGraphics", "ptr", Gs)
    DllCall("gdiplus\GdipSetClipRectI", "ptr", G, "int", x, "int", y, "int", w, "int", h, "int", 0)
    DllCall("gdiplus\GdipSetInterpolationMode", "ptr", G, "int", 5) ; 가장 가까운 픽셀
    DllCall("gdiplus\GdipSetPixelOffsetMode", "ptr", G, "int", 4)
    DllCall("gdiplus\GdipDrawImageRectI", "ptr", G, "ptr", pSmall, "int", x, "int", y, "int", sw * b, "int", sh * b)
    DllCall("gdiplus\GdipSetInterpolationMode", "ptr", G, "int", 0)
    DllCall("gdiplus\GdipSetPixelOffsetMode", "ptr", G, "int", 0)
    DllCall("gdiplus\GdipResetClip", "ptr", G)
    DllCall("gdiplus\GdipDisposeImage", "ptr", pSmall)
    DllCall("gdiplus\GdipDisposeImage", "ptr", pReg)
}

; ---------------- 도구 · 색 · 굵기 ----------------
CapSetTool(t, *) {
    global cap
    cap.tool := t
    CapUpdateToolbar()
}
CapSetColor(i, *) {
    global cap
    cap.color := i
    if (cap.tool = "mosaic" || cap.tool = "crop") ; 색을 고르면 그리는 도구로 돌아온다
        cap.tool := "pen"
    CapUpdateToolbar()
}
CapSetSize(i, *) {
    global cap
    cap.size := i
    CapUpdateToolbar()
}

CapUpdateToolbar() {
    global cap, CAP_TOOLS
    for k, c in cap.toolCtrls {
        c.Opt(k = cap.tool ? "Background93C5FD" : "BackgroundFFFFFF")
        c.Redraw()
    }
    for i, c in cap.colorCtrls
        c.Value := (i = cap.color) ? "✓" : ""
    for i, c in cap.sizeCtrls {
        c.Opt(i = cap.size ? "Background93C5FD" : "BackgroundFFFFFF")
        c.Redraw()
    }
    for t in CAP_TOOLS
        if (t[1] = cap.tool)
            name := t[2]
    try cap.status.Value := name " · 그림 위를 " (cap.tool = "text" ? "클릭해 글자를 넣으세요." : "끌어서 쓰세요.")
        . "   Ctrl+Z 되돌리기 · Ctrl+C 복사 · Ctrl+S 저장"
}

; 화면에 보이는 굵기가 일정하도록 그림 픽셀로 바꾼다 (큰 그림을 줄여 볼 때 선이 가늘어 보이지 않게)
CapWidth(t) {
    global cap, CAP_SIZES
    w := CAP_SIZES[cap.size] * (t = "hl" ? 3 : 1) + (t = "hl" ? 6 : 0)
    return w / cap.s
}

; ---------------- 마우스 ----------------
; 편집 창의 그림판 핸들. 편집 창 상태(cap)는 그림판보다 먼저 만들어지므로, 그 사이에 들어온
; 마우스 메시지가 없는 그림판을 찾다 멈추지 않게 한다(2026-11-25 제보: "no property named canvas").
CapCanvasHwnd() {
    global cap
    return (IsObject(cap) && cap.HasOwnProp("canvas")) ? cap.canvas.Hwnd : 0
}

CapMousePt(lParam, &ix, &iy) {
    global cap
    x := lParam & 0xFFFF, y := (lParam >> 16) & 0xFFFF
    x := x > 0x7FFF ? x - 0x10000 : x, y := y > 0x7FFF ? y - 0x10000 : y
    ix := (x - cap.ox) / cap.s, iy := (y - cap.oy) / cap.s
    return ix >= 0 && iy >= 0 && ix <= cap.imgW && iy <= cap.imgH
}

CapMouseDown(wParam, lParam, msg, hwnd) {
    global cap, CAP_COLORS, CAP_TEXT_SIZES, CAP_MOSAIC_BLOCK
    if !(hwnd && hwnd = CapCanvasHwnd())
        return
    if !CapMousePt(lParam, &ix, &iy)
        return 0
    c := CAP_COLORS[cap.color], t := cap.tool
    if (t = "text") {
        cap.gui.Opt("+OwnDialogs")
        r := InputBox("넣을 글자를 입력하세요.", "글자 넣기", "w340 h120")
        if (r.Result = "OK" && Trim(r.Value) != "")
            CapCommit({t: "text", c: c, text: r.Value, x1: ix, y1: iy, size: CAP_TEXT_SIZES[cap.size] / cap.s})
        return 0
    }
    if (t = "pen" || t = "hl")
        cap.cur := {t: t, c: c, w: CapWidth(t), pts: [ix, iy]}
    else
        cap.cur := {t: t, c: c, w: CapWidth(t), x1: ix, y1: iy, x2: ix, y2: iy, b: Max(4, Round(CAP_MOSAIC_BLOCK / cap.s))}
    DllCall("SetCapture", "ptr", hwnd)
    CapRender()
    return 0
}

CapMouseMove(wParam, lParam, msg, hwnd) {
    global cap
    if !(hwnd && hwnd = CapCanvasHwnd() && IsObject(cap.cur))
        return
    CapMousePt(lParam, &ix, &iy)
    ix := Max(0, Min(cap.imgW, ix)), iy := Max(0, Min(cap.imgH, iy))
    a := cap.cur
    if (a.t = "pen" || a.t = "hl") {
        n := a.pts.Length
        if (Abs(ix - a.pts[n - 1]) + Abs(iy - a.pts[n]) < 1.5 / cap.s)
            return 0
        a.pts.Push(ix, iy)
    } else
        a.x2 := ix, a.y2 := iy
    CapRender()
    return 0
}

CapMouseUp(wParam, lParam, msg, hwnd) {
    global cap
    if !(hwnd && hwnd = CapCanvasHwnd() && IsObject(cap.cur))
        return
    DllCall("ReleaseCapture")
    a := cap.cur
    cap.cur := ""
    if (a.t = "pen" || a.t = "hl" || Abs(a.x2 - a.x1) >= 3 || Abs(a.y2 - a.y1) >= 3)
        CapCommit(a)
    else
        CapRender()
    return 0
}

; 그림판 위에서는 십자 커서 (글자 도구는 I자)
CapSetCursor(wParam, lParam, msg, hwnd) {
    global cap
    if !(wParam && wParam = CapCanvasHwnd() && (lParam & 0xFFFF) = 1)
        return
    DllCall("SetCursor", "ptr", DllCall("LoadCursor", "ptr", 0, "ptr", cap.tool = "text" ? 32513 : 32515, "ptr"))
    return 1
}

OnMessage(0x0201, CapMouseDown) ; WM_LBUTTONDOWN
OnMessage(0x0200, CapMouseMove) ; WM_MOUSEMOVE
OnMessage(0x0202, CapMouseUp)   ; WM_LBUTTONUP
OnMessage(0x0020, CapSetCursor) ; WM_SETCURSOR

; ---------------- 확정 · 되돌리기 · 자르기 ----------------
CapCommit(a) {
    global cap
    if (a.t = "crop") {
        x := Max(0, Round(Min(a.x1, a.x2))), y := Max(0, Round(Min(a.y1, a.y2)))
        w := Min(cap.imgW - x, Round(Abs(a.x2 - a.x1))), h := Min(cap.imgH - y, Round(Abs(a.y2 - a.y1)))
        if (w < 4 || h < 4)
            return CapRender()
        cap.history.Push({orig: cap.orig, annots: cap.annots}) ; 되돌리면 자르기 전 그림·그린 것으로
        cap.orig := CapCloneArea(cap.comp, x, y, w, h)
        cap.annots := []
        CapRebuild()
        cap.dirty := true
        cap.tool := "pen"
        CapUpdateToolbar()
        return CapLayout()
    }
    cap.annots.Push(a)
    cap.history.Push("a")
    G := CapGraphics(cap.comp)
    CapDrawAnnot(G, cap.comp, a)
    DllCall("gdiplus\GdipDeleteGraphics", "ptr", G)
    cap.dirty := true
    cap.cacheOk := false
    CapRender()
}

CapUndo() {
    global cap
    if (!IsObject(cap) || !cap.history.Length)
        return
    e := cap.history.Pop()
    if IsObject(e) {
        DllCall("gdiplus\GdipDisposeImage", "ptr", cap.orig)
        cap.orig := e.orig, cap.annots := e.annots
    } else
        cap.annots.Pop()
    CapRebuild()
    cap.dirty := true
    CapLayout()
}

; ---------------- 복사 · 저장 ----------------
CapCopy() {
    global cap
    if !IsObject(cap)
        return
    if CapToClipboard(cap.comp) {
        cap.dirty := false
        cap.status.Value := "클립보드에 복사했습니다. 붙여넣기(Ctrl+V)로 쓰세요."
    } else
        cap.status.Value := "클립보드에 복사하지 못했습니다. 다시 눌러 주세요."
}

CapSave() {
    global cap
    if !IsObject(cap)
        return
    folder := CapSaveFolder()
    try DirCreate(folder)
    catch {
        MsgBox("저장할 폴더를 만들 수 없습니다.`n" folder "`n`n[다른 이름으로…]로 다른 곳에 저장해 주세요.", "ClassZoom — 캡처", "Icon!")
        return
    }
    stem := folder "\ClassZoom_" FormatTime(, "yyyy-MM-dd_HH-mm-ss")
    path := stem ".png", n := 2
    while FileExist(path)
        path := stem "_" n++ ".png"
    CapSaveTo(path)
}

CapSaveAs() {
    global cap
    if !IsObject(cap)
        return
    folder := CapSaveFolder()
    try DirCreate(folder)
    cap.gui.Opt("+OwnDialogs")
    path := FileSelect("S16", folder "\ClassZoom_" FormatTime(, "yyyy-MM-dd_HH-mm-ss") ".png", "캡처 저장", "그림 (*.png; *.jpg)")
    if (path = "")
        return
    if !RegExMatch(path, "i)\.(png|jpe?g)$")
        path .= ".png"
    CapSaveTo(path)
}

CapSaveTo(path) {
    global cap
    if CapSaveBitmap(cap.comp, path) {
        cap.saved := path
        cap.dirty := false
        cap.status.Value := "저장했습니다: " path
    } else
        MsgBox("저장하지 못했습니다.`n" path, "ClassZoom — 캡처", "Icon!")
}

CapOpenFolder() {
    global cap
    if (IsObject(cap) && cap.saved != "" && FileExist(cap.saved))
        Run('explorer.exe /select,"' cap.saved '"')
    else {
        folder := CapSaveFolder()
        try DirCreate(folder)
        Run('explorer.exe "' folder '"')
    }
}

; ---------------- 닫기 ----------------
; force = 새 캡처로 바꾸는 중 (이미 물어봤다)
CapCloseEditor(force := false) {
    global cap, capZoomResume
    if !IsObject(cap)
        return
    if (!force && cap.dirty) {
        cap.gui.Opt("+OwnDialogs")
        r := MsgBox("편집한 내용을 저장하지 않았습니다.`n닫기 전에 저장할까요?", "ClassZoom — 캡처", "YesNoCancel Icon?")
        if (r = "Cancel")
            return true ; 닫지 않는다
        if (r = "Yes") {
            CapSave()
            if cap.dirty ; 저장 실패
                return true
        }
    }
    for k in ["orig", "comp", "view", "cache"] ; view가 DIB 메모리를 가리키므로 DIB보다 먼저 치운다
        if cap.%k%
            DllCall("gdiplus\GdipDisposeImage", "ptr", cap.%k%)
    old := SendMessage(0x172, 0, 0, cap.canvas)
    if old
        DllCall("DeleteObject", "ptr", old)
    for e in cap.history
        if IsObject(e)
            DllCall("gdiplus\GdipDisposeImage", "ptr", e.orig)
    g := cap.gui
    cap := ""
    try g.Destroy()
    SetTimer(TrimMemory, -3000)
    ; 캡처하느라 잠시 껐던 확대를 같은 단계로 다시 켠다 (새 캡처로 바꾸는 중이면 그 편집 창을 닫을 때)
    if (!force && capZoomResume) {
        step := capZoomResume
        capZoomResume := 0
        ZoomStart(step)
    }
}
