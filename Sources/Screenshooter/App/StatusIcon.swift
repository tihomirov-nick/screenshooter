import AppKit
import QuartzCore

/// The menu bar icon: the app icon's view down a gun barrel, in lines. The ring of the muzzle, three grooves of the
/// rifling turning in, and the far end of the bore as a small ring. It is drawn in code as a template image and stands
/// level with FaceID's icon next to it: the same square status item, a glyph as big as FaceID's (14.3 pt across, which a
/// Retina menu bar shows as 14.5 pt) with its centre where FaceID's sits, and the same line width.
///
/// It moves only at moments that matter and for well under a second: the rifling turns when a capture is taken, as if
/// the barrel rotated, the icon bounces lightly when something lands on the shelf, and the rifling pulses softly while a
/// capture is in progress. Frames are drawn only while it moves; with Reduce Motion it never does.
@MainActor
final class StatusIcon {
    static let shared = StatusIcon()

    /// The line width of FaceID's menu bar icon, measured on the SF Symbol it draws (faceid, 15 pt, regular). One place
    /// to follow it when FaceID's icon changes.
    nonisolated static let lineWidth: CGFloat = 1.18
    /// The glyph across, outer edge to outer edge: FaceID's glyph is as wide and as high.
    nonisolated static let diameter: CGFloat = 14.31
    /// The canvas, with room above the glyph for the bounce.
    nonisolated static let canvas = NSSize(width: 18, height: 18)
    /// FaceID's glyph sits a quarter point right of and below the middle of its status item (on a pixel centre of a
    /// Retina screen); so does this one.
    nonisolated static let center = NSPoint(x: 9.25, y: 9.25)

    enum Motion {
        /// The rifling turns by one groove.
        case turn
        /// The icon hops and lands.
        case bounce

        var duration: CFTimeInterval {
            switch self {
            case .turn: return 0.45
            case .bounce: return 0.55
            }
        }
    }

    private weak var button: NSStatusBarButton?
    private var timer: Timer?
    private var motion: (kind: Motion, start: CFTimeInterval)?
    private var pulseStart: CFTimeInterval?

    private init() {}

    func attach(to button: NSStatusBarButton) {
        self.button = button
        button.image = Self.image()
    }

    func play(_ kind: Motion) {
        guard !Self.reduceMotion else { return }
        motion = (kind, CACurrentMediaTime())
        run()
    }

    /// The rifling pulses while a capture is in progress.
    var capturing = false {
        didSet {
            guard capturing != oldValue else { return }
            pulseStart = capturing && !Self.reduceMotion ? CACurrentMediaTime() : nil
            if pulseStart != nil { run() } else { tick() }
        }
    }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func run() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        var turn: CGFloat = 0
        var lift: CGFloat = 0
        var rifling: CGFloat = 1
        if let pulseStart {
            rifling = Self.pulse(now - pulseStart)
        }
        if let motion {
            let t = (now - motion.start) / motion.kind.duration
            if t >= 1 {
                self.motion = nil
            } else {
                switch motion.kind {
                case .turn: turn = Self.turn(t)
                case .bounce: lift = Self.bounce(t)
                }
            }
        }
        button?.image = Self.image(turn: turn, lift: lift, rifling: rifling)
        if motion == nil, pulseStart == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    /// How far the rifling has turned over the motion, t from 0 to 1: a third of a turn, from one groove to the next,
    /// slow at both ends, so it starts and stops on the icon at rest.
    static func turn(_ t: Double) -> CGFloat {
        let eased = t * t * (3 - 2 * t)
        return CGFloat(eased) * 2 * .pi / 3
    }

    /// How opaque the rifling is while a capture is in progress: down to half and back, every 1.2 s.
    static func pulse(_ seconds: Double) -> CGFloat {
        1 - 0.275 * (1 - cos(2 * .pi * seconds / 1.2))
    }

    /// How high the icon is over the bounce: a hop and a small second one, within the canvas.
    static func bounce(_ t: Double) -> CGFloat {
        if t < 0.6 { return 1.0 * sin(.pi * t / 0.6) }
        if t < 0.9 { return 0.3 * sin(.pi * (t - 0.6) / 0.3) }
        return 0
    }

    /// `turn` rotates the rifling (radians), `lift` raises the whole icon, `rifling` is the opacity of the grooves and
    /// of the far end of the bore.
    static func image(turn: CGFloat = 0, lift: CGFloat = 0, rifling: CGFloat = 1) -> NSImage {
        let image = NSImage(size: canvas, flipped: true) { _ in
            let c = NSPoint(x: center.x, y: center.y - lift)
            let muzzle = (diameter - lineWidth) / 2
            let bore: CGFloat = 2.2
            func stroke(_ path: NSBezierPath, opacity: CGFloat) {
                NSColor.black.withAlphaComponent(opacity).setStroke()
                path.lineWidth = lineWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
            stroke(NSBezierPath(ovalIn: NSRect(x: c.x - muzzle, y: c.y - muzzle, width: 2 * muzzle, height: 2 * muzzle)), opacity: 1)
            // The rifling: three logarithmic spirals from the muzzle to the far end of the bore, turning faster deeper in.
            let grooves = NSBezierPath()
            for k in 0..<3 {
                let start = CGFloat(k) * 2 * .pi / 3 - .pi / 2 + turn
                for i in 0...48 {
                    let f = CGFloat(i) / 48
                    let r = muzzle * pow(bore / muzzle, f), a = start + 2.0 * f
                    let point = NSPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                    if i == 0 { grooves.move(to: point) } else { grooves.line(to: point) }
                }
            }
            grooves.appendOval(in: NSRect(x: c.x - bore, y: c.y - bore, width: 2 * bore, height: 2 * bore))
            stroke(grooves, opacity: rifling)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Screenshooter"
        return image
    }
}
