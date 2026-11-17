; ##########################################################################
; ## 화면 녹화 (classzoom.ahk가 #Include로 불러 쓴다)                       ##
; ##########################################################################
;
; 무엇을 하나
;   F10(또는 위젯의 녹화 버튼): 커서가 있는 모니터 전체 녹화 시작·정지
;   Ctrl+Shift+F10(또는 녹화 버튼 오른쪽 클릭): 마우스로 영역을 끌어 그 부분만 녹화
;   Ctrl+F10(또는 녹화 표시창 버튼): 일시정지 · 계속
;   3·2·1 카운트다운 뒤 시작하고, 끝나면 "동영상\ClassZoom" 폴더에 MP4로 저장한 뒤 폴더를 연다.
;
; 어떻게 하나
;   실제 녹화는 classzoom-rec.exe(도우미, windows\recorder\ClassZoomRec.cs)와 ffmpeg.exe가 한다.
;   화면은 Desktop Duplication(ddagrab)으로 받아 라이브 줌 화면·커서가 보이는 그대로 찍힌다 (안 되면 gdigrab).
;   두 파일은 classzoom.exe 안에 들어 있다가 처음 녹화할 때 꺼낸다(RecEnginePaths). 본체는 도우미를 숨겨 실행하고 "제어 파일"에 rec / pause / stop을 써서
;   조종하며, 도우미가 "상태 파일"에 적는 recording / paused / saving / done / error를 읽는다.
;   카운트다운·녹화 표시창·영역 테두리는 SetWindowDisplayAffinity로 녹화(와 화면 캡처)에서 뺀다.
;   영역 테두리는 녹화 영역 바깥에 그려서, 혹시 빠지지 않더라도 영상에 들어가지 않는다.

#Include unpack.ahk ; 녹화 엔진 압축 풀기

REC_COUNTDOWN := 3          ; 시작 전 카운트다운 (초)
REC_POLL_MS := 250          ; 상태 확인·경과 시간 갱신 간격
REC_BORDER_PX := 3          ; 영역 녹화 테두리 두께

recState := ""              ; "" | "rec" | "paused" | "saving"
recPid := 0, recOut := "", recControl := "", recStatus := ""
recRect := ""               ; {x, y, w, h} 녹화 중인 영역
recElapsed := 0, recSince := 0 ; 지난 조각들의 녹화 시간(ms), 지금 조각을 시작한 시각
recPill := "", recPillText := "", recPillPause := ""
recFrames := []             ; 영역 테두리 창 4개
recDim := "", recHint := "", recCount := ""

; settings.ini [Record]
recMode := "screen"         ; "screen" = 모니터 전체 / "area" = 시작할 때 영역 지정
recMic := true, recSys := true, recFps := 30, recFolder := ""
recQuality := "normal"      ; "high" 고화질 / "normal" 표준 / "low" 저용량(가로 1280 이하)
RecLoadSettings() {
    global SETTINGS_PATH, recMode, recMic, recSys, recFps, recFolder, recQuality
    q := IniRead(SETTINGS_PATH, "Record", "Quality", "normal")
    recQuality := (q = "high" || q = "low") ? q : "normal"
    recMode := IniRead(SETTINGS_PATH, "Record", "Mode", "screen") = "area" ? "area" : "screen"
    recMic := ReadIniNum("Record", "Mic", 0, 1, 1) = 1
    recSys := ReadIniNum("Record", "System", 0, 1, 1) = 1
    recFps := ReadIniNum("Record", "Fps", 10, 60, 30)
    recFolder := IniRead(SETTINGS_PATH, "Record", "Folder", "")
}
RecWriteSettings() {
    global SETTINGS_PATH, recMode, recMic, recSys, recFps, recFolder, recQuality
    IniWrite(recQuality, SETTINGS_PATH, "Record", "Quality")
    IniWrite(recMode, SETTINGS_PATH, "Record", "Mode")
    IniWrite(recMic ? 1 : 0, SETTINGS_PATH, "Record", "Mic")
    IniWrite(recSys ? 1 : 0, SETTINGS_PATH, "Record", "System")
    IniWrite(recFps, SETTINGS_PATH, "Record", "Fps")
    IniWrite(recFolder, SETTINGS_PATH, "Record", "Folder")
}

; 저장 폴더: 설정에서 고른 곳, 없으면 "동영상\ClassZoom"
RecSaveFolder() {
    global recFolder
    if (recFolder != "")
        return recFolder
    p := ""
    try p := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders", "My Video")
    if (p = "")
        p := EnvGet("USERPROFILE") "\Videos"
    return p "\ClassZoom"
}

;---------------- 녹화 엔진 (exe 하나로 배포) ----------------
; 녹화 도우미(classzoom-rec.exe)와 FFmpeg(ffmpeg.exe)은 engine.zip으로 압축되어 classzoom.exe 안에 들어 있다(FileInstall).
; 처음 녹화할 때 한 번만 %LOCALAPPDATA%\ClassZoom\engine\<버전>\에 꺼내 풀고(unpack.ahk), 다음부터는 풀어 둔 것을 쓴다.
; exe 옆에 두 파일이 있으면 그것을 먼저 쓴다 — 소스(.ahk)로 실행할 때, 또는 FFmpeg을 다른 빌드로 바꿔 쓰고 싶을 때.
RecEnginePaths(&ffmpeg, &helper) {
    global APP_VERSION
    ffmpeg := A_ScriptDir "\ffmpeg.exe", helper := A_ScriptDir "\classzoom-rec.exe"
    if (FileExist(ffmpeg) && FileExist(helper))
        return true
    if !A_IsCompiled {
        MsgBox("소스로 실행할 때는 ffmpeg.exe와 classzoom-rec.exe를 classzoom.ahk 옆에 두어야 녹화됩니다.", "ClassZoom — 녹화", "Icon!")
        return false
    }
    root := EnvGet("LOCALAPPDATA") "\ClassZoom\engine"
    dir := root "\" APP_VERSION
    ffmpeg := dir "\ffmpeg.exe", helper := dir "\classzoom-rec.exe"
    if FileExist(dir "\ready")
        return true
    TrayTip("처음 한 번만 녹화 엔진을 준비합니다…", "ClassZoom", "Iconi")
    try {
        DirCreate(dir)
        ; 컴파일할 때 windows\engine\engine.zip을 exe 안에 넣고, 실행할 때 꺼내 푼다
        ; (zip 안: ffmpeg.exe · classzoom-rec.exe · FFmpeg-LICENSE.txt[LGPL 2.1 고지])
        zip := dir "\engine.zip"
        FileInstall("engine\engine.zip", zip, 1)
        if !UnpackZip(zip, dir, "ffmpeg.exe", "classzoom-rec.exe")
            throw Error("압축을 풀지 못했습니다")
        try FileDelete(zip)
        FileAppend(APP_VERSION, dir "\ready") ; 다 꺼낸 뒤에만 표시 (중간에 끊기면 다음에 다시 꺼낸다)
    } catch as err {
        MsgBox("녹화 엔진을 준비하지 못했습니다.`n`n" dir "`n(" err.Message ")", "ClassZoom — 녹화", "Icon!")
        return false
    }
    ; 예전 버전의 엔진은 지운다 (용량 정리)
    loop files root "\*", "D"
        if (A_LoopFileName != APP_VERSION)
            try DirDelete(A_LoopFileFullPath, true)
    TrayTip()
    return true
}

; ---------------- 단축키·버튼이 부르는 것 ----------------
RecToggle(*) {
    global recState, recMode
    if (recState = "rec" || recState = "paused")
        RecStop()
    else if (recState = "")
        RecStart(recMode = "area")
}

RecToggleArea(*) {
    global recState
    if (recState = "rec" || recState = "paused")
        RecStop()
    else if (recState = "")
        RecStart(true)
}

RecPauseToggle(*) {
    global recState, recElapsed, recSince
    if (recState = "rec") {
        if !RecWriteControl("pause")
            return RecControlFailed()
        recElapsed += A_TickCount - recSince
        recState := "paused"
    } else if (recState = "paused") {
        if !RecWriteControl("rec")
            return RecControlFailed()
        recSince := A_TickCount
        recState := "rec"
    }
    RecUpdatePill()
}

; ---------------- 시작 ----------------
RecStart(area) {
    global recState, recPid, recOut, recControl, recStatus, recRect, recElapsed, recSince
    global recMic, recSys, recFps, recQuality, REC_POLL_MS
    if !RecEnginePaths(&ffmpeg, &helper)
        return
    rect := area ? RecPickArea() : RecMonitorRect()
    if !IsObject(rect)
        return
    folder := RecSaveFolder()
    try DirCreate(folder)
    catch {
        MsgBox("녹화를 저장할 폴더를 만들 수 없습니다.`n" folder "`n`n설정 → 녹화 탭에서 다른 폴더를 고르세요.", "ClassZoom — 녹화", "Icon!")
        RecHideFrame()
        return
    }
    if !RecCountdown(rect) {
        RecHideFrame()
        return
    }
    recOut := folder "\ClassZoom_" FormatTime(, "yyyy-MM-dd_HH-mm-ss") ".mp4"
    tmp := A_Temp "\classzoom_rec_" A_TickCount
    recControl := tmp ".control", recStatus := tmp ".status"
    RecWriteControl("rec")
    try FileDelete(recStatus)
    args := '"--ffmpeg=' ffmpeg '" "--out=' recOut '" "--control=' recControl '" "--status=' recStatus '"'
        . ' "--log=' tmp '.log" --x=' rect.x ' --y=' rect.y ' --w=' rect.w ' --h=' rect.h
        . ' --fps=' recFps ' --quality=' recQuality ' --mic=' (recMic ? 1 : 0) ' --sys=' (recSys ? 1 : 0) ' --parent=' ProcessExist()
    try Run('"' helper '" ' args, A_ScriptDir, "Hide", &recPid)
    catch as err {
        MsgBox("녹화 도우미를 실행하지 못했습니다.`n`n(" err.Message ")", "ClassZoom — 녹화", "Icon!")
        RecHideFrame()
        return
    }
    recRect := rect
    recElapsed := 0, recSince := A_TickCount
    recState := "rec"
    RecShowPill(rect)
    SetTimer(RecPoll, REC_POLL_MS)
    UpdateWidgetState()
}

; ---------------- 정지 ----------------
RecStop(*) {
    global recState, recElapsed, recSince
    if (recState != "rec" && recState != "paused")
        return
    if !RecWriteControl("stop")
        return RecControlFailed()
    if (recState = "rec")
        recElapsed += A_TickCount - recSince
    recState := "saving"
    RecUpdatePill()
}

RecControlFailed() {
    TrayTip("녹화 도우미에 명령을 전하지 못했습니다. 한 번 더 눌러 주세요.", "ClassZoom — 녹화", "Icon!")
}

; 도우미가 제어 파일을 읽는 순간과 겹치면 쓰기가 실패할 수 있다. 예전에는 그 한 번을 조용히 버려서
; 일시정지·정지가 먹지 않는 일이 있었다. 이제는 쓰고 다시 읽어 맞을 때까지 잠깐씩 되풀이한다.
RecWriteControl(cmd) {
    global recControl
    loop 40 {
        try {
            f := FileOpen(recControl, "w", "UTF-8-RAW")
            f.Write(cmd)
            f.Close()
            if (Trim(FileRead(recControl, "UTF-8")) = cmd)
                return true
        }
        Sleep(25)
    }
    return false
}

; 도우미가 적는 상태를 읽고, 경과 시간을 갱신한다
RecPoll() {
    global recState, recStatus, recPid, recOut
    RecUpdatePill()
    last := ""
    try {
        for line in StrSplit(Trim(FileRead(recStatus, "UTF-8"), "`r`n "), "`n", "`r")
            if (line != "")
                last := line
    }
    if (SubStr(last, 1, 6) = "error ") {
        RecFinish()
        MsgBox("녹화하지 못했습니다.`n`n" SubStr(last, 7), "ClassZoom — 녹화", "Icon!")
        return
    }
    if (SubStr(last, 1, 5) = "done ") {
        path := SubStr(last, 6)
        RecFinish()
        TrayTip("녹화를 저장했습니다", path, "Iconi")
        try Run('explorer.exe /select,"' path '"')
        return
    }
    ; 도우미가 아무 말 없이 끝나 버렸으면
    if (recPid && !ProcessExist(recPid)) {
        RecFinish()
        MsgBox("녹화 도우미가 예기치 않게 끝났습니다.", "ClassZoom — 녹화", "Icon!")
    }
}

RecFinish() {
    global recState, recPid, recControl, recStatus
    SetTimer(RecPoll, 0)
    recState := "", recPid := 0
    RecHidePill()
    RecHideFrame()
    try FileDelete(recControl)
    try FileDelete(recStatus)
    UpdateWidgetState()
    SetTimer(TrimMemory, -3000)
}

; 프로그램을 끌 때 녹화 중이면 마무리할 시간을 준다 (도우미도 본체가 꺼진 것을 보고 스스로 정리한다)
RecOnExit(*) {
    global recState, recPid
    if (recState = "rec" || recState = "paused") {
        RecWriteControl("stop")
        if recPid
            ProcessWaitClose(recPid, 20)
    }
}
OnExit(RecOnExit)

; ---------------- 녹화 범위 ----------------
RecMonitorRect() {
    MouseGetPos(&mx, &my)
    if !GetMonitorAt(mx, my, &ml, &mt, &mr, &mb, &wl, &wt, &wr, &wb)
        ml := 0, mt := 0, mr := A_ScreenWidth, mb := A_ScreenHeight
    return {x: ml, y: mt, w: mr - ml, h: mb - mt}
}

; 화면을 살짝 어둡게 덮고, 마우스로 끌어 영역을 고른다. Esc나 오른쪽 클릭으로 취소.
; 확대 중이면 확대 화면에 보이는 자리 기준으로 고른다(녹화도 보이는 화면을 담는다).
RecPickArea() {
    global recDim, recHint, vx, vy, vw, vh
    recDim := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000000", "ClassZoom-RecPick")
    recDim.BackColor := "000000"
    recDim.Show("NA x" vx " y" vy " w" vw " h" vh)
    WinSetTransparent(70, recDim)
    MouseGetPos(&mx, &my)
    if !GetMonitorAt(mx, my, &ml, &mt, &mr, &mb, &wl, &wt, &wr, &wb)
        ml := 0, mt := 0, mr := A_ScreenWidth
    recHint := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000000", "ClassZoom-RecHint")
    recHint.BackColor := "1E293B"
    recHint.MarginX := 18, recHint.MarginY := 10
    recHint.SetFont("s12 bold cFFFFFF", "Malgun Gothic")
    recHint.AddText("", "녹화할 영역을 마우스로 끌어 주세요   ·   Esc 취소")
    recHint.Show("AutoSize Hide")
    recHint.GetPos(, , &hw)
    recHint.Show("NA x" (ml + (mr - ml - hw) // 2) " y" (mt + 24))
    RecExclude(recDim.Hwnd), RecExclude(recHint.Hwnd)
    ZoomKeepOrder(true)

    rect := ""
    ; 누르기를 기다린다
    loop {
        if (GetKeyState("Esc", "P") || GetKeyState("RButton", "P"))
            break
        if GetKeyState("LButton", "P") {
            MouseGetPos(&x1, &y1)
            ZoomScreenPos(&x1, &y1)
            x2 := x1, y2 := y1
            while GetKeyState("LButton", "P") {
                MouseGetPos(&x2, &y2)
                ZoomScreenPos(&x2, &y2)
                RecShowFrame({x: Min(x1, x2), y: Min(y1, y2), w: Abs(x2 - x1), h: Abs(y2 - y1)})
                Sleep(10)
            }
            w := Abs(x2 - x1), h := Abs(y2 - y1)
            if (w >= 40 && h >= 40)
                rect := {x: Min(x1, x2), y: Min(y1, y2), w: w, h: h}
            break
        }
        Sleep(10)
    }
    recDim.Destroy(), recHint.Destroy()
    recDim := "", recHint := ""
    if !IsObject(rect)
        RecHideFrame()
    return rect
}

; 영역 바깥에 빨간 테두리 (녹화 영상에는 들어가지 않는다)
RecShowFrame(r) {
    global recFrames, REC_BORDER_PX
    b := REC_BORDER_PX
    if (recFrames.Length = 0)
        loop 4 {
            g := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08080020", "ClassZoom-RecFrame")
            g.BackColor := "EF4444"
            g.Show("NA x0 y0 w1 h1")
            DllCall("SetLayeredWindowAttributes", "ptr", g.Hwnd, "uint", 0, "uchar", 255, "uint", 2)
            RecExclude(g.Hwnd)
            recFrames.Push(g)
        }
    pos := [[r.x - b, r.y - b, r.w + 2 * b, b], [r.x - b, r.y + r.h, r.w + 2 * b, b]
        , [r.x - b, r.y, b, r.h], [r.x + r.w, r.y, b, r.h]]
    for i, p in pos
        DllCall("SetWindowPos", "ptr", recFrames[i].Hwnd, "ptr", -1, "int", p[1], "int", p[2]
            , "int", Max(1, p[3]), "int", Max(1, p[4]), "uint", 0x10 | 0x40) ; NOACTIVATE | SHOWWINDOW
}

RecHideFrame() {
    global recFrames
    for g in recFrames
        try g.Destroy()
    recFrames := []
}

; 녹화·화면 캡처에서 빼기 (WDA_EXCLUDEFROMCAPTURE, Windows 10 2004 이상)
RecExclude(hwnd) {
    try DllCall("SetWindowDisplayAffinity", "ptr", hwnd, "uint", 0x11)
}

; ---------------- 카운트다운 ----------------
RecCountdown(r) {
    global recCount, REC_COUNTDOWN
    size := 160
    recCount := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000000", "ClassZoom-RecCount")
    recCount.BackColor := "1E293B"
    recCount.SetFont("s64 bold cFFFFFF", "Malgun Gothic")
    num := recCount.AddText("x0 y0 w" size " h" size " Center +0x200", REC_COUNTDOWN)
    recCount.Show("NA x" (r.x + (r.w - size) // 2) " y" (r.y + (r.h - size) // 2) " w" size " h" size)
    RoundRegion(recCount.Hwnd, size, size, size)
    WinSetTransparent(225, recCount)
    RecExclude(recCount.Hwnd)
    ZoomKeepOrder(true)
    cancelled := false
    loop REC_COUNTDOWN {
        num.Value := REC_COUNTDOWN - A_Index + 1
        t0 := A_TickCount
        while (A_TickCount - t0 < 1000) {
            if GetKeyState("Esc", "P") {
                cancelled := true
                break 2
            }
            Sleep(20)
        }
    }
    recCount.Destroy()
    recCount := ""
    return !cancelled
}

; ---------------- 녹화 표시창 (● 녹화 중 01:23 [일시정지] [정지]) ----------------
RecShowPill(r) {
    global recPill, recPillText, recPillPause
    if IsObject(recPill)
        try recPill.Destroy()
    w := 330, h := 40
    recPill := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000000", "ClassZoom-RecPill")
    recPill.BackColor := "1E293B"
    recPill.SetFont("s11 bold cEF4444", "Malgun Gothic")
    recPill.AddText("x14 y9 w16", "●")
    recPill.SetFont("s11 bold cFFFFFF")
    recPillText := recPill.AddText("x32 y9 w140", "녹화 중 00:00")
    recPill.SetFont("s10 bold cFFFFFF")
    recPillPause := recPill.AddText("x176 y7 w80 h26 Center +0x200 Background334155", "일시정지")
    btnStop := recPill.AddText("x262 y7 w56 h26 Center +0x200 BackgroundEF4444", "정지")
    recPillPause.OnEvent("Click", RecPauseToggle)
    btnStop.OnEvent("Click", RecStop)
    ; 녹화 영역 바로 위 가운데 (위에 자리가 없으면 영역 안 위쪽)
    if !GetMonitorAt(r.x + r.w // 2, r.y + r.h // 2, &ml, &mt, &mr, &mb, &wl, &wt, &wr, &wb)
        ml := 0, mt := 0
    px := r.x + (r.w - w) // 2
    py := (r.y - h - 10 >= mt) ? r.y - h - 10 : r.y + 10
    recPill.Show("NA x" px " y" py " w" w " h" h)
    RoundRegion(recPill.Hwnd, w, h, 20)
    RecExclude(recPill.Hwnd)
    ZoomKeepOrder(true)
}

RecUpdatePill() {
    global recState, recPillText, recPillPause, recElapsed, recSince
    if !IsObject(recPillText)
        return
    ms := recElapsed + (recState = "rec" ? A_TickCount - recSince : 0)
    t := Format("{:02}:{:02}", ms // 60000, Mod(ms // 1000, 60))
    if (ms >= 3600000)
        t := Format("{}:{:02}:{:02}", ms // 3600000, Mod(ms // 60000, 60), Mod(ms // 1000, 60))
    try {
        if (recState = "rec")
            recPillText.Value := "녹화 중 " t, recPillPause.Value := "일시정지"
        else if (recState = "paused")
            recPillText.Value := "일시정지 " t, recPillPause.Value := "계속"
        else if (recState = "saving")
            recPillText.Value := "저장 중…", recPillPause.Value := ""
    }
}

RecHidePill() {
    global recPill, recPillText, recPillPause
    if IsObject(recPill)
        try recPill.Destroy()
    recPill := "", recPillText := "", recPillPause := ""
}

; 확대 중에도 확대 화면 위(확대하지 않고)에 보여야 하는 녹화 창들 (zoom.ahk ZoomTopHwnds가 부른다)
RecTopHwnds() {
    global recPill, recDim, recHint, recCount, recFrames
    list := []
    for g in [recDim, recHint, recCount, recPill]
        if IsObject(g)
            try list.Push(g.Hwnd)
    for g in recFrames
        try list.Push(g.Hwnd)
    return list
}
