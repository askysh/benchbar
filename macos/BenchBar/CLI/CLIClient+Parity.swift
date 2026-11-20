import Foundation

/// The CLI's commands the BenchBar window had no button for: the command list,
/// services only, the background service, autostart and doctor's acknowledgements.
/// Each one that has a plan goes through it and its token; the others run on a click.
nonisolated extension CLIClient {
    /// benchbar commands --json: which commands and flags this CLI has. Read only.
    func commands() async throws(CLIError) -> CommandCatalog {
        let output = try await run(["commands", "--json"], timeout: Timeout.query, acceptExitCodes: [0], qos: .utility)
        return try BenchJSON.decode(CommandCatalog.self, from: Data(output.stdout.utf8))
    }

    /// benchbar up --services-only: the bench's Redis and nothing else, for a restore or a migrate.
    @discardableResult
    func startServicesOnly(bench: String) async throws(CLIError) -> CommandOutput {
        try await run(["up", "--services-only", "--plain", "--bench-dir", bench], timeout: Timeout.action, acceptExitCodes: [0])
    }

    /// benchbar down on a stopped bench: stops the Redis that `startServicesOnly` started.
    @discardableResult
    func stopServices(bench: String) async throws(CLIError) -> CommandOutput {
        try await run(["down", "--plain", "--bench-dir", bench], timeout: Timeout.action, acceptExitCodes: [0])
    }

    /// benchbar service --dry-run --json: the plan of installing or refreshing the service, and its token. Read only.
    func servicePlan(bench: String) async throws(CLIError) -> ServiceInstallPlan {
        let output = try await run(["service", "--dry-run", "--json", "--bench-dir", bench], timeout: Timeout.doctor, acceptExitCodes: [0])
        do {
            return try ServiceInstallPlan.parse(stream: output.stdout)
        } catch let error as CLIError {
            throw error
        } catch {
            throw .invalidJSON(detail: error.localizedDescription, preview: BenchJSON.preview(Data(output.stdout.utf8)))
        }
    }

    /// benchbar service --apply TOKEN --yes: writes what the person saw. The CLI recomputes the plan and refuses a
    /// token that no longer matches. A step that needs the Mac's password asks in macOS's own dialog
    /// (BENCHBAR_SUDO=gui, as repair does); a cancelled dialog skips that step with a warning.
    @discardableResult
    func installService(token: String, bench: String) async throws(CLIError) -> CommandOutput {
        try await run(["service", "--apply", token, "--yes", "--plain", "--bench-dir", bench],
                      timeout: Timeout.action, acceptExitCodes: [0], extraEnvironment: Self.guiSudo)
    }

    /// benchbar doctor --ack CHECK (or --unack): silences one warning of this bench until its message
    /// changes, or takes that back. A failing check is refused by the CLI.
    @discardableResult
    func acknowledge(_ check: String, on: Bool, bench: String) async throws(CLIError) -> CommandOutput {
        try await run(["doctor", on ? "--ack" : "--unack", check, "--json", "--bench-dir", bench],
                      timeout: Timeout.query, acceptExitCodes: [0])
    }

    /// benchbar autostart (no word) reads the setting. It prints text only, no JSON: "autostart is on (...)".
    func autostart(bench: String) async throws(CLIError) -> Bool? {
        let output = try await run(["autostart", "--plain", "--bench-dir", bench], timeout: Timeout.query, acceptExitCodes: [0], qos: .utility)
        return AutostartText.parse(output.stdout + "\n" + output.stderr)
    }

    @discardableResult
    func setAutostart(_ on: Bool, bench: String) async throws(CLIError) -> CommandOutput {
        try await run(["autostart", on ? "on" : "off", "--plain", "--bench-dir", bench], timeout: Timeout.action, acceptExitCodes: [0])
    }
}

/// What `benchbar autostart` prints: "autostart is on (bench returns after login if it was running)" or
/// "autostart is off". The CLI has no JSON for it (status --json has no field), so the words are read.
nonisolated enum AutostartText {
    static func parse(_ text: String) -> Bool? {
        for line in text.split(separator: "\n") {
            let words = line.lowercased()
            if words.contains("autostart is on") { return true }
            if words.contains("autostart is off") { return false }
        }
        return nil
    }
}
