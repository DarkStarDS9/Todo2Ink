import Foundation

/// Todo2Ink's tile on the device's sleep screen: a 1-bit-per-pixel bitmap the firmware stores per
/// peer as `icon.bin`.
///
/// Drawn in code rather than shipped as an image asset — same reasoning as Snap2Ink's
/// `DeviceIcon.swift`: the device advertises its icon dimensions in the capability characteristic,
/// so the app has to be able to produce whatever size it is asked for, which a fixed-size bundled
/// PNG could not, and it makes the icon a pure function, testable without a bundle at all.
///
/// Row-major, MSB-first within each byte, rows padded to whole bytes, **a set bit is ink** — all
/// four stated in `docs/companion-display-protocol.md` § "Icon field".
///
/// The subject is a checklist — a page with three item rows, the top one checked — since that reads
/// clearly at 64×64 on a monochrome panel and matches what the app actually syncs.
enum DeviceIcon {

    /// Today's size per the protocol document (512 bytes packed); what to draw before a device has
    /// said otherwise.
    static let assumedSize = 64

    /// Renders the icon as a grid of "is this pixel ink", row-major, top-down.
    ///
    /// All geometry is expressed as fractions of the canvas so the same drawing works at whatever
    /// dimensions the firmware turns out to ask for.
    static func bitmap(width: Int = assumedSize, height: Int = assumedSize) -> [Bool] {
        precondition(width > 0 && height > 0)
        let w = Double(width)
        let h = Double(height)
        var pixels = [Bool](repeating: false, count: width * height)

        let page = (left: 0.10 * w, top: 0.08 * h, right: 0.90 * w, bottom: 0.92 * h)
        let corner = 0.06 * min(w, h)
        let borderThickness = 0.045 * min(w, h)

        // Three item rows, evenly spaced down the page.
        let rowCenters = [0.30, 0.545, 0.79].map { $0 * h }
        let boxSize = 0.14 * min(w, h)
        let boxLeft = page.left + 0.10 * w
        let lineLeft = boxLeft + boxSize + 0.06 * w
        let lineRight = page.right - 0.10 * w
        let lineThickness = 0.045 * min(w, h)

        for y in 0..<height {
            for x in 0..<width {
                let px = Double(x) + 0.5
                let py = Double(y) + 0.5

                var ink = false

                // Page outline only (unfilled interior), so the checkboxes/lines read as distinct
                // marks rather than disappearing into a solid block.
                if inRoundedRect(px, py, page.left, page.top, page.right, page.bottom, corner) {
                    let inset = borderThickness
                    let isInterior = inRoundedRect(
                        px, py,
                        page.left + inset, page.top + inset,
                        page.right - inset, page.bottom - inset,
                        max(corner - inset, 0)
                    )
                    if !isInterior { ink = true }
                }

                for (index, cy) in rowCenters.enumerated() {
                    let boxTop = cy - boxSize / 2
                    let boxBottom = cy + boxSize / 2
                    let isChecked = index == 0

                    if isChecked {
                        if inRect(px, py, boxLeft, boxTop, boxLeft + boxSize, boxBottom) { ink = true }
                    } else {
                        let boxInset = 0.06 * min(w, h)
                        let outer = inRect(px, py, boxLeft, boxTop, boxLeft + boxSize, boxBottom)
                        let inner = inRect(
                            px, py,
                            boxLeft + boxInset, boxTop + boxInset,
                            boxLeft + boxSize - boxInset, boxBottom - boxInset
                        )
                        if outer && !inner { ink = true }
                    }

                    let lineTop = cy - lineThickness / 2
                    let lineBottom = cy + lineThickness / 2
                    if inRect(px, py, lineLeft, lineTop, lineRight, lineBottom) { ink = true }
                }

                pixels[y * width + x] = ink
            }
        }

        return pixels
    }

    /// Packs a bitmap into the documented wire form: row-major, 8 pixels per byte, most significant
    /// bit first, rows padded to whole bytes, a set bit meaning ink (black).
    static func packed(_ pixels: [Bool], width: Int, height: Int) -> Data {
        precondition(pixels.count == width * height, "bitmap must match the given dimensions")
        let bytesPerRow = (width + 7) / 8
        var out = Data(repeating: 0, count: bytesPerRow * height)

        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] {
                out[y * bytesPerRow + x / 8] |= UInt8(0x80) >> UInt8(x % 8)
            }
        }

        return out
    }

    /// The icon bytes for a device's advertised dimensions.
    ///
    /// The protocol guarantees the advertised icon width is **always a multiple of 8** — explicitly
    /// a guarantee rather than an accident of today's 64×64 — so the packed size is exactly
    /// `width * height / 8` with no padding convention to invent, and this returns bytes for every
    /// size a conforming device can ask for.
    ///
    /// The length check remains as a backstop only. A wrong length is rejected outright with
    /// `ASSET_ACK(REJECTED_SIZE)`, so if a device ever did violate the guarantee, sending nothing
    /// costs a sleep-screen tile while sending the wrong thing costs a failed enrolment asset and a
    /// confusing error.
    static func encoded(width: Int, height: Int, expectedByteCount: Int) -> Data? {
        guard width > 0, height > 0 else { return nil }
        let bitmap = packed(bitmap(width: width, height: height), width: width, height: height)
        return bitmap.count == expectedByteCount ? bitmap : nil
    }

    // MARK: - Geometry

    private static func inRect(_ x: Double, _ y: Double, _ left: Double, _ top: Double, _ right: Double, _ bottom: Double) -> Bool {
        x >= left && x <= right && y >= top && y <= bottom
    }

    private static func inRoundedRect(
        _ x: Double, _ y: Double,
        _ left: Double, _ top: Double, _ right: Double, _ bottom: Double,
        _ radius: Double
    ) -> Bool {
        guard inRect(x, y, left, top, right, bottom) else { return false }
        let cx = min(max(x, left + radius), right - radius)
        let cy = min(max(y, top + radius), bottom - radius)
        return hypot(x - cx, y - cy) <= radius
    }
}
