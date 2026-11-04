import AppKit
import HubKit
import Observation
import SwiftTerm
import SwiftUI

// MARK: Where things run

/// The login shell's PATH, read once: an app started from Finder has a bare
/// PATH that cannot find claude, gh or brew's git.
enum ShellEnv {
    nonisolated(unsafe) private static var cached: [String: String]?

    static var userShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell { return String(cString: shell) }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// The environment for anything Hub starts: this process's, with the
    /// login shell's PATH and a proper terminal.
    static func environment() -> [String: String] {
        if let cached { return cached }
        var env = ProcessInfo.processInfo.environment
        let process = Process()
        process.executableURL = URL(fileURLWithPath: userShell)
        process.arguments = ["-l", "-i", "-c", "printf '\\n__HUBPATH__%s\\n' \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            if let line = text.split(separator: "\n").last(where: { $0.hasPrefix("__HUBPATH__") }) {
                env["PATH"] = String(line.dropFirst(11))
            }
        }
        let path = env["PATH"] ?? "/usr/bin:/bin"
        let home = CpxConfig.home
        // Where claude, gh and git usually live, in case the shell said nothing.
        for extra in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] where !path.contains(extra) {
            env["PATH"] = (env["PATH"] ?? "") + ":" + extra
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "gh-hub"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        // Started from inside a Claude session (while developing Hub), these would leak in.
        for key in env.keys where key.hasPrefix("CLAUDE_CODE") || key == "CLAUDECODE" { env[key] = nil }
        cached = env
        return env
    }
}

/// Where Claude sessions open.
enum TerminalChoice: String, CaseIterable, Identifiable {
    case hub, ghostty, terminal, iterm
    var id: String { rawValue }

    var label: String {
        switch self {
        case .hub: "Inside GH Hub"
        case .ghostty: "Ghostty"
        case .terminal: "Terminal"
        case .iterm: "iTerm"
        }
    }

    var bundleID: String? {
        switch self {
        case .hub: nil
        case .ghostty: "com.mitchellh.ghostty"
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        }
    }

    var isInstalled: Bool {
        guard let bundleID else { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static var current: TerminalChoice {
        let choice = TerminalChoice(rawValue: UserDefaults.standard.string(forKey: "terminal") ?? "") ?? .hub
        return choice.isInstalled ? choice : .hub
    }
}

/// Editors a worktree can be opened in.
struct Editor: Identifiable, Hashable {
    let name: String
    let bundleID: String
    var id: String { bundleID }

    static let known: [Editor] = [
        Editor(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
        Editor(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
        Editor(name: "Zed", bundleID: "dev.zed.Zed"),
        Editor(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
        Editor(name: "Fold", bundleID: "dev.samiworld.fold"),
        Editor(name: "Sublime Text", bundleID: "com.sublimetext.4"),
        Editor(name: "Nova", bundleID: "com.panic.Nova"),
    ]

    static var installed: [Editor] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    static var preferred: Editor? {
        let id = UserDefaults.standard.string(forKey: "editor") ?? ""
        return installed.first { $0.bundleID == id } ?? installed.first
    }

    func open(_ path: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: config)
    }
}

// MARK: Terminals inside Hub

@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    var title: String
    let repo: String?
    let script: String
    let startedAt = Date.now
    var running = true
    var exitCode: Int32?
    /// The folder the shell reports (OSC 7), when it does.
    var directory: String?
    @ObservationIgnored let view: LocalProcessTerminalView
    @ObservationIgnored private var bridge: Bridge?

    init(title: String, repo: String?, script: String) {
        self.title = title
        self.repo = repo
        self.script = script
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        TerminalStyle.apply(to: view)
        let bridge = Bridge(owner: self)
        self.bridge = bridge
        view.processDelegate = bridge
        // Normally the pane starts it once laid out; this covers a session never shown.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startIfNeeded() }
    }

    private var started = false

    /// Starts the process at the size the pane gave the terminal. Started
    /// earlier, Claude Code draws at a placeholder width and the resize that
    /// follows leaves half-redrawn lines behind.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        let env = ShellEnv.environment().map { "\($0.key)=\($0.value)" }
        view.startProcess(executable: "/bin/bash", args: [script], environment: env, execName: "bash",
                          currentDirectory: CpxConfig.home)
    }

    func terminate() {
        if running { view.terminate() }
        running = false
    }

    /// Delegate calls arrive off the main actor's view of things; hop back.
    final class Bridge: NSObject, LocalProcessTerminalViewDelegate {
        weak var owner: TerminalSession?
        init(owner: TerminalSession) { self.owner = owner }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            Task { @MainActor in if !title.isEmpty { self.owner?.title = title.replacingOccurrences(of: "GH Hub · ", with: "") } }
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            Task { @MainActor in self.owner?.directory = directory.flatMap { URL(string: $0)?.path ?? $0 } }
        }
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            Task { @MainActor in
                self.owner?.running = false
                self.owner?.exitCode = exitCode
            }
        }
    }
}

enum TerminalStyle {
    @MainActor
    static func apply(to view: TerminalView) {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
        let look = TerminalLook.fromGhostty(darkMode: dark)
        let size = CGFloat(look.fontSize)
        if let family = look.fontFamily, let font = NSFont(name: family, size: size)
            ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            view.font = font
        } else {
            view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        view.nativeBackgroundColor = NSColor(hex: look.background) ?? .black
        view.nativeForegroundColor = NSColor(hex: look.foreground) ?? .white
        if let cursor = look.cursor.flatMap(NSColor.init(hex:)) { view.caretColor = cursor }
        if let selection = look.selection.flatMap(NSColor.init(hex:)) { view.selectedTextBackgroundColor = selection }
        if look.palette.count == 16 {
            view.installColors((0..<16).map { index in
                let c = NSColor(hex: look.palette[index] ?? "#888888")?.usingColorSpace(.sRGB) ?? .gray
                return SwiftTerm.Color(red: UInt16(c.redComponent * 65535), green: UInt16(c.greenComponent * 65535),
                                       blue: UInt16(c.blueComponent * 65535))
            })
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}

@MainActor
@Observable
final class TerminalManager {
    private(set) var sessions: [TerminalSession] = []

    var running: [TerminalSession] { sessions.filter(\.running) }

    func session(_ id: UUID) -> TerminalSession? { sessions.first { $0.id == id } }

    @discardableResult
    func start(script: String, title: String, repo: String?) -> TerminalSession {
        let session = TerminalSession(title: title, repo: repo, script: script)
        sessions.insert(session, at: 0)
        return session
    }

    func close(_ id: UUID) {
        session(id)?.terminate()
        sessions.removeAll { $0.id == id }
    }
}

/// Shows a terminal session. The terminal view lives as long as its session,
/// so switching away and back keeps everything on screen.
struct TerminalPane: NSViewRepresentable {
    let session: TerminalSession

    /// Tells the session once Auto Layout has given the terminal its size.
    final class Host: NSView {
        var didLayout: (() -> Void)?
        override func layout() {
            super.layout()
            didLayout?()
        }
    }

    func makeNSView(context: Context) -> NSView {
        let container = Host()
        container.wantsLayer = true
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if session.view.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        let view = session.view
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.layer?.backgroundColor = view.nativeBackgroundColor.cgColor
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        let session = session
        (container as? Host)?.didLayout = { [weak view] in
            guard let view, view.window != nil, view.frame.width > 120, view.frame.height > 60 else { return }
            session.startIfNeeded()
        }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}
