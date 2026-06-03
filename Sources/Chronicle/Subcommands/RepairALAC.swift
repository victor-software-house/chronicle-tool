import ArgumentParser
import ChronicleCore
import Foundation

struct RepairALAC: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repair-alac",
        abstract: "Repair broken ALAC CAF files missing the pakt chunk (Tahoe regression)."
    )

    @Argument(help: "One or more .caf file paths to repair.")
    var files: [String]

    @Option(help: "Output directory for repaired files (default: same as input).")
    var outputDir: String?

    @Flag(help: "Overwrite input files in place.")
    var inPlace = false

    func run() async throws {
        var repaired = 0
        var skipped = 0
        var failed = 0

        for path in files {
            let inputURL = URL(fileURLWithPath: path)
            let name = inputURL.lastPathComponent
            guard FileManager.default.fileExists(atPath: path) else {
                FileHandle.standardError.write(Data("[repair-alac] not found: \(path)\n".utf8))
                failed += 1
                continue
            }

            // Determine output URL
            let outURL: URL
            if inPlace {
                // Write to temp, then replace
                outURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("repair-\(UUID().uuidString).caf")
            } else if let dir = outputDir {
                let dirURL = URL(fileURLWithPath: dir)
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                let stem = inputURL.deletingPathExtension().lastPathComponent
                outURL = dirURL.appendingPathComponent("\(stem)-repaired.caf")
            } else {
                let stem = inputURL.deletingPathExtension().lastPathComponent
                outURL = inputURL.deletingLastPathComponent()
                    .appendingPathComponent("\(stem)-repaired.caf")
            }

            do {
                let result = try await ALACRepairService.repair(
                    inputURL: inputURL,
                    outputURL: outURL
                )

                if inPlace {
                    try FileManager.default.removeItem(at: inputURL)
                    try FileManager.default.moveItem(at: outURL, to: inputURL)
                    print("✔ \(name): \(result.totalFrames) frames, \(String(format: "%.1f", result.duration))s (in-place)")
                } else {
                    print("✔ \(name) → \(outURL.lastPathComponent): \(result.totalFrames) frames, \(String(format: "%.1f", result.duration))s")
                }
                repaired += 1
            } catch ALACRepairService.RepairError.alreadyValid {
                print("· \(name): already valid, skipped")
                skipped += 1
            } catch {
                FileHandle.standardError.write(Data("[repair-alac] \(name): \(error)\n".utf8))
                failed += 1
            }
        }

        print("\nRepaired: \(repaired)  Skipped: \(skipped)  Failed: \(failed)")
        if failed > 0 {
            throw ExitCode.failure
        }
    }
}
