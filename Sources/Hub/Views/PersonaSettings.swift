import HubKit
import SwiftUI

/// Settings › Review personas: the built-in ones, and your own.
struct PersonaSettings: View {
    @AppStorage(ReviewPersona.selectedKey) private var selected = ReviewPersona.general.id
    @AppStorage("reviewPersonas") private var customData: Data?
    @State private var editing: ReviewPersona?

    var body: some View {
        let custom = ReviewPersona.custom()
        SwiftUI.Section {
            Picker("Review as", selection: $selected) {
                ForEach(ReviewPersona.builtIn + custom) { p in Label(p.name, systemImage: p.symbol).tag(p.id) }
            }
            ForEach(ReviewPersona.builtIn + custom) { p in
                HStack(spacing: 8) {
                    Image(systemName: p.symbol).foregroundStyle(Theme.claude).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(p.name)
                            if p.id == selected { Pill(text: "Default", tint: Theme.claude) }
                        }
                        Text(p.lens).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if p.id != selected { Button("Make default") { selected = p.id }.controlSize(.small) }
                    if p.isBuiltIn {
                        Button("Copy…") {
                            editing = ReviewPersona(name: "My \(p.name.lowercased())", symbol: p.symbol, lens: p.lens)
                        }
                        .controlSize(.small)
                        .help("Start your own persona from this one")
                    } else {
                        Button("Edit…") { editing = p }.controlSize(.small)
                    }
                }
            }
            Button("Add persona…") { editing = ReviewPersona(name: "", lens: "") }
        } header: {
            Text("Review personas")
        } footer: {
            Text("The perspective Claude reviews pull requests from. Every review starts as the default; switching on the review card applies to that review only.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { persona in
            PersonaEditor(persona: persona, isNew: !custom.contains { $0.id == persona.id }) { result in
                var list = ReviewPersona.custom()
                switch result {
                case .save(let p):
                    if let i = list.firstIndex(where: { $0.id == p.id }) { list[i] = p } else { list.append(p) }
                case .delete(let p):
                    list.removeAll { $0.id == p.id }
                    if selected == p.id { selected = ReviewPersona.general.id }
                }
                ReviewPersona.saveCustom(list)
                customData = UserDefaults.standard.data(forKey: "reviewPersonas")
                editing = nil
            }
        }
    }
}

private struct PersonaEditor: View {
    enum Result { case save(ReviewPersona), delete(ReviewPersona) }
    @State var persona: ReviewPersona
    var isNew: Bool
    var done: (Result) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let symbols = ["person.crop.circle", "building.columns", "lock.shield", "gauge.with.dots.needle.67percent",
                                  "checklist", "testtube.2", "accessibility", "paintbrush", "server.rack", "cylinder.split.1x2",
                                  "iphone", "globe", "doc.text", "graduationcap"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New persona" : "Edit persona").font(.headline)
            HStack {
                Picker("", selection: $persona.symbol) {
                    ForEach(Self.symbols, id: \.self) { Image(systemName: $0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Name, e.g. Platform architect", text: $persona.name)
                    .textFieldStyle(.roundedBorder)
            }
            Text("What should Claude look for, and what should it leave alone?")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $persona.lens)
                .font(.callout)
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { done(.delete(persona)) }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { done(.save(persona)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(persona.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || persona.lens.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
