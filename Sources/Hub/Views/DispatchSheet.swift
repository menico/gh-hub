import HubKit
import SwiftUI

/// Start a `workflow_dispatch` workflow in any repository, as the account that sees it.
struct DispatchSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var repoName: String = UserDefaults.standard.string(forKey: "lastDispatchRepo") ?? ""
    @State private var workflows: [DispatchableWorkflow] = []
    @State private var workflowID: Int?
    @State private var ref = ""
    @State private var values: [String: String] = [:]
    @State private var loading = false
    @State private var loadError: String?
    @State private var running = false

    private var repo: Repo? { store.repos.first { $0.nameWithOwner == repoName } }
    private var workflow: DispatchableWorkflow? { workflows.first { $0.id == workflowID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.accentGradient)
                VStack(alignment: .leading) {
                    Text("Run workflow").font(.title2.weight(.bold))
                    Text("Trigger any workflow that accepts workflow_dispatch").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            Form {
                Picker("Repository", selection: $repoName) {
                    Text("Choose…").tag("")
                    ForEach(store.repos.filter { repo in
                        let viewers = store.viewers(of: repo)
                        return store.activeScope.map(viewers.contains) ?? !viewers.isEmpty
                    }) { repo in
                        HStack {
                            Text(repo.nameWithOwner)
                        }
                        .tag(repo.nameWithOwner)
                    }
                }

                if loading {
                    HStack { ProgressView().controlSize(.small); Text("Finding workflows…").foregroundStyle(.secondary) }
                } else if let loadError {
                    Text(loadError).foregroundStyle(Theme.red)
                } else if repo != nil {
                    if workflows.isEmpty {
                        Text("No workflow in this repository can be run by hand.").foregroundStyle(.secondary)
                    } else {
                        Picker("Workflow", selection: $workflowID) {
                            ForEach(workflows) { Text($0.workflow.name).tag(Optional($0.id)) }
                        }
                        TextField("Branch or tag", text: $ref)
                    }
                }

                if let workflow, !workflow.inputs.isEmpty {
                    SwiftUI.Section("Inputs") {
                        ForEach(workflow.inputs) { input in inputField(input) }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                if let repo {
                    let actor = store.acting(for: repo)
                    HStack(spacing: 5) {
                        Circle().fill(Theme.color(for: actor)).frame(width: 7, height: 7)
                        Text("Runs as \(store.name(actor))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await run() }
                } label: {
                    if running { ProgressView().controlSize(.small) } else { Label("Run", systemImage: "play.fill") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(workflow == nil || ref.isEmpty || running || missingRequired)
            }
            .padding(16)
        }
        .frame(width: 560, height: 600)
        .task(id: repoName) { await loadWorkflows() }
        .onChange(of: workflowID) { _, _ in resetValues() }
    }

    @ViewBuilder
    private func inputField(_ input: WorkflowInput) -> some View {
        let binding = Binding(get: { values[input.name] ?? "" }, set: { values[input.name] = $0 })
        let label = input.name + (input.required ? " *" : "")
        VStack(alignment: .leading, spacing: 2) {
            switch input.kind {
            case .boolean:
                Toggle(label, isOn: Binding(get: { binding.wrappedValue == "true" }, set: { binding.wrappedValue = $0 ? "true" : "false" }))
            case .choice where !input.options.isEmpty:
                Picker(label, selection: binding) {
                    ForEach(input.options, id: \.self) { Text($0).tag($0) }
                }
            default:
                TextField(label, text: binding, prompt: Text(input.defaultValue ?? ""))
            }
            if let description = input.description, !description.isEmpty {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var missingRequired: Bool {
        workflow?.inputs.contains { $0.required && (values[$0.name] ?? "").isEmpty } ?? false
    }

    private func loadWorkflows() async {
        workflows = []
        workflowID = nil
        loadError = nil
        guard let repo, let client = store.client(store.acting(for: repo)) else { return }
        ref = repo.defaultBranch
        loading = true
        defer { loading = false }
        do {
            workflows = try await client.dispatchableWorkflows(in: repo)
            workflowID = workflows.first?.id
            resetValues()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func resetValues() {
        values = [:]
        for input in workflow?.inputs ?? [] {
            values[input.name] = input.defaultValue ?? (input.kind == .choice ? input.options.first : nil) ?? (input.kind == .boolean ? "false" : "")
        }
    }

    private func run() async {
        guard let repo, let workflow else { return }
        running = true
        defer { running = false }
        let inputs = values.filter { !$0.value.isEmpty }
        let ref = ref
        let ok = await store.perform("Started \(workflow.workflow.name) on \(ref)", {
            try await $0.dispatch(workflow.workflow, in: repo.nameWithOwner, ref: ref, inputs: inputs)
        }, as: store.acting(for: repo))
        if ok {
            UserDefaults.standard.set(repo.nameWithOwner, forKey: "lastDispatchRepo")
            dismiss()
        }
    }
}
