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

    // Scrubber controls (both windows)
    private var scrubbers: [NSSlider] = []
    private var playPauseButtons: [NSButton] = []
    private var timeLabels: [NSTextField] = []
    private var scrubberTimer: Timer?

    override public init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported")
        }

        // ── Load calibration ──
        let projectDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/spheris-smart-stitch")
        let calibURL = projectDir.appendingPathComponent("config/calibration.json")

        guard let calibration = try? CalibrationData.load(from: calibURL) else {
            fatalError("Failed to load calibration from \(calibURL.path)")
        }
        print("Loaded calibration: \(calibration.cameras.count) cameras, output \(calibration.outputWidth)x\(calibration.outputHeight)")

        // ── Generate remap LUT ──
        let remapGen = RemapGenerator(device: device)
        let remapTexture = remapGen.generate(
            calibration: calibration,
            gridSlotCameraIDs: gridSlotCameraIDs,
            outputWidth: calibration.outputWidth,
            outputHeight: calibration.outputHeight
        )

        // ── Compute camera label positions in equirectangular for stitch overlay ──
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

        // Grid view + scrubber in a stack
        let containerView = NSView(frame: gridRect)
        let gv = GridDisplayView(
            frame: NSRect(x: 0, y: 40, width: gridRect.width, height: gridRect.height - 40),
            metalDevice: device
        )
        gv.autoresizingMask = [.width, .height]
        containerView.addSubview(gv)

        let controlBar = makeControlBar(width: gridRect.width)
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

        // Stitch view + scrubber in a stack
        let stitchContainer = NSView(frame: stitchRect)
        let sv = StitchDisplayView(
            frame: NSRect(x: 0, y: 40, width: stitchRect.width, height: stitchRect.height - 40),
            metalDevice: device,
            remapTexture: remapTexture,
            cameraLabels: labelPositions
        )
        sv.autoresizingMask = [.width, .height]
        stitchContainer.addSubview(sv)

        let stitchControlBar = makeControlBar(width: stitchRect.width)
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

        gridWin.makeKeyAndOrderFront(nil)
        stitchWin.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Scrubber controls

    private func makeControlBar(width: CGFloat) -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 36))
        bar.autoresizingMask = [.width]

        let playBtn = NSButton(frame: NSRect(x: 4, y: 4, width: 28, height: 28))
        playBtn.bezelStyle = .regularSquare
        playBtn.title = "⏸"
        playBtn.font = .systemFont(ofSize: 14)
        playBtn.target = self
        playBtn.action = #selector(togglePlayPause)
        bar.addSubview(playBtn)
        playPauseButtons.append(playBtn)

        let slider = NSSlider(frame: NSRect(x: 36, y: 8, width: width - 130, height: 20))
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

    @objc private func togglePlayPause() {
        guard let router = router else { return }
        router.togglePause()
        let title = router.isPaused ? "▶" : "⏸"
        playPauseButtons.forEach { $0.title = title }
    }

    @objc private func scrubberChanged(_ sender: NSSlider) {
        guard let router = router else { return }
        router.seek(toFraction: sender.doubleValue)
        // Sync all scrubbers and buttons
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
        // For each camera, project its center direction to equirectangular UV
        var labels: [(String, Float, Float)] = []
        for (slotIndex, cameraID) in gridSlotCameraIDs.enumerated() {
            guard let cam = calibration.camera(forID: cameraID) else { continue }
            let R = cam.rotationMatrix
            // Camera forward direction (Z-axis) in world space
            let forward = R * SIMD3<Float>(0, 0, 1)
            // Sphere → equirectangular
            let lon = atan2(forward.x, forward.z)
            let lat = asin(min(1, max(-1, forward.y)))
            let u = (lon + .pi) / (2 * .pi)
            let v: Float
            if cam.group == "horizontal" {
                // Pin horizontal labels near the bottom of the frame
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
