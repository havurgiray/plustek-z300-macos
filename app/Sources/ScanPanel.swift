import AppKit

/// The panel that appears when a sheet is inserted: photo or document, and how to scan it.
final class ScanPanel: NSPanel, NSWindowDelegate {
    enum Kind: Int { case photo, document }

    struct Choice {
        var kind: Kind
        var dpi: Int
        var color: Bool
        var format: Imaging.PhotoFormat
        var crop: Bool
        var straighten: Bool
        var searchable: Bool
        var folder: URL?   // nil: the Desktop
    }

    var onScan: ((Choice) -> Void)?
    var onSavePDF: (() -> Void)?
    var onCancel: (() -> Void)?

    private let defaults = UserDefaults.standard
    private let headline = NSTextField(labelWithString: "")
    private let kind = NSSegmentedControl(labels: ["Photo", "Document"], trackingMode: .selectOne, target: nil, action: nil)
    private let photoDPI = NSPopUpButton(), photoFormat = NSPopUpButton(), docDPI = NSPopUpButton(), docColor = NSPopUpButton()
    private let photoCrop = NSButton(checkboxWithTitle: "Crop to the photo", target: nil, action: nil)
    private let photoStraighten = NSButton(checkboxWithTitle: "Straighten if fed in at an angle", target: nil, action: nil)
    private let docStraighten = NSButton(checkboxWithTitle: "Straighten if fed in at an angle", target: nil, action: nil)
    private let docSearchable = NSButton(checkboxWithTitle: "Searchable text (recognized on this Mac)", target: nil, action: nil)
    private let saveToOther = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let chooseFolder = NSButton(title: "Choose…", target: nil, action: nil)
    private var otherReachable = false
    private var otherTitleWidth: CGFloat = 0   // room for saveToOther's title next to chooseFolder
    private var photoOptions = NSView(), docOptions = NSView(), folderOptions = NSView()
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save PDF", target: nil, action: nil)
    private let scanButton = NSButton(title: "Scan", target: nil, action: nil)

    private static let width: CGFloat = 500

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 260), styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = "Z300 Scan"
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        headline.font = .boldSystemFont(ofSize: 14)
        kind.target = self
        kind.action = #selector(kindChanged)
        photoDPI.addItems(withTitles: ["300 dpi", "600 dpi (hi-res)"])
        photoFormat.addItems(withTitles: Imaging.PhotoFormat.allCases.map(\.rawValue))
        docDPI.addItems(withTitles: ["150 dpi", "300 dpi", "600 dpi"])
        docColor.addItems(withTitles: ["Colour", "Grey"])
        // Both kinds' options share one label column width, so switching between them moves nothing sideways.
        let labelWidth = ["Resolution:", "Format:", "Colour:"].map { NSTextField(labelWithString: $0).fittingSize.width }.max()!
        photoOptions = Self.grid([("Resolution:", photoDPI), ("Format:", photoFormat), ("", photoCrop), ("", photoStraighten)],
                                 labelWidth: labelWidth)
        docOptions = Self.grid([("Resolution:", docDPI), ("Colour:", docColor), ("", docStraighten), ("", docSearchable)],
                               labelWidth: labelWidth)
        let folderRow = NSStackView(views: [saveToOther, chooseFolder])
        folderRow.spacing = 8
        let folderGrid = Self.grid([("", folderRow)], labelWidth: labelWidth)
        folderOptions = folderGrid
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 3
        status.preferredMaxLayoutWidth = 360
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        for (button, action) in [(cancelButton, #selector(cancelPressed)), (saveButton, #selector(savePDF)), (scanButton, #selector(scan)),
                                 (chooseFolder, #selector(chooseOtherFolder))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        cancelButton.keyEquivalent = "\u{1b}"
        scanButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [spinner, status, NSView(), cancelButton, saveButton, scanButton])
        buttons.setHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [headline, kind, photoOptions, docOptions, folderOptions, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(10, after: photoOptions)
        stack.setCustomSpacing(10, after: docOptions)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        otherTitleWidth = Self.width - 40 - labelWidth - folderGrid.columnSpacing - folderRow.spacing - chooseFolder.fittingSize.width
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        contentView = stack
        delegate = self
        restoreChoices()
    }

    private static func grid(_ rows: [(String, NSView)], labelWidth: CGFloat) -> NSGridView {
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = labelWidth
        grid.rowSpacing = 8
        return grid
    }

    // MARK: states

    /// A sheet was inserted (or the menu asked for a scan): choose and press Scan.
    func showChoosing(sheetInserted: Bool) {
        headline.stringValue = sheetInserted ? "Something is in the scanner" : "Scan"
        setStatus(sheetInserted ? "" : "Insert the photo or page after pressing Scan.", busy: false)
        refreshOtherFolder()
        setEditable(true)
        saveButton.isHidden = true
        scanButton.isEnabled = true
        scanButton.title = "Scan"
        present()
    }

    func showScanning(page: Int) {
        headline.stringValue = page > 1 ? "Scanning page \(page)…" : "Scanning…"
        setStatus("", busy: true)
        setEditable(false)
        scanButton.isEnabled = false
        saveButton.isEnabled = false
    }

    func showWaitingForSheet() {
        headline.stringValue = "Insert the photo or page"
        setStatus("The scan starts as soon as the scanner feels it.", busy: true)
        setEditable(false)
        scanButton.isEnabled = false
    }

    /// Multi-page document: a page was added; the next inserted page is scanned with the same settings.
    func showPageAdded(count: Int, cutOff: Bool) {
        headline.stringValue = count == 1 ? "1 page scanned" : "\(count) pages scanned"
        setStatus((cutOff ? "That page may be cut off at the end. " : "") + "Insert the next page to add it, or save the PDF.", busy: false)
        setEditable(false)
        saveButton.isHidden = false
        saveButton.isEnabled = true
        scanButton.isEnabled = false
        saveButton.keyEquivalent = "\r"
        present()
    }

    func showSaving() {
        headline.stringValue = "Saving…"
        setStatus("", busy: true)
        saveButton.isEnabled = false
    }

    func showError(_ message: String) {
        headline.stringValue = "Could not scan"
        setStatus(message, busy: false)
        setEditable(true)
        scanButton.isEnabled = true
        scanButton.title = "Try again"
        present()
    }

    private func present() {
        fitToContent()
        if !isVisible { center() }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    private func setStatus(_ text: String, busy: Bool) {
        status.stringValue = text
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        fitToContent()
    }

    /// Sizes the window to exactly what its content needs, keeping the top edge in place. Spare height would
    /// otherwise be spread between the option rows, differently for each kind, and the rows would shift.
    private func fitToContent() {
        guard let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        var frame = frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize))
        frame.origin = NSPoint(x: self.frame.minX, y: self.frame.maxY - frame.height)
        setFrame(frame, display: isVisible)
    }

    private func setEditable(_ on: Bool) {
        for control in [kind, photoDPI, photoFormat, photoCrop, photoStraighten, docDPI, docColor, docStraighten, docSearchable] as [NSControl] {
            control.isEnabled = on
        }
        saveToOther.isEnabled = on && otherReachable
        chooseFolder.isEnabled = on
    }

    /// The checkbox for the other folder (Folders.other, picked with Choose…): disabled until one is chosen,
    /// unticked and disabled while it is not connected. Checked each time the panel opens, since shares come
    /// and go.
    private func refreshOtherFolder() {
        guard let folder = Folders.other else {
            otherReachable = false
            saveToOther.title = "Save to another folder"
            saveToOther.toolTip = "Use Choose… to pick a folder to save scans in instead of the Desktop."
            saveToOther.state = .off
            return
        }
        otherReachable = Folders.isReachable(folder)
        setOtherTitle(folder.lastPathComponent, suffix: otherReachable ? " instead of the Desktop" : " (not connected)")
        saveToOther.toolTip = folder.path
        saveToOther.state = otherReachable && defaults.bool(forKey: "saveToOther") ? .on : .off
    }

    /// "Save to “name” instead of the Desktop", with a long folder name shortened in the middle until the
    /// title fits next to the Choose… button.
    private func setOtherTitle(_ name: String, suffix: String) {
        var shown = name
        var keep = name.count
        while true {
            saveToOther.title = "Save to “\(shown)”\(suffix)"
            guard saveToOther.fittingSize.width > otherTitleWidth, keep > 4 else { return }
            keep -= 1
            shown = String(name.prefix((keep + 1) / 2)) + "…" + String(name.suffix(keep / 2))
        }
    }

    // MARK: actions

    @objc private func kindChanged() {
        let photo = kind.selectedSegment == Kind.photo.rawValue
        photoOptions.isHidden = !photo
        docOptions.isHidden = photo
        fitToContent()
    }

    @objc private func scan() {
        saveChoices()
        onScan?(choice)
    }

    @objc private func savePDF() { onSavePDF?() }

    /// Picks the folder for the checkbox. It is remembered (defaults key otherFolder) and ticked.
    @objc private func chooseOtherFolder() {
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.canCreateDirectories = true
        open.allowsMultipleSelection = false
        open.prompt = "Choose"
        open.message = "Choose where to save scans instead of the Desktop."
        open.directoryURL = Folders.other.flatMap { Folders.isReachable($0) ? $0 : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser
        open.beginSheetModal(for: self) { [weak self] response in
            guard let self, response == .OK, let url = open.url else { return }
            defaults.set(url.path, forKey: "otherFolder")
            defaults.set(true, forKey: "saveToOther")
            refreshOtherFolder()
            saveToOther.isEnabled = otherReachable
            fitToContent()
        }
    }

    @objc private func cancelPressed() { onCancel?() }

    private var dismissing = false

    /// Closes the panel without reporting a cancel.
    func dismiss() {
        dismissing = true
        close()
        dismissing = false
    }

    func windowWillClose(_ notification: Notification) {
        if !dismissing { onCancel?() }
    }

    var choice: Choice {
        let photo = kind.selectedSegment == Kind.photo.rawValue
        return Choice(kind: photo ? .photo : .document,
                      dpi: photo ? [300, 600][photoDPI.indexOfSelectedItem] : [150, 300, 600][docDPI.indexOfSelectedItem],
                      color: photo || docColor.indexOfSelectedItem == 0,
                      format: Imaging.PhotoFormat.allCases[photoFormat.indexOfSelectedItem],
                      crop: photo ? photoCrop.state == .on : true,
                      straighten: (photo ? photoStraighten : docStraighten).state == .on,
                      searchable: !photo && docSearchable.state == .on,
                      folder: otherReachable && saveToOther.state == .on ? Folders.other : nil)
    }

    private func saveChoices() {
        defaults.set(kind.selectedSegment, forKey: "kind")
        defaults.set(photoDPI.indexOfSelectedItem, forKey: "photoDPI")
        defaults.set(photoFormat.indexOfSelectedItem, forKey: "photoFormat")
        defaults.set(photoCrop.state == .on, forKey: "photoCrop")
        defaults.set(photoStraighten.state == .on, forKey: "photoStraighten")
        defaults.set(docStraighten.state == .on, forKey: "docStraighten")
        defaults.set(docDPI.indexOfSelectedItem, forKey: "docDPI")
        defaults.set(docColor.indexOfSelectedItem, forKey: "docColor")
        defaults.set(docSearchable.state == .on, forKey: "docSearchable")
        if otherReachable { defaults.set(saveToOther.state == .on, forKey: "saveToOther") }
    }

    private func restoreChoices() {
        defaults.register(defaults: ["kind": 0, "photoDPI": 0, "photoFormat": 0, "photoCrop": true, "photoStraighten": true,
                                     "docDPI": 1, "docColor": 0, "docStraighten": true, "docSearchable": true,
                                     "otherFolder": "", "saveToOther": false])
        kind.selectedSegment = defaults.integer(forKey: "kind")
        photoDPI.selectItem(at: defaults.integer(forKey: "photoDPI"))
        photoFormat.selectItem(at: defaults.integer(forKey: "photoFormat"))
        photoCrop.state = defaults.bool(forKey: "photoCrop") ? .on : .off
        photoStraighten.state = defaults.bool(forKey: "photoStraighten") ? .on : .off
        docStraighten.state = defaults.bool(forKey: "docStraighten") ? .on : .off
        docDPI.selectItem(at: defaults.integer(forKey: "docDPI"))
        docColor.selectItem(at: defaults.integer(forKey: "docColor"))
        docSearchable.state = defaults.bool(forKey: "docSearchable") ? .on : .off
        kindChanged()
    }
}
