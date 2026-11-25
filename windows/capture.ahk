; ##########################################################################
; ## 화면 캡처 + 편집 창 (classzoom.ahk가 #Include로 불러 쓴다)            ##
; ##########################################################################
;
; 무엇을 하나
;   F6(또는 위젯의 캡처 버튼): 마우스를 올린 창에 빨간 테두리가 뜨고, 클릭하면 그 창을, 누른 채 끌면 그 구역을 찍는다
;   Shift+F6: 커서가 있는 모니터 전체 / Ctrl+Shift+F6: 마우스로 끌어 고른 구역
;   찍은 그림은 곧바로 클립보드에 복사하고, 편집 창(펜·형광펜·네모·화살표·글자·모자이크·자르기)을 띄운다.
;   편집 창에서 [복사]·[저장](사진\ClassZoom 폴더에 PNG)·[다른 이름으로]를 고른다.
;
; 키 겹침을 막은 자리 (2026-11-25 점검)
;   - 캡처 키는 녹화 키처럼 앞 프로그램에 넘기지 않는다(HOTKEY_NO_PASS). 넘기면 한글 F6(스타일) 창이 떠서 함께 찍힌다.
;   - 고르는 동안 Esc는 "취소"로만 쓴다(CapPicking 조건의 Esc). 라이브 줌의 Esc(확대 끄기)보다 먼저 만들어서 이쪽이 이긴다.
;   - 고르는 동안 클릭은 ClassZoom이 받는다(뒤 프로그램의 링크·버튼이 눌리지 않게). 오류가 나도 finally에서 반드시 푼다.
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
capHint := "", capDim := "", capFrames := []
cap := ""                       ; 편집 창 상태 (열려 있지 않으면 "")
capZoomResume := 0              ; 편집 창을 닫으면 다시 켤 확대 단계 (0 = 없음)

; ---------------- 단축키가 부르는 것 ----------------
CapWindow(*) => CapStart("window")
CapScreen(*) => CapStart("screen")
CapArea(*) => CapStart("area")

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
    global cap
    ; 편집 창이 떠 있으면 찍는 동안 감춘다 (새로 찍으면 그 창은 닫는다)
    hadEditor := IsObject(cap)
    if hadEditor {
        if (cap.dirty && MsgBox("편집한 캡처를 저장하지 않았습니다.`n새로 캡처하면 지금 편집 창은 닫힙니다. 계속할까요?"
            , "ClassZoom — 캡처", "YesNo Icon? Default2") != "Yes")
            return
        cap.gui.Hide()
    }
    ; 고르기·찍기는 "모니터마다 DPI 인식" 상태로 한다 (아래 CapDpiBegin 설명). 편집 창은 원래 상태로 띄운다.
    oldDpi := CapDpiBegin()
    try {
        if (mode = "window")
            rect := CapPickWindow()
        else if (mode = "area")
            rect := CapPickArea()
        else
            rect := RecMonitorRect() ; 커서가 있는 모니터 (확대 중이면 확대 화면 그대로)
        pBmp := IsObject(rect) ? CapGrab(rect) : 0
    } finally
        CapDpiEnd(oldDpi)
    if !IsObject(rect) {
        if (hadEditor && IsObject(cap))
            cap.gui.Show()
        return
    }
    if !pBmp {
        MsgBox("화면을 캡처하지 못했습니다.", "ClassZoom — 캡처", "Icon!")
        if (hadEditor && IsObject(cap))
            cap.gui.Show()
        return
    }
    CapToClipboard(pBmp) ; 찍자마자 붙여넣기할 수 있게
    if IsObject(cap)
        CapCloseEditor(true)
    CapOpenEditor(pBmp)
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
    global capPicking
    return capPicking
}
CapSwallow(*) {
}
CapEscCancel(*) {
    global capCancel
    capCancel := true
}
HotIf(CapPickingNow)
Hotkey("Esc", CapEscCancel, "On") ; 라이브 줌 Esc(실행 중 처음 확대할 때 만든다)보다 먼저 만들어 이쪽이 이긴다
HotIf()

; 고르기 시작: 클릭을 삼키고, 드로잉 입력을 잠시 멈춘다
CapPickBegin() {
    global capPicking, capCancel, drawOn, drawGui
    KeyWait("LButton"), KeyWait("RButton") ; 위젯 버튼을 누른 손을 뗀 뒤부터
    capCancel := false
    capPicking := true
    if drawOn {
        SetTimer(DrawPoll, 0)
        try WinSetExStyle("+0x20", drawGui) ; 터치·펜 입력도 판서 층으로 가지 않게
    }
    HotIf()
    for k in ["*LButton", "*LButton up", "*RButton", "*RButton up"]
        Hotkey(k, CapSwallow, "On")
}

CapPickEnd() {
    global capPicking, drawOn, drawGui, inkPinned
    ; 오른쪽 버튼으로 취소했으면 뗀 뒤에 풀어야 뗀 것이 뒤 프로그램에 가지 않는다
    t0 := A_TickCount
    while ((GetKeyState("LButton", "P") || GetKeyState("RButton", "P")) && A_TickCount - t0 < 3000)
        Sleep(10)
    HotIf()
    for k in ["*LButton", "*LButton up", "*RButton", "*RButton up"]
        try Hotkey(k, "Off")
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
CapPickWindow() {
    global CAP_DRAG_PX
    rect := ""
    CapPickBegin()
    try {
        CapShowHint("클릭하면 창 · 끌면 구역을 캡처합니다   ·   Esc 취소")
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
                        CapShowHint("놓으면 이 구역을 캡처합니다   ·   Esc 취소")
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
    global capHint, capDim, capFrames
    list := []
    for g in [capDim, capHint]
        if IsObject(g)
            try list.Push(g.Hwnd)
    for g in capFrames
        try list.Push(g.Hwnd)
    return list
}

; ---------------- 찍기 ----------------
; 보이는 화면 그대로 찍는다(확대 화면·그린 그림 포함). 위젯·강조 원·커서 노릇을 하는 원은 잠깐 감춘다.
CapGrab(r) {
    global widget, spotGui, brushGui, zoomCursorGui
    hidden := []
    for g in [IsSet(widget) ? widget : "", spotGui, brushGui, zoomCursorGui]
        if (IsObject(g) && DllCall("IsWindowVisible", "ptr", g.Hwnd)) {
            DllCall("ShowWindow", "ptr", g.Hwnd, "int", 0)
            hidden.Push(g.Hwnd)
        }
    ToolTip(, , , 19) ; 위젯 설명 풍선
    Sleep(hidden.Length ? 150 : 60) ; 감춘 것이 화면(확대 화면 포함)에서 빠질 때까지
    pBmp := 0
    try {
        hdcS := DllCall("GetDC", "ptr", 0, "ptr")
        hdcM := DllCall("CreateCompatibleDC", "ptr", hdcS, "ptr")
        hbm := DllCall("CreateCompatibleBitmap", "ptr", hdcS, "int", r.w, "int", r.h, "ptr")
        old := DllCall("SelectObject", "ptr", hdcM, "ptr", hbm, "ptr")
        DllCall("BitBlt", "ptr", hdcM, "int", 0, "int", 0, "int", r.w, "int", r.h
            , "ptr", hdcS, "int", r.x, "int", r.y, "uint", 0x40CC0020) ; SRCCOPY | CAPTUREBLT (투명 창까지)
        DllCall("SelectObject", "ptr", hdcM, "ptr", old)
        DllCall("DeleteDC", "ptr", hdcM)
        DllCall("ReleaseDC", "ptr", 0, "ptr", hdcS)
        pTmp := 0
        DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "ptr", hbm, "ptr", 0, "ptr*", &pTmp)
        DllCall("DeleteObject", "ptr", hbm)
        if pTmp {
            pBmp := CapCloneArea(pTmp, 0, 0, r.w, r.h)
            DllCall("gdiplus\GdipDisposeImage", "ptr", pTmp)
        }
    }
    for h in hidden
        DllCall("ShowWindow", "ptr", h, "int", 8) ; SW_SHOWNA
    RaiseWidget()
    return pBmp
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

    g := Gui("+Resize +MinSize840x420", "ClassZoom 캡처 편집")
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
    return IsObject(cap) && !drawOn && WinActive("ahk_id " cap.gui.Hwnd)
}
HotIf(CapEditorActive)
Hotkey("^c", (*) => CapCopy(), "On")
Hotkey("^s", (*) => CapSave(), "On")
Hotkey("^+s", (*) => CapSaveAs(), "On")
Hotkey("^z", (*) => CapUndo(), "On")
HotIf()

CapOnSize(g, minMax, *) {
    global cap
    if (minMax = -1 || !IsObject(cap))
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
    rc := Buffer(16, 0)
    DllCall("GetClientRect", "ptr", cap.canvas.Hwnd, "ptr", rc)
    cw := NumGet(rc, 8, "Int"), ch := NumGet(rc, 12, "Int")
    if (cw < 10 || ch < 10)
        return
    if (cw != cap.cw || ch != cap.ch) {
        for k in ["view", "cache"]
            if cap.%k%
                DllCall("gdiplus\GdipDisposeImage", "ptr", cap.%k%)
        for k in ["view", "cache"] {
            p := 0
            DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", cw, "int", ch, "int", 0, "int", 0x26200A, "ptr", 0, "ptr*", &p)
            cap.%k% := p
        }
        cap.cw := cw, cap.ch := ch
    }
    cap.s := Min(1, (cw - 16) / cap.imgW, (ch - 16) / cap.imgH)
    cap.s := Max(0.05, cap.s)
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
    ; 그림판에 넘긴다. 알파가 있는 비트맵은 static이 복사본을 만들므로 돌려받은 것·남은 것을 모두 지운다
    hbm := 0
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "ptr", cap.view, "ptr*", &hbm, "uint", 0xFFE2E8F0)
    old := SendMessage(0x172, 0, hbm, cap.canvas) ; STM_SETIMAGE
    if old
        DllCall("DeleteObject", "ptr", old)
    if (SendMessage(0x173, 0, 0, cap.canvas) != hbm) ; STM_GETIMAGE
        DllCall("DeleteObject", "ptr", hbm)
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
CapMousePt(lParam, &ix, &iy) {
    global cap
    x := lParam & 0xFFFF, y := (lParam >> 16) & 0xFFFF
    x := x > 0x7FFF ? x - 0x10000 : x, y := y > 0x7FFF ? y - 0x10000 : y
    ix := (x - cap.ox) / cap.s, iy := (y - cap.oy) / cap.s
    return ix >= 0 && iy >= 0 && ix <= cap.imgW && iy <= cap.imgH
}

CapMouseDown(wParam, lParam, msg, hwnd) {
    global cap, CAP_COLORS, CAP_TEXT_SIZES, CAP_MOSAIC_BLOCK
    if !(IsObject(cap) && hwnd = cap.canvas.Hwnd)
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
    if !(IsObject(cap) && hwnd = cap.canvas.Hwnd && IsObject(cap.cur))
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
    if !(IsObject(cap) && hwnd = cap.canvas.Hwnd && IsObject(cap.cur))
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
    if !(IsObject(cap) && wParam = cap.canvas.Hwnd && (lParam & 0xFFFF) = 1)
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
    old := SendMessage(0x172, 0, 0, cap.canvas)
    if old
        DllCall("DeleteObject", "ptr", old)
    for k in ["orig", "comp", "view", "cache"]
        if cap.%k%
            DllCall("gdiplus\GdipDisposeImage", "ptr", cap.%k%)
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
