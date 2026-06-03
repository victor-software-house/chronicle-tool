import ArgumentParser
import Darwin
import Foundation

/// Scans session directories under the chronicle root and removes empty ones
/// (i.e., dirs that contain no audio or transcript artefacts).
///
/// Safety rails:
/// - Agent-detection: refuses to delete when running non-interactively unless `--force`.
/// - Dry-run mode: lists candidates without touching disk.
/// - Final confirmation gate: user must type "DELETE" before any removal.
struct GarbageCollect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gc",
        abstract: "Remove empty session directories left by failed recording starts."
    )

    @Option(help: "Root directory to scan (default: ~/Documents/chronicle).")
    var path: String?

    @Flag(help: "Preview what would be removed without deleting.")
    var dryRun = false

    @Flag(help: "Skip per-directory prompts (still shows final confirmation gate).")
    var yes = false

    @Flag(help: "Bypass agent detection and non-interactive checks.")
    var force = false

    // MARK: - Entry

    func run() throws {
        let root = resolvedRoot()

        if !force {
            try checkNotAgentContext()
        }

        let emptyDirs = try findEmptySessionDirs(under: root)

        if emptyDirs.isEmpty {
            print("No empty session directories found under \(root.path).")
            return
        }

        print("Empty session directories (\(emptyDirs.count)):")
        for dir in emptyDirs {
            print("  \(dir.path)")
        }

        if dryRun {
            print("\n[dry-run] No files deleted.")
            return
        }

        print("\nType DELETE to confirm removal (Ctrl-C to abort):", terminator: " ")
        guard let input = readLine(strippingNewline: true), input == "DELETE" else {
            print("\nAborted — nothing deleted.")
            return
        }

        var removed = 0
        var errors: [String] = []
        for dir in emptyDirs {
            do {
                try FileManager.default.removeItem(at: dir)
                print("Removed: \(dir.path)")
                removed += 1
            } catch {
                errors.append("\(dir.path): \(error.localizedDescription)")
            }
        }

        print("\nDone. Removed \(removed)/\(emptyDirs.count) directories.")
        if !errors.isEmpty {
            fputs("Errors:\n", stderr)
            for e in errors { fputs("  \(e)\n", stderr) }
        }
    }

    // MARK: - Helpers

    func resolvedRoot() -> URL {
        if let p = path {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/chronicle")
    }

    /// Walk `{root}/mic/` and `{root}/sysaudio/` for session dirs.
    /// Exposed as `internal` for testing.
    func scanEmptyDirs() throws -> [URL] {
        return try findEmptySessionDirs(under: resolvedRoot())
    }

    private func findEmptySessionDirs(under root: URL) throws -> [URL] {
        let fm = FileManager.default
        let subdirs = ["mic", "sysaudio"].map { root.appendingPathComponent($0) }
        var empties: [URL] = []

        for subdir in subdirs {
            guard fm.fileExists(atPath: subdir.path) else { continue }
            let entries = try fm.contentsOfDirectory(
                at: subdir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for entry in entries {
                guard isSessionDir(entry) else { continue }
                if try isEmptySessionDir(entry) {
                    empties.append(entry)
                }
            }
        }
        return empties.sorted { $0.path < $1.path }
    }

    /// Session dirs match `YYYY-MM-DDTHH-MM-SS` (19-char basename).
    private func isSessionDir(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.count == 19 else { return false }
        // Quick structural check: YYYY-MM-DDTHH-MM-SS
        let chars = Array(name)
        let dashes: Set<Int> = [4, 7, 13, 16]
        let tPos = 10
        for i in dashes where chars[i] != "-" { return false }
        guard chars[tPos] == "T" else { return false }
        return true
    }

    /// A session dir is empty when it contains zero artefact files.
    private func isEmptySessionDir(_ dir: URL) throws -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        let artefactExtensions: Set<String> = ["caf", "wav", "pcm"]
        let artefactNames: Set<String> = [
            "finals.md", "trace.jsonl", "live.log", "live.md", "format.json"
        ]

        let entries = try fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            let name = entry.lastPathComponent
            let ext  = entry.pathExtension.lowercased()
            if artefactExtensions.contains(ext) { return false }
            if artefactNames.contains(name)      { return false }
        }
        return true
    }

    // MARK: - Agent detection

    func checkNotAgentContext() throws {
        let nonInteractive = Darwin.isatty(STDIN_FILENO) == 0
        let agentEnv       = detectsAgentEnv()

        if nonInteractive || agentEnv != nil {
            let reason = agentEnv.map { "env var \($0) is set" }
                ?? "stdin is not a TTY (non-interactive)"
            fputs(
                """
                [gc] Refusing to delete in agent/non-interactive context (\(reason)).
                     Re-run with --force to override, or run interactively in a terminal.
                     Note: permanent deletion in automated contexts is a safety hazard.

                """,
                stderr
            )
            throw ExitCode(1)
        }
    }

    /// Returns the first matching agent env var name, or nil if none set.
    /// Exposed as `internal` for testing.
    func detectsAgentEnv() -> String? {
        let env = ProcessInfo.processInfo.environment
        let knownKeys = ["CODEX_SANDBOX", "CLAUDE_CODE", "PI_SESSION_ID", "CURSOR_SESSION_ID"]
        for key in knownKeys {
            if env[key] != nil { return key }
        }
        // Any AIDER_* prefix
        for key in env.keys where key.hasPrefix("AIDER_") {
            return key
        }
        return nil
    }
}
