import AppKit

/// Configuration gathered from the setup screen.
public struct SetupConfig {
    var clipDirectory: URL
    var calibrationURL: URL
    var lutName: String?
}

/// Launch screen shown before the main pipeline windows.
@MainActor
public final class SetupPanel: NSWindow {
    private let projectDir: URL
    private let onGo: (SetupConfig) -> Void

    // State
    private var selectedClipDir: URL?
    private var selectedCalibURL: URL?

    // UI refs
    private var clipLabel: NSButton?
    private var calibLabel: NSTextField?
    private var goButton: NSButton?

    public init(projectDir: URL, onGo: @escaping (SetupConfig) -> Void) {
        self.projectDir = projectDir
        self.onGo = onGo

        let w: CGFloat = 780
        let h: CGFloat = 720
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let x = screen.origin.x + (screen.width - w) / 2
        let y = screen.origin.y + (screen.height - h) / 2
        let rect = NSRect(x: x, y: y, width: w, height: h)

        super.init(
            contentRect: rect,
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        self.title = "Spheris360 LIVE"
        self.backgroundColor = NSColor(white: 0.1, alpha: 1)
        self.isMovableByWindowBackground = true

        buildUI()

        // Default clip: last used, or fall back to Roll02_Clip09
        if let lastPath = UserDefaults.standard.string(forKey: "lastClipDirectory"),
           FileManager.default.fileExists(atPath: lastPath) {
            let lastClip = URL(fileURLWithPath: lastPath)
            selectedClipDir = lastClip
            clipLabel?.title = lastClip.lastPathComponent
        } else {
            let clip09 = projectDir.appendingPathComponent("Roll02_Clip09")
            if FileManager.default.fileExists(atPath: clip09.path) {
                selectedClipDir = clip09
                clipLabel?.title = clip09.lastPathComponent
            }
        }

        // Default calibration
        let libDir = projectDir.appendingPathComponent("config/library")
        if let files = try? FileManager.default.contentsOfDirectory(at: libDir, includingPropertiesForKeys: [.creationDateKey]),
           let first = files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first {
            selectedCalibURL = first
            calibLabel?.stringValue = first.deletingPathExtension().lastPathComponent
        }

        updateGoButton()
    }

    private func buildUI() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor

        var yPos = frame.height - 40

        // ── Logo ──
        if let logoURL = Bundle.module.url(forResource: "SA-Wht-logo@3x", withExtension: "png", subdirectory: "Assets"),
           let logoImage = NSImage(contentsOf: logoURL) {
            let logoH: CGFloat = 40
            let logoW = logoH * (logoImage.size.width / logoImage.size.height)
            let logoView = NSImageView(frame: NSRect(x: (frame.width - logoW) / 2, y: yPos - logoH, width: logoW, height: logoH))
            logoView.image = logoImage
            logoView.imageScaling = .scaleProportionallyUpOrDown
            container.addSubview(logoView)
            yPos -= logoH + 16
        }

        // ── Rig images ──
        let imgH: CGFloat = 200
        let imgW: CGFloat = 340
        let gap: CGFloat = 20
        let imgY = yPos - imgH

        // Spheris XL (car) — selectable, active
        let carBtn = makeRigButton(
            frame: NSRect(x: frame.width / 2 - imgW - gap / 2, y: imgY, width: imgW, height: imgH),
            imageResource: "spheris-xl-car",
            logoResource: "SA-XL",
            enabled: true,
            selected: true
        )
        container.addSubview(carBtn)

        // Spheris Air (drone) — disabled for MVP
        let airBtn = makeRigButton(
            frame: NSRect(x: frame.width / 2 + gap / 2, y: imgY, width: imgW, height: imgH),
            imageResource: "spheris-air-drone",
            logoResource: "SA-AIR-wht",
            enabled: false,
            selected: false
        )
        container.addSubview(airBtn)

        yPos = imgY - 30

        // ── Source ──
        let sourceTitle = makeSection(title: "Source", y: yPos, container: container)
        yPos = sourceTitle - 8

        // Array Capture (disabled)
        let captureBtn = NSButton(frame: NSRect(x: 40, y: yPos - 32, width: 160, height: 32))
        captureBtn.bezelStyle = .rounded
        captureBtn.title = "Array Capture"
        captureBtn.font = .systemFont(ofSize: 13)
        captureBtn.isEnabled = false
        container.addSubview(captureBtn)

        // Existing Footage (folder browser)
        let footageBtn = NSButton(frame: NSRect(x: 220, y: yPos - 32, width: 160, height: 32))
        footageBtn.bezelStyle = .rounded
        footageBtn.title = "Existing Footage"
        footageBtn.font = .systemFont(ofSize: 13)
        footageBtn.target = self
        footageBtn.action = #selector(browseFootage)
        container.addSubview(footageBtn)

        let cLabelBtn = NSButton(frame: NSRect(x: 390, y: yPos - 32, width: 340, height: 24))
        cLabelBtn.isBordered = false
        cLabelBtn.alignment = .left
        cLabelBtn.font = .systemFont(ofSize: 12)
        cLabelBtn.contentTintColor = NSColor(white: 0.6, alpha: 1)
        cLabelBtn.title = ""
        cLabelBtn.target = self
        cLabelBtn.action = #selector(browseFootage)
        container.addSubview(cLabelBtn)
        self.clipLabel = cLabelBtn

        yPos -= 56

        // ── Calibration Profile ──
        let calibTitle = makeSection(title: "Calibration Profile", y: yPos, container: container)
        yPos = calibTitle - 8

        let calibBtn = NSButton(frame: NSRect(x: 40, y: yPos - 32, width: 100, height: 32))
        calibBtn.bezelStyle = .rounded
        calibBtn.title = "Browse..."
        calibBtn.font = .systemFont(ofSize: 13)
        calibBtn.target = self
        calibBtn.action = #selector(browseCalibration)
        container.addSubview(calibBtn)

        let newCalibBtn = NSButton(frame: NSRect(x: 148, y: yPos - 32, width: 140, height: 32))
        newCalibBtn.bezelStyle = .rounded
        newCalibBtn.title = "New Calibration"
        newCalibBtn.font = .systemFont(ofSize: 13)
        newCalibBtn.target = self
        newCalibBtn.action = #selector(runNewCalibration)
        container.addSubview(newCalibBtn)

        let calLabel = NSTextField(labelWithString: "")
        calLabel.frame = NSRect(x: 296, y: yPos - 28, width: 440, height: 20)
        calLabel.font = .systemFont(ofSize: 12)
        calLabel.textColor = NSColor(white: 0.6, alpha: 1)
        calLabel.lineBreakMode = .byTruncatingMiddle
        container.addSubview(calLabel)
        self.calibLabel = calLabel

        yPos -= 56

        // ── Color Profile ──
        let colorTitle = makeSection(title: "Color Profile", y: yPos, container: container)
        yPos = colorTitle - 8

        // Find LUT name
        let lutsDir = projectDir.appendingPathComponent("config/luts")
        let lutFiles = (try? FileManager.default.contentsOfDirectory(atPath: lutsDir.path))?.filter { $0.hasSuffix(".cube") }.sorted() ?? []
        let lutName = lutFiles.first ?? "None"

        let lutLabel = NSTextField(labelWithString: lutName)
        lutLabel.frame = NSRect(x: 40, y: yPos - 24, width: 500, height: 20)
        lutLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        lutLabel.textColor = NSColor(red: 0.82, green: 0.63, blue: 0.42, alpha: 1) // copper tone
        container.addSubview(lutLabel)

        yPos -= 60

        // ── GO Button ──
        let goBtn = NSButton(frame: NSRect(x: (frame.width - 120) / 2, y: yPos - 50, width: 120, height: 50))
        goBtn.isBordered = false
        goBtn.wantsLayer = true
        goBtn.layer?.cornerRadius = 10
        goBtn.layer?.backgroundColor = NSColor(red: 0.82, green: 0.63, blue: 0.42, alpha: 1).cgColor
        goBtn.attributedTitle = NSAttributedString(
            string: "GO",
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.boldSystemFont(ofSize: 22),
            ]
        )
        goBtn.target = self
        goBtn.action = #selector(goPressed)
        goBtn.keyEquivalent = "\r"
        container.addSubview(goBtn)
        self.goButton = goBtn

        contentView = container
    }

    // MARK: - Helpers

    private func makeSection(title: String, y: CGFloat, container: NSView) -> CGFloat {
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 24, y: y - 24, width: 400, height: 24)
        label.font = .boldSystemFont(ofSize: 16)
        label.textColor = .white
        container.addSubview(label)
        return y - 28
    }

    private func makeRigButton(frame: NSRect, imageResource: String, logoResource: String, enabled: Bool, selected: Bool) -> NSView {
        let wrapper = NSView(frame: frame)
        wrapper.wantsLayer = true
        wrapper.layer?.cornerRadius = 12
        wrapper.layer?.borderWidth = selected ? 2 : 1
        wrapper.layer?.borderColor = selected
            ? NSColor(red: 0.82, green: 0.63, blue: 0.42, alpha: 1).cgColor  // copper
            : NSColor(white: 0.25, alpha: 1).cgColor
        wrapper.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        wrapper.alphaValue = enabled ? 1.0 : 0.35

        // Product image
        if let imgURL = Bundle.module.url(forResource: imageResource, withExtension: "png", subdirectory: "Assets"),
           let img = NSImage(contentsOf: imgURL) {
            let imgView = NSImageView(frame: NSRect(x: 10, y: 40, width: frame.width - 20, height: frame.height - 56))
            imgView.image = img
            imgView.imageScaling = .scaleProportionallyUpOrDown
            wrapper.addSubview(imgView)
        }

        // Logotype image
        if let logoURL = Bundle.module.url(forResource: logoResource, withExtension: "png", subdirectory: "Assets"),
           let logoImg = NSImage(contentsOf: logoURL) {
            let logoH: CGFloat = 22
            let logoW = logoH * (logoImg.size.width / logoImg.size.height)
            let logoView = NSImageView(frame: NSRect(x: (frame.width - logoW) / 2, y: 8, width: logoW, height: logoH))
            logoView.image = logoImg
            logoView.imageScaling = .scaleProportionallyUpOrDown
            wrapper.addSubview(logoView)
        }

        if !enabled {
            let comingSoon = NSTextField(labelWithString: "Coming Soon")
            comingSoon.frame = NSRect(x: 0, y: frame.height / 2 - 10, width: frame.width, height: 20)
            comingSoon.alignment = .center
            comingSoon.font = .systemFont(ofSize: 11)
            comingSoon.textColor = NSColor(white: 0.5, alpha: 1)
            wrapper.addSubview(comingSoon)
        }

        return wrapper
    }

    private func updateGoButton() {
        goButton?.isEnabled = selectedClipDir != nil && selectedCalibURL != nil
    }

    // MARK: - Actions

    @objc private func browseFootage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = projectDir
        panel.prompt = "Select Clip Folder"

        panel.beginSheetModal(for: self) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.selectedClipDir = url
            self?.clipLabel?.title = url.lastPathComponent
            self?.updateGoButton()
        }
    }

    @objc private func runNewCalibration() {
        guard let clipDir = selectedClipDir else {
            let alert = NSAlert()
            alert.messageText = "Select a clip folder first"
            alert.informativeText = "Choose an Existing Footage folder before running calibration."
            alert.runModal()
            return
        }

        let panel = CalibrateRunnerPanel(
            projectDir: projectDir,
            clipDir: clipDir,
            frameNumber: 100
        ) { [weak self] outputURL in
            guard let self = self, let url = outputURL else { return }
            self.selectedCalibURL = url
            self.calibLabel?.stringValue = url.deletingPathExtension().lastPathComponent
            self.updateGoButton()
        }
        self.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func browseCalibration() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.directoryURL = projectDir.appendingPathComponent("config/library")
        panel.prompt = "Select Calibration Profile"

        panel.beginSheetModal(for: self) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.selectedCalibURL = url
            self?.calibLabel?.stringValue = url.deletingPathExtension().lastPathComponent
            self?.updateGoButton()
        }
    }

    @objc private func goPressed() {
        guard let clipDir = selectedClipDir, let calibURL = selectedCalibURL else { return }

        let lutsDir = projectDir.appendingPathComponent("config/luts")
        let lutFiles = (try? FileManager.default.contentsOfDirectory(atPath: lutsDir.path))?.filter { $0.hasSuffix(".cube") }.sorted() ?? []

        let config = SetupConfig(
            clipDirectory: clipDir,
            calibrationURL: calibURL,
            lutName: lutFiles.first
        )

        // Remember selections for next launch
        UserDefaults.standard.set(clipDir.path, forKey: "lastClipDirectory")

        orderOut(nil)
        onGo(config)
    }
}
