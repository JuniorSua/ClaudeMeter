import Foundation

/// Periodic refresh timer with a configurable interval.
final class RefreshScheduler {
    private var timer: Timer?
    private let onTick: () -> Void

    init(onTick: @escaping () -> Void) {
        self.onTick = onTick
    }

    func start(intervalSeconds: Int) {
        stop()
        let interval = TimeInterval(max(15, intervalSeconds))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.onTick()
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
