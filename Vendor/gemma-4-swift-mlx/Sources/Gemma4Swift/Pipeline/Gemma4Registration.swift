// Enregistrement du model type "gemma4_text" dans LLMTypeRegistry

import Foundation
import MLXLMCommon
import MLXLLM

/// Enregistre Gemma 4 dans le registre de types de modeles de mlx-swift-lm.
/// Doit etre appele AVANT tout chargement de modele Gemma 4.
///
/// Usage:
/// ```swift
/// await Gemma4Registration.register()
/// // Maintenant MLXLMCommon.loadModelContainer(id: "mlx-community/gemma-4-e2b-it-4bit") fonctionne
/// ```
public enum Gemma4Registration {

    /// Enregistre les types "gemma4_text" et "gemma4" dans LLMTypeRegistry.shared
    /// - Parameter multimodal: si true, charge le modele multimodal complet (vision+audio)
    public static func register(multimodal: Bool = false) async {
        await LLMTypeRegistry.shared.registerModelType("gemma4_text") { configData in
            let fullConfig = try JSONDecoder().decode(Gemma4Config.self, from: configData)
            return Gemma4LLMModel(config: fullConfig.textConfig)
        }

        await LLMTypeRegistry.shared.registerModelType("gemma4") { configData in
            let fullConfig = try JSONDecoder().decode(Gemma4Config.self, from: configData)
            if multimodal {
                return Gemma4MultimodalLLMModel(config: fullConfig)
            } else {
                return Gemma4LLMModel(config: fullConfig.textConfig)
            }
        }

        // Gemma 4 "unified" family (the dense 12B/larger any-to-any models). The
        // text decoder is the same architecture as "gemma4" — only the model_type
        // string and the multimodal wrapper weights differ. We load it text-only
        // (the vision/audio embedder weights are dropped by WeightSanitizer), so
        // it drives ChatSession exactly like the smaller text models.
        //
        // We decode ONLY `text_config`: the unified `vision_config`/`audio_config`
        // use a different schema than `Gemma4Config` expects, so decoding the full
        // config would throw. We never touch those modalities here anyway.
        await LLMTypeRegistry.shared.registerModelType("gemma4_unified") { configData in
            let wrapper = try JSONDecoder().decode(UnifiedTextOnlyConfig.self, from: configData)
            return Gemma4LLMModel(config: wrapper.textConfig)
        }
        await LLMTypeRegistry.shared.registerModelType("gemma4_unified_text") { configData in
            let wrapper = try JSONDecoder().decode(UnifiedTextOnlyConfig.self, from: configData)
            return Gemma4LLMModel(config: wrapper.textConfig)
        }
    }

    /// Minimal decoder that pulls just the text decoder config out of a unified
    /// Gemma 4 config.json, ignoring the vision/audio sub-configs.
    private struct UnifiedTextOnlyConfig: Decodable {
        let textConfig: Gemma4TextConfig
        enum CodingKeys: String, CodingKey { case textConfig = "text_config" }
    }
}
