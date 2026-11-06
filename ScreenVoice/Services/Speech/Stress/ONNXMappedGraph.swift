import Foundation

/// Lets ONNX Runtime memory-map a model's weights instead of copying them.
///
/// RUAccent's models keep their weights inside `model.onnx`, which ONNX Runtime reads into its own heap
/// (~3× the file for the stress-usage BERT: protobuf, tensors and packed copies), ~800 MB for the pack. Weights
/// stored as *external data* are memory-mapped instead: clean, file-backed pages the system can drop and reload.
/// The same arithmetic runs either way.
///
/// The pinned `model.onnx` stays untouched (its size and digest are what the pack is verified by). Next to it we
/// write `model.mapped.onnx`, a copy of the graph without the weight bytes whose tensors point back into
/// `model.onnx` by offset, so no weights are duplicated on disk.
enum ONNXMappedGraph {
    /// Tensors smaller than this stay inline.
    static let minimumExternalBytes = 1024

    /// The mapped graph for `model`, written on first use. Nil if the file can't be converted.
    static func graph(for model: URL) -> URL? {
        let mapped = model.deletingPathExtension().appendingPathExtension("mapped.onnx")
        if FileManager.default.fileExists(atPath: mapped.path) { return mapped }
        do {
            let source = try Data(contentsOf: model, options: .alwaysMapped)
            let graph = try rewriteModel(source, weightsFile: model.lastPathComponent)
            let partial = mapped.appendingPathExtension("partial")
            try graph.write(to: partial)
            _ = try FileManager.default.replaceItemAt(mapped, withItemAt: partial)
            return mapped
        } catch {
            return nil
        }
    }

    enum Failure: Error { case malformed }

    // MARK: Protobuf rewriting

    // Field numbers from onnx.proto.
    private static let modelGraph = 7         // ModelProto.graph
    private static let graphInitializer = 5   // GraphProto.initializer
    private static let tensorRawData = 9      // TensorProto.raw_data
    private static let tensorExternalData = 13
    private static let tensorDataLocation = 14

    /// `ModelProto` with every large initializer's `raw_data` replaced by a reference to `weightsFile`.
    static func rewriteModel(_ data: Data, weightsFile: String) throws -> Data {
        try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var converted = 0
            let out = try rewrite(bytes, 0 ..< bytes.count) { field, payload in
                guard field == modelGraph else { return nil }
                return try rewrite(bytes, payload) { field, payload in
                    guard field == graphInitializer else { return nil }
                    let tensor = try externalTensor(bytes, payload, weightsFile: weightsFile)
                    if tensor != nil { converted += 1 }
                    return tensor
                }
            }
            guard converted > 0 else { throw Failure.malformed }
            return out
        }
    }

    /// Copies the message in `range` without field `dropped`, replacing length-delimited fields for which
    /// `transform` returns bytes.
    private static func rewrite(
        _ bytes: UnsafeBufferPointer<UInt8>,
        _ range: Range<Int>,
        dropping dropped: Int? = nil,
        transform: (Int, Range<Int>) throws -> Data? = { _, _ in nil }
    ) throws -> Data {
        var out = Data()
        out.reserveCapacity(min(range.count, 1 << 20))
        var i = range.lowerBound
        while i < range.upperBound {
            let fieldStart = i
            let key = try varint(bytes, &i, end: range.upperBound)
            let field = Int(key >> 3)
            switch key & 7 {
            case 0: _ = try varint(bytes, &i, end: range.upperBound)
            case 1: i += 8
            case 5: i += 4
            case 2:
                let length = Int(try varint(bytes, &i, end: range.upperBound))
                let payload = i ..< i + length
                i += length
                guard i <= range.upperBound else { throw Failure.malformed }
                if let replaced = try transform(field, payload) {
                    appendField(&out, field: field, payload: replaced)
                    continue
                }
            default: throw Failure.malformed
            }
            guard i <= range.upperBound else { throw Failure.malformed }
            if field != dropped {
                out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[fieldStart ..< i]))
            }
        }
        return out
    }

    /// The `TensorProto` in `range` with its raw data external, or nil to keep it as it is.
    private static func externalTensor(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, weightsFile: String) throws -> Data? {
        var rawData: Range<Int>?
        var i = range.lowerBound
        while i < range.upperBound {
            let key = try varint(bytes, &i, end: range.upperBound)
            let field = Int(key >> 3)
            if field == tensorExternalData || field == tensorDataLocation { return nil }
            switch key & 7 {
            case 0: _ = try varint(bytes, &i, end: range.upperBound)
            case 1: i += 8
            case 5: i += 4
            case 2:
                let length = Int(try varint(bytes, &i, end: range.upperBound))
                if field == tensorRawData { rawData = i ..< i + length }
                i += length
            default: throw Failure.malformed
            }
        }
        guard let rawData, rawData.count >= minimumExternalBytes else { return nil }

        var out = try rewrite(bytes, range, dropping: tensorRawData)
        for (key, value) in [("location", weightsFile), ("offset", String(rawData.lowerBound)), ("length", String(rawData.count))] {
            var entry = Data()
            appendField(&entry, field: 1, payload: Data(key.utf8))
            appendField(&entry, field: 2, payload: Data(value.utf8))
            appendField(&out, field: tensorExternalData, payload: entry)
        }
        appendVarint(&out, UInt64(tensorDataLocation << 3))  // wire type 0
        appendVarint(&out, 1)                                // EXTERNAL
        return out
    }

    private static func varint(_ bytes: UnsafeBufferPointer<UInt8>, _ i: inout Int, end: Int) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while i < end, shift < 64 {
            let byte = bytes[i]
            i += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        throw Failure.malformed
    }

    private static func appendVarint(_ out: inout Data, _ value: UInt64) {
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    private static func appendField(_ out: inout Data, field: Int, payload: Data) {
        appendVarint(&out, UInt64(field << 3 | 2))
        appendVarint(&out, UInt64(payload.count))
        out.append(payload)
    }
}
