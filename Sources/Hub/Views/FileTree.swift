import HubKit
import SwiftUI

/// A pull request's files as a folder tree, GitHub style: folders that hold
/// a single folder are merged into one row ("src/app/views").
struct FileNode: Identifiable {
    var name: String
    var path: String
    var children: [FileNode] = []
    var file: PRFile?
    var id: String { path }
    var isFolder: Bool { file == nil }

    /// Every file under this node.
    var files: [PRFile] { file.map { [$0] } ?? children.flatMap(\.files) }

    static func tree(_ files: [PRFile]) -> [FileNode] {
        final class Box {
            var name: String, path: String
            var folders: [String: Box] = [:]
            var order: [String] = []
            var files: [PRFile] = []
            init(name: String, path: String) { self.name = name; self.path = path }
        }
        let root = Box(name: "", path: "")
        for file in files {
            var box = root
            let parts = file.filename.split(separator: "/").map(String.init)
            for part in parts.dropLast() {
                if box.folders[part] == nil {
                    box.folders[part] = Box(name: part, path: box.path.isEmpty ? part : box.path + "/" + part)
                    box.order.append(part)
                }
                box = box.folders[part]!
            }
            box.files.append(file)
        }
        func build(_ box: Box) -> [FileNode] {
            let folders = box.order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key -> FileNode in
                var child = box.folders[key]!
                var name = child.name
                // Merge chains of folders that hold only one folder.
                while child.files.isEmpty, child.folders.count == 1, let only = child.folders.values.first {
                    name += "/" + only.name
                    child = only
                }
                return FileNode(name: name, path: child.path, children: build(child))
            }
            let files = box.files.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }.map {
                FileNode(name: ($0.filename as NSString).lastPathComponent, path: $0.filename, file: $0)
            }
            return folders + files
        }
        return build(root)
    }
}

/// An SF Symbol and tint for a file, by its extension.
enum FileKind {
    static func symbol(_ name: String) -> (String, Color) {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return ("swift", Color(red: 0.98, green: 0.45, blue: 0.25))
        case "ts", "tsx": return ("t.square.fill", Color(red: 0.19, green: 0.47, blue: 0.78))
        case "js", "jsx", "mjs", "cjs": return ("j.square.fill", Color(red: 0.94, green: 0.80, blue: 0.20))
        case "json", "jsonc": return ("curlybraces.square.fill", Color(red: 0.95, green: 0.70, blue: 0.25))
        case "md", "mdx", "markdown": return ("doc.richtext.fill", Color(red: 0.45, green: 0.62, blue: 0.95))
        case "yml", "yaml", "toml": return ("gearshape.fill", Color(red: 0.75, green: 0.45, blue: 0.85))
        case "kt", "kts", "java", "gradle": return ("k.square.fill", Color(red: 0.62, green: 0.45, blue: 0.95))
        case "py": return ("p.square.fill", Color(red: 0.25, green: 0.55, blue: 0.85))
        case "rs": return ("r.square.fill", Color(red: 0.85, green: 0.45, blue: 0.30))
        case "go": return ("g.square.fill", Color(red: 0.30, green: 0.75, blue: 0.85))
        case "sh", "bash", "zsh": return ("terminal.fill", Color(red: 0.40, green: 0.80, blue: 0.50))
        case "css", "scss", "sass", "less": return ("paintbrush.fill", Color(red: 0.30, green: 0.60, blue: 0.95))
        case "html", "htm", "xml", "plist": return ("chevron.left.forwardslash.chevron.right", Color(red: 0.92, green: 0.45, blue: 0.30))
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "pdf": return ("photo.fill", Color(red: 0.35, green: 0.75, blue: 0.65))
        case "lock", "sum", "resolved": return ("lock.fill", .secondary)
        case "sql": return ("cylinder.fill", Color(red: 0.55, green: 0.65, blue: 0.80))
        default:
            if name.hasPrefix(".") { return ("eye.slash.fill", .secondary) }
            if name.lowercased().hasPrefix("dockerfile") { return ("shippingbox.fill", Color(red: 0.25, green: 0.55, blue: 0.90)) }
            return ("doc.fill", .secondary)
        }
    }
}

/// What the tree needs to know about review progress.
struct FileTreeState {
    var viewed: Set<String>
    var openThreads: [String: Int]
    var pending: [String: Int]
    var setViewed: (PRFile, Bool) -> Void
    var select: (PRFile) -> Void
}

struct FileTreeView: View {
    var nodes: [FileNode]
    var state: FileTreeState
    var filter: String = ""
    @State private var closed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visible(nodes)) { node in
                row(node, depth: 0)
            }
        }
    }

    /// Nodes that match the filter (a folder stays if any file in it does).
    private func visible(_ nodes: [FileNode]) -> [FileNode] {
        guard !filter.isEmpty else { return nodes }
        return nodes.compactMap { node in
            if let file = node.file { return file.filename.localizedCaseInsensitiveContains(filter) ? node : nil }
            var copy = node
            copy.children = visible(node.children)
            return copy.children.isEmpty ? nil : copy
        }
    }

    private func row(_ node: FileNode, depth: Int) -> AnyView {
        if node.isFolder {
            let open = !closed.contains(node.path) || !filter.isEmpty
            let files = node.files
            let done = files.filter { state.viewed.contains($0.id) }.count
            return AnyView(VStack(alignment: .leading, spacing: 0) {
                TreeRow(depth: depth) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                    Image(systemName: open ? "folder.fill" : "folder")
                        .foregroundStyle(done == files.count ? Theme.green : Theme.blue.opacity(0.85))
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text("\(done)/\(files.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(done == files.count ? Theme.green : Color.secondary)
                } action: {
                    withAnimation(.snappy(duration: 0.18)) {
                        if closed.contains(node.path) { closed.remove(node.path) } else { closed.insert(node.path) }
                    }
                }
                .contextMenu {
                    Button("Mark folder as viewed") { files.forEach { state.setViewed($0, true) } }
                    Button("Mark folder as not viewed") { files.forEach { state.setViewed($0, false) } }
                }
                if open {
                    ForEach(node.children) { child in row(child, depth: depth + 1) }
                }
            })
        }
        let file = node.file!
        let viewed = state.viewed.contains(file.id)
        let (symbol, tint) = FileKind.symbol(node.name)
        return AnyView(TreeRow(depth: depth, dimmed: viewed) {
            Button { state.setViewed(file, !viewed) } label: {
                Image(systemName: viewed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(viewed ? Theme.green : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .frame(width: 10)
            .help(viewed ? "Viewed — click to unmark" : "Mark as viewed")
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 14)
            Text(node.name)
                .font(.system(size: 12, design: .monospaced))
                .strikethrough(viewed, color: .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            StatusBadge(status: file.status)
            Spacer(minLength: 6)
            if let n = state.openThreads[file.filename], n > 0 {
                Label("\(n)", systemImage: "text.bubble.fill").font(.caption2).foregroundStyle(Theme.blue)
            }
            if let n = state.pending[file.filename], n > 0 {
                Label("\(n)", systemImage: "clock.fill").font(.caption2).foregroundStyle(Theme.amber)
            }
            ChangeBar(additions: file.additions, deletions: file.deletions)
        } action: {
            state.select(file)
        })
    }
}

/// One line of the tree: indent guides, hover highlight.
struct TreeRow<Content: View>: View {
    var depth: Int
    var dimmed = false
    @ViewBuilder var content: () -> Content
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(0..<depth, id: \.self) { _ in
                    Rectangle().fill(.separator.opacity(0.7)).frame(width: 1).padding(.horizontal, 7.5)
                }
            }
            content()
        }
        .font(.system(size: 12.5))
        .opacity(dimmed ? 0.55 : 1)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(hovering ? Theme.blue.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

/// "A", "D", "R" like GitHub's status letters; nothing for a plain change.
struct StatusBadge: View {
    var status: String
    var body: some View {
        let badge: (letter: String, tint: Color)? = switch status {
        case "added": ("A", Theme.green)
        case "removed": ("D", Theme.red)
        case "renamed": ("R", Theme.blue)
        default: nil
        }
        if let badge {
            let letter = badge.letter, tint = badge.tint
            Text(letter)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(tint)
                .frame(width: 14, height: 14)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 3.5))
        }
    }
}

/// Five little blocks, green for added and red for removed, like GitHub's diffstat.
struct ChangeBar: View {
    var additions: Int
    var deletions: Int

    var body: some View {
        let total = additions + deletions
        let green = total == 0 ? 0 : Int((Double(additions) / Double(total) * 5).rounded())
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(Theme.green)
            Text("−\(deletions)").foregroundStyle(Theme.red)
            HStack(spacing: 1.5) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(total == 0 ? Color.secondary.opacity(0.3) : i < green ? Theme.green : Theme.red)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
    }
}
