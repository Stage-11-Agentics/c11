import Foundation

/// Finds where hc's paint ends in a viewer stream (ticket 5, contract L5).
///
/// hc's attach reply has no paint length, control frames overtake stream
/// data, and frame boundaries are not paint boundaries. What the pin does
/// guarantee (hc 0.1.16, `viewers.rs` `paint_state` and `ghostty-vt`
/// `Terminal::paint`):
///
/// - every paint (first paint, the repaint that replaces a dropped backlog,
///   a recovered paint) starts with `CAN` and one fixed mode-reset prelude;
/// - after history, screen and title it always carries exactly one
///   `CSI ? 9001 h|l`, a mode Ghostty's formatter never emits; status records
///   and an optional half-received sequence follow it;
/// - the first paint is queued atomically with the channel's open, so it is
///   the first byte run on a new channel.
///
/// So the screen is complete once the first `CSI ? 9001 h|l` after a prelude
/// has been parsed. Anything else is not proof: a stream that does not open
/// with the prelude is `unprovable`, and a pin this layout was not read from
/// never becomes `painted`.
///
/// Pure value; scans each byte once, allocation-free. Callers feed it the
/// bytes they have handed to `ghostty_surface_process_output`, which parses
/// synchronously (`Termio.processOutput`).
struct HCPaintBoundaryScanner: Sendable {
    enum Phase: Equatable, Sendable {
        /// Fresh attachment: the first bytes must be a paint prelude.
        case awaitingPaint
        /// A CAN arrived outside a paint: a new paint may be starting (hc
        /// replaces a dropped backlog with a fresh paint, and credit chunking
        /// can split its prelude anywhere). The earlier receipt is revoked
        /// from this byte on; if the prelude does not follow, the scanner
        /// returns to the phase it was in.
        case inPrelude
        /// A prelude was seen; its end marker has not been parsed yet.
        case inPaint
        /// The paint whose end marker ended at `watermark` (bytes scanned,
        /// counting from the attachment's first byte) is fully parsed.
        case painted(watermark: UInt64)
        /// No paint boundary can be proven from what was seen.
        case unprovable
    }

    /// hc versions whose paint layout this scanner was read from.
    static let provedPins: Set<String> = ["0.1.16"]

    /// `CAN` + `Terminal::paint`'s fixed prelude, byte for byte.
    static let prelude: [UInt8] = [0x18] + Array((
        "\u{1b}[!p\u{1b}[?2026l\u{1b}[?9l\u{1b}[?1000l\u{1b}[?1001l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1004l"
        + "\u{1b}[?1005l\u{1b}[?1006l\u{1b}[?1015l\u{1b}[?1016l\u{1b}[?2004l\u{1b}[?1l\u{1b}[?66l\u{1b}[?2031l"
        + "\u{1b}[?2048l\u{1b}[=0;1u\u{1b}[?1049l\u{1b}[?1047l\u{1b}[?47l\u{1b}[H\u{1b}[2J"
    ).utf8)

    /// `CSI ? 9001`, followed by `h` or `l`.
    static let endMarker: [UInt8] = Array("\u{1b}[?9001".utf8)

    /// A paint larger than this never ends for our purposes (hc's default
    /// history is 5 MB). Past it the boundary is unprovable until a new prelude.
    static let maxPaintBytes: UInt64 = 32 * 1024 * 1024

    private(set) var phase: Phase
    /// Bytes scanned since the attachment started.
    private(set) var scannedBytes: UInt64 = 0
    /// Paints whose end marker was parsed on this attachment.
    private(set) var completedPaints: UInt64 = 0

    private var preludeIndex = 0
    private var markerIndex = 0
    private var paintStart: UInt64 = 0
    /// Where `inPrelude` returns when the bytes after a CAN are not a prelude.
    private var resumePhase: Phase = .unprovable

    /// - Parameter pinVersion: the serving hc version; outside `provedPins`
    ///   the scanner is `unprovable` and stays that way.
    init(pinVersion: String) {
        phase = Self.provedPins.contains(pinVersion) ? .awaitingPaint : .unprovable
        pinProved = Self.provedPins.contains(pinVersion)
    }

    private let pinProved: Bool

    var isPainted: Bool {
        if case .painted = phase { return true }
        return false
    }

    mutating func scan(_ data: Data) {
        data.withUnsafeBytes { scan($0) }
    }

    mutating func scan(_ buffer: UnsafeRawBufferPointer) {
        guard pinProved, let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            scannedBytes &+= UInt64(buffer.count)
            return
        }
        let count = buffer.count
        let prelude = Self.prelude
        let marker = Self.endMarker
        var i = 0
        while i < count {
            // Outside a paint, with no partial prelude, skip straight to the
            // next CAN: CAN occurs only at the prelude's first byte.
            if phase != .inPaint, phase != .awaitingPaint, preludeIndex == 0 {
                guard let found = memchr(base + i, 0x18, count - i) else {
                    scannedBytes &+= UInt64(count - i)
                    return
                }
                let skip = UnsafeRawPointer(found) - UnsafeRawPointer(base + i)
                scannedBytes &+= UInt64(skip)
                i += skip
            }
            let byte = base[i]
            i += 1
            scannedBytes &+= 1

            // Prelude: may restart a paint at any point (a dropped backlog is
            // replaced by a new paint, possibly cutting an earlier one short).
            if byte == prelude[preludeIndex] {
                if preludeIndex == 0, phase != .inPaint, phase != .awaitingPaint, phase != .inPrelude {
                    // Revoke at the first byte a new paint could start with.
                    resumePhase = phase
                    phase = .inPrelude
                }
                preludeIndex += 1
                if preludeIndex == prelude.count {
                    preludeIndex = 0
                    markerIndex = 0
                    phase = .inPaint
                    paintStart = scannedBytes
                    continue
                }
            } else {
                if phase == .inPrelude {
                    // Not a paint after all: CAN in the program's own output.
                    phase = resumePhase
                }
                preludeIndex = 0
                if phase == .awaitingPaint {
                    // The attachment did not open with a paint: no proof.
                    phase = .unprovable
                }
                if byte == 0x18 {
                    preludeIndex = 1
                    if phase != .inPaint {
                        resumePhase = phase
                        phase = .inPrelude
                    }
                }
            }

            guard phase == .inPaint else { continue }
            if markerIndex == marker.count {
                if byte == 0x68 || byte == 0x6c { // 'h' / 'l'
                    markerIndex = 0
                    phase = .painted(watermark: scannedBytes)
                    completedPaints &+= 1
                    continue
                }
                markerIndex = 0
            }
            if byte == marker[markerIndex] {
                markerIndex += 1
            } else {
                markerIndex = byte == 0x1b ? 1 : 0
            }
            if scannedBytes &- paintStart > Self.maxPaintBytes {
                phase = .unprovable
                markerIndex = 0
            }
        }
    }
}
