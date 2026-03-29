import AppKit

/// Panel that runs calibrate.py and streams its output in real time.
@MainActor
public final class CalibrateRunnerPanel: NSPanel {
    private let projectDir: URL
    private let clipDir: URL
    private let frameNumber: Int
    private let quality: String
    private let onComplete: (URL?) -> Void

    private var logView: NSTextView!
    private var goButton: NSButton!
    private var frameField: NSTextField!
    private var qualityPicker: NSPopUpButton!
    private var process: Process?
    private var outputURL: URL?

    public init(projectDir: URL, clipDir: URL, frameNumber: Int,
                onComplete: @escaping (URL?) -> Void) {
        self.projectDir = projectDir
        self.clipDir = clipDir
        self.frameNumber = frameNumber
        self.quality = "fast"
        self.onComplete = onComplete

        let w: CGFloat = 620
        let h: CGFloat = 520
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let x = screen.origin.x + (screen.width - w) / 2
        let y = screen.origin.y + (screen.height - h) / 2

        super.init(
            contentRect: NSRect(x: x, y: y, width: w, height: h),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        self.title = "New Calibration"
        self.isFloatingPanel = true
        buildUI(width: w, height: h)
    }

    private func buildUI(width: CGFloat, height: CGFloat) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        var y = height - 30

        // Clip info
        let clipInfo = NSTextField(labelWithString: "Clip: \(clipDir.lastPathComponent)")
        clipInfo.frame = NSRect(x: 16, y: y - 20, width: width - 32, height: 20)
        clipInfo.font = .systemFont(ofSize: 13, weight: .medium)
        clipInfo.textColor = .white
        container.addSubview(clipInfo)
        y -= 36

        // Frame number
        let frameLabel = NSTextField(labelWithString: "Frame:")
        frameLabel.frame = NSRect(x: 16, y: y - 20, width: 50, height: 20)
        frameLabel.font = .systemFont(ofSize: 12)
        frameLabel.textColor = .secondaryLabelColor
        container.addSubview(frameLabel)

        let ff = NSTextField(frame: NSRect(x: 70, y: y - 22, width: 80, height: 24))
        ff.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        ff.integerValue = frameNumber
        ff.alignment = .center
        container.addSubview(ff)
        self.frameField = ff

        // Quality picker
        let qualLabel = NSTextField(labelWithString: "Quality:")
        qualLabel.frame = NSRect(x: 170, y: y - 20, width: 55, height: 20)
        qualLabel.font = .systemFont(ofSize: 12)
        qualLabel.textColor = .secondaryLabelColor
        container.addSubview(qualLabel)

        let qp = NSPopUpButton(frame: NSRect(x: 230, y: y - 24, width: 120, height: 28))
        qp.addItems(withTitles: ["fast (~1s)", "full (~30s)"])
        qp.selectItem(at: 0)
        container.addSubview(qp)
        self.qualityPicker = qp

        // Run button
        let runBtn = NSButton(frame: NSRect(x: width - 110, y: y - 26, width: 90, height: 32))
        runBtn.bezelStyle = .rounded
        runBtn.title = "Calibrate"
        runBtn.font = .boldSystemFont(ofSize: 13)
        runBtn.target = self
        runBtn.action = #selector(runCalibration)
        runBtn.keyEquivalent = "\r"
        container.addSubview(runBtn)
        self.goButton = runBtn

        y -= 42

        // Log output (scrollable text view)
        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 16, width: width - 32, height: y - 24))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let tv = NSTextView(frame: scrollView.contentView.bounds)
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.backgroundColor = NSColor(white: 0.08, alpha: 1)
        tv.textColor = NSColor(white: 0.7, alpha: 1)
        tv.autoresizingMask = [.width, .height]
        tv.textContainerInset = NSSize(width: 4, height: 4)
        scrollView.documentView = tv
        container.addSubview(scrollView)
        self.logView = tv

        appendLog("Ready to calibrate.\n")
        appendLog("  Clip: \(clipDir.lastPathComponent)\n")
        appendLog("  Adjust frame number and quality, then click Calibrate.\n")

        contentView = container
    }

    private func appendLog(_ text: String) {
        logView.textStorage?.append(NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor(white: 0.75, alpha: 1),
            ]
        ))
        logView.scrollToEndOfDocument(nil)
    }

    private func appendLogHighlight(_ text: String) {
        logView.textStorage?.append(NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor(red: 0.82, green: 0.63, blue: 0.42, alpha: 1),
            ]
        ))
        logView.scrollToEndOfDocument(nil)
    }

    @objc private func runCalibration() {
        goButton.isEnabled = false
        goButton.title = "Running..."

        let frame = frameField.integerValue
        let quality = qualityPicker.indexOfSelectedItem == 0 ? "fast" : "full"
        let scriptPath = projectDir.appendingPathComponent("tools/calibrate.py").path
        let libraryDir = projectDir.appendingPathComponent("config/library").path

        appendLog("\n── Starting calibration ──\n")
        appendLog("  Frame: \(frame)  Quality: \(quality)\n\n")

        let venvPython = projectDir.appendingPathComponent("tools/.venv/bin/python3").path
        let pythonPath = FileManager.default.fileExists(atPath: venvPython) ? venvPython : "/usr/bin/env"
        let pythonArgs = pythonPath == venvPython ? ["-u"] : ["python3", "-u"]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = pythonArgs + [
            scriptPath,
            "--input", clipDir.path,
            "--frame", String(frame),
            "--quality", quality,
            "--library-dir", libraryDir,
            "--no-preview",
        ]
        proc.currentDirectoryURL = projectDir

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Read output on background threads to avoid pipe buffer deadlocks
        func streamPipe(_ pipe: Pipe, panel: CalibrateRunnerPanel) {
            let fh = pipe.fileHandleForReading
            DispatchQueue.global(qos: .userInitiated).async {
                while true {
                    let data = fh.availableData
                    if data.isEmpty { break }  // EOF
                    if let text = String(data: data, encoding: .utf8) {
                        DispatchQueue.main.async { [weak panel] in
                            panel?.appendLog(text)
                        }
                    }
                }
            }
        }
        streamPipe(outPipe, panel: self)
        streamPipe(errPipe, panel: self)

        proc.terminationHandler = { [weak self] proc in
            // Small delay to let final pipe reads flush
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let self = self else { return }

                if proc.terminationStatus == 0 {
                    self.appendLogHighlight("\n── Calibration complete! ──\n")
                    // Find the newest JSON in the library
                    let libDir = self.projectDir.appendingPathComponent("config/library")
                    if let files = try? FileManager.default.contentsOfDirectory(
                        at: libDir, includingPropertiesForKeys: [.creationDateKey]
                    ) {
                        let newest = files
                            .filter { $0.pathExtension == "json" }
                            .sorted {
                                let d1 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                                let d2 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                                return d1 > d2
                            }
                            .first
                        self.outputURL = newest
                        if let url = newest {
                            self.appendLogHighlight("  Output: \(url.lastPathComponent)\n")
                        }
                    }
                    self.goButton.title = "Done"
                    // Auto-close and return result after a brief pause
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.onComplete(self.outputURL)
                        self.close()
                    }
                } else {
                    self.appendLogHighlight("\n── Calibration failed (exit \(proc.terminationStatus)) ──\n")
                    self.goButton.title = "Retry"
                    self.goButton.isEnabled = true
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
        } catch {
            appendLogHighlight("Failed to start: \(error.localizedDescription)\n")
            goButton.title = "Retry"
            goButton.isEnabled = true
        }
    }
}
