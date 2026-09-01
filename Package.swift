// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "PromptIterationAssistant",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "PromptIterationCore", targets: ["PromptIterationCore"]),
    .executable(name: "PromptIterationAssistant", targets: ["PromptIterationAssistant"]),
    .executable(name: "PromptIterationCoreChecks", targets: ["PromptIterationCoreChecks"]),
  ],
  targets: [
    .target(
      name: "PromptIterationCore",
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .executableTarget(
      name: "PromptIterationAssistant",
      dependencies: ["PromptIterationCore"]
    ),
    .executableTarget(
      name: "PromptIterationCoreChecks",
      dependencies: ["PromptIterationCore"]
    ),
  ],
  swiftLanguageModes: [.v5]
)
