import Foundation
import Testing
@testable import ScreenVoice

/// The mapped graph must give ONNX Runtime the same weights, read from the original file by offset.
@Suite("ONNX mapped weights")
struct ONNXMappedGraphTests {
    /// A tiny token model shaped like RUAccent's: `logits = Gather(table, input_ids)`, with a 512 × 2 float table
    /// (4 KB, so it goes external) and a 2-float bias that stays inline.
    private static func model(table: [Float]) -> Data {
        func varint(_ value: UInt64) -> Data {
            var v = value, out = Data()
            while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
            out.append(UInt8(v))
            return out
        }
        func field(_ number: Int, _ payload: Data) -> Data { varint(UInt64(number << 3 | 2)) + varint(UInt64(payload.count)) + payload }
        func field(_ number: Int, _ text: String) -> Data { field(number, Data(text.utf8)) }
        func field(_ number: Int, int value: Int) -> Data { varint(UInt64(number << 3)) + varint(UInt64(value)) }
        func floats(_ values: [Float]) -> Data { values.withUnsafeBufferPointer { Data(buffer: $0) } }
        func tensor(_ name: String, dims: [Int], _ values: [Float]) -> Data {
            dims.map { field(1, int: $0) }.reduce(Data(), +) + field(2, int: 1) + field(8, name) + field(9, floats(values))
        }
        func valueInfo(_ name: String, type: Int, dims: [String]) -> Data {
            let shape = dims.map { field(1, field(2, $0)) }.reduce(Data(), +)
            return field(1, name) + field(2, field(1, field(1, int: type) + field(2, shape)))
        }
        let graph = field(1, field(1, "table") + field(1, "input_ids") + field(2, "gathered") + field(4, "Gather"))
            + field(1, field(1, "gathered") + field(1, "bias") + field(2, "logits") + field(4, "Add"))
            + field(2, "g")
            + field(5, tensor("table", dims: [512, 2], table))
            + field(5, tensor("bias", dims: [2], [0.5, -0.5]))
            + field(11, valueInfo("input_ids", type: 7, dims: ["batch", "sequence"]))
            + field(11, valueInfo("attention_mask", type: 7, dims: ["batch", "sequence"]))
            + field(12, valueInfo("logits", type: 1, dims: ["batch", "sequence", "labels"]))
        return field(1, int: 8) + field(8, field(2, int: 13)) + field(7, graph)
    }

    @Test func runtimeReadsTheWeightsFromTheOriginalFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "mapped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let table = (0 ..< 1024).map { Float($0) * 0.25 }
        let file = directory.appending(path: "model.onnx")
        try Self.model(table: table).write(to: file)

        let model = try ONNXModel(file: file)
        #expect(model.mapsWeights)
        let mapped = directory.appending(path: "model.mapped.onnx")
        let mappedSize = try #require(try FileManager.default.attributesOfItem(atPath: mapped.path)[.size] as? Int)
        #expect(mappedSize < 1024, "the table should not be copied into the graph (\(mappedSize) bytes)")

        let (values, shape) = try model.logits(inputIDs: [3, 511, 0])
        #expect(shape == [1, 3, 2])
        #expect(values == [table[6] + 0.5, table[7] - 0.5, table[1022] + 0.5, table[1023] - 0.5, table[0] + 0.5, table[1] - 0.5])

        // The next load reuses the graph; a damaged one is replaced by the original's weights.
        #expect(try ONNXModel(file: file).mapsWeights)
        try Data("not a model".utf8).write(to: mapped)
        let fallback = try ONNXModel(file: file)
        #expect(!fallback.mapsWeights)
        #expect(try fallback.logits(inputIDs: [3]).values == [table[6] + 0.5, table[7] - 0.5])
        #expect(try ONNXModel(file: file).mapsWeights)
    }

    @Test func refusesFilesWithoutLargeWeights() {
        #expect(throws: ONNXMappedGraph.Failure.self) {
            try ONNXMappedGraph.rewriteModel(Data([0x08, 0x08]), weightsFile: "model.onnx")
        }
        #expect(throws: ONNXMappedGraph.Failure.self) {
            try ONNXMappedGraph.rewriteModel(Data([0x3A, 0x7F, 0x01]), weightsFile: "model.onnx")
        }
    }
}
