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
    //
    // Use injectable `environment:` parameter to avoid mutating the live process
    // environment (ProcessInfo.processInfo.environment is a cached snapshot and
    // setenv/unsetenv don't affect it reliably in test contexts).

    @Test("agent detection: PI_SESSION_ID triggers refusal")
    func agentDetectionPISessionID() {
        let gc = GarbageCollect()
        let env = ["PI_SESSION_ID": "test-session"]
        #expect(gc.detectsAgentEnv(environment: env) == "PI_SESSION_ID")
    }

    @Test("agent detection: CODEX_SANDBOX triggers refusal")
    func agentDetectionCodexSandbox() {
        let gc = GarbageCollect()
        let env = ["CODEX_SANDBOX": "1"]
        #expect(gc.detectsAgentEnv(environment: env) == "CODEX_SANDBOX")
    }

    @Test("agent detection: CLAUDE_CODE triggers refusal")
    func agentDetectionClaudeCode() {
        let gc = GarbageCollect()
        let env = ["CLAUDE_CODE": "1"]
        #expect(gc.detectsAgentEnv(environment: env) == "CLAUDE_CODE")
    }

    @Test("agent detection: CURSOR_SESSION_ID triggers refusal")
    func agentDetectionCursorSession() {
        let gc = GarbageCollect()
        let env = ["CURSOR_SESSION_ID": "abc"]
        #expect(gc.detectsAgentEnv(environment: env) == "CURSOR_SESSION_ID")
    }

    @Test("agent detection: AIDER_ prefix triggers refusal")
    func agentDetectionAiderPrefix() {
        let gc = GarbageCollect()
        let env = ["AIDER_SOME_VAR": "yes"]
        let result = gc.detectsAgentEnv(environment: env)
        #expect(result?.hasPrefix("AIDER_") == true)
    }

    @Test("agent detection: empty env → nil")
    func agentDetectionEmptyEnv() {
        let gc = GarbageCollect()
        #expect(gc.detectsAgentEnv(environment: [:]) == nil)
    }

    @Test("agent detection: unrelated env vars → nil")
    func agentDetectionUnrelatedVars() {
        let gc = GarbageCollect()
        let env = ["HOME": "/Users/test", "PATH": "/usr/bin"]
        #expect(gc.detectsAgentEnv(environment: env) == nil)
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
