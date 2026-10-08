import os

/// `log stream --predicate 'subsystem == "com.screenshooter.app"' --level debug` shows these.
enum Log {
    static let capture = Logger(subsystem: "com.screenshooter.app", category: "capture")
    static let island = Logger(subsystem: "com.screenshooter.app", category: "island")
}
