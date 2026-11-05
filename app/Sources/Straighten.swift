import Accelerate
import CoreGraphics
import Foundation

/// Straightening of sheets fed in at an angle, and detection of sheets the scanner stopped short of.
/// Both work against the scanner's black backing, like Imaging.cropToSheet.
extension Imaging {
    private static let backing = 48               // luma at or below this is backing
    private static let minAngle = 0.2 * .pi / 180 // smaller tilts are left alone

    /// True when the sheet still covers the scan's last lines. The firmware ends a scan a fixed distance after
    /// the sheet leaves the paper sensor, so this means the sheet was longer than the scan, or slid off the
    /// sensor before its end.
    static func reachesEnd(_ image: Engine.Image) -> Bool {
        let rows = max(2, image.dpi / 20)   // the last 1/20 inch
        guard image.height > rows else { return false }
        var covered = 0
        image.pixels.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let p = buf.bindMemory(to: UInt8.self)
            for y in (image.height - rows)..<image.height where brightCount(p, row: y, image) > image.width / 50 { covered += 1 }
        }
        return covered > rows / 2
    }

    /// Rotates a tilted sheet upright and crops to it. Nil when it is not tilted or no clear edges were found;
    /// callers then use cropToSheet.
    static func straighten(_ image: Engine.Image) -> Engine.Image? {
        let hull = convexHull(edgePoints(image))
        guard hull.count >= 4, let angle = minAreaRectAngle(hull), abs(angle) >= minAngle,
              let upright = rotate(image, by: -angle) else { return nil }
        let cropped = cropToSheet(upright)
        guard cropped.width < upright.width || cropped.height < upright.height else { return nil }
        return inset(cropped, by: 2)   // the rotated edge blends with the backing for a pixel or so
    }

    private static func inset(_ image: Engine.Image, by n: Int) -> Engine.Image {
        let w = image.width - 2 * n, h = image.height - 2 * n, bpp = image.bytesPerPixel
        guard w > 0, h > 0 else { return image }
        var out = Data(count: w * h * bpp)
        out.withUnsafeMutableBytes { dst in
            image.pixels.withUnsafeBytes { src in
                for y in 0..<h {
                    memcpy(dst.baseAddress! + y * w * bpp, src.baseAddress! + ((y + n) * image.width + n) * bpp, w * bpp)
                }
            }
        }
        return Engine.Image(pixels: out, width: w, height: h, bytesPerPixel: bpp, dpi: image.dpi)
    }

    // MARK: geometry

    private static func brightCount(_ p: UnsafeBufferPointer<UInt8>, row y: Int, _ image: Engine.Image) -> Int {
        var n = 0
        let bpp = image.bytesPerPixel, start = y * image.width * bpp
        for x in 0..<image.width where luma(p, start + x * bpp, bpp) > backing { n += 1 }
        return n
    }

    @inline(__always) private static func luma(_ p: UnsafeBufferPointer<UInt8>, _ i: Int, _ bpp: Int) -> Int {
        bpp == 3 ? (Int(p[i]) * 3 + Int(p[i + 1]) * 6 + Int(p[i + 2])) / 10 : Int(p[i])
    }

    /// The outermost bright runs (3+ pixels, so specks of dust don't count) of every row the sheet covers.
    private static func edgePoints(_ image: Engine.Image) -> [CGPoint] {
        let w = image.width, bpp = image.bytesPerPixel, run = 3
        var points: [CGPoint] = []
        image.pixels.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let p = buf.bindMemory(to: UInt8.self)
            for y in 0..<image.height {
                let start = y * w * bpp
                guard brightCount(p, row: y, image) > w / 50 else { continue }
                var left = -1, right = -1, streak = 0
                for x in 0..<w {
                    streak = luma(p, start + x * bpp, bpp) > backing ? streak + 1 : 0
                    if streak == run { left = x - run + 1; break }
                }
                streak = 0
                for x in stride(from: w - 1, through: 0, by: -1) {
                    streak = luma(p, start + x * bpp, bpp) > backing ? streak + 1 : 0
                    if streak == run { right = x + run - 1; break }
                }
                if left >= 0, right >= left {
                    points.append(CGPoint(x: left, y: y))
                    points.append(CGPoint(x: right, y: y))
                }
            }
        }
        return points
    }

    /// Andrew's monotone chain.
    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let pts = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard pts.count > 2 else { return pts }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for p in pts {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in pts.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Angle of the smallest-area rectangle around the hull (one side lies on a hull edge), in image
    /// coordinates (y down), folded into (-45°, 45°].
    private static func minAreaRectAngle(_ hull: [CGPoint]) -> Double? {
        var best: (area: Double, angle: Double)?
        for i in hull.indices {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let len = hypot(Double(b.x - a.x), Double(b.y - a.y))
            guard len > 0 else { continue }
            let dx = Double(b.x - a.x) / len, dy = Double(b.y - a.y) / len
            var minU = Double.infinity, maxU = -Double.infinity, minV = Double.infinity, maxV = -Double.infinity
            for p in hull {
                let u = Double(p.x) * dx + Double(p.y) * dy, v = -Double(p.x) * dy + Double(p.y) * dx
                minU = min(minU, u); maxU = max(maxU, u); minV = min(minV, v); maxV = max(maxV, v)
            }
            let area = (maxU - minU) * (maxV - minV)
            if best == nil || area < best!.area { best = (area, atan2(dy, dx)) }
        }
        guard var angle = best?.angle else { return nil }
        while angle > .pi / 4 { angle -= .pi / 2 }
        while angle <= -.pi / 4 { angle += .pi / 2 }
        return angle
    }

    /// Rotates the whole image about its centre onto a canvas large enough to keep the corners, filling with
    /// black backing. `angle` is in image coordinates (y down): positive turns content clockwise on screen.
    private static func rotate(_ image: Engine.Image, by angle: Double) -> Engine.Image? {
        let w = image.width, h = image.height, bpp = image.bytesPerPixel
        let c = abs(cos(angle)), s = abs(sin(angle))
        let nw = Int((Double(w) * c + Double(h) * s).rounded(.up)), nh = Int((Double(w) * s + Double(h) * c).rounded(.up))
        // vImage's positive angle turns content counterclockwise on screen.
        let vAngle = Float(-angle)
        let flags = vImage_Flags(kvImageBackgroundColorFill | kvImageHighQualityResampling)
        var src = image.pixels
        var out = Data(count: nw * nh * bpp)
        let ok: Bool = src.withUnsafeMutableBytes { (srcBuf: UnsafeMutableRawBufferPointer) in
            out.withUnsafeMutableBytes { (dstBuf: UnsafeMutableRawBufferPointer) in
                var s8 = vImage_Buffer(data: srcBuf.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * bpp)
                var d8 = vImage_Buffer(data: dstBuf.baseAddress, height: vImagePixelCount(nh), width: vImagePixelCount(nw), rowBytes: nw * bpp)
                if bpp == 1 {
                    return vImageRotate_Planar8(&s8, &d8, nil, vAngle, 0, flags) == kvImageNoError
                }
                // vImage rotates 4-channel pixels: go through ARGB.
                let sA = UnsafeMutableRawPointer.allocate(byteCount: w * h * 4, alignment: 16)
                let dA = UnsafeMutableRawPointer.allocate(byteCount: nw * nh * 4, alignment: 16)
                defer { sA.deallocate(); dA.deallocate() }
                var s32 = vImage_Buffer(data: sA, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var d32 = vImage_Buffer(data: dA, height: vImagePixelCount(nh), width: vImagePixelCount(nw), rowBytes: nw * 4)
                let black: [UInt8] = [255, 0, 0, 0]
                return vImageConvert_RGB888toARGB8888(&s8, nil, 255, &s32, false, vImage_Flags(kvImageNoFlags)) == kvImageNoError
                    && vImageRotate_ARGB8888(&s32, &d32, nil, vAngle, black, flags) == kvImageNoError
                    && vImageConvert_ARGB8888toRGB888(&d32, &d8, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            }
        }
        return ok ? Engine.Image(pixels: out, width: nw, height: nh, bytesPerPixel: bpp, dpi: image.dpi) : nil
    }
}
