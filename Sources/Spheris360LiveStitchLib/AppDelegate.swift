import AppKit
import Metal
import simd

/// Drew's grid ordering: sky cams top, fronts middle, backs bottom.
let gridSlotCameraIDs = ["G", "H", "J", "A", "B", "C", "D", "E", "F"]

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var gridWindow: NSWindow?
    private var stitchWindow: NSWindow?
    private var gridView: GridDisplayView?
    private var stitchView: StitchDisplayView?
    private var router: VideoInputRouter?

    // Calibration
    private var metalDevice: MTLDevice?
    private var remapGen: RemapGenerator?
    private var calibLibrary: CalibrationLibrary?
    private var currentProfile: CalibrationProfile?

    // Scrubber controls (both windows)
    private var scrubbers: [NSSlider] = []
    private var playPauseButtons: [NSButton] = []
    private var timeLabels: [NSTextField] = []
    private var scrubberTimer: Timer?

    // Calibration picker (grid window only)
    private var calibButton: NSButton?
    private var pickerPanel: CalibrationPickerPanel?

    // Streaming
    private var streamSettings: StreamSettings?
    private var frameGrabber: FrameGrabber?
    private var rtmpStreamer: RTMPStreamer?
    private var streamButton: NSButton?
    private var streamSettingsPanel: StreamSettingsPanel?

    override public init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported")
        }
        self.metalDevice = device
        self.remapGen = RemapGenerator(device: device)

        // ── Set up calibration library ──
        let projectDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/spheris-smart-stitch")
        let library = CalibrationLibrary(projectDir: projectDir)
        library.migrateIfNeeded()
        self.calibLibrary = library

        // Load last-used or newest profile
        let profile = library.lastUsedProfile() ?? library.availableProfiles().first
        guard let profile = profile,
              let calibration = try? library.load(profile) else {
            fatalError("No calibration profiles found in config/library/")
        }
        library.setLastUsed(profile)
        self.currentProfile = profile
        print("Loaded calibration: \(profile.displayName) (\(calibration.cameras.count) cameras, \(calibration.outputWidth)x\(calibration.outputHeight))")

        // ── Generate remap LUT ──
        let remapTexture = remapGen!.generate(
            calibration: calibration,
            gridSlotCameraIDs: gridSlotCameraIDs,
            outputWidth: calibration.outputWidth,
            outputHeight: calibration.outputHeight
        )
        let labelPositions = computeStitchLabelPositions(calibration: calibration)

        // ── Window 1: 3x3 Grid with scrubber ──
        let gridRect = NSRect(x: 50, y: 400, width: 1440, height: 850)
        let gridWin = NSWindow(
            contentRect: gridRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        gridWin.title = "Spheris 360 — Camera Grid"
        gridWin.minSize = NSSize(width: 720, height: 445)

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
        let stitchRect = NSRect(x: 50, y: 50, width: 1280, height: 640)
        let stitchWin = NSWindow(
            contentRect: stitchRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        stitchWin.title = "Spheris 360 — Live Stitch"
        stitchWin.minSize = NSSize(width: 640, height: 320)

        let stitchContainer = NSView(frame: stitchRect)
        let sv = StitchDisplayView(
            frame: NSRect(x: 0, y: 40, width: stitchRect.width, height: stitchRect.height - 40),
            metalDevice: device,
            remapTexture: remapTexture,
            cameraLabels: labelPositions
        )
        sv.autoresizingMask = [.width, .height]
        stitchContainer.addSubview(sv)

        let stitchControlBar = makePlaybackControlBar(width: stitchRect.width)
        stitchContainer.addSubview(stitchControlBar)

        stitchWin.contentView = stitchContainer
        self.stitchWindow = stitchWin
        self.stitchView = sv

        // ── Set up file providers ──
        let clipDir = projectDir.appendingPathComponent("Roll02_Clip09")
        let router = VideoInputRouter()
        router.setDisplayView(gv)
        router.setStitchView(sv)

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
        NSApp.activate(ignoringOtherApps: true)
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
        let labelPositions = computeStitchLabelPositions(calibration: calibration)
        stitchView?.updateCalibration(remapTexture: remapTexture, cameraLabels: labelPositions)
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
            }
        )
        panel.center()
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        self.pickerPanel = panel
    }

    // MARK: - Control bars

    /// Grid window control bar: play/pause + calibration picker + scrubber + time
    private func makeGridControlBar(width: CGFloat) -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 36))
        bar.autoresizingMask = [.width]

        // Calibration library button
        let calibBtn = NSButton(frame: NSRect(x: 4, y: 4, width: 340, height: 28))
        calibBtn.bezelStyle = .rounded
        calibBtn.title = currentProfile?.displayName ?? "No Calibration"
        calibBtn.alignment = .left
        calibBtn.lineBreakMode = .byTruncatingTail
        calibBtn.font = .systemFont(ofSize: 11)
        calibBtn.target = self
        calibBtn.action = #selector(openCalibrationLibrary)
        bar.addSubview(calibBtn)
        self.calibButton = calibBtn

        let playBtn = NSButton(frame: NSRect(x: 348, y: 4, width: 28, height: 28))
        playBtn.bezelStyle = .regularSquare
        playBtn.title = "⏸"
        playBtn.font = .systemFont(ofSize: 14)
        playBtn.target = self
        playBtn.action = #selector(togglePlayPause)
        bar.addSubview(playBtn)
        playPauseButtons.append(playBtn)

        let sliderX: CGFloat = 380
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

        let playBtn = NSButton(frame: NSRect(x: 88, y: 4, width: 28, height: 28))
        playBtn.bezelStyle = .regularSquare
        playBtn.title = "⏸"
        playBtn.font = .systemFont(ofSize: 14)
        playBtn.target = self
        playBtn.action = #selector(togglePlayPause)
        bar.addSubview(playBtn)
        playPauseButtons.append(playBtn)

        let slider = NSSlider(frame: NSRect(x: 120, y: 8, width: width - 214, height: 20))
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
        streamButton?.title = "Live"
    }

    private func stopStreaming() {
        rtmpStreamer?.stop()
        frameGrabber?.enabled = false
        streamButton?.title = "Stream"
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
