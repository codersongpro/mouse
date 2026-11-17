; ##########################################################################
; ## 녹화 엔진 압축 풀기 (record.ahk가 #Include로 불러 쓴다)               ##
; ##########################################################################
;
; exe 용량을 줄이려고 녹화 엔진(ffmpeg.exe·classzoom-rec.exe·라이선스)은 engine.zip 하나로 압축해 exe 안에 넣는다.
; 처음 녹화할 때 그 zip을 꺼내 여기서 푼다.
;   1) Windows 10(1803 이후)·11에 기본으로 있는 tar.exe로 푼다 (빠르고 창이 뜨지 않는다)
;   2) tar.exe가 없거나 실패하면 Windows 탐색기의 압축 풀기(Shell.Application)로 푼다
; 다 풀리면 true. 빌드 서버에서도 이 파일만 따로 불러 시험한다(.github/workflows/build-windows.yml).

UnpackZip(zip, dir, mustHave*) {
    tar := A_WinDir "\System32\tar.exe"
    if FileExist(tar) {
        try RunWait('"' tar '" -xf "' zip '" -C "' dir '"', dir, "Hide")
        if UnpackDone(dir, mustHave)
            return true
    }
    try {
        sh := ComObject("Shell.Application")
        ; 4 진행 창 숨김 · 16 덮어쓰기 묻지 않음 · 1024 오류 창 숨김
        sh.Namespace(dir).CopyHere(sh.Namespace(zip).Items(), 4 | 16 | 1024)
        ; CopyHere는 다 끝나기 전에 돌아올 수 있어 파일이 생길 때까지 기다린다 (최대 2분)
        t0 := A_TickCount
        while (A_TickCount - t0 < 120000) {
            if UnpackDone(dir, mustHave)
                return true
            Sleep(250)
        }
    }
    return UnpackDone(dir, mustHave)
}

; 필요한 파일이 모두 있고, 다른 프로그램이 아직 쓰고 있지 않은가(크기가 0보다 크고 열린다)
UnpackDone(dir, names) {
    for n in names {
        p := dir "\" n
        if !FileExist(p)
            return false
        try {
            if (FileGetSize(p) = 0)
                return false
            FileOpen(p, "r").Close()
        } catch
            return false
    }
    return true
}
