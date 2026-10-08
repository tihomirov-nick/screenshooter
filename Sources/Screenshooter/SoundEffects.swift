import AppKit
import AudioToolbox

/// Short sounds for the moments that matter. They are macOS's own interface sounds, read from disk while
/// the app runs (never copied into it), and play the way the system's own do, the screenshot shutter
/// included: at the alert volume of System Settings → Sound, through the device chosen there for sound
/// effects, and only while interface sound effects are on there. Nothing plays while "Sound effects" is
/// off in the app's settings.
enum SoundEffects {
    enum Event {
        /// A capture was taken.
        case shutter
        /// Text was recognised and copied.
        case success
        /// Something went wrong: no text found, a capture or a file could not be kept.
        case failure
        /// Put on the shelf.
        case added
        /// Copied to the clipboard.
        case copied
        /// Taken off the shelf or moved to the Trash.
        case removed
        /// Saved to a file or into a folder.
        case sent

        /// The file under the system sounds folder, and the sound from /System/Library/Sounds to play
        /// if that file is missing.
        fileprivate var sound: (path: String, fallback: String) {
            switch self {
            case .shutter: return ("system/Screen Capture.aif", "Tink")
            case .success: return ("system/head_gestures_double_nod.caf", "Glass")
            case .failure: return ("system/head_gestures_double_shake.caf", "Basso")
            case .added, .copied: return ("system/head_gestures_partial_nod.caf", "Tink")
            case .removed: return ("dock/poof item off dock.aif", "Pop")
            case .sent: return ("system/SentMessage.caf", "Purr")
            }
        }
    }

    private static let folder = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/"
    /// Registers and plays the sounds, so the main thread never waits for a file.
    private static let queue = DispatchQueue(label: "Screenshooter.Sounds", qos: .userInitiated)
    /// One system sound per file, made on first use. Touched on `queue` only.
    private static var registered: [String: SystemSoundID] = [:]

    static func play(_ event: Event) {
        guard Prefs.soundEffects else { return }
        let sound = event.sound
        queue.async {
            if let id = systemSound(sound.path) {
                AudioServicesPlaySystemSound(id)
            } else {
                DispatchQueue.main.async { NSSound(named: sound.fallback)?.play() }
            }
        }
    }

    private static func systemSound(_ path: String) -> SystemSoundID? {
        if let id = registered[path] { return id }
        let url = URL(fileURLWithPath: folder + path)
        var id: SystemSoundID = 0
        guard FileManager.default.fileExists(atPath: url.path),
              AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError else { return nil }
        registered[path] = id
        return id
    }
}
