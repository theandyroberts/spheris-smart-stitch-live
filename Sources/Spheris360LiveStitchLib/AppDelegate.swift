import AppKit
import Metal
import simd

/// Drew's grid ordering: sky cams top, fronts middle, backs bottom.
let gridSlotCameraIDs = ["G", "H", "J", "A", "B", "C", "D", "E", "F"]

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var gridWindow: NSWindow?
    private var stitchWindow: NSWindow?
    private var vcamWindow: NSWindow?
    private var gridView: GridDisplayView?
    private var stitchView: StitchDisplayView?
    private var vcamView: VirtualCameraView?
    private var router: VideoInputRouter?

    // Calibration
    private var metalDevice: MTLDevice?
    private var remapGen: RemapGenerator?
    private var calibLibrary: CalibrationLibrary?
    private var currentProfile: CalibrationProfile?
    private var currentClipDir: URL?

    // Scrubber controls (both windows)
    private var scrubbers: [NSSlider] = []
    private var playPauseButtons: [NSButton] = []
    private var timeLabels: [NSTextField] = []
    private var scrubberTimer: Timer?

    // Calibration picker (grid window only)
    private var calibButton: NSButton?
    private var pickerPanel: CalibrationPickerPanel?

    // Color grading
    private var lutTexture: MTLTexture?
    private var lutEnabled: Bool = false
    private var gradeButtons: [NSButton] = []
    private var exposureLabels: [NSTextField] = []
    private var currentExposure: Float = 0

    // Seam optimization
    private var seamOptimizer: SeamOptimizer?
    private var currentRemapTexture: MTLTexture?

    // Streaming
    private var streamSettings: StreamSettings?
    private var frameGrabber: FrameGrabber?
    private var rtmpStreamer: RTMPStreamer?
    private var streamButton: NSButton?
    private var streamSettingsPanel: StreamSettingsPanel?
    private var stitchControlBar: NSView?
    private var onAirPill: NSView?
    private var onAirDot: NSTextField?

    private var setupPanel: SetupPanel?
    private var projectDir: URL!

    override public init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let projDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/spheris-smart-stitch")
        self.projectDir = projDir

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported")
        }
        self.metalDevice = device
        self.remapGen = RemapGenerator(device: device)
        self.seamOptimizer = SeamOptimizer(device: device)

        // ── Set up calibration library ──
        let library = CalibrationLibrary(projectDir: projDir)
        library.migrateIfNeeded()
        self.calibLibrary = library

        // Show setup screen
        let panel = SetupPanel(projectDir: projDir) { [weak self] config in
            self?.launchPipeline(config: config)
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.setupPanel = panel
    }

    private func launchPipeline(config: SetupConfig) {
        guard let device = metalDevice else { return }

        // ── Load calibration ──
        guard let calibration = try? CalibrationData.load(from: config.calibrationURL) else {
            fatalError("Failed to load calibration from \(config.calibrationURL.lastPathComponent)")
        }

        // Track profile in library
        let profileName = config.calibrationURL.deletingPathExtension().lastPathComponent
        let profile = CalibrationProfile(
            url: config.calibrationURL,
            displayName: profileName,
            created: "",
            lensInfo: ""
        )
        calibLibrary?.setLastUsed(profile)
        self.currentProfile = profile
        print("Loaded calibration: \(profile.displayName) (\(calibration.cameras.count) cameras, \(calibration.outputWidth)x\(calibration.outputHeight))")

        // ── Generate remap LUT ──
        let remapTexture = remapGen!.generate(
            calibration: calibration,
            gridSlotCameraIDs: gridSlotCameraIDs,
            outputWidth: calibration.outputWidth,
            outputHeight: calibration.outputHeight
        )
        self.currentRemapTexture = remapTexture
        let labelPositions = computeStitchLabelPositions(calibration: calibration)

        // ── Load color grading LUT ──
        let projectDir = self.projectDir!
        let lutsDir = projectDir.appendingPathComponent("config/luts")
        let luts = LUTLoader.availableLUTs(lutsDir: lutsDir)
        if let firstLUT = luts.first {
            self.lutTexture = LUTLoader.load(cubeURL: firstLUT, device: device)
        }

        // ── Window 1: 3x3 Grid with scrubber ──
        let gridRect = NSRect(x: 50, y: 400, width: 1440, height: 850)
        let gridWin = NSWindow(
            contentRect: gridRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        gridWin.title = "Spheris 360 — Camera Grid"
        gridWin.minSize = NSSize(width: 720, height: 445)
        gridWin.contentAspectRatio = NSSize(width: 3, height: 2)  // 3x3 grid of ~16:9 cells + control bar

        let containerView = NSView(frame: gridRect)
        let gv = GridDisplayView(
            frame: NSRect(x: 0, y: 40, width: gridRect.width, height: gridRect.height - 40),
            metalDevice: device
        )
        gv.autoresizingMask = [.width, .height]
        containerView.addSubview(gv)

        let controlBar = makeGridControlBar(width: gridRect.width)
        containerView.addSubview(controlBar)

        gridWin.contentView = containerView
        self.gridWindow = gridWin
        self.gridView = gv

        // ── Window 2: Stitched Equirectangular ──
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let stitchW = min(screen.width - 40, 2560)          // leave 20 px margin each side
        let stitchH = stitchW / 2                            // 2:1 equirectangular
        let stitchX = screen.origin.x + (screen.width - stitchW) / 2
        let stitchY = screen.origin.y + 20                   // near bottom of screen
        let stitchRect = NSRect(x: stitchX, y: stitchY, width: stitchW, height: stitchH)
        let stitchWin = NSWindow(
            contentRect: stitchRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        stitchWin.title = "Spheris 360 — Live Stitch"
        stitchWin.minSize = NSSize(width: 640, height: 320)
        stitchWin.contentAspectRatio = NSSize(width: 2, height: 1)  // 2:1 equirectangular

        let stitchContainer = NSView(frame: stitchRect)
        let sv = StitchDisplayView(
            frame: NSRect(x: 0, y: 40, width: stitchRect.width, height: stitchRect.height - 40),
            metalDevice: device,
            remapTexture: remapTexture,
            cameraLabels: labelPositions,
            lutTexture: lutTexture
        )
        sv.autoresizingMask = [.width, .height]
        stitchContainer.addSubview(sv)

        let stitchControlBar = makePlaybackControlBar(width: stitchRect.width)
        stitchContainer.addSubview(stitchControlBar)
        self.stitchControlBar = stitchControlBar

        // ON AIR pill — hidden until streaming starts; click to open stream settings
        let pill = NSButton(frame: NSRect(x: 8, y: 6, width: 76, height: 26))
        pill.isBordered = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 13
        pill.layer?.backgroundColor = NSColor(red: 0.85, green: 0.08, blue: 0.08, alpha: 1).cgColor
        pill.attributedTitle = NSAttributedString(
            string: "  ON AIR",
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.boldSystemFont(ofSize: 11),
            ]
        )
        pill.target = self
        pill.action = #selector(openStreamSettings)
        pill.isHidden = true
        stitchContainer.addSubview(pill)
        self.onAirPill = pill
        // Pulsing dot overlay — sits on top of the pill
        let dot = NSTextField(labelWithString: "●")
        dot.frame = NSRect(x: 6, y: 4, width: 14, height: 18)
        dot.font = .boldSystemFont(ofSize: 12)
        dot.textColor = .white
        dot.backgroundColor = .clear
        dot.isBordered = false
        dot.wantsLayer = true
        dot.isHidden = true
        pill.addSubview(dot)
        self.onAirDot = dot

        stitchWin.contentView = stitchContainer
        self.stitchWindow = stitchWin
        self.stitchView = sv

        // ── Window 3: Virtual Camera (rectilinear look-around) ──
        let vcamW: CGFloat = 960
        let vcamH: CGFloat = 720  // 4:3
        let vcamX = screen.origin.x + screen.width - vcamW - 20
        let vcamY = screen.origin.y + screen.height - vcamH - 20
        let vcamRect = NSRect(x: vcamX, y: vcamY, width: vcamW, height: vcamH)
        let vcamWin = NSWindow(
            contentRect: vcamRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        vcamWin.title = "Spheris 360 — Virtual Camera"
        vcamWin.minSize = NSSize(width: 480, height: 360)
        vcamWin.contentAspectRatio = NSSize(width: 4, height: 3)  // 4:3 rectilinear
        vcamWin.minSize = NSSize(width: 480, height: 360)

        // Virtual camera starts at equirect center (lon=0 = rig forward)
        let vcamContainer = NSView(frame: vcamRect)
        let vv = VirtualCameraView(
            frame: NSRect(x: 0, y: 40, width: vcamRect.width, height: vcamRect.height - 40),
            metalDevice: device,
            remapTexture: remapTexture
        )
        vv.autoresizingMask = [.width, .height]
        if let lut = lutTexture { vv.setLUT(lut) }
        vcamContainer.addSubview(vv)

        let vcamControlBar = makeVCamControlBar(width: vcamRect.width)
        vcamContainer.addSubview(vcamControlBar)

        vcamWin.contentView = vcamContainer
        self.vcamWindow = vcamWin
        self.vcamView = vv
        vv.onVehicleChanged = { [weak self] _ in
            guard let self = self, let picker = self.vehiclePicker else { return }
            let next = (picker.indexOfSelectedItem + 1) % picker.numberOfItems
            picker.selectItem(at: next)
            self.vehicleChanged(picker)
        }

        // ── Set up crop engine and overlay simulator ──
        let cropEngine = CropEngine()
        let refDir = projectDir.appendingPathComponent("reference")
        if let simulator = OverlaySimulator(device: device, referenceDir: refDir) {
            gv.setOverlaySimulator(simulator)
        }

        // ── Set up file providers ──
        let clipDir = config.clipDirectory
        self.currentClipDir = clipDir
        let router = VideoInputRouter()
        router.setDisplayView(gv)
        router.setStitchView(sv)
        router.setVirtualCameraView(vv)
        router.setCropEngine(cropEngine)

        for (slotIndex, cameraID) in gridSlotCameraIDs.enumerated() {
            guard let cam = calibration.camera(forID: cameraID) else { continue }
            let movURL = findMOV(in: clipDir, prefix: cam.imageFile)
                ?? findMOV(in: clipDir, letterPrefix: cameraID)
            guard let url = movURL else {
                print("Warning: no MOV found for camera \(cameraID)")
                continue
            }
            let provider = FilePlaybackProvider(fileURL: url, slotIndex: slotIndex)
            router.setProvider(provider, slot: slotIndex)
        }

        self.router = router

        do {
            try router.startAll()
            print("Playback started: 9 cameras at 24fps")
        } catch {
            fatalError("Failed to start playback: \(error)")
        }

        // Update scrubber position periodically
        scrubberTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateScrubberPosition() }
        }

        // ── Set up streaming ──
        let ss = StreamSettings()
        self.streamSettings = ss
        let grabber = FrameGrabber(device: device, width: ss.streamWidth, height: ss.streamHeight, fps: ss.streamFPS)
        self.frameGrabber = grabber
        sv.frameGrabber = grabber

        let streamer = RTMPStreamer(settings: ss)
        self.rtmpStreamer = streamer
        grabber.onFrame = { [weak streamer] data, _, _ in
            streamer?.pushFrame(data)
        }

        gridWin.makeKeyAndOrderFront(nil)
        stitchWin.orderFront(nil)
        vcamWin.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Add View menu with label toggle
        let viewMenu = NSMenu(title: "View")
        let labelItem = NSMenuItem(title: "Show Camera Labels", action: #selector(toggleLabels), keyEquivalent: "l")
        labelItem.keyEquivalentModifierMask = []  // just L, no Cmd
        viewMenu.addItem(labelItem)
        let gradeItem = NSMenuItem(title: "Toggle Color Grade", action: #selector(toggleColorGrade), keyEquivalent: "g")
        gradeItem.keyEquivalentModifierMask = []  // just G, no Cmd
        viewMenu.addItem(gradeItem)
        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewMenuItem.submenu = viewMenu
        NSApp.mainMenu?.addItem(viewMenuItem)

        // Global key monitor — MTKView subclasses eat keyDown before the menu sees it
        // Skip when virtual camera window is key (it handles F/B/L/R/G itself)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
            let vcamIsKey = self?.vcamWindow?.isKeyWindow ?? false
            switch event.charactersIgnoringModifiers {
            case "l" where !vcamIsKey: self?.toggleLabels(); return nil
            case "g" where !vcamIsKey: self?.toggleColorGrade(); return nil
            default: return event
            }
        }
    }

    @objc private func toggleLabels() {
        let newState: Bool
        if let gv = gridView {
            newState = !gv.showLabels
            gv.showLabels = newState
        } else {
            newState = true
        }
        stitchView?.showLabels = newState
    }

    @objc private func toggleColorGrade() {
        lutEnabled = !lutEnabled
        stitchView?.lutEnabled = lutEnabled
        vcamView?.lutEnabled = lutEnabled
        // Update buttons to show active state
        for btn in gradeButtons {
            btn.title = lutEnabled ? "Grade ●" : "Grade"
            btn.contentTintColor = lutEnabled ? .systemGreen : nil
        }
        // Reset exposure when toggling off
        if !lutEnabled {
            applyExposure(0)
        }
        // Update window titles
        stitchWindow?.title = lutEnabled
            ? "Spheris 360 — Live Stitch [Graded]"
            : "Spheris 360 — Live Stitch"
        vcamWindow?.title = lutEnabled
            ? "Spheris 360 — Virtual Camera [Graded]"
            : "Spheris 360 — Virtual Camera"
    }

    @objc private func exposureUp() {
        applyExposure(currentExposure + 0.5)
    }

    @objc private func exposureDown() {
        applyExposure(currentExposure - 0.5)
    }

    private func applyExposure(_ ev: Float) {
        let clamped = max(-4, min(4, ev))
        currentExposure = clamped
        stitchView?.exposure = clamped
        vcamView?.exposure = clamped
        let text = clamped >= 0
            ? String(format: "+%.1f", clamped)
            : String(format: "%.1f", clamped)
        exposureLabels.forEach { $0.stringValue = text }
    }

    // MARK: - Seam optimization

    @objc private func optimizeSeams() {
        guard let remap = currentRemapTexture,
              let router = router,
              let optimizer = seamOptimizer
        else {
            print("Seam optimization: missing remap texture or router")
            return
        }

        let frames = router.latestCleanFrames
        guard !frames.isEmpty else {
            print("Seam optimization: no camera frames available yet")
            return
        }

        print("Starting seam optimization...")

        // Run on background thread to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async {
            guard let optimized = optimizer.optimize(
                remapTexture: remap,
                cameraFrames: frames
            ) else {
                DispatchQueue.main.async {
                    print("Seam optimization: failed")
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.currentRemapTexture = optimized
                self.stitchView?.updateCalibration(remapTexture: optimized)
                self.vcamView?.updateCalibration(remapTexture: optimized)
                print("Seam optimization: applied")
            }
        }
    }

    // MARK: - Calibration switching

    private func applyCalibration(_ calibration: CalibrationData) {
        guard let remapGen = remapGen else { return }
        let remapTexture = remapGen.generate(
            calibration: calibration,
            gridSlotCameraIDs: gridSlotCameraIDs,
            outputWidth: calibration.outputWidth,
            outputHeight: calibration.outputHeight
        )
        self.currentRemapTexture = remapTexture
        let labelPositions = computeStitchLabelPositions(calibration: calibration)
        stitchView?.updateCalibration(remapTexture: remapTexture, cameraLabels: labelPositions)
        vcamView?.updateCalibration(remapTexture: remapTexture)
        print("Switched calibration: \(calibration.cameras.count) cameras, \(calibration.outputWidth)x\(calibration.outputHeight)")
    }

    private func updateCalibButton() {
        calibButton?.title = currentProfile?.displayName ?? "No Calibration"
    }

    @objc private func openCalibrationLibrary() {
        guard let library = calibLibrary, let window = gridWindow else { return }
        let panel = CalibrationPickerPanel(
            library: library,
            currentProfile: currentProfile,
            onSelect: { [weak self] profile in
                guard let self = self else { return }
                guard let calibration = try? library.load(profile) else {
                    print("Failed to load calibration: \(profile.displayName)")
                    return
                }
                library.setLastUsed(profile)
                self.currentProfile = profile
                self.updateCalibButton()
                self.applyCalibration(calibration)
            },
            onRename: { [weak self] profile in
                let alert = NSAlert()
                alert.messageText = "Rename Calibration"
                alert.informativeText = "Enter a new name:"
                let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
                input.stringValue = profile.displayName
                alert.accessoryView = input
                alert.addButton(withTitle: "Rename")
                alert.addButton(withTitle: "Cancel")
                alert.window.initialFirstResponder = input
                guard alert.runModal() == .alertFirstButtonReturn else { return nil }
                let newName = input.stringValue.trimmingCharacters(in: .whitespaces)
                guard !newName.isEmpty, newName != profile.displayName else { return nil }
                do {
                    let updated = try library.rename(profile, to: newName)
                    if self?.currentProfile?.url == profile.url {
                        self?.currentProfile = updated
                        self?.updateCalibButton()
                    }
                    return updated
                } catch {
                    print("Failed to rename: \(error)")
                    return nil
                }
            },
            onNewCalibration: { [weak self] in
                self?.runInSessionCalibration()
            }
        )
        panel.center()
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        self.pickerPanel = panel
    }

    private func runInSessionCalibration() {
        guard let clipDir = currentClipDir, let window = gridWindow else { return }

        // Get current frame number from the router
        let fps = 24.0
        let duration = router?.clipDuration ?? 0
        let fraction = router?.currentFraction ?? 0
        let currentFrame = Int(fraction * duration * fps)

        let runner = CalibrateRunnerPanel(
            projectDir: projectDir,
            clipDir: clipDir,
            frameNumber: currentFrame
        ) { [weak self] outputURL in
            guard let self = self, let url = outputURL else { return }
            // Load and apply the new calibration
            guard let calibration = try? CalibrationData.load(from: url) else {
                print("Failed to load new calibration")
                return
            }
            let profile = CalibrationProfile(
                url: url,
                displayName: url.deletingPathExtension().lastPathComponent,
                created: "",
                lensInfo: ""
            )
            self.calibLibrary?.setLastUsed(profile)
            self.currentProfile = profile
            self.updateCalibButton()
            self.applyCalibration(calibration)
            // Refresh the picker if it's still open
            self.pickerPanel?.refreshProfiles()
        }
        window.addChildWindow(runner, ordered: .above)
        runner.makeKeyAndOrderFront(nil)
    }

    // MARK: - Control bars

    /// Grid window control bar: play/pause + calibration picker + scrubber + time
    private func makeGridControlBar(width: CGFloat) -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 36))
        bar.autoresizingMask = [.width]

        // Calibration library button
        let calibBtn = NSButton(frame: NSRect(x: 4, y: 4, width: 270, height: 28))
        calibBtn.bezelStyle = .rounded
        calibBtn.title = currentProfile?.displayName ?? "No Calibration"
        calibBtn.alignment = .left
        calibBtn.lineBreakMode = .byTruncatingTail
        calibBtn.font = .systemFont(ofSize: 11)
        calibBtn.target = self
        calibBtn.action = #selector(openCalibrationLibrary)
        bar.addSubview(calibBtn)
        self.calibButton = calibBtn

        let playBtn = NSButton(frame: NSRect(x: 278, y: 4, width: 28, height: 28))
        playBtn.bezelStyle = .regularSquare
        playBtn.title = "⏸"
        playBtn.font = .systemFont(ofSize: 14)
        playBtn.target = self
        playBtn.action = #selector(togglePlayPause)
        bar.addSubview(playBtn)
        playPauseButtons.append(playBtn)

        let sliderX: CGFloat = 310
        let slider = NSSlider(frame: NSRect(x: sliderX, y: 8, width: width - sliderX - 94, height: 20))
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = 0
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(scrubberChanged(_:))
        slider.autoresizingMask = [.width]
        bar.addSubview(slider)
        scrubbers.append(slider)

        let label = NSTextField(frame: NSRect(x: width - 90, y: 8, width: 86, height: 20))
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.textColor = .secondaryLabelColor
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.stringValue = "00:00 / 00:00"
        label.alignment = .right
        label.autoresizingMask = [.minXMargin]
        bar.addSubview(label)
        timeLabels.append(label)

        return bar
    }

    /// Stitch window control bar: stream button + play/pause + scrubber + time
    private func makePlaybackControlBar(width: CGFloat) -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 36))
        bar.autoresizingMask = [.width]

        // Stream control button
        let sBtn = NSButton(frame: NSRect(x: 4, y: 4, width: 80, height: 28))
        sBtn.bezelStyle = .rounded
        sBtn.title = "Stream"
        sBtn.font = .systemFont(ofSize: 11)
        sBtn.target = self
        sBtn.action = #selector(openStreamSettings)
        bar.addSubview(sBtn)
        self.streamButton = sBtn

        // Color grade toggle
        let gBtn = NSButton(frame: NSRect(x: 88, y: 4, width: 62, height: 28))
        gBtn.bezelStyle = .rounded
        gBtn.title = "Grade"
        gBtn.font = .systemFont(ofSize: 11)
        gBtn.target = self
        gBtn.action = #selector(toggleColorGrade)
        bar.addSubview(gBtn)
        self.gradeButtons.append(gBtn)

        // Exposure: [ - ] 0.0 [ + ]
        let expMinus = NSButton(frame: NSRect(x: 154, y: 4, width: 24, height: 28))
        expMinus.bezelStyle = .regularSquare
        expMinus.title = "−"
        expMinus.font = .systemFont(ofSize: 14)
        expMinus.target = self
        expMinus.action = #selector(exposureDown)
        bar.addSubview(expMinus)

        let expLabel = NSTextField(frame: NSRect(x: 178, y: 8, width: 38, height: 20))
        expLabel.isEditable = false
        expLabel.isBordered = false
        expLabel.backgroundColor = .clear
        expLabel.textColor = .secondaryLabelColor
        expLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        expLabel.stringValue = " 0.0"
        expLabel.alignment = .center
        bar.addSubview(expLabel)
        self.exposureLabels.append(expLabel)

        let expPlus = NSButton(frame: NSRect(x: 216, y: 4, width: 24, height: 28))
        expPlus.bezelStyle = .regularSquare
        expPlus.title = "+"
        expPlus.font = .systemFont(ofSize: 14)
        expPlus.target = self
        expPlus.action = #selector(exposureUp)
        bar.addSubview(expPlus)

        // Seam optimization button
        let seamBtn = NSButton(frame: NSRect(x: 244, y: 4, width: 62, height: 28))
        seamBtn.bezelStyle = .rounded
        seamBtn.title = "Seams"
        seamBtn.font = .systemFont(ofSize: 11)
        seamBtn.target = self
        seamBtn.action = #selector(optimizeSeams)
        bar.addSubview(seamBtn)

        let playBtn = NSButton(frame: NSRect(x: 310, y: 4, width: 28, height: 28))
        playBtn.bezelStyle = .regularSquare
        playBtn.title = "⏸"
        playBtn.font = .systemFont(ofSize: 14)
        playBtn.target = self
        playBtn.action = #selector(togglePlayPause)
        bar.addSubview(playBtn)
        playPauseButtons.append(playBtn)

        let slider = NSSlider(frame: NSRect(x: 342, y: 8, width: width - 436, height: 20))
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = 0
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(scrubberChanged(_:))
        slider.autoresizingMask = [.width]
        bar.addSubview(slider)
        scrubbers.append(slider)

        let label = NSTextField(frame: NSRect(x: width - 90, y: 8, width: 86, height: 20))
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.textColor = .secondaryLabelColor
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.stringValue = "00:00 / 00:00"
        label.alignment = .right
        label.autoresizingMask = [.minXMargin]
        bar.addSubview(label)
        timeLabels.append(label)

        return bar
    }

    /// Virtual camera control bar: grade + exposure + FBLR hints
    private func makeVCamControlBar(width: CGFloat) -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 36))
        bar.autoresizingMask = [.width]

        // Color grade toggle
        let gBtn = NSButton(frame: NSRect(x: 4, y: 4, width: 62, height: 28))
        gBtn.bezelStyle = .rounded
        gBtn.title = "Grade"
        gBtn.font = .systemFont(ofSize: 11)
        gBtn.target = self
        gBtn.action = #selector(toggleColorGrade)
        bar.addSubview(gBtn)
        gradeButtons.append(gBtn)

        // Exposure: [ - ] 0.0 [ + ]
        let expMinus = NSButton(frame: NSRect(x: 70, y: 4, width: 24, height: 28))
        expMinus.bezelStyle = .regularSquare
        expMinus.title = "−"
        expMinus.font = .systemFont(ofSize: 14)
        expMinus.target = self
        expMinus.action = #selector(exposureDown)
        bar.addSubview(expMinus)

        let expLabel = NSTextField(frame: NSRect(x: 94, y: 8, width: 38, height: 20))
        expLabel.isEditable = false
        expLabel.isBordered = false
        expLabel.backgroundColor = .clear
        expLabel.textColor = .secondaryLabelColor
        expLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        expLabel.stringValue = " 0.0"
        expLabel.alignment = .center
        bar.addSubview(expLabel)
        exposureLabels.append(expLabel)

        let expPlus = NSButton(frame: NSRect(x: 132, y: 4, width: 24, height: 28))
        expPlus.bezelStyle = .regularSquare
        expPlus.title = "+"
        expPlus.font = .systemFont(ofSize: 14)
        expPlus.target = self
        expPlus.action = #selector(exposureUp)
        bar.addSubview(expPlus)

        // Vehicle interior picker
        let vLabel = NSTextField(labelWithString: "Interior:")
        vLabel.frame = NSRect(x: 166, y: 8, width: 50, height: 20)
        vLabel.font = .systemFont(ofSize: 11)
        vLabel.textColor = .secondaryLabelColor
        bar.addSubview(vLabel)

        let vPicker = NSPopUpButton(frame: NSRect(x: 218, y: 4, width: 140, height: 28))
        // Scan for OBJ models
        let vehiclesDir = projectDir.appendingPathComponent("config/vehicles")
        let models = VehicleModelLoader.availableModels(vehiclesDir: vehiclesDir)
        vehicleModelURLs = models.map { $0.url }
        var titles = ["None"]
        titles += models.map { $0.name }
        // Legacy angle-based options
        titles += ["~ Convertible", "~ Sedan", "~ SUV / Truck"]
        vPicker.addItems(withTitles: titles)
        vPicker.selectItem(at: 0)
        vPicker.font = .systemFont(ofSize: 11)
        vPicker.target = self
        vPicker.action = #selector(vehicleChanged(_:))
        bar.addSubview(vPicker)
        self.vehiclePicker = vPicker

        // FBLR hint
        let hint = NSTextField(frame: NSRect(x: width - 150, y: 8, width: 146, height: 20))
        hint.isEditable = false
        hint.isBordered = false
        hint.backgroundColor = .clear
        hint.textColor = NSColor.tertiaryLabelColor
        hint.font = .systemFont(ofSize: 10)
        hint.stringValue = "F front  B back  L left  R right"
        hint.alignment = .right
        hint.autoresizingMask = [.minXMargin]
        bar.addSubview(hint)

        return bar
    }

    private var vehiclePicker: NSPopUpButton?
    private var vehicleModelURLs: [URL] = []

    @objc private func vehicleChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        if idx == 0 {
            // "None" — clear vehicle, fall back to angle-based
            vcamView?.loadVehicle(objURL: nil)
            vcamView?.vehicleType = 0
        } else if idx <= vehicleModelURLs.count {
            // OBJ model
            vcamView?.vehicleType = 0  // disable angle-based
            vcamView?.loadVehicle(objURL: vehicleModelURLs[idx - 1])
        } else {
            // Legacy angle-based (convertible/sedan/SUV after the OBJ entries)
            let legacyIdx = idx - vehicleModelURLs.count
            vcamView?.loadVehicle(objURL: nil)
            vcamView?.vehicleType = UInt32(legacyIdx)
        }
    }

    // MARK: - Streaming controls

    @objc private func openStreamSettings() {
        guard let settings = streamSettings, let window = stitchWindow else { return }
        let panel = StreamSettingsPanel(
            settings: settings,
            isStreaming: { [weak self] in self?.rtmpStreamer?.isStreaming ?? false },
            onStart: { [weak self] in self?.startStreaming() },
            onStop: { [weak self] in self?.stopStreaming() }
        )
        panel.center()
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        self.streamSettingsPanel = panel
    }

    private func startStreaming() {
        guard let streamer = rtmpStreamer, let grabber = frameGrabber, let settings = streamSettings else { return }
        grabber.updateFPS(settings.streamFPS)
        // Start ffmpeg lazily on first frame so we know the drawable size
        grabber.onFrame = { [weak streamer] data, w, h in
            if let s = streamer, !s.isStreaming {
                try? s.start(inputWidth: w, inputHeight: h)
            }
            streamer?.pushFrame(data)
        }
        grabber.enabled = true
        // Hide controls, show ON AIR pill
        stitchControlBar?.isHidden = true
        onAirPill?.isHidden = false
        onAirDot?.isHidden = false
        pulseOnAirDot()
        // Expand stitch view into the control bar area
        if let sv = stitchView {
            var f = sv.frame
            f.origin.y = 0
            f.size.height = sv.superview?.bounds.height ?? f.size.height
            sv.frame = f
        }
        // Genie the stream settings panel into the ON AIR pill
        genieCloseStreamPanel()
    }

    private func stopStreaming() {
        rtmpStreamer?.stop()
        frameGrabber?.enabled = false
        // Restore controls, hide ON AIR pill
        stitchControlBar?.isHidden = false
        onAirPill?.isHidden = true
        onAirDot?.isHidden = true
        onAirDot?.layer?.removeAllAnimations()
        // Restore stitch view to leave room for control bar
        if let sv = stitchView {
            var f = sv.frame
            f.origin.y = 40
            f.size.height = (sv.superview?.bounds.height ?? f.size.height + 40) - 40
            sv.frame = f
        }
    }

    private func pulseOnAirDot() {
        guard let layer = onAirDot?.layer else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.15
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "dotPulse")
    }

    /// Animate the stream settings panel shrinking into the ON AIR pill location,
    /// like a genie-into-bottle effect.
    private func genieCloseStreamPanel() {
        guard let panel = streamSettingsPanel,
              let pill = onAirPill,
              let stitchWin = stitchWindow else { return }

        // Convert pill center to screen coordinates for the miniaturize target
        let pillInWindow = pill.convert(pill.bounds, to: nil)
        let pillOnScreen = stitchWin.convertToScreen(pillInWindow)

        // Snapshot the panel content into an image for the shrink animation
        guard let panelView = panel.contentView else {
            panel.orderOut(nil)
            return
        }
        let panelFrame = panel.frame
        guard let bitmap = panelView.bitmapImageRepForCachingDisplay(in: panelView.bounds) else {
            panel.orderOut(nil)
            return
        }
        panelView.cacheDisplay(in: panelView.bounds, to: bitmap)

        // Create a temporary overlay window for the animation
        let animWin = NSWindow(contentRect: panelFrame,
                               styleMask: [.borderless],
                               backing: .buffered, defer: false)
        animWin.isOpaque = false
        animWin.backgroundColor = .clear
        animWin.level = .floating
        let imgView = NSImageView(frame: NSRect(origin: .zero, size: panelFrame.size))
        let img = NSImage(size: panelView.bounds.size)
        img.addRepresentation(bitmap)
        imgView.image = img
        imgView.wantsLayer = true
        animWin.contentView = imgView
        animWin.orderFront(nil)

        // Hide the real panel immediately
        stitchWin.removeChildWindow(panel)
        panel.orderOut(nil)

        // Animate: shrink + move toward the pill
        let targetRect = NSRect(x: pillOnScreen.midX - 10,
                                y: pillOnScreen.midY - 5,
                                width: 20, height: 10)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animWin.animator().setFrame(targetRect, display: true)
            animWin.animator().alphaValue = 0
        }, completionHandler: {
            animWin.orderOut(nil)
        })
    }

    // MARK: - Playback controls

    @objc private func togglePlayPause() {
        guard let router = router else { return }
        router.togglePause()
        let title = router.isPaused ? "▶" : "⏸"
        playPauseButtons.forEach { $0.title = title }
    }

    @objc private func scrubberChanged(_ sender: NSSlider) {
        guard let router = router else { return }
        router.seek(toFraction: sender.doubleValue)
        for s in scrubbers where s !== sender { s.doubleValue = sender.doubleValue }
        playPauseButtons.forEach { $0.title = "▶" }
        updateTimeLabels()
    }

    private func updateScrubberPosition() {
        guard let router = router, !router.isPaused else { return }
        let frac = router.currentFraction
        scrubbers.forEach { $0.doubleValue = frac }
        updateTimeLabels()
    }

    private func updateTimeLabels() {
        guard let router = router else { return }
        let dur = router.clipDuration
        let cur = router.currentFraction * dur
        let text = "\(formatTime(cur)) / \(formatTime(dur))"
        timeLabels.forEach { $0.stringValue = text }
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Camera label positions for stitch overlay

    private func computeStitchLabelPositions(calibration: CalibrationData) -> [(String, Float, Float)] {
        var labels: [(String, Float, Float)] = []
        for (_, cameraID) in gridSlotCameraIDs.enumerated() {
            guard let cam = calibration.camera(forID: cameraID) else { continue }
            let R = cam.rotationMatrix
            let forward = R * SIMD3<Float>(0, 0, 1)
            let lon = atan2(forward.x, forward.z)
            let lat = asin(min(1, max(-1, forward.y)))
            let u = (lon + .pi) / (2 * .pi)
            let v: Float
            if cam.group == "horizontal" {
                v = 0.85
            } else {
                v = (lat + .pi / 2) / .pi
            }
            labels.append(("CAM \(cameraID)", u, v))
        }
        return labels
    }

    // MARK: - Helpers

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    public func applicationWillTerminate(_ notification: Notification) {
        scrubberTimer?.invalidate()
        rtmpStreamer?.stop()
        router?.stopAll()
    }

    private func findMOV(in dir: URL, prefix: String) -> URL? {
        let url = dir.appendingPathComponent(prefix + ".mov")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func findMOV(in dir: URL, letterPrefix: String) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        for name in contents.sorted() where name.lowercased().hasSuffix(".mov") {
            if name.uppercased().hasPrefix(letterPrefix + "0") {
                return dir.appendingPathComponent(name)
            }
        }
        return nil
    }
}
