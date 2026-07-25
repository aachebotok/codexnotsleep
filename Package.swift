// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Methamphetamine",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "MethamphetamineCore", targets: ["MethamphetamineCore"]),
    .library(name: "MethamphetamineUI", targets: ["MethamphetamineUI"]),
    .executable(name: "Methamphetamine", targets: ["MethamphetamineApp"]),
    .executable(name: "MethamphetamineStorybook", targets: ["MethamphetamineStorybook"]),
  ],
  targets: [
    .target(name: "MethamphetamineCore"),
    .target(name: "MethamphetamineUI"),
    .executableTarget(
      name: "MethamphetamineApp",
      dependencies: ["MethamphetamineCore", "MethamphetamineUI"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("IOKit"),
        .linkedFramework("Security"),
        .linkedFramework("ServiceManagement"),
      ]
    ),
    .executableTarget(
      name: "MethamphetamineStorybook",
      dependencies: ["MethamphetamineUI"],
      linkerSettings: [.linkedFramework("AppKit")]
    ),
    .testTarget(name: "MethamphetamineCoreTests", dependencies: ["MethamphetamineCore"]),
    .testTarget(
      name: "MethamphetamineAppTests",
      dependencies: ["MethamphetamineApp", "MethamphetamineCore", "MethamphetamineUI"]),
  ],
  swiftLanguageModes: [.v6]
)
