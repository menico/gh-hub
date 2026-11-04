import Foundation

/// The contract with the `gh` command: which accounts are signed in, and the
/// token for each. Nothing else goes through `gh`; the API is called directly.
public enum GHCLI {
    public enum Failure: LocalizedError {
        case notInstalled
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled: "The gh command was not found. Install it with `brew install gh`."
            case .failed(let message): message
            }
        }
    }

    /// Variables that make `gh` ignore its own keyring. A shell that exports
    /// GH_TOKEN would otherwise hand every account the same token.
    static let tokenVariables = ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"]

    public static func executable() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + path.split(separator: ":").map(String.init)
        let fm = FileManager.default
        return dirs.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent("gh") }
            .first { fm.isExecutableFile(atPath: $0.path) }
    }

    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: String
    }

    static func run(_ arguments: [String]) async throws -> Output {
        guard let exe = executable() else { throw Failure.notInstalled }
        return try await Task.detached {
            let process = Process()
            process.executableURL = exe
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            for key in tokenVariables { env.removeValue(forKey: key) }
            process.environment = env
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Output(
                status: process.terminationStatus,
                stdout: stdout,
                stderr: String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    /// Every account `gh` holds a working login for, on every host.
    public static func accounts() async throws -> [Account] {
        let output = try await run(["auth", "status", "--json", "hosts"])
        // `gh auth status` exits non-zero when any one login is broken, but
        // still prints the full list; trust the JSON over the exit code.
        guard let parsed = try? parseAccounts(output.stdout) else {
            throw Failure.failed(output.stderr.isEmpty ? "Could not read `gh auth status`." : output.stderr)
        }
        return parsed
    }

    static func parseAccounts(_ data: Data) throws -> [Account] {
        struct Status: Decodable {
            struct Entry: Decodable {
                var state: String
                var active: Bool?
                var host: String
                var login: String
            }
            var hosts: [String: [Entry]]
        }
        let status = try JSONDecoder().decode(Status.self, from: data)
        return status.hosts.keys.sorted().flatMap { host in
            status.hosts[host, default: []]
                .filter { $0.state == "success" }
                .map { Account(login: $0.login, host: $0.host) }
        }
    }

    public static func token(for account: Account) async throws -> String {
        let output = try await run(["auth", "token", "--hostname", account.host, "--user", account.login])
        let token = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.status == 0, !token.isEmpty else {
            throw Failure.failed(output.stderr.isEmpty ? "No token for \(account.login)." : output.stderr)
        }
        return token
    }
}
