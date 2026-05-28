import Foundation
import Testing
@testable import Chronicle

/// Requirements covered:
/// - 1.4: `sysaudio` and `mic` maintain independent source state.
/// - 10.1: daemon control paths are local-only filesystem paths.
@Suite("Daemon runtime path models")
struct RuntimePathsTests {
  @Test("capture sources have stable wire identifiers")
  func captureSourcesHaveStableWireIdentifiers() throws {
    #expect(CaptureSource.allCases == [.sysaudio, .mic])
    #expect(CaptureSource.sysaudio.rawValue == "sysaudio")
    #expect(CaptureSource.mic.rawValue == "mic")

    let encoded = try JSONEncoder().encode(CaptureSource.sysaudio)
    #expect(String(decoding: encoded, as: UTF8.self) == "\"sysaudio\"")
    #expect(try JSONDecoder().decode(CaptureSource.self, from: Data(#""mic""#.utf8)) == .mic)
  }

  @Test("daemon lifecycle states cover status and ownership projections")
  func daemonLifecycleStatesCoverStatusAndOwnershipProjections() throws {
    #expect(DaemonLifecycle.allCases == [
      .stopped,
      .starting,
      .capturing,
      .reconfiguring,
      .degraded,
      .stopping,
      .escalating,
      .stale,
      .failed,
    ])

    let encoded = try JSONEncoder().encode(DaemonLifecycle.capturing)
    #expect(String(decoding: encoded, as: UTF8.self) == "\"capturing\"")
    #expect(try JSONDecoder().decode(DaemonLifecycle.self, from: Data(#""stale""#.utf8)) == .stale)
  }

  @Test("source runtime paths are deterministic and independent")
  func sourceRuntimePathsAreDeterministicAndIndependent() {
    let root = URL(fileURLWithPath: "/tmp/chronicle-runtime-test", isDirectory: true)
    let sysaudio = RuntimePaths(source: .sysaudio, rootDirectory: root)
    let mic = RuntimePaths(source: .mic, rootDirectory: root)
    let sysaudioAgain = RuntimePaths(source: .sysaudio, rootDirectory: root)

    #expect(sysaudio == sysaudioAgain)
    #expect(sysaudio.sourceDirectory == root.appendingPathComponent("sysaudio", isDirectory: true))
    #expect(mic.sourceDirectory == root.appendingPathComponent("mic", isDirectory: true))

    #expect(sysaudio.socketURL != mic.socketURL)
    #expect(sysaudio.lockURL != mic.lockURL)
    #expect(sysaudio.pidURL != mic.pidURL)
    #expect(sysaudio.logURL != mic.logURL)
  }

  @Test("runtime paths use local file URLs and stable file names")
  func runtimePathsUseLocalFileURLsAndStableFileNames() {
    let root = URL(fileURLWithPath: "/tmp/chronicle-runtime-test", isDirectory: true)

    for source in CaptureSource.allCases {
      let paths = RuntimePaths(source: source, rootDirectory: root)

      #expect(paths.source == source)
      #expect(paths.rootDirectory == root)
      #expect(paths.sourceDirectory.deletingLastPathComponent() == root)
      #expect(paths.sourceDirectory.lastPathComponent == source.rawValue)

      #expect(paths.socketURL.isFileURL)
      #expect(paths.lockURL.isFileURL)
      #expect(paths.pidURL.isFileURL)
      #expect(paths.logURL.isFileURL)
      #expect(paths.socketURL.host == nil)

      #expect(paths.socketURL.lastPathComponent == "control.sock")
      #expect(paths.lockURL.lastPathComponent == "owner.lock")
      #expect(paths.pidURL.lastPathComponent == "owner.pid")
      #expect(paths.logURL.lastPathComponent == "daemon.jsonl")
    }
  }

  @Test("default root prefers absolute XDG_RUNTIME_DIR")
  func defaultRootPrefersAbsoluteXDGRuntimeDirectory() {
    let root = RuntimePaths.defaultRootDirectory(environment: ["XDG_RUNTIME_DIR": "/tmp/chronicle-xdg"])
    #expect(root == URL(fileURLWithPath: "/tmp/chronicle-xdg", isDirectory: true).appendingPathComponent("chronicle", isDirectory: true))
  }

  @Test("default root ignores relative XDG_RUNTIME_DIR")
  func defaultRootIgnoresRelativeXDGRuntimeDirectory() {
    let root = RuntimePaths.defaultRootDirectory(environment: ["XDG_RUNTIME_DIR": "relative/path"])
    #expect(root.isFileURL)
    #expect(root.lastPathComponent.starts(with: "chronicle-"))
    #expect(root.path.hasPrefix(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).path))
  }

  @Test("prepare directories creates local mode 0700 roots")
  func prepareDirectoriesCreatesLocalMode0700Roots() throws {
    let uniqueRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("chronicle-runtime-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: uniqueRoot) }

    let paths = RuntimePaths(source: .sysaudio, rootDirectory: uniqueRoot)
    try paths.prepareDirectories()

    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: paths.sourceDirectory.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)

    let rootAttributes = try FileManager.default.attributesOfItem(atPath: uniqueRoot.path)
    let sourceAttributes = try FileManager.default.attributesOfItem(atPath: paths.sourceDirectory.path)
    #expect(rootAttributes[FileAttributeKey.posixPermissions] as? Int == 0o700)
    #expect(sourceAttributes[FileAttributeKey.posixPermissions] as? Int == 0o700)
  }
}
