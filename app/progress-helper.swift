// osxeql-progress — the setup window shown during first-time install.
//
// launcher.sh pipes one command per line on stdin:
//   PHASE <text>      headline for the current step
//   DETAIL <text>     sub-line under the headline ("3.2 of 6.0 GB")
//   PROGRESS <0-100>  determinate progress
//   INDET             indeterminate (barber pole)
//   LOG <text>        append a line to the scrolling log
//   READY <text>      headline + chime + dock bounce (login screen is up)
//   DONE <text>       headline + bar full + chime
//   QUIT              close the window and exit
// stdin EOF with no DONE/QUIT = the setup script died; say so and stay open.
//
// --snapshot <dir> renders two canned states (mid-install, ready) to PNGs
// offscreen and exits — UI verification without Screen Recording permission.
//
// Compiled by packaging/build-app.sh into Contents/Resources/osxeql-progress.

import AppKit

final class ProgressUI: NSObject, NSWindowDelegate {
    let window: NSWindow
    let phase = NSTextField(labelWithString: "Starting setup")
    let detail = NSTextField(labelWithString: "")
    let bar = NSProgressIndicator()
    let logView = NSTextView()
    let closeButton = NSButton()
    private(set) var finished = false

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        super.init()
        window.title = "osxEQL Setup"
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self

        let content = window.contentView!
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        phase.font = .systemFont(ofSize: 16, weight: .semibold)
        phase.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        // Always determinate — the indeterminate→determinate mode switch has been
        // seen not to render the fill. Phases without measurable progress hide
        // the bar instead (INDET); PROGRESS unhides it.
        bar.minValue = 0; bar.maxValue = 100
        bar.isIndeterminate = false
        bar.isHidden = true
        bar.style = .bar

        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .secondaryLabelColor
        logView.backgroundColor = .textBackgroundColor
        let scroll = NSScrollView()
        scroll.documentView = logView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        closeButton.title = "Close"
        closeButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(closePressed)

        for v: NSView in [phase, detail, bar, scroll, closeButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        logView.autoresizingMask = [.width]
        logView.frame = NSRect(x: 0, y: 0, width: 440, height: 180)

        NSLayoutConstraint.activate([
            phase.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            phase.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            phase.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            detail.topAnchor.constraint(equalTo: phase.bottomAnchor, constant: 4),
            detail.leadingAnchor.constraint(equalTo: phase.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: phase.trailingAnchor),
            bar.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: phase.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: phase.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: phase.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: phase.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -14),
            closeButton.trailingAnchor.constraint(equalTo: phase.trailingAnchor),
            closeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
    }

    @objc func closePressed() { NSApp.terminate(nil) }
    func windowWillClose(_ n: Notification) { NSApp.terminate(nil) }

    func appendLog(_ line: String) {
        let ts = DateFormatter()
        ts.dateFormat = "HH:mm:ss"
        let text = "\(ts.string(from: Date()))  \(line)\n"
        logView.textStorage?.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        logView.scrollToEndOfDocument(nil)
    }

    func handle(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        switch cmd {
        case "PHASE":
            phase.stringValue = arg
            appendLog(arg)
        case "DETAIL":
            detail.stringValue = arg
        case "PROGRESS":
            if let v = Double(arg) {
                bar.isHidden = false
                bar.doubleValue = v
            }
        case "INDET":
            bar.isHidden = true
        case "LOG":
            appendLog(arg)
        case "READY":
            phase.stringValue = arg
            appendLog(arg)
            bar.isHidden = true
            NSSound(named: "Glass")?.play()
            NSApp.requestUserAttention(.criticalRequest)
            window.makeKeyAndOrderFront(nil)
        case "DONE":
            finished = true
            phase.stringValue = arg
            appendLog(arg)
            detail.stringValue = "You can close this window."
            bar.isHidden = false
            bar.doubleValue = 100
            NSSound(named: "Glass")?.play()
        case "FAIL":
            finished = true
            phase.stringValue = arg
            appendLog(arg)
            bar.isHidden = true
        case "QUIT":
            NSApp.terminate(nil)
        default: break
        }
    }

    func stdinClosed() {
        guard !finished else { return }
        phase.stringValue = "Setup stopped unexpectedly"
        detail.stringValue = "Log: ~/Library/Application Support/osxEQL/logs/app-launch.log"
        bar.isIndeterminate = false
        bar.doubleValue = 0
        appendLog("The setup process exited before finishing.")
    }

    func snapshot(to url: URL) {
        let view = window.contentView!
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

let app = NSApplication.shared
let snapshotMode = CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--snapshot"
if snapshotMode { app.appearance = NSAppearance(named: .aqua) }   // deterministic render
let ui = ProgressUI()

// --snapshot <dir>: render canned states to PNGs and exit (no window shown)
if snapshotMode {
    // Canned strings mirror what app/launcher.sh actually sends — keep in sync,
    // so the snapshots verify the UI users really see.
    let dir = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    for cmd in ["PHASE Setting up the Wine environment", "INDET",
                "LOG Installing Daybreak's launcher",
                "LOG Launcher updating itself",
                "PHASE Downloading EverQuest Legends", "DETAIL 3.2 of 6.0 GB",
                "PROGRESS 54"] {
        ui.handle(cmd)
    }
    ui.snapshot(to: dir.appendingPathComponent("progress-mid.png"))
    ui.handle("READY LaunchPad is ready — log in there")
    ui.handle("DETAIL You can close this window; it keeps tracking the install if you leave it open.")
    ui.snapshot(to: dir.appendingPathComponent("progress-ready.png"))
    ui.handle("DONE EverQuest Legends is installed — press PLAY in LaunchPad")
    ui.snapshot(to: dir.appendingPathComponent("progress-done.png"))
    exit(0)
}

app.setActivationPolicy(.regular)
let iconPath = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().appendingPathComponent("AppIcon.icns").path
if let icon = NSImage(contentsOfFile: iconPath) { app.applicationIconImage = icon }

// stdin reader — dispatch each line to the main thread
let stdinQueue = DispatchQueue(label: "stdin")
stdinQueue.async {
    while let line = readLine(strippingNewline: true) {
        let l = line
        DispatchQueue.main.async { ui.handle(l) }
    }
    DispatchQueue.main.async { ui.stdinClosed() }
}

ui.window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
