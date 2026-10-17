// swift-tools-version: 5.9
// tvOS build of just_audio for flutter-tvos. It compiles the same Objective-C sources as the iOS/macOS plugin
// (symlinked through `Classes`), so the Darwin player, SpectrumTap and equalizer stay in one place.
import PackageDescription

let package = Package(
  name: "just_audio",
  platforms: [
    .tvOS(.v13),
  ],
  products: [
    .library(name: "just-audio", targets: ["just_audio"]),
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
  ],
  targets: [
    .target(
      name: "just_audio",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework"),
      ],
      path: "Classes",
      cSettings: [
        .headerSearchPath("include/just_audio"),
      ],
      linkerSettings: [
        .linkedFramework("Accelerate"),
        .linkedFramework("MediaToolbox"),
      ]
    ),
  ]
)
