import Foundation

/// How Hub's built-in terminal looks: read from Ghostty's config so it
/// matches the terminal you already use. Colours are "#rrggbb".
public struct TerminalLook: Equatable, Sendable {
    public var fontFamily: String?
    public var fontSize: Double = 13
    public var background = "#282c34"
    public var foreground = "#ffffff"
    public var cursor: String?
    public var selection: String?
    /// Sixteen ANSI colours, when a theme sets them.
    public var palette: [Int: String] = [:]

    public init() {}

    static let configPaths = [
        "~/Library/Application Support/com.mitchellh.ghostty/config",
        "~/.config/ghostty/config",
    ]
    static let themeFolders = [
        "~/.config/ghostty/themes",
        "~/Library/Application Support/com.mitchellh.ghostty/themes",
        "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
    ]

    /// Ghostty's settings, or the defaults when Ghostty is not set up.
    public static func fromGhostty(darkMode: Bool = true) -> TerminalLook {
        var look = TerminalLook()
        for path in configPaths {
            let full = (path as NSString).expandingTildeInPath
            guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
            look.apply(text, darkMode: darkMode, loadTheme: { name in
                for folder in themeFolders {
                    let file = (folder as NSString).expandingTildeInPath + "/" + name
                    if let theme = try? String(contentsOfFile: file, encoding: .utf8) { return theme }
                }
                return nil
            })
        }
        return look
    }

    /// Applies one config file. A theme is applied first, so the file's own
    /// colours win, as in Ghostty.
    public mutating func apply(_ config: String, darkMode: Bool, loadTheme: (String) -> String?) {
        let pairs = Self.pairs(config)
        if let theme = pairs.last(where: { $0.0 == "theme" })?.1 {
            // "light:Rose Pine Dawn,dark:Rose Pine" picks by appearance.
            var name = theme
            if theme.contains(":") {
                let options = Dictionary(theme.split(separator: ",").compactMap { part -> (String, String)? in
                    let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    return kv.count == 2 ? (kv[0], kv[1]) : nil
                }, uniquingKeysWith: { a, _ in a })
                name = options[darkMode ? "dark" : "light"] ?? options.values.first ?? theme
            }
            if let text = loadTheme(name) { applyColours(Self.pairs(text)) }
        }
        applyColours(pairs)
        for (key, value) in pairs {
            switch key {
            case "font-family": if fontFamily == nil { fontFamily = value }
            case "font-size": if let size = Double(value) { fontSize = size }
            default: break
            }
        }
    }

    private mutating func applyColours(_ pairs: [(String, String)]) {
        for (key, value) in pairs {
            let colour = value.hasPrefix("#") ? value : "#" + value
            switch key {
            case "background": background = colour
            case "foreground": foreground = colour
            case "cursor-color": cursor = colour
            case "selection-background": selection = colour
            case "palette":
                let kv = value.split(separator: "=", maxSplits: 1)
                if kv.count == 2, let index = Int(kv[0].trimmingCharacters(in: .whitespaces)) {
                    let hex = kv[1].trimmingCharacters(in: .whitespaces)
                    palette[index] = hex.hasPrefix("#") ? hex : "#" + hex
                }
            default: break
            }
        }
    }

    static func pairs(_ text: String) -> [(String, String)] {
        text.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            return (line[..<eq].trimmingCharacters(in: .whitespaces), value)
        }
    }
}
