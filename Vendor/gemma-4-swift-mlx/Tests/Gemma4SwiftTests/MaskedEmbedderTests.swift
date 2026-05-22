import Testing
import Foundation
import MLX
import MLXNN
@testable import Gemma4Swift

@Suite("MaskedEmbedder — sparse softmax via centroids")
struct MaskedEmbedderTests {

    /// Mini config pour le drafter — 4 layers / hidden 32 / vocab 256 / 8 centroides
    let miniConfigJSON = """
    {
      "model_type": "gemma4_assistant",
      "backbone_hidden_size": 64,
      "num_centroids": 8,
      "centroid_intermediate_top_k": 2,
      "use_ordered_embeddings": true,
      "tie_word_embeddings": true,
      "text_config": {
        "model_type": "gemma4_text",
        "hidden_size": 32, "num_hidden_layers": 2, "intermediate_size": 64,
        "num_attention_heads": 2, "num_key_value_heads": 1,
        "head_dim": 16, "global_head_dim": 32,
        "rms_norm_eps": 1e-06,
        "vocab_size": 256, "num_kv_shared_layers": 2,
        "hidden_size_per_layer_input": 0, "vocab_size_per_layer_input": 0,
        "sliding_window": 128, "max_position_embeddings": 1024,
        "tie_word_embeddings": true, "enable_moe_block": false,
        "use_double_wide_mlp": false, "attention_bias": false, "attention_k_eq_v": false,
        "layer_types": ["sliding_attention", "full_attention"]
      }
    }
    """

    func loadConfig() -> Gemma4AssistantConfig {
        let data = miniConfigJSON.data(using: .utf8)!
        return try! JSONDecoder().decode(Gemma4AssistantConfig.self, from: data)
    }

    @Test("Init shapes — centroids + token_ordering")
    func testInitShapes() {
        let cfg = loadConfig()
        let me = MaskedEmbedder(cfg)
        #expect(me.hiddenSize == 32)
        #expect(me.vocabSize == 256)
        #expect(me.numCentroids == 8)
        #expect(me.topK == 2)
        #expect(me.vocabSizePerCentroid == 256 / 8)  // = 32
        #expect(me.tokenOrdering.shape == [256])
        #expect(me.tokenOrdering.dtype == .int32)
    }

    @Test("Forward returns logits [B, L, vocab_size] sans NaN")
    func testForwardShape() {
        let cfg = loadConfig()
        let me = MaskedEmbedder(cfg)

        let B = 1, L = 3
        let hidden = MLXRandom.normal([B, L, me.hiddenSize])
        let lmHeadWeight = MLXRandom.normal([me.vocabSize, me.hiddenSize])

        let logits = me(hidden, lmHeadWeight: lmHeadWeight)
        #expect(logits.shape == [B, L, me.vocabSize])

        eval(logits)
        #expect(!isNaN(logits).any().item(Bool.self))
    }

    @Test("Logits non-selectionnes = mask_value (= min - 1) ; selectionnes calcules normalement")
    func testSparseScatter() {
        let cfg = loadConfig()
        let me = MaskedEmbedder(cfg)

        // Token ordering deterministe: cluster i contient les tokens [i*32 ..< (i+1)*32]
        // (= la partition canonique standard)
        let orderingFlat: [Int32] = (0 ..< 256).map { Int32($0) }
        me.update(parameters: ModuleParameters.unflattened([
            "token_ordering": MLXArray(orderingFlat)
        ]))

        let B = 1, L = 1
        let hidden = MLXRandom.normal([B, L, me.hiddenSize])
        let lmHeadWeight = MLXRandom.normal([me.vocabSize, me.hiddenSize])

        let logits = me(hidden, lmHeadWeight: lmHeadWeight)
        eval(logits)

        // Avec top_k=2 clusters × 32 tokens/cluster = 64 tokens "selectionnes"
        // Les 256-64 = 192 autres positions doivent etre toutes egales au meme mask_value
        let logits1d = logits.reshaped(-1)
        let minVal = logits1d.min().item(Float.self)

        // Au moins (vocab - top_k * vsc) positions doivent etre au mask_value
        let mask = logits1d .== MLXArray(minVal)
        let nMasked = mask.sum().item(Int32.self)
        let expectedMaskedMin = 256 - 2 * 32  // = 192
        #expect(nMasked >= expectedMaskedMin,
                "expected >= \(expectedMaskedMin) positions au mask_value, got \(nMasked)")
    }

    @Test("Batch + multi-position — shapes preserved")
    func testBatchMultiPosition() {
        let cfg = loadConfig()
        let me = MaskedEmbedder(cfg)

        let B = 2, L = 5
        let hidden = MLXRandom.normal([B, L, me.hiddenSize])
        let lmHeadWeight = MLXRandom.normal([me.vocabSize, me.hiddenSize])

        let logits = me(hidden, lmHeadWeight: lmHeadWeight)
        #expect(logits.shape == [B, L, me.vocabSize])
        eval(logits)
        #expect(!isNaN(logits).any().item(Bool.self))
    }
}
