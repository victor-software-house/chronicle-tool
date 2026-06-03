import ChronicleCore
import ArgumentParser
import ChronicleCore
import CoreGraphics
import ChronicleCore
import Foundation
import ChronicleCore
import ImageIO
import ChronicleCore
import Vision

/// Document-aware OCR using Tahoe's `RecognizeDocumentsRequest` (new in macOS 26 / iOS 26).
/// Falls back to the legacy `RecognizeTextRequest` when document mode is unavailable.
///
/// Both APIs run on-device. Document mode adds table extraction, paragraph
/// structure, and layout-aware reading order — useful for screenshots of code,
/// chat, browsers, and documents.
///
/// References:
/// - https://developer.apple.com/documentation/Vision/RecognizeDocumentsRequest
/// - WWDC25 session 272, "Read documents using the Vision framework"
struct OCR: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ocr",
    abstract: "On-device OCR via Vision RecognizeDocumentsRequest (Tahoe 26+); falls back to RecognizeTextRequest."
  )

  @Option(name: [.long, .customShort("i")], help: "Input image (png/jpg/heic/tiff).")
  var input: String

  @Option(name: [.long, .customShort("o")], help: "Output JSON path.")
  var output: String

  @Flag(name: .long, help: "Force legacy RecognizeTextRequest instead of RecognizeDocumentsRequest.")
  var textOnly: Bool = false

  func run() async throws {
    let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: inputURL.path) else {
      throw ValidationError("Input image does not exist: \(inputURL.path)")
    }

    guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw ValidationError("Could not decode image at: \(inputURL.path)")
    }
    let width = cgImage.width
    let height = cgImage.height
    FileHandle.standardError.write(Data("[ocr] image=\(width)x\(height) mode=\(textOnly ? "text" : "documents")\n".utf8))

    struct Line: Codable {
      let text: String
      let confidence: Double
      let bbox: BBox?
    }
    struct BBox: Codable {
      let x: Double
      let y: Double
      let width: Double
      let height: Double
    }
    struct Doc: Codable {
      let inputPath: String
      let imageWidth: Int
      let imageHeight: Int
      let mode: String
      let elapsedSeconds: Double
      let lineCount: Int
      let plainText: String
      let lines: [Line]
    }

    let started = Date()
    var lines: [Line] = []

    if textOnly {
      var request = RecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      let observations = try await request.perform(on: cgImage)
      for obs in observations {
        guard let candidate = obs.topCandidates(1).first else { continue }
        let bb = obs.boundingBox.cgRect
        lines.append(Line(
          text: candidate.string,
          confidence: Double(candidate.confidence),
          bbox: BBox(
            x: Double(bb.origin.x) * Double(width),
            y: (1.0 - Double(bb.origin.y) - Double(bb.size.height)) * Double(height),
            width: Double(bb.size.width) * Double(width),
            height: Double(bb.size.height) * Double(height)
          )
        ))
      }
    } else {
      var request = RecognizeDocumentsRequest()
      let observations = try await request.perform(on: cgImage)
      for obs in observations {
        let doc = obs.document
        for paragraph in doc.paragraphs {
          for line in paragraph.lines {
            lines.append(Line(
              text: line.transcript,
              confidence: 1.0,
              bbox: nil
            ))
          }
        }
        for table in doc.tables {
          let rowCount = table.rows.count
          let colCount = table.columns.count
          lines.append(Line(text: "--- TABLE \(rowCount)x\(colCount) ---", confidence: 1.0, bbox: nil))
          for r in 0..<rowCount {
            for c in 0..<colCount {
              if let cell = table.cell(row: r, col: c) {
                let txt = cell.content.text.transcript
                if !txt.isEmpty {
                  lines.append(Line(text: "[\(r),\(c)] \(txt)", confidence: 1.0, bbox: nil))
                }
              }
            }
          }
        }
      }
    }

    let elapsed = Date().timeIntervalSince(started)
    let plain = lines.map(\.text).joined(separator: "\n")
    let doc = Doc(
      inputPath: inputURL.path,
      imageWidth: width,
      imageHeight: height,
      mode: textOnly ? "RecognizeTextRequest" : "RecognizeDocumentsRequest",
      elapsedSeconds: elapsed,
      lineCount: lines.count,
      plainText: plain,
      lines: lines
    )

    let outURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(doc).write(to: outURL)

    FileHandle.standardError.write(Data("[ocr] lines=\(lines.count) elapsed=\(String(format: "%.3f", elapsed))s wrote \(outURL.path)\n".utf8))
  }
}
