// Scans one page through macOS's ImageCaptureCore, the path Preview and Image Capture use.
// Usage: icscan <name-substring> <out-dir> [dpi] [timeout-seconds]
import Foundation
import ImageCaptureCore

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: icscan <name-substring> <out-dir> [dpi] [timeout]"); exit(2) }
let wanted = args[1], outDir = URL(fileURLWithPath: args[2], isDirectory: true)
let dpi = Int(args.count > 3 ? args[3] : "150") ?? 150
let timeout = Double(args.count > 4 ? args[4] : "60") ?? 60

final class Scanner: NSObject, ICDeviceBrowserDelegate, ICScannerDeviceDelegate {
    let browser = ICDeviceBrowser()
    var device: ICScannerDevice?
    func start() {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue |
            ICDeviceLocationTypeMask.shared.rawValue | ICDeviceLocationTypeMask.bonjour.rawValue)!
        browser.start()
    }
    func deviceBrowser(_ b: ICDeviceBrowser, didAdd d: ICDevice, moreComing: Bool) {
        guard device == nil, let s = d as? ICScannerDevice, (s.name ?? "").contains(wanted) else { return }
        print("using: \(s.name ?? "?")")
        device = s
        s.delegate = self
        s.requestOpenSession()
    }
    func deviceBrowser(_ b: ICDeviceBrowser, didRemove d: ICDevice, moreGoing: Bool) {}
    func didRemove(_ device: ICDevice) {}
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error { fail("open session: \(error)") }
        print("session open; functional units: \(device.capabilities)")
    }
    func scannerDevice(_ scanner: ICScannerDevice, didSelect unit: ICScannerFunctionalUnit, error: Error?) {
        if let error { fail("select unit: \(error)") }
        guard !unit.supportedResolutions.isEmpty else { return } // capabilities arrive in a later callback
        print("unit: \(unit.type.rawValue) resolutions: \(Array(unit.supportedResolutions).prefix(12))")
        unit.resolution = unit.supportedResolutions.contains(dpi) ? dpi : unit.preferredResolutions.first ?? unit.supportedResolutions.first ?? dpi
        unit.pixelDataType = .RGB
        unit.bitDepth = .depth8Bits
        if let fb = unit as? ICScannerFunctionalUnitFlatbed {
            fb.scanArea = NSRect(x: 0, y: 0, width: fb.physicalSize.width, height: fb.physicalSize.height)
        }
        scanner.transferMode = .fileBased
        scanner.downloadsDirectory = outDir
        scanner.documentName = "icscan"
        scanner.documentUTI = "public.tiff"
        print("scanning at \(unit.resolution) dpi")
        scanner.requestScan()
    }
    func deviceDidBecomeReady(_ device: ICDevice) {
        print("ready")
        guard let s = device as? ICScannerDevice else { return }
        s.requestSelect(s.availableFunctionalUnitTypes.first.map { ICScannerFunctionalUnitType(rawValue: $0.uintValue)! } ?? .flatbed)
    }
    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) { print("saved: \(url.path)") }
    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        if let error { fail("scan: \(error)") }
        print("scan complete"); exit(0)
    }
    func device(_ device: ICDevice, didEncounterError error: Error?) { if let error { print("device error: \(error)") } }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
}
func fail(_ m: String) -> Never { print("FAILED: \(m)"); exit(1) }

let s = Scanner()
s.start()
RunLoop.main.run(until: Date().addingTimeInterval(timeout))
fail("timed out")
