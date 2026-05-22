import Testing
import Foundation
import MLX
import MLXNN
import MLXLMCommon
@testable import Gemma4Swift

@Suite("forwardWithIntermediates / forwardCollectingIntermediates — exposition hidden + intermediates")
struct ForwardWithIntermediatesTests {

    /// Mini text config: 4 layers (pas de kv-shared), hidden 32, vocab 256.
    /// Pas de per-layer inputs (hiddenSizePerLayerInput=0) pour simplicite.
    let miniConfigJSON = """
    {
      "model_type": "gemma4_text",
      "hidden_size": 32, "num_hidden_layers": 4, "intermediate_size": 64,
      "num_attention_heads": 2, "num_key_value_heads": 1,
      "head_dim": 16, "global_head_dim": 32,
      "rms_norm_eps": 1e-06,
      "vocab_size": 256, "num_kv_shared_layers": 0,
      "hidden_size_per_layer_input": 0, "vocab_size_per_layer_input": 0,
      "sliding_window": 128, "max_position_embeddings": 1024,
      "tie_word_embeddings": true, "enable_moe_block": false,
      "use_double_wide_mlp": false, "attention_bias": false, "attention_k_eq_v": false,
      "final_logit_softcapping": 0,
      "layer_types": ["sliding_attention", "sliding_attention", "sliding_attention", "full_attention"]
    }
    """

    func loadConfig() -> Gemma4TextConfig {
        let data = miniConfigJSON.data(using: .utf8)!
        return try! JSONDecoder().decode(Gemma4TextConfig.self, from: data)
    }

    @Test("forwardCollectingIntermediates retourne hidden post-norm + intermediates [n_layers]")
    func testTextModelForwardIntermediates() {
        let cfg = loadConfig()
        let model = Gemma4TextModel(cfg)

        let B = 1, L = 4
        let inputs = MLXArray((0 ..< B * L).map { Int32($0 % 100) }).reshaped(B, L)

        let out = model.forwardCollectingIntermediates(inputs: inputs)

        // Shapes
        #expect(out.hidden.shape == [B, L, cfg.hiddenSize])
        #expect(out.preNormHidden.shape == [B, L, cfg.hiddenSize])
        #expect(out.intermediates.count == cfg.numHiddenLayers)

        // Chaque intermediate doit avoir K/V shape [B, kvHeads, L, headDim]
        // Note: full attention layer 3 utilise global_head_dim (32), sliding 0..2 utilise head_dim (16).
        let kvHeads = cfg.numKeyValueHeads
        let resolved = cfg.resolvedLayerTypes
        for (i, intOpt) in out.intermediates.enumerated() {
            guard let inter = intOpt else { Issue.record("layer \(i) intermediate is nil"); continue }
            let expectedDim = resolved[i] == "full_attention" ? cfg.globalHeadDim : cfg.headDim
            #expect(inter.keys.shape == [B, kvHeads, L, expectedDim],
                    "layer \(i) (\(resolved[i])): K shape=\(inter.keys.shape)")
            #expect(inter.values.shape == [B, kvHeads, L, expectedDim])
        }

        // No NaN
        eval(out.hidden, out.preNormHidden)
        #expect(!isNaN(out.hidden).any().item(Bool.self))
        #expect(!isNaN(out.preNormHidden).any().item(Bool.self))
    }

    @Test("callAsFunction == forwardCollectingIntermediates.hidden (parite)")
    func testCallAsFunctionParity() {
        let cfg = loadConfig()
        let model = Gemma4TextModel(cfg)

        let B = 1, L = 4
        let inputs = MLXArray((0 ..< B * L).map { Int32($0 % 100) }).reshaped(B, L)

        let directOut = model(inputs: inputs)
        let viaIntermediates = model.forwardCollectingIntermediates(inputs: inputs).hidden

        eval(directOut, viaIntermediates)
        let diff = abs(directOut - viaIntermediates).max().item(Float.self)
        // Doit etre exactement egal (delegate path)
        #expect(diff == 0, "callAsFunction et forwardCollectingIntermediates.hidden doivent etre identiques (got max diff \(diff))")
    }

    @Test("pre-norm hidden != post-norm hidden (normalize a change la valeur)")
    func testPreNormDifferentFromPostNorm() {
        let cfg = loadConfig()
        let model = Gemma4TextModel(cfg)

        let B = 1, L = 2
        let inputs = MLXArray((0 ..< B * L).map { Int32($0 % 100) }).reshaped(B, L)

        let out = model.forwardCollectingIntermediates(inputs: inputs)
        eval(out.hidden, out.preNormHidden)

        // norm modifie la magnitude — les deux doivent differer
        let diff = abs(out.hidden - out.preNormHidden).max().item(Float.self)
        #expect(diff > 1e-3, "post-norm devrait differer de pre-norm (got diff \(diff))")
    }

    @Test("LanguageModel.forwardWithIntermediates: logits + preNormHidden tous deux exposes")
    func testLanguageModelForwardIntermediates() {
        let cfg = loadConfig()
        let langModel = Gemma4LanguageModel(cfg)

        let B = 1, L = 3
        let inputs = MLXArray((0 ..< B * L).map { Int32($0 % 100) }).reshaped(B, L)

        let out = langModel.forwardWithIntermediates(inputs: inputs)
        #expect(out.logits.shape == [B, L, cfg.vocabSize])
        #expect(out.hiddenStates.shape == [B, L, cfg.hiddenSize])
        #expect(out.preNormHiddenStates.shape == [B, L, cfg.hiddenSize])
        #expect(out.intermediates.count == cfg.numHiddenLayers)

        // logits non-NaN
        eval(out.logits, out.preNormHiddenStates)
        #expect(!isNaN(out.logits).any().item(Bool.self))
        #expect(!isNaN(out.preNormHiddenStates).any().item(Bool.self))
    }

    @Test("LanguageModel.callAsFunction == forwardWithIntermediates.logits (parite)")
    func testLanguageModelCallParity() {
        let cfg = loadConfig()
        let langModel = Gemma4LanguageModel(cfg)

        let B = 1, L = 3
        let inputs = MLXArray((0 ..< B * L).map { Int32($0 % 100) }).reshaped(B, L)

        let directLogits = langModel(inputs: inputs)
        let viaIntLogits = langModel.forwardWithIntermediates(inputs: inputs).logits

        eval(directLogits, viaIntLogits)
        let diff = abs(directLogits - viaIntLogits).max().item(Float.self)
        #expect(diff == 0, "callAsFunction et forwardWithIntermediates.logits doivent etre identiques (got max diff \(diff))")
    }
}
