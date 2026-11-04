import Foundation

/// Just enough YAML to read a workflow's `workflow_dispatch` inputs. Workflow
/// files are regular enough that indentation tells the whole story; anything
/// stranger still dispatches, only without a form for its inputs.
public enum WorkflowFile {
    /// The inputs of a manually triggerable workflow, or nil when the
    /// workflow cannot be started by hand.
    public static func dispatchInputs(in yaml: String) -> [WorkflowInput]? {
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(Line.init)

        guard let start = lines.firstIndex(where: { $0.key == "workflow_dispatch" }) else {
            // `on: workflow_dispatch` or `on: [push, workflow_dispatch]`.
            let inline = lines.contains { line in
                (line.key == "on" || line.key == "\"on\"" || line.key == "'on'") && line.value.contains("workflow_dispatch")
                    || line.text == "- workflow_dispatch"
            }
            return inline ? [] : nil
        }

        let base = lines[start].indent
        var inputsIndent: Int?
        var nameIndent: Int?
        var inputs: [WorkflowInput] = []
        var current: WorkflowInput?
        var listKey: String?

        func flush() {
            if let input = current { inputs.append(input) }
            current = nil
        }

        for line in lines[(start + 1)...] where !line.isBlank {
            if line.indent <= base { break }
            guard let inputsAt = inputsIndent else {
                if line.key == "inputs" { inputsIndent = line.indent }
                continue
            }
            if line.indent <= inputsAt { break }
            if nameIndent == nil { nameIndent = line.indent }
            if line.indent == nameIndent, let key = line.key {
                flush()
                current = WorkflowInput(name: unquote(key))
                listKey = nil
                continue
            }
            guard current != nil else { continue }
            if line.text.hasPrefix("- "), listKey == "options" {
                current?.options.append(unquote(String(line.text.dropFirst(2))))
                continue
            }
            guard let key = line.key else { continue }
            let value = unquote(line.value)
            listKey = nil
            switch key {
            case "description": current?.description = value
            case "required": current?.required = value.lowercased() == "true"
            case "default": current?.defaultValue = value
            case "type": current?.kind = WorkflowInput.Kind(rawValue: value) ?? .string
            case "options":
                if value.hasPrefix("[") {
                    current?.options = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .split(separator: ",").map { unquote(String($0)) }
                } else {
                    listKey = "options"
                }
            default: break
            }
        }
        flush()
        return inputs
    }

    struct Line {
        let indent: Int
        let text: String
        let key: String?
        let value: String

        var isBlank: Bool { text.isEmpty }

        init(_ raw: Substring) {
            var body = String(raw)
            if let hash = body.range(of: " #") { body = String(body[..<hash.lowerBound]) }
            indent = body.prefix { $0 == " " }.count
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            text = trimmed.hasPrefix("#") ? "" : trimmed
            if !text.hasPrefix("- "), let colon = text.firstIndex(of: ":") {
                key = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
                value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            } else {
                key = nil
                value = ""
            }
        }
    }

    static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        for quote in ["\"", "'"] where trimmed.count >= 2 && trimmed.hasPrefix(quote) && trimmed.hasSuffix(quote) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}
