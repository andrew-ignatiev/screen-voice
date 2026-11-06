import Foundation
import MLX
import MLXNN

/// siriusfreak's Russian stress LoRA for Qwen3-TTS 1.7B Base (r 16 on the talker's attention and MLP): with it
/// the model follows U+0301 stress marks; without it the marks garble words.
///
/// The adapter is applied at run time, `y = W₈x + (α/r)·B·A·x`, rather than merged: merging into the 8-bit
/// weights means re-quantizing them, which adds ~50% more weight error than this (measured against the exact
/// bf16 merge, whose 8-bit version is what the listening test used).
enum StressLoRA {
    private struct Config: Decodable {
        let r: Int
        let alpha: Double
        let appliedTo: String

        enum CodingKeys: String, CodingKey {
            case r, alpha
            case appliedTo = "applied_to"
        }
    }

    /// Wraps every adapted projection of `model`'s talker. Returns the number of wrapped layers.
    @discardableResult
    static func apply(to model: Module, adapterDirectory: URL) throws -> Int {
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: adapterDirectory.appending(path: "adapter.json")))
        guard config.appliedTo == "talker.model", config.r > 0 else {
            throw RussianStressError.badFile("adapter.json")
        }
        let scale = Float(config.alpha / Double(config.r))
        let tensors = try loadArrays(url: adapterDirectory.appending(path: "adapter.safetensors"))
        let modules = Dictionary(model.namedModules(), uniquingKeysWith: { first, _ in first })

        let suffix = ".lora_A.weight"
        var wrapped = 0
        for key in tensors.keys.sorted() where key.hasSuffix(suffix) {
            let name = String(key.dropLast(suffix.count))
            let path = config.appliedTo + "." + name
            var components = path.split(separator: ".").map(String.init)
            let child = components.removeLast()
            guard let down = tensors[key], let up = tensors[name + ".lora_B.weight"],
                  let parent = modules[components.joined(separator: ".")],
                  let base = modules[path] as? QuantizedLinear,
                  down.ndim == 2, up.ndim == 2, down.dim(0) == config.r, up.dim(1) == config.r,
                  up.dim(0) == base.shape.0, down.dim(1) == base.shape.1
            else {
                throw RussianStressError.badFile("adapter.safetensors (\(name))")
            }
            let layer = LoRAQuantizedLinear(base: base, down: down, up: up, scale: scale)
            try parent.update(modules: ModuleChildren.unflattened([(child, layer)]), verify: .noUnusedKeys)
            wrapped += 1
        }
        guard wrapped > 0 else { throw RussianStressError.badFile("adapter.safetensors") }
        return wrapped
    }
}

/// A quantized projection plus a low-rank update.
final class LoRAQuantizedLinear: QuantizedLinear {
    /// Aᵀ, [in, r].
    let loraDown: MLXArray
    /// (α/r)·Bᵀ, [r, out].
    let loraUp: MLXArray

    init(base: QuantizedLinear, down: MLXArray, up: MLXArray, scale: Float) {
        let dtype = base.scales.dtype
        loraDown = down.transposed().asType(dtype)
        loraUp = (up.transposed().asType(.float32) * scale).asType(dtype)
        super.init(
            weight: base.weight, bias: base.bias, scales: base.scales, biases: base.biases,
            groupSize: base.groupSize, bits: base.bits, mode: base.mode
        )
        freeze()
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        super.callAsFunction(x) + matmul(matmul(x, loraDown), loraUp)
    }
}
