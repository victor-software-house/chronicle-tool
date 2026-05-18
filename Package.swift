// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "chronicle",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "chronicle", targets: ["Chronicle"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.14.5"),
    .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.16.0")
  ],
  targets: [
    .executableTarget(
      name: "Chronicle",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "FluidAudio", package: "FluidAudio"),
        .product(name: "WhisperKit", package: "WhisperKit")
      ],
      path: "Sources/Chronicle",
      linkerSettings: [
        // Embed Info.plist so the OS treats us as a real app for TCC dialogs.
        // Required for NSMicrophoneUsageDescription to be presented.
        .unsafeFlags([
          "-Xlinker", "-sectcreate",
          "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist",
          "-Xlinker", "Info.plist"
        ])
      ]
    ),
    .testTarget(
      name: "ChronicleTests",
      dependencies: ["Chronicle"],
      path: "Tests/ChronicleTests"
    )
  ]
)
