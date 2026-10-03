import Foundation
@preconcurrency import OnnxRuntimeBindings
import RecitationKit

/// The streaming Zipformer on ONNX Runtime's CPU execution provider (int8
/// ARM64 kernels). Each run's `new_*` outputs become the next run's state
/// inputs as-is, with no copy.
///
/// This is the only file that knows about ONNX Runtime; a Core ML backend can
/// replace it behind `ZipformerBackend`.
final class OnnxZipformerBackend: ZipformerBackend {
  enum Failure: LocalizedError {
    case missingOutput(String)
    var errorDescription: String? {
      switch self { case let .missingOutput(name): "The model did not return \(name)." }
    }
  }

  private let session: ORTSession
  private let io: ZipformerIO
  private let zeroStates: [String: ORTValue]
  private var states: [String: ORTValue]
  private let outputNames: Set<String>
  private let windowShape: [NSNumber]

  /// - Parameter threads: intra-op threads. One: the model runs once per
  ///   480 ms, and with spinning off every parallel section of a second
  ///   thread costs a wake-up, ~6,800 operations per run.
  init(modelPath: String, io: ZipformerIO = .shipped, threads: Int32 = 1) throws {
    let env = try ORTEnv(loggingLevel: .warning)
    let options = try ORTSessionOptions()
    try options.setGraphOptimizationLevel(.all)
    try options.setIntraOpNumThreads(threads)
    // The model runs once per 480 ms; spinning worker threads would only burn battery.
    try options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
    session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)
    self.io = io
    var zeros: [String: ORTValue] = [:]
    for input in io.stateInputs {
      let isInt64 = input.dtype == .int64
      let data = NSMutableData(length: input.elementCount * (isInt64 ? 8 : 4))!  // zero-filled
      zeros[input.name] = try ORTValue(tensorData: data, elementType: isInt64 ? .int64 : .float,
                                       shape: input.dims.map { NSNumber(value: $0) })
    }
    zeroStates = zeros
    states = zeros
    outputNames = Set(["log_probs"] + io.stateInputs.map { "new_\($0.name)" })
    windowShape = [1, io.windowFrames, io.featureDim].map { NSNumber(value: $0) }
  }

  func reset() {
    states = zeroStates
  }

  func run(features: [Float]) throws -> [Float] {
    let x = features.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress!, length: $0.count * MemoryLayout<Float>.size) }
    var inputs = states
    inputs["x"] = try ORTValue(tensorData: x, elementType: .float, shape: windowShape)
    let outputs = try session.run(withInputs: inputs, outputNames: outputNames, runOptions: nil)
    var next: [String: ORTValue] = [:]
    for input in io.stateInputs {
      guard let value = outputs["new_\(input.name)"] else { throw Failure.missingOutput("new_\(input.name)") }
      next[input.name] = value
    }
    guard let logProbs = outputs["log_probs"] else { throw Failure.missingOutput("log_probs") }
    states = next
    let data = try logProbs.tensorData() as Data
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  }
}
