import Foundation
import os

/// Local debug logging only. Never logs prompt/completion content.
enum AppLog {
    static let general = os.Logger(subsystem: "com.local.ClaudeMeter", category: "general")
    static let scanner = os.Logger(subsystem: "com.local.ClaudeMeter", category: "scanner")
}
