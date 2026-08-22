// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CodexNotSleep",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "CodexNotSleepCore", targets: ["CodexNotSleepCore"]),
    .executable(name: "CodexNotSleep", targets: ["CodexNotSleepApp"]),
  ],
  targets: [
    .target(name: "CodexNotSleepCore"),
    .executableTarget(
      name: "CodexNotSleepApp",
      dependencies: ["CodexNotSleepCore"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("IOKit"),
        .linkedFramework("Security"),
        .linkedFramework("ServiceManagement"),
      ]
    ),
    .testTarget(name: "CodexNotSleepCoreTests", dependencies: ["CodexNotSleepCore"]),
    .testTarget(
      name: "CodexNotSleepAppTests",
      dependencies: ["CodexNotSleepApp", "CodexNotSleepCore"]),
  ],
  swiftLanguageModes: [.v6]
)
