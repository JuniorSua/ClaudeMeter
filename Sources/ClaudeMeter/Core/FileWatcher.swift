import Foundation
import CoreServices

/// Recursive FSEvents watcher with debounce. Callback fires on the main queue.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.local.ClaudeMeter.filewatcher")
    private var pending: DispatchWorkItem?
    private let debounce: TimeInterval
    private let onChange: () -> Void

    init?(paths: [String], debounce: TimeInterval = 1.0, onChange: @escaping () -> Void) {
        self.debounce = debounce
        self.onChange = onChange

        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().fire()
        }
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func fire() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async(execute: self.onChange)
        }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
