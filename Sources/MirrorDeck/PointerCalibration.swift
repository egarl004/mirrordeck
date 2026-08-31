import AppKit
import CoreGraphics

/// Works out how many relative HID units correspond to one screen width by
/// watching the mirrored video: move the pointer a known amount, see how far it
/// actually moved, divide. iOS exposes no way to query its pointer scaling, and
/// it changes with the phone's tracking-speed setting, so measuring it is the
/// only way to know — and the mirror already shows us the answer.
enum PointerCalibration {

    /// Snapshot of the mirror window's contents.
    static func capture(window: NSWindow) -> CGImage? {
        CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .nominalResolution])
    }

    private struct Gray {
        let w: Int, h: Int, px: [UInt8]
    }

    /// Downsampled luminance, which is all the differencing needs.
    private static func gray(_ image: CGImage, scale: Int = 4) -> Gray? {
        let w = image.width / scale, h = image.height / scale
        guard w > 8, h > 8 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Gray(w: w, h: h, px: px)
    }

    /// Centroid of everything that changed between two frames, in pixels of the
    /// first image. The pointer is usually the only thing moving, but a
    /// centroid degrades gracefully if the screen has other animation.
    static func movement(from a: CGImage, to b: CGImage, threshold: Int = 24) -> CGPoint? {
        guard let ga = gray(a), let gb = gray(b),
              ga.w == gb.w, ga.h == gb.h else { return nil }
        var sumX = 0.0, sumY = 0.0, count = 0.0
        for y in 0..<ga.h {
            for x in 0..<ga.w {
                let i = y * ga.w + x
                if abs(Int(ga.px[i]) - Int(gb.px[i])) > threshold {
                    sumX += Double(x); sumY += Double(y); count += 1
                }
            }
        }
        // Too few pixels means nothing moved; too many means the whole screen
        // changed and this is not the pointer.
        guard count >= 4, count < Double(ga.w * ga.h) / 8 else { return nil }
        let scale = Double(a.width) / Double(ga.w)
        return CGPoint(x: sumX / count * scale, y: sumY / count * scale)
    }
}
