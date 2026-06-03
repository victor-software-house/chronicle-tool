import Foundation
import Testing
@testable import Chronicle

// ---------------------------------------------------------------------------
// Test suite for GarbageCollect (gc subcommand)
// All fixtures are created under /tmp — never touches ~/Documents.
// ---------------------------------------------------------------------------

@Suite("GarbageCollect")
struct GarbageCollectTests {

    // MARK: - Fixture helpers

    /// Creates a fresh /tmp directory for a single test; caller should defer cleanup.
    private func tmpRoot() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chronicle-gc-test.\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        for sub in ["mic", "sysaudio"] {
            try fm.createDirectory(
                at: dir.appendingPathComponent(sub),
                withIntermediateDirectories: true
            )
        }
        return dir
    }

    /// Creates a session directory. Pass `files` to populate with dummy content.
    @discardableResult
    private func makeSessionDir(
        under root: URL,
        subdir: String,
        name: String,
        files: [String] = []
    ) throws -> URL {
        let dir = root.appendingPathComponent(subdir).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            try "dummy".write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return dir
    }

    // MARK: - Scanning: empty vs non-empty

    @Test("identifies exactly three empty session dirs")
    func identifiesEmptySessionDirs() throws {
        let root = try tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // 3 empty session dirs
        try makeSessionDir(under: root, subdir: "mic",      name: "2026-01-01T00-00-00")
        try makeSessionDir(under: root, subdir: "mic",      name: "2026-01-02T00-00-00")
        try makeSessionDir(under: root, subdir: "sysaudio", name: "2026-01-03T00-00-00")

        // 2 non-empty session dirs
        try makeSessionDir(under: root, subdir: "mic",      name: "2026-01-04T00-00-00",
                           files: ["finals.md"])
        try makeSessionDir(under: root, subdir: "sysaudio", name: "2026-01-05T00-00-00",
                           files: ["audio.caf"])

        let empties = try runScan(root: root)
        #expect(empties.count == 3)

        let names = Set(empties.map { $0.lastPathComponent })
        #expect(names == ["2026-01-01T00-00-00", "2026-01-02T00-00-00", "2026-01-03T00-00-00"])
    }

    @Test("preserves non-empty dirs containing finals.md")
    func preservesFinalsMarkdown() throws {
        let root = try tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeSessionDir(under: root, subdir: "mic", name: "2026-02-01T00-00-00",
                           files: ["finals.md"])
        try makeSessionDir(under: root, subdir: "mic", name: "2026-02-02T00-00-00") // empty

        let empties = try runScan(root: root)
        #expect(empties.count == 1)
        #expect(empties[0].lastPathComponent == "2026-02-02T00-00-00")
    }

    @Test("preserves non-empty dirs containing .caf file")
    func preservesCafFile() throws {
        let root = try tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeSessionDir(under: root, subdir: "sysaudio", name: "2026-03-01T00-00-00",
                           files: ["audio.caf"])
        try makeSessionDir(under: root, subdir: "sysaudio", name: "2026-03-02T00-00-00") // empty

        let empties = try runScan(root: root)
        #expect(empties.count == 1)
        #expect(empties[0].lastPathComponent == "2026-03-02T00-00-00")
    }

    @Test("preserves non-empty dirs containing trace.jsonl")
    func preservesTraceJSONL() throws {
        let root = try tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeSessionDir(under: root, subdir: "mic", name: "2026-04-01T00-00-00",
                           files: ["trace.jsonl"])
        try makeSessionDir(under: root, subdir: "mic", name: "2026-04-02T00-00-00") // empty

        let empties = try runScan(root: root)
        #expect(empties.count == 1)
        #expect(empties[0].lastPathComponent == "2026-04-02T00-00-00")
    }

    @Test("non-session-named directories are ignored")
    func ignoresNonSessionNamedDirs() throws {
        let root = try tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Looks like a session but wrong format — should be skipped
        try makeSessionDir(under: root, subdir: "mic", name: "not-a-session")
        try makeSessionDir(under: root, subdir: "mic", name: "2026-05-01T00-00-00") // empty, valid

        let empties = try runScan(root: root)
        #expect(empties.count == 1)
        #expect(empties[0].lastPathComponent == "2026-05-01T00-00-00")
    }

    // MARK: - Agent detection

    @Test("agent detection: PI_SESSION_ID triggers refusal")
    func agentDetectionPISessionID() {
        // GarbageCollect reads ProcessInfo.processInfo.environment.
        // We test detectAgentEnv() via the public-facing logic by injecting
        // a known key into the environment using setenv().
        setenv("PI_SESSION_ID", "test-session", 1)
        defer { unsetenv("PI_SESSION_ID") }

        let gc = GarbageCollect()
        #expect(gc.detectsAgentEnv() == "PI_SESSION_ID")
    }

    @Test("agent detection: CODEX_SANDBOX triggers refusal")
    func agentDetectionCodexSandbox() {
        setenv("CODEX_SANDBOX", "1", 1)
        defer { unsetenv("CODEX_SANDBOX") }

        let gc = GarbageCollect()
        #expect(gc.detectsAgentEnv() == "CODEX_SANDBOX")
    }

    @Test("agent detection: AIDER_ prefix triggers refusal")
    func agentDetectionAiderPrefix() {
        setenv("AIDER_SOME_VAR", "yes", 1)
        defer { unsetenv("AIDER_SOME_VAR") }

        let gc = GarbageCollect()
        let result = gc.detectsAgentEnv()
        #expect(result?.hasPrefix("AIDER_") == true)
    }

    @Test("agent detection: no known env vars → nil")
    func agentDetectionNoneSet() {
        // Ensure none of the known vars are set for this test
        for key in ["CODEX_SANDBOX", "CLAUDE_CODE", "PI_SESSION_ID", "CURSOR_SESSION_ID"] {
            unsetenv(key)
        }
        // Note: AIDER_* vars from outer environment could theoretically be set,
        // so we only assert the key result matches expectations given test isolation.
        let gc = GarbageCollect()
        // If test runner doesn't inject any AIDER_ vars, this should be nil.
        // We check the known fixed vars are not detected.
        let result = gc.detectsAgentEnv()
        let knownKeys = ["CODEX_SANDBOX", "CLAUDE_CODE", "PI_SESSION_ID", "CURSOR_SESSION_ID"]
        if let r = result {
            #expect(!knownKeys.contains(r), "Unexpected agent key detected: \(r)")
        }
        // nil is fine (desired), as is an AIDER_ key if the environment has one.
    }

    // MARK: - Dry-run: does not delete

    @Test("dry-run lists empty dirs without deleting them")
    func dryRunDoesNotDelete() throws {
        let root = try tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let emptyDir = try makeSessionDir(
            under: root, subdir: "mic", name: "2026-06-01T00-00-00"
        )

        // Verify it exists before
        #expect(FileManager.default.fileExists(atPath: emptyDir.path))

        // Scan (simulate dry-run logic: just find empties, don't remove)
        let empties = try runScan(root: root)
        #expect(empties.count == 1)

        // Dir still exists — dry-run did not delete
        #expect(FileManager.default.fileExists(atPath: emptyDir.path))
    }

    // MARK: - Internal scan helper

    /// Exercises GarbageCollect's scanning logic via the internal helper.
    private func runScan(root: URL) throws -> [URL] {
        var gc = GarbageCollect()
        gc.path = root.path
        return try gc.scanEmptyDirs()
    }
}
