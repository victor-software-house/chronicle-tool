import ChronicleCore
import ArgumentParser
import ChronicleCore
import CoreGraphics
import ChronicleCore
import Foundation
import ChronicleCore
import FoundationModels
import ChronicleCore
import ImageIO
import ChronicleCore
import Vision

/// Image description via Vision multi-request extraction + Foundation Models
/// prose synthesis.
///
/// Apple does not expose a multimodal image-to-text LLM on Tahoe 26 GA:
/// `LanguageModelSession.respond(...)` takes only text. The canonical
/// pattern is to mine the image with Vision's structured requests
/// (classification, animals, faces, humans, OCR, aesthetics, smudge) and
/// hand the structured facts to `FoundationModels` for natural-language
/// rendering via a `@Generable` struct.
///
/// References:
/// - https://developer.apple.com/documentation/Vision
/// - WWDC25 session 272, "Read documents using the Vision framework"
/// - WWDC25 session 286, "Meet the Foundation Models framework"
struct Describe: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "describe",
    abstract: "Describe an image in prose by chaining Vision requests with a FoundationModels narration step."
  )

  @Option(name: [.long, .customShort("i")], help: "Input image (png/jpg/heic/tiff).")
  var input: String

  @Option(name: [.long, .customShort("o")], help: "Output JSON path (full facts + narration).")
  var output: String?

  @Option(name: .long, help: "Top-K classification labels to keep.")
  var topK: Int = 8

  @Option(name: .long, help: "Confidence threshold for classification + animal labels (0.0-1.0).")
  var threshold: Double = 0.1

  @Flag(name: .long, help: "Skip the FoundationModels narration step (raw Vision facts only).")
  var noNarration: Bool = false

  func run() async throws {
    let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: inputURL.path) else {
      throw ValidationError("Input image does not exist: \(inputURL.path)")
    }
    guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw ValidationError("Could not decode image at: \(inputURL.path)")
    }
    let width = cgImage.width, height = cgImage.height
    FileHandle.standardError.write(Data("[describe] image=\(width)x\(height)\n".utf8))

    let started = Date()

    // ----- Vision: parallel-ish multi-request extraction -----
    async let classify: [Vision.ClassificationObservation] = {
      var req = ClassifyImageRequest()
      return (try? await req.perform(on: cgImage)) ?? []
    }()

    async let animals: [RecognizedObjectObservation] = {
      var req = RecognizeAnimalsRequest()
      return (try? await req.perform(on: cgImage)) ?? []
    }()

    async let faces: [FaceObservation] = {
      var req = DetectFaceRectanglesRequest()
      return (try? await req.perform(on: cgImage)) ?? []
    }()

    async let humans: [HumanObservation] = {
      var req = DetectHumanRectanglesRequest()
      return (try? await req.perform(on: cgImage)) ?? []
    }()

    async let textLines: [String] = {
      var req = RecognizeTextRequest()
      req.recognitionLevel = .accurate
      guard let obs = try? await req.perform(on: cgImage) else { return [] }
      return obs.compactMap { $0.topCandidates(1).first?.string }
    }()

    async let aesthetics: ImageAestheticsScoresObservation? = {
      let req = CalculateImageAestheticsScoresRequest()
      return try? await req.perform(on: cgImage)
    }()

    async let smudge: SmudgeObservation? = {
      let req = DetectLensSmudgeRequest()
      return try? await req.perform(on: cgImage)
    }()

    let visionStarted = Date()
    let classifyR = await classify
    let animalsR = await animals
    let facesR = await faces
    let humansR = await humans
    let textR = await textLines
    let aestheticsR = await aesthetics
    let smudgeR = await smudge
    let visionElapsed = Date().timeIntervalSince(visionStarted)

    let topLabels = classifyR
      .filter { Double($0.confidence) >= threshold }
      .sorted { $0.confidence > $1.confidence }
      .prefix(topK)
      .map { LabelHit(identifier: $0.identifier, confidence: Double($0.confidence)) }

    let animalLabels = animalsR.flatMap { obs in
      obs.labels
        .filter { Double($0.confidence) >= threshold }
        .map { LabelHit(identifier: $0.identifier, confidence: Double($0.confidence)) }
    }

    let facts = ImageFacts(
      width: width,
      height: height,
      topLabels: Array(topLabels),
      animals: animalLabels,
      faceCount: facesR.count,
      humanCount: humansR.count,
      ocrLineCount: textR.count,
      ocrTextSample: textR.prefix(5).joined(separator: " | "),
      aestheticOverall: aestheticsR.map { Double($0.overallScore) },
      aestheticIsUtility: aestheticsR.map { $0.isUtility },
      smudgeConfidence: smudgeR.map { Double($0.confidence) }
    )

    // ----- FoundationModels: prose narration -----
    var narration: ImageNarration? = nil
    var narrationElapsed: Double = 0
    if !noNarration {
      let model = SystemLanguageModel.default
      switch model.availability {
      case .available:
        let session = LanguageModelSession(
          model: model,
          instructions: """
            You write short, faithful descriptions of images based on structured
            facts a computer vision system extracted. Do not invent details the
            facts do not support. Prefer concrete nouns. If something is unclear,
            say so. Keep the caption under 30 words.
            """
        )

        let factsBlob: String = {
          var parts: [String] = []
          parts.append("Image: \(facts.width)x\(facts.height) px.")
          if !facts.topLabels.isEmpty {
            parts.append("Top labels (with confidence): "
              + facts.topLabels.map { "\($0.identifier) (\(String(format: "%.2f", $0.confidence)))" }
                  .joined(separator: ", ") + ".")
          }
          if !facts.animals.isEmpty {
            parts.append("Animals detected: "
              + facts.animals.map { "\($0.identifier) (\(String(format: "%.2f", $0.confidence)))" }
                  .joined(separator: ", ") + ".")
          }
          if facts.faceCount > 0 { parts.append("Faces: \(facts.faceCount).") }
          if facts.humanCount > 0 { parts.append("Humans: \(facts.humanCount).") }
          if facts.ocrLineCount > 0 {
            parts.append("OCR found \(facts.ocrLineCount) text lines; sample: \"\(facts.ocrTextSample)\".")
          }
          if let a = facts.aestheticOverall {
            parts.append("Aesthetic score: \(String(format: "%.2f", a)), utility-image=\(facts.aestheticIsUtility ?? false).")
          }
          if let s = facts.smudgeConfidence, s > 0.5 {
            parts.append("Lens smudge confidence: \(String(format: "%.2f", s)).")
          }
          return parts.joined(separator: " ")
        }()

        let prompt = """
          Facts about the image:
          \(factsBlob)

          Produce a short prose caption and the structured fields requested.
          """

        let nStart = Date()
        do {
          let response = try await session.respond(to: prompt, generating: ChronicleImageNarration.self)
          let n = response.content
          narration = ImageNarration(
            caption: n.caption,
            prominentObjects: n.prominentObjects,
            settingType: n.settingType,
            hasReadableText: n.hasReadableText,
            qualityNotes: n.qualityNotes
          )
          narrationElapsed = Date().timeIntervalSince(nStart)
        } catch {
          FileHandle.standardError.write(Data("[describe] narration error: \(error)\n".utf8))
        }
      case .unavailable(let reason):
        FileHandle.standardError.write(Data("[describe] narration skipped: \(reason)\n".utf8))
      @unknown default:
        break
      }
    }

    let elapsed = Date().timeIntervalSince(started)

    let doc = OutputDoc(
      inputPath: inputURL.path,
      elapsedSeconds: elapsed,
      visionSeconds: visionElapsed,
      narrationSeconds: narrationElapsed,
      facts: facts,
      narration: narration
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(doc)
    if let output {
      try data.write(to: URL(fileURLWithPath: (output as NSString).expandingTildeInPath))
      FileHandle.standardError.write(Data(
        "[describe] vision=\(String(format: "%.2f", visionElapsed))s narrate=\(String(format: "%.2f", narrationElapsed))s total=\(String(format: "%.2f", elapsed))s wrote \(output)\n".utf8
      ))
      if let n = narration {
        print("caption: \(n.caption)")
      }
    } else {
      FileHandle.standardOutput.write(data)
      print()
    }
  }

  struct LabelHit: Codable { let identifier: String; let confidence: Double }

  struct ImageFacts: Codable {
    let width: Int
    let height: Int
    let topLabels: [LabelHit]
    let animals: [LabelHit]
    let faceCount: Int
    let humanCount: Int
    let ocrLineCount: Int
    let ocrTextSample: String
    let aestheticOverall: Double?
    let aestheticIsUtility: Bool?
    let smudgeConfidence: Double?
  }

  struct ImageNarration: Codable {
    let caption: String
    let prominentObjects: [String]
    let settingType: String
    let hasReadableText: Bool
    let qualityNotes: String
  }

  struct OutputDoc: Codable {
    let inputPath: String
    let elapsedSeconds: Double
    let visionSeconds: Double
    let narrationSeconds: Double
    let facts: ImageFacts
    let narration: ImageNarration?
  }
}

@Generable
struct ChronicleImageNarration {
  @Guide(description: "One-sentence prose caption of the image, under 30 words, grounded in the facts.")
  var caption: String
  @Guide(description: "Most prominent objects or subjects in the image (max 6).")
  var prominentObjects: [String]
  @Guide(description: "What kind of scene this is: photograph, screenshot, document, diagram, terminal, browser, code-editor, chat, illustration, other.")
  var settingType: String
  @Guide(description: "True if the image contains readable text.")
  var hasReadableText: Bool
  @Guide(description: "Short note about image quality, focus, or aesthetics; one short sentence.")
  var qualityNotes: String
}
