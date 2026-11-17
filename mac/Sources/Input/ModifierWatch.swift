import AppKit

// ================= 드로잉 중에만 도는 20Hz 살핌 =================
// C안 판은 키 창이 아니어서 flagsChanged가 오지 않는다. 그래서 드로잉 중에만 ⌥ 상태를 직접 읽는다
// (CGEventSource.flagsState — 권한 불필요, D3). 같은 박자로 "포인터 아래 창"과 시스템 커서 숨김도 살핀다.
// 드로잉을 끄면 멈춘다 — 쉬는 동안 도는 타이머는 없다.
@MainActor final class ModifierWatch {
    var onTick: () -> Void = {}
    private var timer: Timer?
    var isRunning: Bool { timer != nil }

    // ⌥가 지금 눌려 있는가
    nonisolated static func optionDown() -> Bool { CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) }
    // 왼쪽·오른쪽 ⌥를 따로 (키 자리 58 = 왼쪽, 61 = 오른쪽). 오른쪽 ⌥는 "누르는 동안 드로잉", 왼쪽 ⌥는 지우개다.
    nonisolated static func leftOptionDown() -> Bool { CGEventSource.keyState(.combinedSessionState, key: 58) }
    nonisolated static func rightOptionDown() -> Bool { CGEventSource.keyState(.combinedSessionState, key: 61) }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }
}
