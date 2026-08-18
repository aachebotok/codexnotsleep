// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CodexNotSleep",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "CodexNotSleepCore", targets: ["CodexNotSleepCore"]),
    .library(name: "CodexNotSleepUI", targets: ["CodexNotSleepUI"]),
    .executable(name: "CodexNotSleep", targets: ["CodexNotSleepApp"]),
    .executable(name: "CodexNotSleepStorybook", targets: ["CodexNotSleepStorybook"]),
  ],
  targets: [
    .target(name: "CodexNotSleepCore"),
    .target(name: "CodexNotSleepUI"),
    .executableTarget(
      name: "CodexNotSleepApp",
      dependencies: ["CodexNotSleepCore", "CodexNotSleepUI"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("IOKit"),
        .linkedFramework("Security"),
        .linkedFramework("ServiceManagement"),
      ]
    ),
    .executableTarget(
      name: "CodexNotSleepStorybook",
      dependencies: ["CodexNotSleepUI"],
      linkerSettings: [.linkedFramework("AppKit")]
    ),
    .testTarget(name: "CodexNotSleepCoreTests", dependencies: ["CodexNotSleepCore"]),
    .testTarget(
      name: "CodexNotSleepAppTests",
      dependencies: ["CodexNotSleepApp", "CodexNotSleepCore", "CodexNotSleepUI"]),
  ],
  swiftLanguageModes: [.v6]
)
