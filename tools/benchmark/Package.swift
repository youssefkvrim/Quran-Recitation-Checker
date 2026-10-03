// swift-tools-version: 6.0
// The full recognition chain on real recordings: Swift fbank, windowing and
// session; ONNX Runtime (Python) for the model. See tools/benchmark/run.sh.
import PackageDescription

let package = Package(
  name: "Benchmark",
  platforms: [.macOS(.v14)],
  dependencies: [.package(path: "../../RecitationKit")],
  targets: [.executableTarget(name: "Benchmark", dependencies: ["RecitationKit"])]
)
