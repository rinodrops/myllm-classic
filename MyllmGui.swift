import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Binary Discovery

private func findBinary(name: String, envKey: String) -> String? {
    let env = ProcessInfo.processInfo.environment
    if let path = env[envKey], !path.isEmpty,
       FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    // App bundle: check Contents/Resources/bin/ first
    let execDir = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent().path
    let bundleBin = URL(fileURLWithPath: execDir)
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/bin/\(name)")
        .path
    if FileManager.default.isExecutableFile(atPath: bundleBin) { return bundleBin }
    for dir in ["/opt/homebrew/bin", "/usr/local/bin",
                "\(NSHomeDirectory())/.local/bin", "/usr/bin"]
    {
        let path = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return nil
}

private func findMyllmScript() -> String? {
    let execDir = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent().path
    // App bundle: binary lives in Contents/MacOS/, resources in Contents/Resources/bin/
    let bundleResources = URL(fileURLWithPath: execDir)
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/bin")
        .path
    for candidate in ["\(bundleResources)/myllm",
                      "\(execDir)/myllm",
                      "\(NSHomeDirectory())/.local/bin/myllm",
                      "/usr/local/bin/myllm"]
    {
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}

// MARK: - First-Launch Config Bootstrap

/// If no user config exists, copy the starter template from the app bundle.
/// Returns true if a new config was created.
@discardableResult
private func bootstrapConfigIfNeeded() -> Bool {
    let fm = FileManager.default
    let configPath = ProcessInfo.processInfo.environment["CONFIG_FILE"]
        ?? "\(NSHomeDirectory())/.config/myllm/config.toml"
    guard !fm.fileExists(atPath: configPath) else { return false }

    // Find the bundled template: Contents/Resources/config.toml
    let execDir = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent().path
    let templatePath = URL(fileURLWithPath: execDir)
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/config.toml")
        .path
    guard fm.fileExists(atPath: templatePath) else { return false }

    let configDir = (configPath as NSString).deletingLastPathComponent
    try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
    guard (try? fm.copyItem(atPath: templatePath, toPath: configPath)) != nil else { return false }

    let alert = NSAlert()
    alert.messageText = "Configuration Created"
    alert.informativeText = "A starter config was created at:\n\(configPath)\n\nEdit it to configure your models and tasks."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    alert.runModal()
    return true
}

// MARK: - Accessibility Permission

/// Request Accessibility permission so My LLM can send Cmd+C to capture selected text.
/// - First call `AXIsProcessTrustedWithOptions(prompt: true)` — triggers the OS dialog
///   when the app is not yet in TCC (fresh install or after `tccutil reset`).
/// - If already in TCC as "disabled" (e.g., after a dev rebuild), the OS dialog is
///   suppressed by the system; show our own NSAlert with a direct link to System Settings.
private func requestAccessibilityIfNeeded() {
    // Ask the OS to prompt. Returns true immediately if already trusted.
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(opts)
    guard !trusted else { return }

    // Still not trusted after the prompt call — app is likely in TCC as "disabled".
    // Give the OS dialog 0.5 s to appear; if it does, great. If not, show our own alert.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        guard !AXIsProcessTrusted() else { return }   // granted in the meantime

        let alert = NSAlert()
        alert.messageText = "Enable Accessibility for My LLM"
        alert.informativeText = """
            My LLM uses Accessibility to copy your selected text when you trigger a task. \
            Without it, only clipboard contents are used.

            Please enable My LLM in:
            System Settings › Privacy & Security › Accessibility
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
        }
    }
}

// MARK: - Config Reader

private struct TaskInfo {
    let id: String
    let displayName: String
    let hotkey: String?
    let autoCopy: Bool?   // nil = inherit from [general] auto_copy
}

// Extract the value from a TOML assignment RHS, stripping inline comments and quotes.
// Handles: quoted strings ("value") and unquoted values (true, false, 5m, …)
private func configValue(from rhs: String) -> String {
    let t = rhs.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("\"") {
        // Quoted: extract content between the first pair of double quotes
        let inner = t.dropFirst()
        if let closeIdx = inner.firstIndex(of: "\"") {
            return String(inner[inner.startIndex..<closeIdx])
        }
    }
    // Unquoted: strip inline comment (space + # signals comment start)
    let noComment = t.components(separatedBy: " #").first ?? t
    return noComment.trimmingCharacters(in: .whitespaces)
}

private func readTasks() -> [TaskInfo] {
    let configPath = ProcessInfo.processInfo.environment["CONFIG_FILE"]
        ?? "\(NSHomeDirectory())/.config/myllm/config.toml"
    guard let raw = try? String(contentsOfFile: configPath, encoding: .utf8) else { return [] }

    var tasks: [TaskInfo] = []
    var currentId: String?
    var currentName: String?
    var currentHotkey: String?
    var currentAutoCopy: Bool?
    var inMultiline = false

    for line in raw.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)

        // Track multiline literal strings (''') via parity of occurrences
        let tqCount = t.components(separatedBy: "'''").count - 1
        if tqCount % 2 == 1 { inMultiline.toggle() }
        // Skip lines that are inside a multiline block, or that start/close one
        if inMultiline || (tqCount % 2 == 1 && !inMultiline) { continue }

        if t.hasPrefix("[") {
            // Save previous task before moving to next section
            if let id = currentId {
                tasks.append(TaskInfo(id: id, displayName: currentName ?? id,
                                      hotkey: currentHotkey, autoCopy: currentAutoCopy))
                currentId = nil
                currentName = nil
                currentHotkey = nil
                currentAutoCopy = nil
            }
            // Match [tasks.xxx] direct children only (not [tasks.xxx.yyy])
            if t.hasPrefix("[tasks."), t.hasSuffix("]") {
                let inner = String(t.dropFirst(7).dropLast())
                if !inner.contains(".") { currentId = inner }
            }
        } else if currentId != nil {
            let parts = t.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let val = configValue(from: String(parts[1]))
                if key == "name"       { currentName   = val.isEmpty ? nil : val }
                if key == "hotkey"     { currentHotkey = val.isEmpty ? nil : val }
                if key == "auto_copy" {
                    if val == "true"  { currentAutoCopy = true }
                    if val == "false" { currentAutoCopy = false }
                }
            }
        }
    }
    if let id = currentId {
        tasks.append(TaskInfo(id: id, displayName: currentName ?? id,
                              hotkey: currentHotkey, autoCopy: currentAutoCopy))
    }
    return tasks
}

private func readTranslationHotkey() -> String? {
    let configPath = ProcessInfo.processInfo.environment["CONFIG_FILE"]
        ?? "\(NSHomeDirectory())/.config/myllm/config.toml"
    guard let raw = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
    var inTranslation = false
    var inMultiline = false
    for line in raw.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        let tqCount = t.components(separatedBy: "'''").count - 1
        if tqCount % 2 == 1 { inMultiline.toggle() }
        if inMultiline || (tqCount % 2 == 1 && !inMultiline) { continue }
        if t.hasPrefix("[") {
            inTranslation = (t == "[translation]")
        } else if inTranslation, t.hasPrefix("hotkey") {
            let parts = t.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let val = configValue(from: String(parts[1]))
                if !val.isEmpty { return val }
            }
        }
    }
    return nil
}

// Read [general] auto_copy. Returns nil if key absent (caller should default to true).
private func readGeneralAutoCopy() -> Bool? {
    let configPath = ProcessInfo.processInfo.environment["CONFIG_FILE"]
        ?? "\(NSHomeDirectory())/.config/myllm/config.toml"
    guard let raw = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
    var inGeneral = false
    for line in raw.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[") {
            inGeneral = (t == "[general]")
        } else if inGeneral {
            let parts = t.split(separator: "=", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces) == "auto_copy" {
                let val = configValue(from: String(parts[1]))
                if val == "true"  { return true }
                if val == "false" { return false }
            }
        }
    }
    return nil
}

// Read [general] appearance. Returns "dark" (default), "light", or "system".
private func readGeneralAppearance() -> String {
    let configPath = ProcessInfo.processInfo.environment["CONFIG_FILE"]
        ?? "\(NSHomeDirectory())/.config/myllm/config.toml"
    guard let raw = try? String(contentsOfFile: configPath, encoding: .utf8) else { return "dark" }
    var inGeneral = false
    for line in raw.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[") {
            inGeneral = (t == "[general]")
        } else if inGeneral {
            let parts = t.split(separator: "=", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces) == "appearance" {
                let val = configValue(from: String(parts[1]))
                if val == "light" || val == "system" { return val }
                return "dark"
            }
        }
    }
    return "dark"
}

// Read [translation] auto_copy. Returns nil if key absent.
private func readTranslationAutoCopy() -> Bool? {
    let configPath = ProcessInfo.processInfo.environment["CONFIG_FILE"]
        ?? "\(NSHomeDirectory())/.config/myllm/config.toml"
    guard let raw = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
    var inTranslation = false
    var inMultiline = false
    for line in raw.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        let tqCount = t.components(separatedBy: "'''").count - 1
        if tqCount % 2 == 1 { inMultiline.toggle() }
        if inMultiline || (tqCount % 2 == 1 && !inMultiline) { continue }
        if t.hasPrefix("[") {
            inTranslation = (t == "[translation]")
        } else if inTranslation {
            let parts = t.split(separator: "=", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces) == "auto_copy" {
                let val = configValue(from: String(parts[1]))
                if val == "true"  { return true }
                if val == "false" { return false }
            }
        }
    }
    return nil
}

// Resolve effective auto_copy: section-level override → [general] auto_copy → true.
private func resolveAutoCopy(sectionLevel: Bool?) -> Bool {
    if let v = sectionLevel { return v }
    if let v = readGeneralAutoCopy() { return v }
    return true
}

// Parse "cmd+shift+b" → (virtualKeyCode, carbonModifiers). Returns nil if invalid.
private func parseHotkey(_ s: String) -> (keyCode: UInt32, modifiers: UInt32)? {
    // ANSI virtual key codes (kVK_ANSI_*)
    let keyCodeMap: [Character: UInt32] = [
        "a": 0,  "s": 1,  "d": 2,  "f": 3,  "h": 4,  "g": 5,
        "z": 6,  "x": 7,  "c": 8,  "v": 9,  "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "u": 32, "i": 34, "o": 31, "p": 35,
        "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]
    let parts = s.lowercased().split(separator: "+").map(String.init)
    guard let keyStr = parts.last, keyStr.count == 1,
          let keyChar = keyStr.first, let keyCode = keyCodeMap[keyChar] else { return nil }
    var mods: UInt32 = 0
    for mod in parts.dropLast() {
        switch mod {
        case "cmd":             mods |= UInt32(1) << 8   // cmdKey     = 256
        case "shift":           mods |= UInt32(1) << 9   // shiftKey   = 512
        case "opt", "option":   mods |= UInt32(1) << 11  // optionKey  = 2048
        case "ctrl", "control": mods |= UInt32(1) << 12  // controlKey = 4096
        default: break
        }
    }
    return mods != 0 ? (keyCode, mods) : nil
}

// Parse "cmd+shift+b" → (key: "b", mask: .command | .shift) for NSMenuItem display.
private func menuKeyEquivalent(from hotkey: String) -> (key: String, mask: NSEvent.ModifierFlags) {
    let parts = hotkey.lowercased().split(separator: "+").map(String.init)
    var mask: NSEvent.ModifierFlags = []
    for mod in parts.dropLast() {
        switch mod {
        case "cmd":             mask.insert(.command)
        case "shift":           mask.insert(.shift)
        case "opt", "option":   mask.insert(.option)
        case "ctrl", "control": mask.insert(.control)
        default: break
        }
    }
    return (parts.last ?? "", mask)
}

// MARK: - Carbon Hotkey Callback

// File-level constant: @convention(c) closure that routes to AppDelegate via userData.
private let carbonHotkeyDispatch: EventHandlerUPP = { _, event, userData in
    guard let event = event else { return OSStatus(eventNotHandledErr) }
    var hotkeyID = EventHotKeyID()
    guard GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
    ) == noErr else { return OSStatus(eventNotHandledErr) }
    if let ptr = userData {
        Unmanaged<AppDelegate>.fromOpaque(ptr).takeUnretainedValue()
            .handleHotKey(id: hotkeyID.id)
    }
    return noErr
}

// MARK: - LLM Processor

final class LLMProcessor: ObservableObject {
    @Published var output = ""
    @Published var isDone = false
    @Published var errorMessage: String?

    private var process: Process?
    private var completed = false
    private var onDone: ((String) -> Void)?
    private var stderrBuffer = ""

    func start(task: String, input: String, onDone: @escaping (String) -> Void) {
        self.onDone = onDone

        guard let scriptPath = findMyllmScript() else {
            return fail(
                "myllm script not found.\n"
                + "Install via:\n"
                + "  bash -c \"$(curl -fsSL https://raw.githubusercontent.com/rinodrops/myllm-cli/main/install.sh)\""
            )
        }

        let jq = findBinary(name: "jq", envKey: "JQ") ?? "jq"
        let whichlang = findBinary(name: "whichlang-cli", envKey: "WHICHLANG") ?? ""
        let config = ProcessInfo.processInfo.environment["CONFIG_FILE"]
            ?? "\(NSHomeDirectory())/.config/myllm/config.toml"

        // Single-quote the script path, escaping any embedded single quotes
        let safePath = scriptPath.replacingOccurrences(of: "'", with: "'\\''")

        // translate uses its own routing path (language detection, different prompts)
        let bashCmd: String
        if task == "translate" {
            bashCmd = "source '\(safePath)' && translate \"$MYLLM_INPUT\" \"\" \"\""
        } else {
            bashCmd = "source '\(safePath)' && myllm_process \"$MYLLM_TASK\" \"$MYLLM_INPUT\""
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", bashCmd]
        proc.environment = [
            "HOME":         NSHomeDirectory(),
            "PATH":         "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin",
            "TERM":         "dumb",
            "LANG":         "en_US.UTF-8",
            "LC_ALL":       "en_US.UTF-8",
            "JQ":           jq,
            "WHICHLANG":    whichlang,
            "CONFIG_FILE":  config,
            "MYLLM_TASK":   task,
            "MYLLM_INPUT":  input,
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty {
                outPipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async { self?.finish() }
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async { self?.output += text }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty {
                errPipe.fileHandleForReading.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                self?.stderrBuffer += text
            }
        }

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.finish() }
        }

        process = proc
        do {
            try proc.run()
        } catch {
            fail("Failed to launch bash: \(error.localizedDescription)")
        }
    }

    func cancel() { process?.terminate() }

    private func finish() {
        guard !completed else { return }
        completed = true
        isDone = true
        // Surface stderr as error only when there was no stdout output
        if output.isEmpty, !stderrBuffer.isEmpty {
            errorMessage = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        onDone?(output)
    }

    private func fail(_ message: String) {
        guard !completed else { return }
        completed = true
        errorMessage = message
        isDone = true
        onDone?("")
    }
}

// MARK: - Content View

/// Tracks the minY of the bottom sentinel inside the output ScrollView,
/// measured in the scroll container's coordinate space.
private struct BottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ContentView: View {
    let task: String
    let taskDisplayName: String
    let inputText: String
    let autoCopy: Bool
    let quitOnClose: Bool

    @StateObject private var processor = LLMProcessor()
    /// True when the bottom of the output is visible — enables auto-scroll during streaming.
    @State private var outputAutoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            inputPane
            outputPane
        }
        .frame(width: 600, height: 460)
        .onAppear {
            processor.start(task: task, input: inputText) { result in
                if autoCopy, !result.isEmpty { copyToClipboard(result) }
            }
        }
    }

    // MARK: Header

    private var headerBar: some View {
        HStack {
            Spacer().frame(width: 70)
            Text(taskDisplayName)
                .font(.headline)
                .foregroundColor(.primary)
            Spacer()
            Button {
                if quitOnClose {
                    NSApplication.shared.terminate(nil)
                } else {
                    NSApp.keyWindow?.orderOut(nil)
                    NSApp.setActivationPolicy(.accessory)
                }
            } label: {
                Text("ESC to close")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .frame(height: 30)
        .padding(.top, -30)
        .padding(.bottom, 8)
        .padding(.horizontal)
    }

    // MARK: Input

    private var inputPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Input")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 4)
            ScrollView {
                Text(inputText)
                    .textSelection(.enabled)
                    .foregroundColor(.primary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
            .background(Color.primary.opacity(0.06))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
    }

    // MARK: Output

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Output")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !processor.isDone {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                }
                Spacer()
                if processor.isDone, processor.errorMessage == nil {
                    Button("Copy") { copyToClipboard(processor.output) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.primary.opacity(0.12))
                        .foregroundColor(.primary)
                }
            }
            .padding(.horizontal)
            .frame(height: 20)

            ZStack {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Group {
                                if let err = processor.errorMessage {
                                    Text(err)
                                        .foregroundColor(.red.opacity(0.9))
                                } else if processor.output.isEmpty {
                                    Text("Processing…")
                                        .foregroundColor(.secondary)
                                } else {
                                    Text(processor.output)
                                        .textSelection(.enabled)
                                        .foregroundColor(.primary)
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)

                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: BottomOffsetKey.self,
                                    value: geo.frame(in: .named("outputArea")).minY
                                )
                            }
                            .frame(height: 0)
                            .id("scroll-bottom")
                        }
                    }
                    .onChange(of: processor.output) { _ in
                        if outputAutoScroll {
                            proxy.scrollTo("scroll-bottom", anchor: .bottom)
                        }
                    }
                }
            }
            .frame(height: 200)
            .coordinateSpace(name: "outputArea")
            .onPreferenceChange(BottomOffsetKey.self) { minY in
                // Bottom sentinel within (or at) the 200 pt visible area → we're at the bottom.
                outputAutoScroll = minY <= 204
            }
            .background(Color.primary.opacity(0.06))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    // MARK: Helpers

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Key Handler

struct KeyEventHandlingView: NSViewRepresentable {
    let quitOnClose: Bool
    func makeNSView(context: Context) -> NSView {
        let view = KeyView(quitOnClose: quitOnClose)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class KeyView: NSView {
    let quitOnClose: Bool
    init(quitOnClose: Bool) {
        self.quitOnClose = quitOnClose
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    // Pass all mouse/scroll hit-tests through so ScrollViews underneath receive events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            if quitOnClose {
                NSApplication.shared.terminate(nil)
            } else {
                window?.orderOut(nil)
                NSApp.setActivationPolicy(.accessory)
            }
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: NSWindow?
    var statusItem: NSStatusItem?
    private var isMenuBarMode = false
    private var hotkeyRefs: [EventHotKeyRef] = []
    private var hotkeyTaskMap: [UInt32: String] = [:]
    private var carbonEventHandler: EventHandlerRef?
    private var previousApp: NSRunningApplication?

    func applicationDidFinishLaunching(_: Notification) {
        bootstrapConfigIfNeeded()
        requestAccessibilityIfNeeded()

        let args = CommandLine.arguments
        var task = ""
        var taskDisplayName: String?
        var rawInput: String?
        var autoCopy = true

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--task":
                i += 1
                if i < args.count { task = args[i] }
            case "--task-name":
                i += 1
                if i < args.count { taskDisplayName = args[i] }
            case "--no-copy":
                autoCopy = false
            default:
                if !args[i].hasPrefix("-") { rawInput = args[i] }
            }
            i += 1
        }

        if task.isEmpty && rawInput == nil {
            // No task specified: run as persistent menu bar app
            isMenuBarMode = true
            setupMenuBar()
            return
        }

        // Single-shot mode: process one task and quit when window closes
        // Resolve input: argument > clipboard > fallback message
        let clipboardText = NSPasteboard.general.string(forType: .string) ?? ""
        let raw: String
        if let r = rawInput, !r.isEmpty {
            raw = r
        } else if !clipboardText.isEmpty {
            raw = clipboardText
        } else {
            raw = "No text selected and clipboard is empty."
        }

        let inputText = raw

        // Resolve task and display name
        let allTasks = readTasks()
        if task.isEmpty { task = allTasks.first?.id ?? "business" }
        let taskInfo = allTasks.first(where: { $0.id == task })
        let displayName = taskDisplayName ?? taskInfo?.displayName ?? task
        // --no-copy flag overrides config; otherwise use resolved auto_copy
        let effectiveAutoCopy = autoCopy ? resolveAutoCopy(sectionLevel: taskInfo?.autoCopy) : false

        openWindow(task: task, displayName: displayName, inputText: inputText,
                   autoCopy: effectiveAutoCopy, quitOnClose: true)
    }

    // MARK: Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem?.button {
            let symbolName: String
            if #available(macOS 15.4, *) {
                symbolName = "character.textbox.badge.sparkles"
            } else {
                symbolName = "character.textbox"
            }
            btn.image = NSImage(systemSymbolName: symbolName,
                                accessibilityDescription: "My LLM")
        }
        rebuildMenu()
        registerHotkeys()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let aboutItem = NSMenuItem(
            title: "About My LLM",
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem.separator())

        let allTasks = readTasks()
        for info in allTasks {
            let item = NSMenuItem(
                title: info.displayName,
                action: #selector(menuTaskSelected(_:)),
                keyEquivalent: ""
            )
            item.representedObject = info.id
            item.target = self
            if let hk = info.hotkey {
                let (key, mask) = menuKeyEquivalent(from: hk)
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = mask
            }
            menu.addItem(item)
        }

        // Always include translate
        let translateHotkey = readTranslationHotkey()
        let translateKE = translateHotkey.map { menuKeyEquivalent(from: $0) }
        let translateItem = NSMenuItem(
            title: "Translate",
            action: #selector(menuTaskSelected(_:)),
            keyEquivalent: translateKE?.key ?? ""
        )
        translateItem.representedObject = "translate"
        translateItem.target = self
        if let mask = translateKE?.mask { translateItem.keyEquivalentModifierMask = mask }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(translateItem)

        menu.addItem(NSMenuItem.separator())
        let reloadItem = NSMenuItem(
            title: "Reload Config",
            action: #selector(reloadConfig(_:)),
            keyEquivalent: ""
        )
        reloadItem.target = self
        menu.addItem(reloadItem)

        let openFolderItem = NSMenuItem(
            title: "Open Config Folder",
            action: #selector(openConfigFolder(_:)),
            keyEquivalent: ""
        )
        openFolderItem.target = self
        menu.addItem(openFolderItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(
            title: "Quit My LLM",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem?.menu = menu
    }

    @objc private func showAbout(_: NSMenuItem) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }

    // Capture the previously active app before the menu steals focus
    func menuWillOpen(_ menu: NSMenu) {
        previousApp = NSWorkspace.shared.frontmostApplication
    }

    @objc private func menuTaskSelected(_ sender: NSMenuItem) {
        guard let taskId = sender.representedObject as? String else { return }
        let allTasks = readTasks()
        let taskInfo = allTasks.first(where: { $0.id == taskId })
        let displayName = taskId == "translate" ? "Translate" : (taskInfo?.displayName ?? taskId)
        let sectionAutoCopy = taskId == "translate" ? readTranslationAutoCopy() : taskInfo?.autoCopy
        // previousApp was captured in menuWillOpen before focus shifted to My LLM
        captureSelectionAndOpen(taskId: taskId, displayName: displayName,
                                sectionAutoCopy: sectionAutoCopy, quitOnClose: false,
                                sourcePID: previousApp?.processIdentifier)
    }

    // Post Cmd+C directly to the source app by PID, then wait for the clipboard.
    // Sends Cmd+C to the source app by PID to capture selected text, then opens the window.
    // Requires Accessibility permission; falls back to current clipboard if not granted.
    private func captureSelectionAndOpen(taskId: String, displayName: String,
                                         sectionAutoCopy: Bool?, quitOnClose: Bool,
                                         sourcePID: pid_t?)
    {
        let changeCountBefore = NSPasteboard.general.changeCount
        let hasAccessibility = AXIsProcessTrusted()

        if hasAccessibility, let pid = sourcePID {
            let src = CGEventSource(stateID: .combinedSessionState)
            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true) // kVK_ANSI_C
            let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags   = .maskCommand
            if let kd = keyDown { kd.postToPid(pid) }
            if let ku = keyUp   { ku.postToPid(pid) }
        }

        let delay: Double = (hasAccessibility && sourcePID != nil) ? 0.25 : 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let text: String
            if hasAccessibility, NSPasteboard.general.changeCount != changeCountBefore {
                // Clipboard changed: the source app had a selection
                text = NSPasteboard.general.string(forType: .string) ?? ""
            } else {
                // No change: nothing was selected; use whatever was already in clipboard
                text = NSPasteboard.general.string(forType: .string) ?? ""
            }
            let inputText = text.isEmpty ? "Clipboard is empty." : text
            self.openWindow(task: taskId, displayName: displayName, inputText: inputText,
                            autoCopy: resolveAutoCopy(sectionLevel: sectionAutoCopy),
                            quitOnClose: quitOnClose)
        }
    }

    @objc private func reloadConfig(_ sender: Any?) {
        hotkeyRefs.forEach { UnregisterEventHotKey($0) }
        if let ref = carbonEventHandler { RemoveEventHandler(ref) }
        hotkeyRefs = []
        hotkeyTaskMap = [:]
        carbonEventHandler = nil
        rebuildMenu()
        registerHotkeys()
    }

    @objc private func openConfigFolder(_ sender: Any?) {
        let configPath = ProcessInfo.processInfo.environment["CONFIG_FILE"]
            ?? "\(NSHomeDirectory())/.config/myllm/config.toml"
        let folderURL = URL(fileURLWithPath: configPath).deletingLastPathComponent()
        NSWorkspace.shared.open(folderURL)
    }

    // MARK: Hotkey Registration

    private func registerHotkeys() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotkeyDispatch, 1, &eventType, selfPtr, &carbonEventHandler
        )
        var nextID: UInt32 = 1
        for task in readTasks() {
            guard let hkStr = task.hotkey,
                  let (keyCode, modifiers) = parseHotkey(hkStr) else { continue }
            let hkID = EventHotKeyID(signature: 0x4D4C4C4D, id: nextID)
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref = ref {
                hotkeyRefs.append(ref)
                hotkeyTaskMap[nextID] = task.id
                nextID += 1
            }
        }
        if let hkStr = readTranslationHotkey(),
           let (keyCode, modifiers) = parseHotkey(hkStr) {
            let hkID = EventHotKeyID(signature: 0x4D4C4C4D, id: nextID)
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref = ref {
                hotkeyRefs.append(ref)
                hotkeyTaskMap[nextID] = "translate"
            }
        }
    }

    func handleHotKey(id: UInt32) {
        guard let taskId = hotkeyTaskMap[id] else { return }
        // Capture frontmost app NOW (source app still has focus when hotkey fires)
        let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let allTasks = readTasks()
            let taskInfo = allTasks.first(where: { $0.id == taskId })
            let displayName = taskId == "translate" ? "Translate" : (taskInfo?.displayName ?? taskId)
            let sectionAutoCopy = taskId == "translate" ? readTranslationAutoCopy() : taskInfo?.autoCopy
            self.captureSelectionAndOpen(taskId: taskId, displayName: displayName,
                                         sectionAutoCopy: sectionAutoCopy, quitOnClose: false,
                                         sourcePID: sourcePID)
        }
    }

    func applicationWillTerminate(_: Notification) {
        hotkeyRefs.forEach { UnregisterEventHotKey($0) }
        if let ref = carbonEventHandler { RemoveEventHandler(ref) }
    }

    // MARK: Window Factory

    func openWindow(task: String, displayName: String, inputText: String,
                    autoCopy: Bool, quitOnClose: Bool)
    {
        // Hide any existing window instead of closing it
        window?.orderOut(nil)

        // Build window
        let rootView = ZStack {
            ContentView(
                task: task,
                taskDisplayName: displayName,
                inputText: inputText,
                autoCopy: autoCopy,
                quitOnClose: quitOnClose
            )
            KeyEventHandlingView(quitOnClose: quitOnClose)
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        let appearanceSetting = readGeneralAppearance()
        switch appearanceSetting {
        case "light":  win.appearance = NSAppearance(named: .aqua)
        case "system": win.appearance = nil
        default:       win.appearance = NSAppearance(named: .darkAqua)
        }
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.styleMask.insert(.fullSizeContentView)

        // Frosted glass background
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true

        // Dark overlay to ensure text contrast (dark mode only)
        if appearanceSetting == "dark" {
            let overlay = NSView()
            overlay.wantsLayer = true
            overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
            overlay.frame = blur.bounds
            overlay.autoresizingMask = [.width, .height]
            blur.addSubview(overlay)
        }

        let host = NSHostingView(rootView: rootView)
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)

        win.contentView = blur
        win.center()
        win.title = "myllm"
        win.level = .floating
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        window = win
        if isMenuBarMode { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    // Intercept the red X button (performClose) in menu bar mode — hide instead of close
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isMenuBarMode {
            sender.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
            return false
        }
        return true
    }

    // windowWillClose only fires in single-shot mode (menu bar mode uses orderOut)
    func windowWillClose(_: Notification) {
        window = nil
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
