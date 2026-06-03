// Port de language.py Attention — Attention multi-tete avec global_head_dim, K=V, partial RoPE

import Foundation
import MLX
import MLXFast
import MLXNN
import MLXLMCommon

/// Attention multi-tete Gemma 4
/// - global_head_dim pour full attention, head_dim pour sliding
/// - K=V optionnel (values = raw k_proj avant k_norm)
/// - KV sharing pour les couches tardives
/// - RoPE par type d'attention (standard ou proportional)
/// - Utilise attentionWithCacheUpdate() pour le support quantized KV cache
public class Gemma4Attention: Module {
    let config: Gemma4TextConfig
    let layerIdx: Int
    let layerType: String
    let isSliding: Bool
    let headDim: Int
    let numHeads: Int
    let numKVHeads: Int
    let useKEqV: Bool
    let isKvSharedLayer: Bool
    /// Si true, la couche n'a JAMAIS ses propres K/V (drafter Assistant) — on skip
    /// k_proj/v_proj/k_norm/v_norm a l'init et on force le path sharedKV au forward.
    let kvSharedOnly: Bool
    let scale: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear?
    @ModuleInfo(key: "v_proj") var vProj: Linear?
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm?
    @ModuleInfo(key: "v_norm") var vNorm: RMSNormNoScale?

    let rope: RoPEWrapper

    public init(_ config: Gemma4TextConfig, layerIdx: Int, kvSharedOnly: Bool = false) {
        self.config = config
        self.layerIdx = layerIdx
        self.kvSharedOnly = kvSharedOnly

        let layerTypes = config.resolvedLayerTypes
        self.layerType = layerTypes[layerIdx]
        self.isSliding = layerType == "sliding_attention"

        // head_dim dynamique: global_head_dim pour full attention
        if !isSliding && config.globalHeadDim > 0 {
            self.headDim = config.globalHeadDim
        } else {
            self.headDim = config.headDim
        }

        let dim = config.hiddenSize
        self.numHeads = config.numAttentionHeads

        // K=V pour full attention (modeles 26B/31B)
        self.useKEqV = config.attentionKEqV && !isSliding
        if useKEqV, let globalKvHeads = config.numGlobalKeyValueHeads {
            self.numKVHeads = globalKvHeads
        } else {
            self.numKVHeads = config.numKeyValueHeads
        }

        self.scale = 1.0

        self._qProj.wrappedValue = Linear(dim, numHeads * headDim, bias: false)
        self._oProj.wrappedValue = Linear(numHeads * headDim, dim, bias: false)
        self._qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)

        if kvSharedOnly {
            // Drafter Assistant: pas de K/V propres, jamais. Skip les modules associes.
            self._kProj.wrappedValue = nil
            self._vProj.wrappedValue = nil
            self._kNorm.wrappedValue = nil
            self._vNorm.wrappedValue = nil
        } else {
            self._kProj.wrappedValue = Linear(dim, numKVHeads * headDim, bias: false)
            if !useKEqV {
                self._vProj.wrappedValue = Linear(dim, numKVHeads * headDim, bias: false)
            } else {
                self._vProj.wrappedValue = nil
            }
            self._kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
            self._vNorm.wrappedValue = RMSNormNoScale(eps: config.rmsNormEps)
        }

        // KV sharing
        let firstKvSharedLayerIdx = config.firstKvSharedLayerIdx
        self.isKvSharedLayer = layerIdx >= firstKvSharedLayerIdx && firstKvSharedLayerIdx > 0

        // RoPE adapte au type d'attention
        let ropeTheta = config.ropeTheta(forLayerType: layerType)
        let ropeType = config.ropeType(forLayerType: layerType)
        let partialRotaryFactor = ropeType == "proportional" ? config.fullAttentionPartialRotaryFactor : 1.0

        self.rope = RoPEFactory.create(
            dims: headDim,
            base: ropeTheta,
            traditional: false,
            ropeType: ropeType,
            partialRotaryFactor: partialRotaryFactor
        )

        super.init()
    }

    /// Forward pass avec support du KV sharing entre couches.
    ///
    /// Quand `sharedKV` est fourni (couches KV-shared sans cache, i.e. training),
    /// les K/V partages sont reutilises au lieu d'etre recalcules via k_proj/v_proj.
    /// Cela reproduit le mecanisme `shared_kv` de Python mlx-lm.
    ///
    /// Retourne `(output, kv, offset)` pour permettre le suivi des intermediaires
    /// dans le forward pass du TextModel.
    public func callAsFunction(
        _ x: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode = .none,
        cache: KVCache? = nil,
        sharedKV: (keys: MLXArray, values: MLXArray)? = nil,
        sharedOffset: Int? = nil
    ) -> (output: MLXArray, kv: (keys: MLXArray, values: MLXArray), offset: Int) {
        let (B, L, _) = (x.dim(0), x.dim(1), x.dim(2))

        var queries = qProj(x).reshaped(B, L, numHeads, headDim)
        queries = qNorm(queries)
        queries = queries.transposed(0, 2, 1, 3)

        var keys: MLXArray
        var values: MLXArray
        var effectiveOffset: Int

        if let (sharedKeys, sharedValues) = sharedKV {
            // KV sharing sans cache (training): reutiliser les K/V d'une couche precedente
            // Les K/V sont deja normalises, transposes et RoPE'd
            keys = sharedKeys
            values = sharedValues
            effectiveOffset = sharedOffset ?? 0
            queries = rope(queries, offset: effectiveOffset)

            let output = MLXFast.scaledDotProductAttention(
                queries: queries,
                keys: keys,
                values: values,
                scale: scale,
                mask: mask
            )
            .transposed(0, 2, 1, 3)
            .reshaped(B, L, -1)
            return (oProj(output), (keys, values), effectiveOffset)

        } else if isKvSharedLayer, let cache = cache {
            // KV sharing avec cache (inference): reutiliser le cache existant.
            // IMPORTANT: cache.offset a deja ete incremente de L par la couche concrete
            // source (qui s'execute avant nous dans le meme forward). Nos queries
            // correspondent aux positions globales [cache.offset - L, ..., cache.offset - 1],
            // donc RoPE doit etre applique a (cache.offset - L), pas cache.offset.
            // (Equivaut a `offset` parameter passe par la textModel cote Python.)
            effectiveOffset = cache.offset - L
            queries = rope(queries, offset: effectiveOffset)

            // TurboQuant shared
            if let turboCache = cache as? TurboQuantKVCache {
                let output = turboCache.quantizedAttention(
                    queries: queries, scale: scale, mask: mask
                )
                .transposed(0, 2, 1, 3)
                .reshaped(B, L, -1)
                let state = cache.state
                return (oProj(output), (state[0], state[1]), effectiveOffset)
            }

            // Standard shared: lire les K/V decompresses du cache
            let state = cache.state
            if state.count >= 2 {
                let output = MLXFast.scaledDotProductAttention(
                    queries: queries,
                    keys: state[0],
                    values: state[1],
                    scale: scale,
                    mask: mask
                )
                .transposed(0, 2, 1, 3)
                .reshaped(B, L, -1)
                return (oProj(output), (state[0], state[1]), effectiveOffset)
            }
            // Fallback: compute own KV (ne devrait pas arriver)
            let kv = computeKV(x: x, B: B, L: L)
            keys = kv.keys; values = kv.values
            keys = rope(keys, offset: effectiveOffset)

            let output = attentionWithCacheUpdate(
                queries: queries, keys: keys, values: values,
                cache: cache, scale: scale, mask: mask
            )
            .transposed(0, 2, 1, 3)
            .reshaped(B, L, -1)
            return (oProj(output), (keys, values), effectiveOffset)
        }

        // Non-shared: calculer ses propres K/V
        let kv = computeKV(x: x, B: B, L: L)
        keys = kv.keys; values = kv.values

        // Lire l'offset AVANT que attentionWithCacheUpdate() l'incremente
        effectiveOffset = cache?.offset ?? 0

        // Appliquer RoPE aux queries ET aux keys
        queries = rope(queries, offset: effectiveOffset)
        keys = rope(keys, offset: effectiveOffset)

        // TurboQuant path
        if let turboCache = cache as? TurboQuantKVCache {
            turboCache.update(keys: keys, values: values)
            let output = turboCache.quantizedAttention(
                queries: queries, scale: scale, mask: mask
            )
            .transposed(0, 2, 1, 3)
            .reshaped(B, L, -1)
            return (oProj(output), (keys, values), effectiveOffset)
        }

        // Standard path: sdpaWithCacheUpdate() gere l'update du cache. Pour les
        // grands head dims (couches full-attention du 12B, headDim=512) il evite
        // le kernel Metal fuse qui plante sur certains GPU.
        let output = sdpaWithCacheUpdate(
            queries: queries,
            keys: keys,
            values: values,
            cache: cache,
            mask: mask
        )
        .transposed(0, 2, 1, 3)
        .reshaped(B, L, -1)

        return (oProj(output), (keys, values), effectiveOffset)
    }

    // MARK: - Attention sans kernel Metal fuse (grands head dims)

    /// Equivalent de `MLXLMCommon.attentionWithCacheUpdate`, mais quand le head
    /// dim est trop grand pour le kernel SDPA fuse (ex. 512 sur les couches
    /// full-attention du 12B : il demande un threadgroup de 1024, au-dela du max
    /// par-pipeline de certains GPU — 768 sur M1 Pro — et avorte), il calcule
    /// l'attention avec un simple matmul + softmax. Les petits head dims gardent
    /// le chemin rapide fuse.
    private func sdpaWithCacheUpdate(
        queries: MLXArray, keys: MLXArray, values: MLXArray,
        cache: KVCache?, mask: MLXFast.ScaledDotProductAttentionMaskMode
    ) -> MLXArray {
        guard headDim > 256 else {
            return attentionWithCacheUpdate(
                queries: queries, keys: keys, values: values,
                cache: cache, scale: scale, mask: mask)
        }
        let k: MLXArray, v: MLXArray
        if let cache {
            (k, v) = cache.update(keys: keys, values: values)
        } else {
            (k, v) = (keys, values)
        }
        return manualAttention(queries: queries, keys: k, values: v, mask: mask)
    }

    /// Attention classique : softmax(QKᵀ·scale + masque)·V. Groupe les queries
    /// par tete K/V et laisse le matmul diffuser les têtes K/V sur la dimension de
    /// repeat — evite de materialiser des K/V repetes (memoire). Utilise des
    /// kernels generiques (matmul/softmax) qui respectent la limite de threads.
    private func manualAttention(
        queries: MLXArray, keys: MLXArray, values: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode
    ) -> MLXArray {
        // queries [B, H, L, D] ; keys/values [B, Hkv, S, D]
        let b = queries.dim(0)
        let lq = queries.dim(2)
        let d = queries.dim(3)
        let hkv = keys.dim(1)
        let s = keys.dim(2)
        let nRep = numHeads / hkv

        // Compute in fp32: the 512-dim QKᵀ accumulates too much fp16 error
        // otherwise, perturbing the logits enough to mis-sample tokens (corrupted
        // JSON). The fused kernel accumulates in higher precision internally.
        let q = (nRep > 1 ? queries.reshaped(b, hkv, nRep, lq, d) : queries).asType(.float32)
        let k = (nRep > 1 ? keys.reshaped(b, hkv, 1, s, d) : keys).asType(.float32)
        let v = (nRep > 1 ? values.reshaped(b, hkv, 1, s, d) : values).asType(.float32)

        var scores = matmul(q * scale, k.swappedAxes(-1, -2))
        switch mask {
        case .array(let m):
            scores = scores + Self.broadcastMask(m.asType(.float32), rank: scores.ndim)
        case .causal:
            // Masque causal additif, avec decalage si un prefixe est deja en cache.
            let rows = MLXArray(0 ..< lq).reshaped(lq, 1)
            let cols = MLXArray(0 ..< s).reshaped(1, s)
            let keep = cols .<= (rows + (s - lq))
            let additive = (1 - keep.asType(.float32)) * Float(-1e9)
            scores = scores + additive
        default:
            break
        }
        let weights = softmax(scores, axis: -1, precise: true)
        var out = matmul(weights, v)
        if nRep > 1 { out = out.reshaped(b, numHeads, lq, d) }
        return out.asType(queries.dtype)
    }

    /// Prepend des axes unitaires a un masque additif pour qu'il diffuse contre
    /// un tenseur de scores de rang `rank` (ses dims [.., L, S] restent alignees).
    private static func broadcastMask(_ m: MLXArray, rank: Int) -> MLXArray {
        guard m.ndim < rank else { return m }
        var shape = Array(repeating: 1, count: rank - m.ndim)
        shape.append(contentsOf: m.shape)
        return m.reshaped(shape)
    }

    private func computeKV(
        x: MLXArray, B: Int, L: Int
    ) -> (keys: MLXArray, values: MLXArray) {
        guard let kProj = kProj, let kNorm = kNorm, let vNorm = vNorm else {
            fatalError("computeKV appele sur une couche kvSharedOnly — sharedKV doit etre fourni externe")
        }
        var keys = kProj(x).reshaped(B, L, numKVHeads, headDim)

        // K=V: values sont le raw k_proj output (avant k_norm)
        var values: MLXArray
        if useKEqV {
            values = keys
        } else {
            values = vProj!(x).reshaped(B, L, numKVHeads, headDim)
        }

        keys = kNorm(keys)
        values = vNorm(values)
        values = values.transposed(0, 2, 1, 3)

        // RoPE est applique par l'appelant avec l'offset correct du cache
        keys = keys.transposed(0, 2, 1, 3)

        return (keys, values)
    }
}
