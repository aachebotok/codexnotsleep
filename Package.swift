// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Methamphetamine",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "MethamphetamineCore", targets: ["MethamphetamineCore"]),
    .executable(name: "Methamphetamine", targets: ["MethamphetamineApp"]),
  ],
  targets: [
    .target(name: "MethamphetamineCore"),
    .executableTarget(
      name: "MethamphetamineApp",
      dependencies: ["MethamphetamineCore"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("IOKit"),
        .linkedFramework("Security"),
        .linkedFramework("ServiceManagement"),
      ]
    ),
    .testTarget(name: "MethamphetamineCoreTests", dependencies: ["MethamphetamineCore"]),
    .testTarget(
      name: "MethamphetamineAppTests", dependencies: ["MethamphetamineApp", "MethamphetamineCore"]),
  ],
  swiftLanguageModes: [.v6]
)
