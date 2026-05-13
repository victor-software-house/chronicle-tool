// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "chronicle",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "chronicle", targets: ["Chronicle"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
  ],
  targets: [
    .executableTarget(
      name: "Chronicle",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ],
      path: "Sources/Chronicle"
    )
  ]
)
