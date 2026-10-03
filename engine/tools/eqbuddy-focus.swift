// eqbuddy-focus — hide EQBuddy while EverQuest isn't the frontmost app, macOS side.
//
// EQBuddy's own "Hide when game unfocused" asks Windows (GetForegroundWindow) which
// window is in front. Under osxEQL the game lives in its own Wine virtual desktop
// (explorer /desktop=osxEQL) while EQBuddy (window mode) is a separate Mac window
// outside it, and EQBuddy never sees eqgame.exe as the foreground: the option
// either never fires or keeps the widget hidden. The truth is on the Mac side, where
// every Wine process is its own Mac app — so this helper watches which Mac app is
// frontmost and hides / unhides EQBuddy's app (NSRunningApplication.hide/unhide:
// no Accessibility permission needed).
//
// Shown when: the game isn't running, or the frontmost app is the game (eqgame.exe,
// or the osxEQL virtual-desktop explorer that hosts it) or EQBuddy itself.
// Hidden otherwise. Only un-hides what it hid. Exits when EQBuddy exits.
//
// Second job — alert SOUNDS (see "Alert sounds" below): EQBuddy's WPF MediaPlayer
// cannot play anything under osxEQL's Wine, so the sound is played here with afplay.
//
// Third job — close EQBuddy with the game (see "Auto-close" in update()).
//
// Usage: eqbuddy-focus --prefix <WINEPREFIX> [--autohide on|off] [--autoclose on|off]
// Started by engine/eqbuddy.sh next to EQBuddy. Built by packaging/build-app.sh into
// the .app, or on first use by the engine.
import AppKit

let cliArgs = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let i = cliArgs.firstIndex(of: name), i + 1 < cliArgs.count else { return nil }
    return cliArgs[i + 1]
}
let autohide = (option("--autohide") ?? "on") != "off"
let autoclose = (option("--autoclose") ?? "on") != "off"
let prefix = option("--prefix")

var cmdCache: [pid_t: String] = [:]

/// Lower-cased "localizedName + argv" of a process: Wine apps all run the same
/// loader binary, so the Windows exe name is only reliably in the arguments.
func ident(_ app: NSRunningApplication) -> String {
    let pid = app.processIdentifier
    if let c = cmdCache[pid] { return c }
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    var args = ""
    if sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 {
        var buf = [UInt8](repeating: 0, count: size)
        if sysctl(&mib, 3, &buf, &size, nil, 0) == 0 {
            args = String(decoding: buf[4..<size].map { $0 == 0 ? 32 : $0 }, as: UTF8.self)
        }
    }
    let s = ((app.localizedName ?? "") + " " + args).lowercased()
    cmdCache[pid] = s
    return s
}

func running(_ needle: String, in apps: [NSRunningApplication]? = nil) -> [NSRunningApplication] {
    (apps ?? NSWorkspace.shared.runningApplications).filter { ident($0).contains(needle) }
}

func isGameSide(_ s: String) -> Bool {
    s.contains("eqgame.exe") || s.contains("eqbuddy.exe") || s.contains("/desktop=osxeql")
}

/// One line per decision, to logs/eqbuddy.log (stdout is redirected there).
func note(_ s: String) {
    let t = ISO8601DateFormatter().string(from: Date())
    print("eqbuddy-focus \(t) \(s)")
    fflush(stdout)
}

var hiddenByUs = Set<pid_t>()
var lastState = ""
var sawBuddy = false
let started = Date()
var sawGame = false
var gameGoneSince: Date? = nil
var quitAskedAt: Date? = nil
/// How long the game must stay gone before EQBuddy is closed: covers a quick
/// relaunch from LaunchPad (and the gap while eqgame restarts) without closing it.
let closeGrace: TimeInterval = 20

func update(front: NSRunningApplication?) {
    let apps = NSWorkspace.shared.runningApplications
    let buddies = running("eqbuddy.exe", in: apps)
    if buddies.isEmpty {
        // Give EQBuddy time to start; after that, no EQBuddy = nothing left to do.
        if sawBuddy || Date().timeIntervalSince(started) > 120 {
            note("EQBuddy not running — exiting")
            exit(0)
        }
        return
    }
    sawBuddy = true
    let gameUp = !running("eqgame.exe", in: apps).isEmpty
    let frontIdent = (front ?? NSWorkspace.shared.frontmostApplication).map(ident) ?? ""
    let show = !gameUp || isGameSide(frontIdent)
    let state = "front=[\(frontIdent.prefix(160))] game=\(gameUp) buddies=\(buddies.map { $0.processIdentifier }) -> \(show ? "show" : "hide")"
    if state != lastState { note(state); lastState = state }

    // ---- Auto-close: the game was running and is gone for closeGrace -> quit EQBuddy.
    // Only once the game has been seen in THIS session, so an EQBuddy opened on its
    // own (no game) is never closed. Graceful first: terminate() is a normal macOS
    // "Quit", which Wine's Mac driver turns into a Windows end-of-session, so EQBuddy
    // shuts down cleanly and saves its settings. Forced only if it ignores that for
    // 30 s. The helper then exits on its own (no EQBuddy left).
    // No polling tick: the deadlines below re-run update() themselves (wakeAfter).
    if gameUp {
        sawGame = true; gameGoneSince = nil; quitAskedAt = nil
    } else if autoclose && sawGame {
        let gone = gameGoneSince ?? Date()
        if gameGoneSince == nil { wakeAfter(closeGrace + 0.5) }
        gameGoneSince = gone
        if Date().timeIntervalSince(gone) >= closeGrace {
            if let asked = quitAskedAt {
                if Date().timeIntervalSince(asked) > 30 {
                    note("EQBuddy ignored Quit for 30 s — forcing it closed")
                    buddies.forEach { _ = $0.forceTerminate() }
                    quitAskedAt = Date()   // don't spam; its termination wakes us
                    wakeAfter(31)
                }
            } else {
                wakeAfter(30.5)            // check whether the Quit was honoured
                note("game closed \(Int(closeGrace)) s ago — quitting EQBuddy")
                // Un-hide first: a hidden Wine app may not process the quit request.
                buddies.forEach { if hiddenByUs.contains($0.processIdentifier) { $0.unhide() }; _ = $0.terminate() }
                hiddenByUs.removeAll()
                quitAskedAt = Date()
            }
            return
        }
    }

    guard autohide else { return }
    for b in buddies {
        let pid = b.processIdentifier
        if show {
            if hiddenByUs.contains(pid) { b.unhide(); hiddenByUs.remove(pid) }
        } else if !b.isHidden {
            if b.hide() { hiddenByUs.insert(pid) } else { note("hide() refused for pid \(pid)") }
        }
    }
}

/// One-shot re-check at a deadline (startup grace, auto-close timers) — replaces the
/// old 2 s polling tick, so nothing runs while nothing happens.
func wakeAfter(_ seconds: TimeInterval) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { autoreleasepool { update(front: nil) } }
}

let nc = NSWorkspace.shared.notificationCenter
// Event-driven only: app launched (the game starting), activated (focus), terminated.
nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { _ in
    autoreleasepool { update(front: nil) }
}
nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
    autoreleasepool { update(front: n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication) }
}
nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
    autoreleasepool {
        if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            cmdCache[a.processIdentifier] = nil
            hiddenByUs.remove(a.processIdentifier)
        }
        update(front: nil)
    }
}
// ---- Alert sounds -----------------------------------------------------------------
// EQBuddy plays alerts through WPF's MediaPlayer -> Wine's wmp -> DirectShow. Wine's
// WAV parser lives in winegstreamer, and osxEQL's Wine is built without GStreamer, so
// every play fails: "Alert sound could not be played: 0x80040218"
// (VFW_E_CANNOT_RENDER) lands in EQBuddy's error.log. That line IS the "an alert
// wanted a sound now" signal, so we tail error.log and play it on the Mac with
// afplay — as EQBuddy 1.x's native Mac build did (same clip mapping, MIT).
//
// Which sound: the log line doesn't say. We use the sound all enabled sound-rules
// share if they share one, else the shared "Alert sound" (AlertSound) setting.
// Volume: AlertVolume. "Off" plays nothing.
let macClips = ["Ding": "Ping", "Notify": "Glass", "Chimes": "Blow", "Chord": "Pop",
                "Tada": "Hero", "Exclamation": "Sosumi", "Alarm": "Submarine",
                // EQBuddy's legacy SystemSounds names (AlertSoundCatalog.Normalize)
                "Asterisk": "Ping", "Beep": "Pop", "Hand": "Blow", "Question": "Glass"]

var cachedDirs: [URL] = []
var cachedDirsAt = Date.distantPast
/// Re-listed at most every 10 s: the profile folder appears once, on EQBuddy's first run.
/// (With the 30 s re-arm and event-driven reads, this is now rarely hit at all.)
func profileDirs() -> [URL] {
    if Date().timeIntervalSince(cachedDirsAt) < 10 { return cachedDirs }
    cachedDirs = listProfileDirs()
    cachedDirsAt = Date()
    return cachedDirs
}

func listProfileDirs() -> [URL] {
    guard let prefix else { return [] }
    let users = URL(fileURLWithPath: prefix).appendingPathComponent("drive_c/users")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []
    return names.map { users.appendingPathComponent($0).appendingPathComponent("AppData/Roaming/EQBuddy Evolved") }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
}

func macClip(_ name: String) -> String? {
    let clip = macClips[name] ?? "Ping"
    for dir in [NSHomeDirectory() + "/Library/Sounds", "/Library/Sounds", "/System/Library/Sounds"] {
        let p = "\(dir)/\(clip).aiff"
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    return nil
}

/// A sound choice (built-in name, "Off", or a Windows path to the player's own file)
/// -> a Mac file afplay can play, or nil for silence.
func resolveSound(_ raw: String) -> String? {
    let choice = raw.trimmingCharacters(in: .whitespaces)
    if choice.caseInsensitiveCompare("Off") == .orderedSame { return nil }
    if choice.isEmpty || macClips[choice] != nil { return macClip(choice.isEmpty ? "Ding" : choice) }
    // Custom file: C:\... inside the prefix.
    if let prefix, choice.count > 3, Array(choice)[1] == ":" {
        let rel = String(choice.dropFirst(3)).replacingOccurrences(of: "\\", with: "/")
        let p = prefix + "/drive_c/" + rel
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    return macClip("Ding")
}

func soundToPlay(settings: URL) -> (String, Double)? {
    guard let data = try? Data(contentsOf: settings),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return macClip("Ding").map { ($0, 1.0) }
    }
    let shared = json["AlertSound"] as? String ?? "Ding"
    let volume = min(max((json["AlertVolume"] as? Double) ?? 1.0, 0), 1)
    var chosen = Set<String>()
    for rule in json["TrackedRules"] as? [[String: Any]] ?? [] {
        guard rule["Enabled"] as? Bool ?? true, rule["AlertSound"] as? Bool ?? false else { continue }
        let own = rule["AlertSoundName"] as? String ?? ""
        chosen.insert(own.isEmpty ? shared : own)
    }
    let pick = chosen.count == 1 ? chosen.first! : shared
    return resolveSound(pick).map { ($0, volume) }
}

var logOffsets: [String: UInt64] = [:]
var lastPlay = Date.distantPast

func pollErrorLogs() {
    for dir in profileDirs() {
        let log = dir.appendingPathComponent("error.log").path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: log),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            if logOffsets[log] == nil { logOffsets[log] = 0 }   // not created yet: read it all once it is
            continue
        }
        guard let from = logOffsets[log] else { logOffsets[log] = size; continue }  // start at the end
        if size < from { logOffsets[log] = size; continue }                          // truncated/rotated
        if size == from { continue }
        guard let fh = FileHandle(forReadingAtPath: log) else { continue }
        fh.seek(toFileOffset: from)
        let chunk = String(decoding: fh.readData(ofLength: Int(size - from)), as: UTF8.self)
        fh.closeFile()
        logOffsets[log] = size
        guard chunk.contains("Alert sound could not be played")
                || chunk.contains("No alert sound could be played") else { continue }
        // EQBuddy already coalesces bursts; keep one sound per half second anyway.
        guard Date().timeIntervalSince(lastPlay) > 0.5,
              let sound = soundToPlay(settings: dir.appendingPathComponent("settings.json")) else { continue }
        let (file, volume) = sound
        lastPlay = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = ["-v", String(format: "%.3f", volume), file]
        do { try p.run() } catch { note("afplay failed: \(error)") }
        note("alert sound -> \((file as NSString).lastPathComponent) @ \(volume)")
    }
}
// ---- Memory ---------------------------------------------------------------------
// Every callback runs inside autoreleasepool {}. This is a plain command-line tool
// (no NSApplication), and RunLoop.main.run() does NOT drain an autorelease pool per
// iteration the way AppKit's event loop does: the Foundation objects each tick
// creates (runningApplications arrays, file attribute dictionaries, …) could pile up
// unfreed, 5 polls a second for hours — the prime suspect for the Mac slowing to a
// freeze after long sessions (reported 2026-09-30).
//
// Hourly, the helper logs the memory footprint of itself, EQBuddy and the game, so a
// growing process shows up in logs/eqbuddy.log instead of being guessed at.
func footprintMB(_ pid: pid_t) -> Int {
    var info = rusage_info_v2()
    let r = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
    }
    return r == 0 ? Int(info.ri_phys_footprint / 1_048_576) : -1
}

func logMemory() {
    let apps = NSWorkspace.shared.runningApplications
    var parts = ["helper \(footprintMB(getpid())) MB"]
    for (label, needle) in [("EQBuddy", "eqbuddy.exe"), ("eqgame", "eqgame.exe")] {
        for a in running(needle, in: apps) { parts.append("\(label) \(footprintMB(a.processIdentifier)) MB") }
    }
    note("memory: " + parts.joined(separator: ", "))
}

// ---- Watching error.log without polling ------------------------------------------
// A kqueue vnode source per error.log (DispatchSource): the kernel wakes us only when
// EQBuddy writes to it — i.e. only when an alert actually wants a sound. A file that
// doesn't exist yet (first run), or was rotated/deleted, is (re)armed by a slow 30 s
// check that only stats a couple of paths. Replaces the 0.5 s poll + 2 s tick that
// were suspected of game micro-stutters (user report, 2026-10).
var watchers: [String: DispatchSourceFileSystemObject] = [:]

func armWatchers() {
    for dir in profileDirs() {
        let log = dir.appendingPathComponent("error.log").path
        if watchers[log] != nil { continue }
        let fd = open(log, O_EVTONLY)
        guard fd >= 0 else {
            if logOffsets[log] == nil { logOffsets[log] = 0 }  // not created yet: read it all once it is
            continue
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                            eventMask: [.write, .extend, .delete, .rename],
                                                            queue: .main)
        src.setEventHandler {
            autoreleasepool {
                if !src.data.isDisjoint(with: [.delete, .rename]) {
                    src.cancel(); watchers[log] = nil   // re-armed by the next armWatchers()
                }
                pollErrorLogs()
            }
        }
        src.setCancelHandler { close(fd) }
        watchers[log] = src
        src.resume()
    }
}

autoreleasepool { pollErrorLogs(); armWatchers() }   // sets the start offsets, then watches
Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in autoreleasepool { armWatchers(); pollErrorLogs() } }

wakeAfter(121)   // EQBuddy never showed up within the startup grace -> exit
Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in autoreleasepool { logMemory() } }
Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { _ in autoreleasepool { logMemory() } }
note("started (pid \(getpid()), autohide \(autohide ? "on" : "off"), autoclose \(autoclose ? "on" : "off"), prefix \(prefix ?? "-"))")
autoreleasepool { update(front: nil) }
RunLoop.main.run()
