import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum Imaging {
    /// Crops to the sheet against the scanner's black backing: the rows and columns with enough pixels
    /// brighter than the backing. Leaves the image alone when nothing sheet-sized stands out.
    static func cropToSheet(_ image: Engine.Image) -> Engine.Image {
        let w = image.width, h = image.height, bpp = image.bytesPerPixel
        let threshold = 48, minSize = image.dpi / 2
        var top = -1, bottom = -1, left = w, right = -1
        var columnHits = [Int](repeating: 0, count: w)
        image.pixels.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let p = buf.bindMemory(to: UInt8.self)
            for y in 0..<h {
                var hits = 0
                let row = y * w * bpp
                for x in 0..<w {
                    let i = row + x * bpp
                    let lum = bpp == 3 ? (Int(p[i]) * 3 + Int(p[i + 1]) * 6 + Int(p[i + 2])) / 10 : Int(p[i])
                    if lum > threshold { hits += 1; columnHits[x] += 1 }
                }
                if hits > w / 50 { if top < 0 { top = y }; bottom = y }
            }
        }
        let rows = bottom - top + 1
        for x in 0..<w where rows > 0 && columnHits[x] > rows / 50 {
            left = min(left, x)
            right = x
        }
        guard top >= 0, right - left + 1 >= minSize, rows >= minSize else { return image }
        let cw = right - left + 1
        var out = Data(count: cw * rows * bpp)
        out.withUnsafeMutableBytes { dst in
            image.pixels.withUnsafeBytes { src in
                for y in 0..<rows {
                    memcpy(dst.baseAddress! + y * cw * bpp, src.baseAddress! + ((top + y) * w + left) * bpp, cw * bpp)
                }
            }
        }
        return Engine.Image(pixels: out, width: cw, height: rows, bytesPerPixel: bpp, dpi: image.dpi)
    }

    /// `saturation` scales each pixel's colour around its luma (0.8 is 20% less saturated, brightness unchanged);
    /// `gamma` above 1 brightens midtones and shadows while black and white stay put (1.14 raised a photo's
    /// mean brightness by 10%, 1.31 by 20%).
    static func adjust(_ image: Engine.Image, saturation: Double, gamma: Double) -> Engine.Image {
        guard saturation != 1 || gamma != 1 else { return image }
        let lut = (0..<256).map { UInt8(min(255, (255 * pow(Double($0) / 255, 1 / gamma)).rounded())) }
        let s = Float(saturation), color = image.bytesPerPixel == 3
        var out = image
        out.pixels.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            let p = buf.bindMemory(to: UInt8.self)
            guard color else {
                for i in 0..<p.count { p[i] = lut[Int(p[i])] }
                return
            }
            for i in stride(from: 0, to: p.count - 2, by: 3) {
                let r = Float(p[i]), g = Float(p[i + 1]), b = Float(p[i + 2])
                let y = 0.299 * r + 0.587 * g + 0.114 * b
                p[i] = lut[Int(max(0, min(255, (y + s * (r - y)).rounded())))]
                p[i + 1] = lut[Int(max(0, min(255, (y + s * (g - y)).rounded())))]
                p[i + 2] = lut[Int(max(0, min(255, (y + s * (b - y)).rounded())))]
            }
        }
        return out
    }

    static func cgImage(_ image: Engine.Image) -> CGImage? {
        let color = image.bytesPerPixel == 3
        guard let space = CGColorSpace(name: color ? CGColorSpace.sRGB : CGColorSpace.genericGrayGamma2_2),
              let provider = CGDataProvider(data: image.pixels as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 8 * image.bytesPerPixel,
                       bytesPerRow: image.width * image.bytesPerPixel, space: space, bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    enum PhotoFormat: String, CaseIterable {
        case jpeg = "JPEG", png = "PNG", tiff = "TIFF"
        var type: UTType { self == .jpeg ? .jpeg : self == .png ? .png : .tiff }
        var fileExtension: String { self == .jpeg ? "jpg" : self == .png ? "png" : "tiff" }
    }

    static func write(_ image: Engine.Image, as format: PhotoFormat, to url: URL) throws {
        guard let cg = cgImage(image),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw Engine.Failure.failed("cannot create \(url.lastPathComponent)")
        }
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: image.dpi, kCGImagePropertyDPIHeight: image.dpi]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Engine.Failure.failed("cannot write \(url.lastPathComponent)") }
    }

    /// Writes the pages as a PDF at their real size. Pages are embedded as JPEG; with `searchable`, the text
    /// macOS recognizes on each page is laid over it invisibly, so it can be searched, selected and copied.
    static func writePDF(_ pages: [Engine.Image], searchable: Bool, to url: URL) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else { throw Engine.Failure.failed("cannot create PDF") }
        for page in pages {
            guard let cg = cgImage(page), let jpeg = jpegBacked(cg) else { continue }
            var box = CGRect(x: 0, y: 0, width: CGFloat(page.width) * 72 / CGFloat(page.dpi),
                             height: CGFloat(page.height) * 72 / CGFloat(page.dpi))
            ctx.beginPage(mediaBox: &box)
            ctx.draw(jpeg, in: box)
            if searchable { drawInvisibleText(recognizeText(cg), in: box, ctx: ctx) }
            ctx.endPage()
        }
        ctx.closePDF()
    }

    /// Re-decodes the image from JPEG data, so the PDF context embeds the JPEG stream instead of raw pixels.
    private static func jpegBacked(_ image: CGImage) -> CGImage? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func recognizeText(_ image: CGImage) -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return request.results ?? []
    }

    private static func drawInvisibleText(_ lines: [VNRecognizedTextObservation], in box: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in lines {
            guard let text = line.topCandidates(1).first?.string, !text.isEmpty else { continue }
            let r = VNImageRectForNormalizedRect(line.boundingBox, Int(box.width), Int(box.height))
            let font = CTFontCreateWithName("Helvetica" as CFString, max(r.height * 0.85, 1), nil)
            let ctLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            ctx.textMatrix = CGAffineTransform(scaleX: width > 0 ? r.width / width : 1, y: 1)
            ctx.textPosition = CGPoint(x: r.minX, y: r.minY + r.height * 0.2)
            CTLineDraw(ctLine, ctx)
        }
        ctx.restoreGState()
    }
}
