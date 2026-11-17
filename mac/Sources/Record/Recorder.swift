import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

// ================= 화면 녹화 (ClassZoom) =================
// F10(또는 위젯 녹화 버튼): 커서가 있는 화면 전체 녹화 시작·정지
// ⌃⇧F10(또는 위젯 오른쪽 클릭 메뉴): 마우스로 끌어 고른 영역만 녹화
// ⌃F10(또는 녹화 표시창 버튼): 일시정지·계속
//
//  - 화면과 컴퓨터 소리: ScreenCaptureKit (macOS 13+). 마이크: AVCaptureSession (기본 입력 장치).
//  - 한 직렬 큐(writeQueue)에서 AVAssetWriter에 넣는다: 영상 1 + 소리 최대 2(컴퓨터·마이크) 트랙.
//    끝나면 소리 트랙이 둘이면 한 트랙으로 섞어 다시 저장한다(AVAssetExportSession은 소리 트랙을 섞어 내보낸다).
//  - 일시정지: 그동안 들어온 것은 버리고, 멈춘 시간만큼 뒤 샘플의 시각을 당긴다(한 파일로 이어진다).
//  - 카운트다운·녹화 표시창·영역 테두리는 받는 그림에서 뺀다(영상에 찍히지 않는다).
//  - 확대·드로잉 중에는 진짜 커서를 숨기고 우리가 그린 커서·붓 동그라미가 커서 노릇을 하므로, 그때는 시스템 커서를 넣지 않는다.

@MainActor final class Recorder: NSObject {
    enum Phase: Equatable { case idle, picking, countdown, recording, paused, saving }
    private(set) var phase: Phase = .idle { didSet { if phase != oldValue { onChange() } } }
    var isActive: Bool { phase != .idle }
    var onChange: () -> Void = {}
    var cursorDrawnByUs: () -> Bool = { false }   // 확대·드로잉 중 (그때는 시스템 커서를 넣지 않는다)

    private var stream: SCStream?
    private var engine: RecordEngine?
    private var micSession: AVCaptureSession?
    private var rect = CGRect.zero               // 녹화 영역 (전역 pt)
    private var screen: NSScreen?
    private var outURL: URL?
    private var startedAt: CFTimeInterval = 0
    private var elapsedBefore: CFTimeInterval = 0
    private var timer: Timer?

    private var pill: NSPanel?
    private var pillTime: NSTextField?
    private var pillPause: NSButton?
    private var countdown: NSPanel?
    private var frames: [NSWindow] = []
    private var picker: AreaPicker?

    var windowNumbers: [Int] {
        ([pill, countdown] as [NSWindow?]).compactMap { $0?.windowNumber } + frames.map(\.windowNumber) + (picker?.windowNumbers ?? [])
    }

    // ---------- 단축키·버튼 ----------
    func toggle(area: Bool) {
        switch phase {
        case .idle: area ? pickArea() : startOnCursorScreen()
        case .recording, .paused: stop()
        default: break
        }
    }

    func pauseToggle() {
        guard let e = engine else { return }
        if phase == .recording {
            elapsedBefore += CACurrentMediaTime() - startedAt
            e.pause()
            phase = .paused
        } else if phase == .paused {
            startedAt = CACurrentMediaTime()
            e.resume()
            phase = .recording
        }
        updatePill()
    }

    // ---------- 범위 ----------
    private func startOnCursorScreen() {
        let m = NSEvent.mouseLocation
        guard let scr = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? NSScreen.main else { return }
        begin(rect: scr.frame, on: scr)
    }

    private func pickArea() {
        phase = .picking
        let p = AreaPicker()
        picker = p
        p.pick { [weak self] r in
            guard let self else { return }
            self.picker = nil
            guard let r, let scr = NSScreen.screens.first(where: { $0.frame.intersects(r) }) else { self.phase = .idle; return }
            self.begin(rect: r.intersection(scr.frame), on: scr)
        }
    }

    // ---------- 시작 ----------
    private func begin(rect r: CGRect, on scr: NSScreen) {
        rect = r.integral
        screen = scr
        if rect.width < scr.frame.width || rect.height < scr.frame.height { showFrames(around: rect) }
        phase = .countdown
        runCountdown { [weak self] go in
            guard let self else { return }
            guard go else { self.cleanUp(); return }
            Task { @MainActor in await self.startCapture() }
        }
    }

    private func moviesFolder() -> URL {
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return base.appendingPathComponent("ClassZoom", isDirectory: true)
    }

    private func startCapture() async {
        guard let scr = screen else { cleanUp(); return }
        let s = Settings.shared
        let folder = moviesFolder()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let final = folder.appendingPathComponent("ClassZoom_\(f.string(from: Date())).mp4")
        outURL = final

        // 마이크 권한 (처음 한 번 묻는다). 거절되면 목소리 없이 녹화한다.
        var useMic = s.recMic
        if useMic {
            let st = AVCaptureDevice.authorizationStatus(for: .audio)
            if st == .notDetermined { useMic = await AVCaptureDevice.requestAccess(for: .audio) }
            else if st != .authorized { useMic = false; Notice.show(Notice.microphoneDenied()) }
        }

        do {
            showPill()
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let did = (scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == did }) else { throw RecordError.noDisplay }
            let ex = Set(windowNumbers)
            let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { ex.contains(Int($0.windowID)) })

            let scale = scr.backingScaleFactor
            // sourceRect는 화면 안 좌표, 왼쪽 위 원점(pt)
            let local = CGRect(x: rect.minX - scr.frame.minX, y: scr.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
            var w = Int(rect.width * scale), h = Int(rect.height * scale)
            w -= w % 2; h -= h % 2
            let cfg = SCStreamConfiguration()
            if local.size != scr.frame.size { cfg.sourceRect = local }
            cfg.width = w
            cfg.height = h
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(10, min(60, s.recFps))))
            cfg.queueDepth = 8
            cfg.showsCursor = !cursorDrawnByUs()
            cfg.capturesAudio = s.recSys
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 2

            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("classzoom-\(UUID().uuidString).mp4")
            let eng = try RecordEngine(url: tmp, width: w, height: h, system: s.recSys, mic: useMic)
            engine = eng

            let st = SCStream(filter: filter, configuration: cfg, delegate: nil)
            try st.addStreamOutput(eng, type: .screen, sampleHandlerQueue: eng.queue)
            if s.recSys { try st.addStreamOutput(eng, type: .audio, sampleHandlerQueue: eng.queue) }
            try await st.startCapture()
            stream = st

            if useMic, let dev = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: dev) {
                let session = AVCaptureSession()
                let out = AVCaptureAudioDataOutput()
                if session.canAddInput(input) { session.addInput(input) }
                if session.canAddOutput(out) { session.addOutput(out) }
                out.setSampleBufferDelegate(eng, queue: eng.queue)
                session.startRunning()
                micSession = session
            }
            startedAt = CACurrentMediaTime()
            elapsedBefore = 0
            phase = .recording
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updatePill() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            updatePill()
            Log.log("REC", "start \(w)x\(h) sys=\(s.recSys) mic=\(useMic)")
        } catch {
            Log.log("REC", "start failed \(error)")
            cleanUp()
            if error is RecordError { Notice.show(NoticeContent(title: "녹화를 시작하지 못했습니다", body: ["\(error)"])) }
            else { Notice.show(Notice.screenRecordingNeeded(feature: "화면 녹화")) }
        }
    }

    // 확대·드로잉을 켜고 끄면 시스템 커서를 넣을지 다시 정한다
    func updateCursorCapture() {
        guard let st = stream, let scr = screen else { return }
        let s = Settings.shared
        let cfg = SCStreamConfiguration()
        let local = CGRect(x: rect.minX - scr.frame.minX, y: scr.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        let scale = scr.backingScaleFactor
        var w = Int(rect.width * scale), h = Int(rect.height * scale)
        w -= w % 2; h -= h % 2
        if local.size != scr.frame.size { cfg.sourceRect = local }
        cfg.width = w; cfg.height = h
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(10, min(60, s.recFps))))
        cfg.queueDepth = 8
        cfg.showsCursor = !cursorDrawnByUs()
        cfg.capturesAudio = s.recSys
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        Task { try? await st.updateConfiguration(cfg) }
    }

    // ---------- 정지·저장 ----------
    func stop() {
        guard phase == .recording || phase == .paused, let eng = engine else { return }
        if phase == .recording { elapsedBefore += CACurrentMediaTime() - startedAt }
        phase = .saving
        updatePill()
        micSession?.stopRunning(); micSession = nil
        let st = stream; stream = nil
        let final = outURL
        Task { @MainActor in
            try? await st?.stopCapture()
            let result = await eng.finish(to: final)
            self.cleanUp()
            switch result {
            case .success(let url):
                Log.log("REC", "saved \(url.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .failure(let e):
                Log.log("REC", "save failed \(e)")
                Notice.show(NoticeContent(title: "녹화를 저장하지 못했습니다", body: ["\(e.localizedDescription)"]))
            }
        }
    }

    private func cleanUp() {
        timer?.invalidate(); timer = nil
        engine = nil
        pill?.orderOut(nil); pill = nil
        countdown?.orderOut(nil); countdown = nil
        frames.forEach { $0.orderOut(nil) }; frames = []
        phase = .idle
    }

    // 앱을 끌 때: 녹화 중이면 영상을 마무리할 시간을 조금 준다
    func finishBeforeQuit() {
        guard phase == .recording || phase == .paused else { return }
        stop()
        let until = Date().addingTimeInterval(8)
        while phase != .idle && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    }

    // ---------- 카운트다운 (3 · 2 · 1, Esc로 취소) ----------
    private func runCountdown(_ done: @escaping (Bool) -> Void) {
        let size: CGFloat = 150
        let p = NSPanel(contentRect: NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.ignoresMouseEvents = true
        p.level = ZOOM_TOP_LEVEL
        p.collectionBehavior = EVERYWHERE
        p.isReleasedWhenClosed = false
        p.sharingType = .none
        let bg = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(calibratedRed: 0x1E / 255, green: 0x29 / 255, blue: 0x3B / 255, alpha: 0.9).cgColor
        bg.layer?.cornerRadius = size / 2
        let l = NSTextField(labelWithString: "3")
        l.font = .systemFont(ofSize: 72, weight: .bold)
        l.textColor = .white
        l.alignment = .center
        l.frame = NSRect(x: 0, y: (size - 90) / 2, width: size, height: 90)
        bg.addSubview(l)
        p.contentView = bg
        p.orderFrontRegardless()
        countdown = p
        var n = 3
        var escMonitor: Any?
        var cancelled = false
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { e in if e.keyCode == 53 { cancelled = true } }
        func next() {
            if cancelled || phase != .countdown {
                if let m = escMonitor { NSEvent.removeMonitor(m) }
                countdown?.orderOut(nil); countdown = nil
                done(false); return
            }
            if n == 0 {
                if let m = escMonitor { NSEvent.removeMonitor(m) }
                countdown?.orderOut(nil); countdown = nil
                done(true); return
            }
            l.stringValue = "\(n)"
            n -= 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { next() }
        }
        next()
    }

    // ---------- 녹화 표시창 (● 녹화 중 01:23 [일시정지] [정지]) ----------
    private func showPill() {
        let w: CGFloat = 320, h: CGFloat = 40
        let y = rect.maxY + h + 10 <= (screen?.visibleFrame.maxY ?? .infinity) ? rect.maxY + 10 : rect.maxY - h - 10
        let p = NSPanel(contentRect: NSRect(x: rect.midX - w / 2, y: y, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = ZOOM_TOP_LEVEL
        p.collectionBehavior = EVERYWHERE
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.sharingType = .none
        let bg = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(calibratedRed: 0x1E / 255, green: 0x29 / 255, blue: 0x3B / 255, alpha: 0.95).cgColor
        bg.layer?.cornerRadius = h / 2
        let dot = NSTextField(labelWithString: "●")
        dot.textColor = NSColor(calibratedRed: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1)
        dot.font = .systemFont(ofSize: 14, weight: .bold)
        dot.frame = NSRect(x: 14, y: 10, width: 18, height: 20)
        let t = NSTextField(labelWithString: "녹화 준비 중")
        t.textColor = .white
        t.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        t.frame = NSRect(x: 34, y: 10, width: 120, height: 20)
        let pause = NSButton(title: "일시정지", target: self, action: #selector(pillPauseClicked))
        pause.bezelStyle = .rounded
        pause.frame = NSRect(x: 156, y: 6, width: 84, height: 28)
        let stopB = NSButton(title: "정지", target: self, action: #selector(pillStopClicked))
        stopB.bezelStyle = .rounded
        stopB.frame = NSRect(x: 244, y: 6, width: 64, height: 28)
        [dot, t, pause, stopB].forEach(bg.addSubview)
        p.contentView = bg
        p.orderFrontRegardless()
        pill = p; pillTime = t; pillPause = pause
    }

    @objc private func pillPauseClicked() { pauseToggle() }
    @objc private func pillStopClicked() { stop() }

    private func updatePill() {
        let secs = Int(elapsedBefore + (phase == .recording ? CACurrentMediaTime() - startedAt : 0))
        let t = secs >= 3600 ? String(format: "%d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60) : String(format: "%02d:%02d", secs / 60, secs % 60)
        switch phase {
        case .recording: pillTime?.stringValue = "녹화 중 \(t)"; pillPause?.title = "일시정지"; pillPause?.isEnabled = true
        case .paused: pillTime?.stringValue = "일시정지 \(t)"; pillPause?.title = "계속"; pillPause?.isEnabled = true
        case .saving: pillTime?.stringValue = "저장 중…"; pillPause?.isEnabled = false
        default: break
        }
    }

    // ---------- 영역 테두리 (영역 바깥에 그려 영상에 들어가지 않는다) ----------
    private func showFrames(around r: CGRect) {
        let b: CGFloat = 3
        let rects = [CGRect(x: r.minX - b, y: r.maxY, width: r.width + 2 * b, height: b),
                     CGRect(x: r.minX - b, y: r.minY - b, width: r.width + 2 * b, height: b),
                     CGRect(x: r.minX - b, y: r.minY, width: b, height: r.height),
                     CGRect(x: r.maxX, y: r.minY, width: b, height: r.height)]
        frames = rects.map { fr in
            let w = NSWindow(contentRect: fr, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = true
            w.backgroundColor = NSColor(calibratedRed: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1)
            w.ignoresMouseEvents = true
            w.level = ZOOM_TOP_LEVEL
            w.collectionBehavior = EVERYWHERE
            w.isReleasedWhenClosed = false
            w.sharingType = .none
            w.orderFrontRegardless()
            return w
        }
    }
}

enum RecordError: Error, CustomStringConvertible {
    case noDisplay, writer(String)
    var description: String {
        switch self {
        case .noDisplay: return "녹화할 화면을 찾지 못했습니다."
        case .writer(let s): return "영상 파일을 만들지 못했습니다. (\(s))"
        }
    }
}

// ---------- 받은 것을 파일에 쓰기 (writeQueue에서만 돈다) ----------
final class RecordEngine: NSObject, SCStreamOutput, AVCaptureAudioDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "classzoom.record")
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let sysAudio: AVAssetWriterInput?
    private let micAudio: AVAssetWriterInput?
    private let url: URL
    private var started = false
    private var paused = false
    private var pausedAt = CMTime.invalid
    private var offset = CMTime.zero
    private var finished = false

    init(url: URL, width: Int, height: Int, system: Bool, mic: Bool) throws {
        self.url = url
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) } catch { throw RecordError.writer(error.localizedDescription) }
        let bitrate = max(2_000_000, width * height * 4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoExpectedSourceFrameRateKey: 30],
        ])
        video.expectsMediaDataInRealTime = true
        func audio(_ ch: Int) -> AVAssetWriterInput {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: ch, AVEncoderBitRateKey: 160_000,
            ])
            a.expectsMediaDataInRealTime = true
            return a
        }
        sysAudio = system ? audio(2) : nil
        micAudio = mic ? audio(1) : nil
        super.init()
        guard writer.canAdd(video) else { throw RecordError.writer("video") }
        writer.add(video)
        for a in [sysAudio, micAudio] { if let a, writer.canAdd(a) { writer.add(a) } }
    }

    func pause() { queue.async { self.paused = true; self.pausedAt = CMClockGetTime(CMClockGetHostTimeClock()) } }
    func resume() {
        queue.async {
            if self.pausedAt.isValid { self.offset = CMTimeAdd(self.offset, CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), self.pausedAt)) }
            self.pausedAt = .invalid
            self.paused = false
        }
    }

    // 화면·컴퓨터 소리 (ScreenCaptureKit)
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen:
            guard let attach = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attach.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            append(sb, to: video, isVideo: true)
        case .audio:
            if let a = sysAudio { append(sb, to: a, isVideo: false) }
        default:
            break
        }
    }

    // 마이크 (AVCaptureSession)
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let a = micAudio { append(sb, to: a, isVideo: false) }
    }

    private func append(_ sb: CMSampleBuffer, to input: AVAssetWriterInput, isVideo: Bool) {
        guard !finished, !paused else { return }
        if !started {
            guard isVideo else { return } // 첫 화면이 들어온 때부터 시작한다
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sb))
            started = true
        }
        guard input.isReadyForMoreMediaData, let shifted = shift(sb) else { return }
        input.append(shifted)
    }

    // 일시정지한 시간만큼 당긴다
    private func shift(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
        guard offset != .zero else { return sb }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var info = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(1, count))
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &info, entriesNeededOut: &count)
        for i in 0..<info.count {
            if info[i].presentationTimeStamp.isValid { info[i].presentationTimeStamp = CMTimeSubtract(info[i].presentationTimeStamp, offset) }
            if info[i].decodeTimeStamp.isValid { info[i].decodeTimeStamp = CMTimeSubtract(info[i].decodeTimeStamp, offset) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: info.count, sampleTimingArray: &info, sampleBufferOut: &out)
        return out
    }

    // 마무리: 파일을 닫고, 소리 트랙이 둘이면 하나로 섞어 최종 자리에 둔다
    func finish(to final: URL?) async -> Result<URL, Error> {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.finished = true
                guard self.started else { c.resume(); return }
                self.video.markAsFinished()
                self.sysAudio?.markAsFinished()
                self.micAudio?.markAsFinished()
                self.writer.finishWriting { c.resume() }
            }
        }
        guard started, writer.status == .completed, let final else {
            return .failure(RecordError.writer(writer.error?.localizedDescription ?? "녹화된 화면이 없습니다"))
        }
        let audioTracks = [sysAudio, micAudio].compactMap { $0 }.count
        if audioTracks < 2 {
            do {
                try? FileManager.default.removeItem(at: final)
                try FileManager.default.moveItem(at: url, to: final)
                return .success(final)
            } catch { return .failure(error) }
        }
        // 컴퓨터 소리 + 마이크를 한 트랙으로 섞는다
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            try? FileManager.default.moveItem(at: url, to: final)
            return .success(final)
        }
        export.outputURL = final
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await export.export()
        if export.status == .completed {
            try? FileManager.default.removeItem(at: url)
            return .success(final)
        }
        // 섞기에 실패하면 섞지 않은 파일이라도 남긴다
        try? FileManager.default.moveItem(at: url, to: final)
        return .success(final)
    }
}

// ---------- 영역 고르기: 화면을 살짝 어둡게 덮고 끌어서 고른다 (Esc·오른쪽 클릭 = 취소) ----------
@MainActor final class AreaPicker {
    private var windows: [NSWindow] = []
    private var done: ((CGRect?) -> Void)?
    private var monitors: [Any] = []
    var windowNumbers: [Int] { windows.map(\.windowNumber) }

    final class PickView: NSView {
        var start: NSPoint?
        var current: NSPoint?
        var onFinish: (CGRect?) -> Void = { _ in }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
        // 라이브 줌 중이면 진짜 커서가 아니라 확대 화면에 보이는 커서 자리로 고른다 (녹화는 보이는 화면을 담는다)
        private var at: NSPoint { ZoomMap.screenPoint(NSEvent.mouseLocation) }
        override func mouseDown(with e: NSEvent) { start = at; current = start; needsDisplay = true }
        override func mouseDragged(with e: NSEvent) { current = at; needsDisplay = true }
        override func mouseUp(with e: NSEvent) {
            guard let a = start else { onFinish(nil); return }
            let b = at
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            onFinish(r.width >= 40 && r.height >= 40 ? r : nil)
        }
        override func rightMouseDown(with e: NSEvent) { onFinish(nil) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 0, alpha: 0.28).setFill()
            bounds.fill()
            guard let a = start, let b = current, let w = window else { return }
            let la = w.convertPoint(fromScreen: a), lb = w.convertPoint(fromScreen: b)
            let r = NSRect(x: min(la.x, lb.x), y: min(la.y, lb.y), width: abs(la.x - lb.x), height: abs(la.y - lb.y))
            NSColor.clear.setFill()
            r.fill(using: .copy)
            NSColor(calibratedRed: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255, alpha: 1).setStroke()
            let p = NSBezierPath(rect: r); p.lineWidth = 2; p.stroke()
        }
    }

    final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    func pick(_ completion: @escaping (CGRect?) -> Void) {
        done = completion
        for scr in NSScreen.screens {
            let w = KeyPanel(contentRect: scr.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.level = ZOOM_TOP_LEVEL
            w.collectionBehavior = EVERYWHERE
            w.isReleasedWhenClosed = false
            w.sharingType = .none
            let v = PickView(frame: NSRect(origin: .zero, size: scr.frame.size))
            v.onFinish = { [weak self] r in self?.finish(r) }
            w.contentView = v
            w.setFrame(scr.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        windows.first?.makeKey()
        let esc: (NSEvent) -> Void = { [weak self] e in if e.keyCode == 53 { self?.finish(nil) } }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: esc) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { esc($0); return nil }) { monitors.append(l) }
        Log.log("REC", "pick area")
    }

    private func finish(_ r: CGRect?) {
        guard let d = done else { return }
        done = nil
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        windows.forEach { $0.orderOut(nil) }; windows = []
        d(r)
    }
}
