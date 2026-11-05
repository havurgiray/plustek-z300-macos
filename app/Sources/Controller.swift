import AppKit
import IOKit
import IOKit.usb
import UserNotifications

/// Holds the scanner while nothing else needs it, so its paper sensor can start a scan, and lets go for
/// ePhoto, for scans from other apps (the SANE backend asks over a distributed notification), and for sleep.
final class Controller: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private enum Pause: Hashable { case ePhoto, otherApp, sleep }

    private static let vendor = 0x07b3, products = [0x131c, 0x143d]
    private static let ePhotoID = "com.plustek.ePhoto"
    private static let releaseRequest = Notification.Name("z300bridge.release")
    private static let resumeRequest = Notification.Name("z300bridge.resume")
    /// Our own apiUnregister makes the scanner re-enumerate; don't grab it again during that.
    private static let cooldown: TimeInterval = 3

    private let engine: Engine
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var panel: ScanPanel?

    private var registered = false
    private var busy = false                    // an engine call is running on engine.queue
    private var pauses = Set<Pause>()
    private var otherAppSince: Date?
    private var cooldownUntil = Date.distantPast
    private var retryTimer: Timer?
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    // The current scan session: the panel's choice, pages of a multi-page document, and whether the next
    // inserted sheet should be scanned without asking.
    private var choice: ScanPanel.Choice?
    private var pages: [Engine.Image] = []
    private var pagesCutOff = false
    private var scanOnNextSheet = false

    init(engine: Engine) {
        self.engine = engine
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "scanner", accessibilityDescription: "Z300 Scan")
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Scan…", action: #selector(scanFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())
        UserDefaults.standard.register(defaults: Dictionary(uniqueKeysWithValues: Self.adjustments.map { ($0.key, $0.default) }))
        for adjustment in Self.adjustments {
            let item = NSMenuItem(title: adjustment.title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu()
            for (title, value) in adjustment.choices {
                let choice = NSMenuItem(title: title, action: #selector(setAdjustment(_:)), keyEquivalent: "")
                choice.representedObject = [adjustment.key: value]
                item.submenu?.addItem(choice)
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Z300 Scan", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        markAdjustments()

        engine.onPaperInserted = { [weak self] in DispatchQueue.main.async { self?.sheetInserted() } }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(self, selector: #selector(otherAppWantsScanner), name: Self.releaseRequest, object: nil)
        dc.addObserver(self, selector: #selector(otherAppDone), name: Self.resumeRequest, object: nil)

        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == Self.ePhotoID }) { pauses.insert(.ePhoto) }
        watchUSB()

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        log("started")
        reconcile()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if registered { engine.queue.sync { engine.unregister() } }
    }

    // MARK: holding the scanner

    private var connected: Bool { Self.products.contains { usbDevicePresent(Self.vendor, $0) } }

    /// Takes or releases the scanner to match what should happen now.
    private func reconcile() {
        defer { updateStatus() }
        if let since = otherAppSince, Date().timeIntervalSince(since) > 15 * 60 {
            log("no resume from the other app after 15 minutes, taking the scanner back")
            pauses.remove(.otherApp)
            otherAppSince = nil
        }
        guard !busy else { return }
        let want = pauses.isEmpty && connected
        if want && !registered {
            let wait = cooldownUntil.timeIntervalSinceNow
            if wait > 0 { scheduleRetry(after: wait); return }
            busy = true
            engine.queue.async {
                let r = self.engine.register()
                DispatchQueue.main.async {
                    self.busy = false
                    self.registered = r == 0
                    log("register -> \(r)")
                    if r != 0 { self.scheduleRetry(after: 5) }
                    self.reconcile()
                }
            }
        } else if !want && registered {
            endSession()   // someone else needs the scanner, or it went away
            release()
        }
    }

    private func release() {
        busy = true
        engine.queue.async {
            self.engine.unregister()
            DispatchQueue.main.async {
                self.busy = false
                self.registered = false
                self.cooldownUntil = Date().addingTimeInterval(Self.cooldown)
                log("released (\(self.pauses))")
                self.reconcile()
            }
        }
    }

    private func scheduleRetry(after seconds: TimeInterval) {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.reconcile() }
    }

    private func updateStatus() {
        let text: String
        if pauses.contains(.ePhoto) { text = "Paused: ePhoto is open" }
        else if pauses.contains(.otherApp) { text = "Paused: another app is scanning" }
        else if !connected { text = "Scanner not connected" }
        else if registered { text = "Ready: insert a photo or document" }
        else { text = "Connecting to the scanner…" }
        statusLine.title = text
        statusItem.button?.toolTip = "Z300 Scan: \(text)"
        statusItem.button?.appearsDisabled = !registered
    }

    @objc private func appLaunched(_ n: Notification) {
        guard (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.ePhotoID else { return }
        pauses.insert(.ePhoto)
        reconcile()
    }

    @objc private func appTerminated(_ n: Notification) {
        guard (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.ePhotoID else { return }
        pauses.remove(.ePhoto)
        cooldownUntil = Date().addingTimeInterval(Self.cooldown)   // ePhoto's release re-enumerates the scanner too
        reconcile()
    }

    @objc private func willSleep() {
        pauses.insert(.sleep)
        reconcile()
    }

    @objc private func didWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.pauses.remove(.sleep)
            self.reconcile()
        }
    }

    @objc private func otherAppWantsScanner() {
        log("another app asked for the scanner")
        pauses.insert(.otherApp)
        otherAppSince = Date()
        reconcile()
    }

    @objc private func otherAppDone() {
        log("the other app is done with the scanner")
        pauses.remove(.otherApp)
        otherAppSince = nil
        cooldownUntil = Date().addingTimeInterval(Self.cooldown)
        reconcile()
    }

    // MARK: USB

    private func watchUSB() {
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .defaultMode)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for product in Self.products {
            for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var it: io_iterator_t = 0
                IOServiceAddMatchingNotification(notifyPort, type, usbMatch(Self.vendor, product), { context, it in
                    while case let obj = IOIteratorNext(it), obj != 0 { IOObjectRelease(obj) }
                    Unmanaged<Controller>.fromOpaque(context!).takeUnretainedValue().usbChanged()
                }, me, &it)
                while case let obj = IOIteratorNext(it), obj != 0 { IOObjectRelease(obj) }
                iterators.append(it)
            }
        }
    }

    private func usbChanged() {
        if !connected && registered && !busy {
            log("scanner unplugged")
            endSession()
            release()
        } else {
            reconcile()
        }
    }

    // MARK: scanning

    private func sheetInserted() {
        guard registered, !busy else { return }
        if scanOnNextSheet, let choice {
            scan(choice)
        } else if panel?.isVisible != true {
            openPanel(sheetInserted: true)
        }
    }

    @objc private func scanFromMenu() {
        openPanel(sheetInserted: false)
    }

    /// Colour adjustments applied to every scan (Imaging.adjust). Raw scans come out oversaturated and dark;
    /// the defaults were picked by eye on side-by-side photo scans. Brightness percentages are the rise in a
    /// photo's mean brightness that the curve gave.
    private static let adjustments: [(title: String, key: String, default: Double, choices: [(String, Double)])] = [
        ("Colour Intensity", "saturation", 0.85,
         [("As Scanned", 1.0), ("10% Less", 0.9), ("15% Less", 0.85), ("20% Less", 0.8)]),
        ("Brightness", "gamma", 1.6,
         [("As Scanned", 1.0), ("20% Brighter", 1.31), ("30% Brighter", 1.5), ("35% Brighter", 1.6), ("40% Brighter", 1.71)]),
    ]

    @objc private func setAdjustment(_ item: NSMenuItem) {
        guard let setting = item.representedObject as? [String: Double], let (key, value) = setting.first else { return }
        UserDefaults.standard.set(value, forKey: key)
        markAdjustments()
    }

    private func markAdjustments() {
        for item in statusItem.menu?.items ?? [] {
            for choice in item.submenu?.items ?? [] {
                guard let (key, value) = (choice.representedObject as? [String: Double])?.first else { continue }
                choice.state = UserDefaults.standard.double(forKey: key) == value ? .on : .off
            }
        }
    }

    private func openPanel(sheetInserted: Bool) {
        let panel = self.panel ?? ScanPanel()
        self.panel = panel
        panel.onScan = { [weak self] choice in
            self?.choice = choice
            self?.pages = []
            self?.scan(choice)
        }
        panel.onSavePDF = { [weak self] in self?.saveDocument() }
        panel.onCancel = { [weak self] in self?.endSession() }
        panel.showChoosing(sheetInserted: sheetInserted)
    }

    private func scan(_ choice: ScanPanel.Choice) {
        guard registered, !busy else {
            panel?.showError(registered ? "The scanner is busy." : "The scanner is not available right now.")
            return
        }
        scanOnNextSheet = false
        busy = true
        panel?.showScanning(page: pages.count + 1)
        let settings = Engine.Settings(dpi: choice.dpi, color: choice.color)
        let saturation = UserDefaults.standard.double(forKey: "saturation"), gamma = UserDefaults.standard.double(forKey: "gamma")
        engine.queue.async {
            let result = Result { try self.engine.scan(settings) }.map { raw -> Scanned in
                var image = raw
                if choice.crop { image = (choice.straighten ? Imaging.straighten(raw) : nil) ?? Imaging.cropToSheet(raw) }
                return Scanned(image: Imaging.adjust(image, saturation: saturation, gamma: gamma), cutOff: Imaging.reachesEnd(raw))
            }
            DispatchQueue.main.async {
                self.busy = false
                self.scanned(result, choice: choice)
                self.reconcile()
            }
        }
    }

    private struct Scanned {
        let image: Engine.Image
        let cutOff: Bool   // the sheet reached the scan's last line (Imaging.reachesEnd)
    }

    private func scanned(_ result: Result<Scanned, Error>, choice: ScanPanel.Choice) {
        switch result {
        case .failure(Engine.Failure.noPaper):
            scanOnNextSheet = true
            panel?.showWaitingForSheet()
        case .failure(let error):
            log("scan failed: \(error)")
            panel?.showError("\(error)")
        case .success(let scan) where choice.kind == .photo:
            save(extension: choice.format.fileExtension, choice: choice, cutOff: scan.cutOff) {
                try Imaging.write(scan.image, as: choice.format, to: $0)
            }
        case .success(let scan):
            pages.append(scan.image)
            pagesCutOff = pagesCutOff || scan.cutOff
            scanOnNextSheet = true
            panel?.showPageAdded(count: pages.count, cutOff: scan.cutOff)
        }
    }

    private func saveDocument() {
        guard let choice, !pages.isEmpty else { return endSession() }
        scanOnNextSheet = false
        let pages = self.pages
        save(extension: "pdf", choice: choice, cutOff: pagesCutOff) {
            try Imaging.writePDF(pages, searchable: choice.searchable, to: $0)
        }
    }

    /// Writes the scan in the background into the chosen folder (Folders.store), then reports it.
    private func save(extension ext: String, choice: ScanPanel.Choice, cutOff: Bool, write: @escaping (URL) throws -> Void) {
        panel?.showSaving()
        let folder = choice.folder ?? Folders.desktop
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Folders.store(extension: ext, in: folder, write: write) }
            DispatchQueue.main.async {
                switch result {
                case .success(let stored):
                    self.saved(stored.url, cutOff: cutOff, missed: stored.fellBack ? folder : nil)
                case .failure(let error):
                    self.panel?.showError("\(error)")
                }
            }
        }
    }

    /// `missed`: the chosen folder, when it could not take the scan and it went to the Desktop instead.
    private func saved(_ url: URL, cutOff: Bool, missed: URL?) {
        log("saved \(url.path)\(cutOff ? " (may be cut off)" : "")")
        endSession()
        let folder = url.deletingLastPathComponent()
        let place = folder.standardizedFileURL.path == Folders.desktop.standardizedFileURL.path
            ? "on your Desktop" : "in “\(folder.lastPathComponent)”"
        let content = UNMutableNotificationContent()
        content.title = missed != nil ? "Scan saved to the Desktop instead"
            : cutOff ? "Scan saved, but it may be cut off" : "Scan saved"
        content.body = (missed.map { "“\($0.lastPathComponent)” could not be reached. " } ?? "")
            + "\(url.lastPathComponent) is \(place)." + (cutOff
            ? " It may be cut off: the item reached the end of the scan. It was longer than the scan allows (36 inches, 18 at 600 dpi), or slid off the paper sensor before its end."
            : "")
        content.userInfo = ["path": url.path]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: url.path, content: content, trigger: nil))
    }

    private func endSession() {
        choice = nil
        pages = []
        pagesCutOff = false
        scanOnNextSheet = false
        panel?.dismiss()
    }

    // MARK: notifications

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

private func usbMatch(_ vendor: Int, _ product: Int) -> CFMutableDictionary {
    let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
    match[kUSBVendorID] = vendor
    match[kUSBProductID] = product
    return match
}

func usbDevicePresent(_ vendor: Int, _ product: Int) -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, usbMatch(vendor, product))
    defer { if service != 0 { IOObjectRelease(service) } }
    return service != 0
}

private let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/z300-bridge/app.log")

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}
