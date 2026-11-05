import Foundation

/// Plustek's ScanApi engine, loaded from the vendor framework (interface in scanapi/scanapi.h).
/// Every call blocks, so callers run them on `queue`.
final class Engine {
    struct Settings {
        var dpi: Int
        var color: Bool
    }

    /// Tightly packed 8-bit RGB or gray pixels.
    struct Image {
        var pixels: Data
        var width: Int
        var height: Int
        let bytesPerPixel: Int
        let dpi: Int
    }

    enum Failure: Error {
        case noPaper
        case busy
        case failed(String)
    }

    static let defaultPath = "/Applications/Plustek/ePhoto Z300/ScanApi.framework/ScanApi"
    private static let sheetfedSource: UInt32 = 4           // the only source with capabilities on the Z300
    private static let retNoPaper: Int32 = -97
    private static let retBusy: Int32 = -90                 // also returned when the scanner is unplugged
    private static let retPaperOut: Int32 = 6
    private static let retNoMoreData: Int32 = 2
    private static let stopAtPaperEnd: UInt32 = 1 << 16     // STARTSCAN.flag
    private static let startScanCopy = 0x800                // apiStartScan copies 0x713 bytes of STARTSCAN
    /// Longest sheet scanned: the engine's MaxPaperLength at 300 dpi, half of it at 600 to bound memory.
    /// Scans still end at the sheet's end.
    private static func maxLengthInches(dpi: Int) -> Double { dpi > 300 ? 18 : 36 }
    private static let linesPerRead = 300

    let queue = DispatchQueue(label: "z300.engine")
    /// Called on an engine thread when the paper sensor sees a sheet arrive.
    var onPaperInserted: (() -> Void)?

    private let t: UnsafeMutablePointer<SCANAPI_FUNCTION_TABLE>

    init?(path: String = Engine.defaultPath) {
        guard let lib = dlopen(path, RTLD_NOW | RTLD_LOCAL), let sym = dlsym(lib, "SCANAPI_GetFunctionTable") else { return nil }
        typealias GetTable = @convention(c) () -> UnsafeMutablePointer<SCANAPI_FUNCTION_TABLE>?
        guard let table = unsafeBitCast(sym, to: GetTable.self)() else { return nil }
        t = table
    }

    /// Takes the scanner. 0 on success; `retBusy` while another process holds it or it is unplugged.
    func register() -> Int32 {
        var version = SCANAPI_VERSION_INFO()
        let r = t.pointee.Register!(&version)
        guard r == 0 else { return r }
        // apiStartScan does not proceed while a device event is pending without a handler.
        typealias Handler = @convention(c) (UInt32, Int32, UnsafeMutableRawPointer?) -> Int32
        typealias SetHandler = @convention(c) (Handler?, UnsafeMutableRawPointer?, Bool) -> Int32
        let handler: Handler = { event, value, context in
            guard event == 2, value == 1, let context else { return 0 }   // button 1 is the paper sensor
            Unmanaged<Engine>.fromOpaque(context).takeUnretainedValue().onPaperInserted?()
            return 0
        }
        _ = unsafeBitCast(t.pointee.ScannerEventCallback!, to: SetHandler.self)(handler, Unmanaged.passUnretained(self).toOpaque(), true)
        var caps: UnsafeMutableRawPointer?
        _ = t.pointee.GetDeviceCapability!(&caps)
        return 0
    }

    /// Releases the scanner. The engine makes it re-enumerate on USB.
    func unregister() {
        _ = t.pointee.Unregister!()
    }

    /// Scans one sheet from the feeder; throws `.noPaper` when it is empty.
    /// The engine's gray mode and resolutions below 300 dpi break the feed on the Z300: it logs the motor's
    /// resolution as 0, the motor jolts and the sheet does not advance, so every line is the same. The scanner
    /// therefore always scans in colour at 300 or 600 dpi; gray and lower resolutions are made from that.
    func scan(_ settings: Settings) throws -> Image {
        let scanDPI = settings.dpi > 300 ? 600 : 300
        var image = try scanAtNativeResolution(Settings(dpi: scanDPI, color: true))
        if !settings.color { image = Engine.gray(image) }
        if scanDPI > settings.dpi && scanDPI % settings.dpi == 0 { image = Engine.downscale(image, by: scanDPI / settings.dpi) }
        return image
    }

    /// Luma of an RGB image (Rec. 601 weights).
    private static func gray(_ image: Image) -> Image {
        let n = image.width * image.height
        var out = Data(count: n)
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            image.pixels.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                let d = dst.bindMemory(to: UInt8.self), s = src.bindMemory(to: UInt8.self)
                for i in 0..<n {
                    let r: Int = 299 * Int(s[3 * i]), g: Int = 587 * Int(s[3 * i + 1]), b: Int = 114 * Int(s[3 * i + 2])
                    d[i] = UInt8((r + g + b + 500) / 1000)
                }
            }
        }
        return Image(pixels: out, width: image.width, height: image.height, bytesPerPixel: 1, dpi: image.dpi)
    }

    /// Averages each `factor` × `factor` block into one pixel.
    private static func downscale(_ image: Image, by factor: Int) -> Image {
        let w = image.width / factor, h = image.height / factor, bpp = image.bytesPerPixel, n = factor * factor
        var out = Data(count: w * h * bpp)
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            image.pixels.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                let d = dst.bindMemory(to: UInt8.self), s = src.bindMemory(to: UInt8.self)
                for y in 0..<h {
                    for x in 0..<w {
                        for c in 0..<bpp {
                            var sum = 0
                            for dy in 0..<factor {
                                let row = (y * factor + dy) * image.width
                                for dx in 0..<factor { sum += Int(s[(row + x * factor + dx) * bpp + c]) }
                            }
                            d[(y * w + x) * bpp + c] = UInt8((sum + n / 2) / n)
                        }
                    }
                }
            }
        }
        return Image(pixels: out, width: w, height: h, bytesPerPixel: bpp, dpi: image.dpi / factor)
    }

    private func scanAtNativeResolution(_ settings: Settings) throws -> Image {
        let prop = UnsafeMutablePointer<SCANAPI_SCAN_PROPERTY>.allocate(capacity: 1)
        prop.initialize(to: SCANAPI_SCAN_PROPERTY())
        defer { prop.deallocate() }
        prop.pointee.source.source = Engine.sheetfedSource
        prop.pointee.mode = settings.color ? 2 : 1
        prop.pointee.wBitDepth = 8
        prop.pointee.dwDpiX = UInt32(settings.dpi)
        prop.pointee.dwDpiY = UInt32(settings.dpi)
        prop.pointee.scan_area.xySize.x = 8.5
        prop.pointee.scan_area.xySize.y = Engine.maxLengthInches(dpi: settings.dpi)
        prop.pointee.scan_area.unit = UInt32(SCANAPI_UNIT_INCH)

        var layout = SCANAPI_IMAGE_INFO()
        let lr = t.pointee.GetImageLayout!(prop, &layout)
        guard lr == 0, layout.dwPixel > 0, layout.dwLine > 0 else { throw Failure.failed("layout \(lr)") }

        let startMemory = UnsafeMutableRawPointer.allocate(byteCount: Engine.startScanCopy, alignment: 8)
        startMemory.initializeMemory(as: UInt8.self, repeating: 0, count: Engine.startScanCopy)
        defer { startMemory.deallocate() }
        let start = startMemory.bindMemory(to: SCANAPI_STARTSCAN.self, capacity: 1)
        start.pointee.pscan_property = prop
        start.pointee.pfnCallback = { _, _ in 0 }
        start.pointee.ScanCount = 1
        start.pointee.flag = Engine.stopAtPaperEnd

        let sr = t.pointee.StartScan!(start)
        if sr == Engine.retNoPaper { throw Failure.noPaper }
        if sr == Engine.retBusy { throw Failure.busy }
        guard sr == 0 else { throw Failure.failed("start \(sr)") }

        let bpp = settings.color ? 3 : 1
        let stride = Int(layout.dwByte), packed = Int(layout.dwPixel) * bpp, maxLines = Int(layout.dwLine)
        var raw = Data(count: stride * (maxLines + Engine.linesPerRead))
        var lines = 0, rr: Int32 = 0
        raw.withUnsafeMutableBytes { buf in
            while lines < maxLines {
                var got: UInt32 = 0
                rr = t.pointee.Read!(buf.baseAddress!.advanced(by: lines * stride).assumingMemoryBound(to: UInt8.self),
                                    UInt32(stride * Engine.linesPerRead), &got)
                lines += Int(got)
                if rr != 0 || got == 0 { break }
            }
        }
        _ = t.pointee.StopScan!()
        _ = t.pointee.EndScan!(true)
        lines = min(lines, maxLines)
        guard rr == 0 || rr == Engine.retPaperOut || rr == Engine.retNoMoreData, lines > 0 else {
            throw Failure.failed("read \(rr) after \(lines) lines")
        }
        if stride != packed {
            raw.withUnsafeMutableBytes { buf in
                for y in 1..<lines { memmove(buf.baseAddress! + y * packed, buf.baseAddress! + y * stride, packed) }
            }
        }
        raw.count = packed * lines
        return Image(pixels: raw, width: Int(layout.dwPixel), height: lines, bytesPerPixel: bpp, dpi: settings.dpi)
    }
}
