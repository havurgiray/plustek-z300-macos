// Lists the scanners macOS's ImageCaptureCore can see, the same list Preview and Image Capture show.
import Foundation
import ImageCaptureCore

final class Lister: NSObject, ICDeviceBrowserDelegate {
    let browser = ICDeviceBrowser()
    func start() {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.scanner.rawValue |
            ICDeviceLocationTypeMask.local.rawValue | ICDeviceLocationTypeMask.shared.rawValue |
            ICDeviceLocationTypeMask.bonjour.rawValue | ICDeviceLocationTypeMask.bluetooth.rawValue)!
        browser.start()
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        print("found: \(device.name ?? "?") | transport=\(device.transportType ?? "?") | location=\(device.locationDescription ?? "?")")
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}
}

let lister = Lister()
lister.start()
RunLoop.main.run(until: Date().addingTimeInterval(Double(CommandLine.arguments.dropFirst().first ?? "8") ?? 8))
print("done")
