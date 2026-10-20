import SwiftUI

// MARK: - Owl Sprite
//
// The HUD's mascot, drawn the way an NES cart would draw it:
// - 24x24 metasprite (3x3 tiles of 8x8), shown at a whole-number scale.
// - Two sprite palettes of 3 colours + transparent. The body uses one; the
//   beak, quill and sweat drop sit on an overlay layer with the other (the
//   Mega Man face trick for more colour on one character).
// - Colours are picked from the NES master palette.
// - Animation is held frames at 15 ticks/s (one tick = 4 NES frames).
//   No easing, no tweening: a hop moves in whole pixels.
//
// Art is plain text so a diff shows the change. '.' is transparent.

enum OwlPalette {
    /// Body palette: 0x07 dark, 0x18 brown, 0x37 cream.
    /// Overlay palette: 0x27 orange, 0x30 white, 0x2C sky.
    static let colors: [Character: Color] = [
        "D": Color(nesHex: 0x881400),
        "B": Color(nesHex: 0xAC7C00),
        "C": Color(nesHex: 0xFCE0A8),
        "Y": Color(nesHex: 0xFCA044),
        "W": Color(nesHex: 0xFCFCFC),
        "L": Color(nesHex: 0x3CBCFC)
    ]
}

enum OwlEyes {
    case open, down, closed, up, happy, dizzy

    /// The 4x4 inside of each spectacle ring, top to bottom.
    var interior: [String] {
        switch self {
        case .open:   return ["CCCC", "CWDC", "CDDC", "CCCC"]
        case .down:   return ["CCCC", "CCCC", "CWDC", "CDDC"]
        case .closed: return ["CCCC", "CCCC", "DDDD", "CCCC"]
        case .up:     return ["WDCC", "DDCC", "CCCC", "CCCC"]
        case .happy:  return ["CCCC", "CDDC", "DCCD", "CCCC"]
        case .dizzy:  return ["DDCC", "CCDD", "CCDD", "DDCC"]
        }
    }

    /// Mirror the right eye so `>` pairs with `<`. Off for the rest: their
    /// catchlights must sit on the same side, as if lit from one lamp.
    var mirrorsRightEye: Bool { self == .dizzy }
}

enum OwlArt {
    static let size = 24

    /// Body with the eye rows (9-12) left for `body(eyes:)` to fill.
    private static let bodyTemplate: [String] = [
        "........................",
        "........................",
        "........................",
        "...DD............DD.....",
        "...DBD..........DBD.....",
        "...DBBDDDDDDDDDDBBD.....",
        "..DBBBBBBBBBBBBBBBBD....",
        "..DBBBBBBBBBBBBBBBBD....",
        "..DBBDDDDBBBBDDDDBBD....",
        "", "", "", "",
        "..DBBDDDDBYYBDDDDBBD....",
        "..DBBBBBCCCCCCBBBBBD....",
        "..DBDBBCCCCCCCCBBDBD....",
        "..DBDBCCBCCCCBCCBDBD....",
        "..DBDBCCCBCCBCCCBDBD....",
        "..DBDBCCCCCCCCCCBDBD....",
        "..DBBDBCCCCCCCCBDBBD....",
        "...DBBBBCCCCCCBBBBD.....",
        "....DDDDDDDDDDDDDD......",
        ".......YYY....YYY.......",
        "........................"
    ]

    /// Middle columns between the rings, per eye row: forehead, bridge, beak.
    private static let eyeMids = ["BB", "DD", "BB", "YY"]

    static func body(eyes: OwlEyes) -> [String] {
        var rows = bodyTemplate
        for (i, inner) in eyes.interior.enumerated() {
            let right = eyes.mirrorsRightEye ? String(inner.reversed()) : inner
            rows[9 + i] = "..DB" + "D\(inner)D" + eyeMids[i] + "D\(right)D" + "BD...."
        }
        return rows
    }

    /// Quill held in the right wing, nib at bottom left. 7x8, overlay palette
    /// plus the body's dark for the nib.
    static let quill: [String] = [
        "......W",
        ".....WW",
        "....WWW",
        "...WWW.",
        "..WWW..",
        "..WW...",
        ".W.....",
        "D......"
    ]

    static let sweat: [String] = [
        ".L.",
        "LLL",
        "LLL",
        ".L."
    ]
}

/// One drawable layer: a grid placed at a pixel offset.
struct OwlLayer {
    let rows: [String]
    var dx = 0
    var dy = 0
}

enum OwlPose {
    case idle, blink, writeDown, writeUp, think, thinkBlink, happy(hop: Int), dizzy(shake: Int)

    var layers: [OwlLayer] {
        let quillRest = OwlLayer(rows: OwlArt.quill, dx: 16, dy: 12)
        switch self {
        case .idle:
            return [OwlLayer(rows: OwlArt.body(eyes: .open)), quillRest]
        case .blink:
            return [OwlLayer(rows: OwlArt.body(eyes: .closed)), quillRest]
        case .writeDown:
            return [OwlLayer(rows: OwlArt.body(eyes: .down)), OwlLayer(rows: OwlArt.quill, dx: 15, dy: 14)]
        case .writeUp:
            return [OwlLayer(rows: OwlArt.body(eyes: .down)), OwlLayer(rows: OwlArt.quill, dx: 16, dy: 12)]
        case .think:
            return [OwlLayer(rows: OwlArt.body(eyes: .up)), quillRest]
        case .thinkBlink:
            return [OwlLayer(rows: OwlArt.body(eyes: .closed)), quillRest]
        case .happy(let hop):
            return [OwlLayer(rows: OwlArt.body(eyes: .happy), dy: -hop),
                    OwlLayer(rows: OwlArt.quill, dx: 16, dy: 12 - hop)]
        case .dizzy(let shake):
            return [OwlLayer(rows: OwlArt.body(eyes: .dizzy), dx: shake),
                    OwlLayer(rows: OwlArt.sweat, dx: 19 + shake, dy: 4),
                    quillRest]
        }
    }
}

// MARK: - Choreography

/// What the owl is doing. Maps from the HUD state.
public enum OwlMood: Equatable {
    case listening(speaking: Bool)
    case thinking
    case done
    case failed
}

enum OwlScript {
    static let ticksPerSecond = 15.0

    /// `tick` counts from when the mood started, so one-shot moves (hop,
    /// shake) play once from the top.
    static func pose(for mood: OwlMood, tick: Int) -> OwlPose {
        switch mood {
        case .listening(speaking: true):
            // Two-frame scribble, two ticks each (~3.75 strokes/s).
            return (tick / 2).isMultiple(of: 2) ? .writeDown : .writeUp
        case .listening(speaking: false):
            // Hold, then blink. A double blink every third cycle keeps it alive.
            let t = tick % 45
            if t < 2 { return .blink }
            if tick % 135 < 45, t >= 4, t < 6 { return .blink }
            return .idle
        case .thinking:
            return tick % 30 < 2 ? .thinkBlink : .think
        case .done:
            // Whole-pixel jump: up 2, 3, 3, 2, land; then a smaller hop.
            let arc = [0, 2, 3, 3, 2, 0, 0, 1, 1, 0]
            return .happy(hop: tick < arc.count ? arc[tick] : 0)
        case .failed:
            let shake = [1, -1, 1, -1, 1, -1]
            return .dizzy(shake: tick < shake.count ? shake[tick] : 0)
        }
    }
}

// MARK: - View

public struct OwlSpriteView: View {
    let mood: OwlMood
    let moodStartedAt: Date
    var scale: CGFloat = 2
    var paused = false

    public init(mood: OwlMood, moodStartedAt: Date, scale: CGFloat = 2, paused: Bool = false) {
        self.mood = mood
        self.moodStartedAt = moodStartedAt
        self.scale = scale
        self.paused = paused
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1 / OwlScript.ticksPerSecond, paused: paused)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(moodStartedAt))
            let pose = OwlScript.pose(for: mood, tick: Int(elapsed * OwlScript.ticksPerSecond))
            Canvas { gc, _ in
                for layer in pose.layers {
                    draw(layer, in: &gc)
                }
            }
        }
        .frame(width: CGFloat(OwlArt.size) * scale, height: CGFloat(OwlArt.size) * scale)
        .accessibilityHidden(true)
    }

    private func draw(_ layer: OwlLayer, in gc: inout GraphicsContext) {
        for (y, row) in layer.rows.enumerated() {
            for (x, ch) in row.enumerated() {
                guard let color = OwlPalette.colors[ch] else { continue }
                let rect = CGRect(
                    x: CGFloat(x + layer.dx) * scale,
                    y: CGFloat(y + layer.dy) * scale,
                    width: scale, height: scale
                )
                gc.fill(Path(rect), with: .color(color))
            }
        }
    }
}

private extension Color {
    init(nesHex hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
