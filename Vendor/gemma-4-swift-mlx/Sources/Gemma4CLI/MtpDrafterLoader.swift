// Helper de chargement du drafter Assistant pour les commandes CLI qui supportent
// `--draft-model` (Generate, Chat, Describe).

import Foundation
import MLX
import MLXNN
import Gemma4Swift

/// Telecharge si necessaire et charge le drafter Assistant. Verifie le mappage
/// des poids via `update(parameters:verify:.all)`.
public func loadDrafter(
    repo: String,
    hfToken: String?
) async throws -> Gemma4AssistantDraftModel {
    print("Chargement du drafter \(repo)...")
    let drafterDir = try await Gemma4ModelDownloader.download(
        modelId: repo, token: resolveHFToken(hfToken)
    ) { p in
        print("\r  drafter: \(Int(p.fraction * 100))% — \(p.currentFile)              ", terminator: "")
        fflush(stdout)
    }
    print()

    let cfgData = try Data(contentsOf: drafterDir.appendingPathComponent("config.json"))
    let cfg = try JSONDecoder().decode(Gemma4AssistantConfig.self, from: cfgData)
    let drafter = Gemma4AssistantDraftModel(cfg)

    let safetensors = try FileManager.default
        .contentsOfDirectory(at: drafterDir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "safetensors" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    var raw: [String: MLXArray] = [:]
    for url in safetensors {
        for (k, v) in try MLX.loadArrays(url: url) {
            raw[k] = v
        }
    }
    let sanitized = Gemma4AssistantWeightSanitizer.sanitize(
        weights: raw, tieWordEmbeddings: cfg.tieWordEmbeddings
    )
    try drafter.update(parameters: ModuleParameters.unflattened(sanitized), verify: .all)
    print("  drafter: \(sanitized.count) tenseurs charges (hidden=\(cfg.textConfig.hiddenSize), backbone=\(cfg.backboneHiddenSize))")
    return drafter
}
