import AppKit

/// Panel for configuring and controlling the RTMP stream.
@MainActor
public final class StreamSettingsPanel: NSPanel {
    private let settings: StreamSettings
    private var onStart: (() -> Void)?
    private var onStop: (() -> Void)?
    private var isStreamingGetter: (() -> Bool)?

    private var rtmpField: NSTextField!
    private var fpsSlider: NSSlider!
    private var fpsLabel: NSTextField!
    private var bitrateField: NSTextField!
    private var toggleButton: NSButton!
    private var statusLabel: NSTextField!

    public init(settings: StreamSettings,
                isStreaming: @escaping () -> Bool,
                onStart: @escaping () -> Void,
                onStop: @escaping () -> Void) {
        self.settings = settings
        self.onStart = onStart
        self.onStop = onStop
        self.isStreamingGetter = isStreaming

        let rect = NSRect(x: 0, y: 0, width: 480, height: 260)
        super.init(contentRect: rect,
                   styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = "Stream Settings"
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false

        let container = NSView(frame: rect)
        var y: CGFloat = 220

        // RTMP URL
        container.addSubview(makeLabel("RTMP URL:", x: 16, y: y))
        rtmpField = NSTextField(frame: NSRect(x: 120, y: y, width: 340, height: 22))
        rtmpField.stringValue = settings.rtmpURL
        rtmpField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        container.addSubview(rtmpField)
        y -= 34

        // FPS
        container.addSubview(makeLabel("Stream FPS:", x: 16, y: y))
        fpsSlider = NSSlider(frame: NSRect(x: 120, y: y, width: 220, height: 22))
        fpsSlider.minValue = 2
        fpsSlider.maxValue = 15
        fpsSlider.integerValue = settings.streamFPS
        fpsSlider.target = self
        fpsSlider.action = #selector(fpsChanged)
        container.addSubview(fpsSlider)
        fpsLabel = NSTextField(labelWithString: "\(settings.streamFPS) fps")
        fpsLabel.frame = NSRect(x: 350, y: y, width: 60, height: 22)
        container.addSubview(fpsLabel)
        y -= 34

        // Bitrate
        container.addSubview(makeLabel("Bitrate:", x: 16, y: y))
        bitrateField = NSTextField(frame: NSRect(x: 120, y: y, width: 100, height: 22))
        bitrateField.stringValue = settings.videoBitrate
        container.addSubview(bitrateField)
        y -= 34

        // Resolution (read-only display)
        container.addSubview(makeLabel("Resolution:", x: 16, y: y))
        let resLabel = NSTextField(labelWithString: "\(settings.streamWidth)x\(settings.streamHeight)")
        resLabel.frame = NSRect(x: 120, y: y, width: 200, height: 22)
        resLabel.textColor = .secondaryLabelColor
        container.addSubview(resLabel)
        y -= 44

        // Start/Stop button
        toggleButton = NSButton(frame: NSRect(x: 16, y: y, width: 120, height: 32))
        toggleButton.bezelStyle = .rounded
        toggleButton.target = self
        toggleButton.action = #selector(toggleStream)
        container.addSubview(toggleButton)

        // Status
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 146, y: y + 6, width: 320, height: 22)
        statusLabel.textColor = .secondaryLabelColor
        container.addSubview(statusLabel)

        contentView = container
        updateUI()
    }

    private func updateUI() {
        let streaming = isStreamingGetter?() ?? false
        toggleButton.title = streaming ? "Stop Streaming" : "Start Streaming"
        statusLabel.stringValue = streaming ? "Streaming to \(settings.rtmpURL)" : "Not streaming"
    }

    @objc private func fpsChanged() {
        let fps = fpsSlider.integerValue
        fpsLabel.stringValue = "\(fps) fps"
    }

    @objc private func toggleStream() {
        // Save current field values
        settings.rtmpURL = rtmpField.stringValue
        settings.streamFPS = fpsSlider.integerValue
        settings.videoBitrate = bitrateField.stringValue
        settings.save()

        let streaming = isStreamingGetter?() ?? false
        if streaming {
            onStop?()
        } else {
            onStart?()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.updateUI()
        }
    }

    private func makeLabel(_ text: String, x: CGFloat, y: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: x, y: y, width: 100, height: 22)
        label.alignment = .right
        return label
    }
}
