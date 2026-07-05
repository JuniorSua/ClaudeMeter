import AppKit

@main
struct ClaudeMeterApp {
    // NSApplication.delegate is weak — this static keeps the delegate alive
    // for the app's lifetime (a local would be released in release builds).
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
