import Foundation
import OnnxRuntimeBindings

/// One ONNX Runtime session on the CPU, fed int64 token tensors of batch size 1.
final class ONNXModel: @unchecked Sendable {
    /// One per process; ONNX Runtime environments are thread-safe.
    nonisolated(unsafe) private static let environment: ORTEnv? = try? ORTEnv(loggingLevel: .warning)

    private let session: ORTSession
    private let inputNames: Set<String>

    init(file: URL, threads: Int = 2) throws {
        guard let environment = Self.environment else { throw RussianStressError.runtime("ONNX Runtime didn’t start") }
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(Int32(threads))
        // Not `.all`: ONNX Runtime 1.24's extended fusions move the stress model's scores by up to 0.1, enough to
        // cross RUAccent's 0.55 threshold on rare words. Basic optimization gives the unoptimized numbers (and the
        // Python reference's marks) at the same speed.
        try options.setGraphOptimizationLevel(.basic)
        session = try ORTSession(env: environment, modelPath: file.path, sessionOptions: options)
        inputNames = Set(try session.inputNames())
    }

    /// Runs the model on one sequence and returns `logits` as floats (row-major) with its shape.
    /// `token_type_ids` (all zero) is passed only to models that take it.
    func logits(inputIDs: [Int]) throws -> (values: [Float], shape: [Int]) {
        let count = inputIDs.count
        var inputs = [
            "input_ids": try Self.tensor(inputIDs.map(Int64.init)),
            "attention_mask": try Self.tensor([Int64](repeating: 1, count: count)),
        ]
        if inputNames.contains("token_type_ids") {
            inputs["token_type_ids"] = try Self.tensor([Int64](repeating: 0, count: count))
        }
        let outputs = try session.run(withInputs: inputs, outputNames: ["logits"], runOptions: nil)
        guard let output = outputs["logits"] else { throw RussianStressError.runtime("no logits") }
        let shape = try output.tensorTypeAndShapeInfo().shape.map(\.intValue)
        let data = try output.tensorData() as Data
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return (values, shape)
    }

    private static func tensor(_ values: [Int64]) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * 8) }
        return try ORTValue(tensorData: data, elementType: .int64, shape: [1, NSNumber(value: values.count)])
    }

    /// Softmax of each row of `width` values.
    static func softmaxRows(_ values: [Float], width: Int) -> [[Float]] {
        stride(from: 0, to: values.count, by: width).map { start in
            let row = values[start ..< start + width]
            let maximum = row.max() ?? 0
            let exps = row.map { exp($0 - maximum) }
            let sum = exps.reduce(0, +)
            return exps.map { $0 / sum }
        }
    }
}
