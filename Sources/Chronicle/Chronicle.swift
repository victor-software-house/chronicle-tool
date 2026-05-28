import ArgumentParser
import Foundation

@main
struct Chronicle: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "chronicle",
    abstract: "Tahoe Neural Engine speech, ML, vision, and LLM toolkit for the chronicle project.",
    version: "0.1.0",
    subcommands: [
      Transcribe.self,
      Live.self,
      Mic.self,
      SysAudio.self,
      Classify.self,
      Tag.self,
      Summarize.self,
      Translate.self,
      OCR.self,
      Describe.self,
      Diarize.self,
      EncodeOpus.self,
      EncodeALAC.self,
      ScratchExport.self,
      Merge.self,
      DaemonRun.self,
      DaemonStart.self,
      DaemonStop.self,
      DaemonStatusCommand.self,
      DaemonTail.self,
      DaemonMark.self,
      DaemonClip.self,
      DaemonConfig.self
    ],
    defaultSubcommand: nil
  )
}
