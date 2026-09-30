// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "RecitationKit",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [
    .library(name: "RecitationKit", targets: ["RecitationKit"]),
  ],
  targets: [
    .target(name: "RecitationKit"),
    .testTarget(
      name: "RecitationKitTests",
      dependencies: ["RecitationKit"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
