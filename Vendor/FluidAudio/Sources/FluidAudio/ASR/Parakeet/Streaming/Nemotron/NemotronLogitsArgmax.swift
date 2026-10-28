import Accelerate
@preconcurrency import CoreML
import Foundation

// WhisperASR patch (fix/nemotron-logits): dtype- and stride-aware logits reads.
//
// The original `findMaxIndex` bound `logits.dataPointer` as contiguous Float32
// and ran `vDSP_maxvi` over `logits.count` elements. When CoreML hands back the
// logits as Float16 (2 bytes/element) or with a padded/strided last axis, that
// reads past the end of the buffer — a heap over-read that segfaults whenever the
// buffer ends at a VM region boundary (seen as EXC_BAD_ACCESS in vDSP_maxvi ←
// findMaxIndex ← selectToken, "Bytes after previous region: 1").
// These helpers follow the same pattern as `argmaxFrame` in
// StreamingNemotronMultilingualAsrManager+Decode.swift.

/// Number of vocab entries (last axis) of a logits tensor shaped [..., vocab].
@inline(__always)
internal func nemotronLogitsVocab(_ logits: MLMultiArray) -> Int {
    guard let last = logits.shape.last?.intValue, last > 0 else { return logits.count }
    return last
}

/// Argmax over the last axis of the first row of `logits` (shape [1, 1, 1, vocab]
/// for single-step decoding). Never reads outside the tensor.
internal func nemotronArgmaxLastAxis(_ logits: MLMultiArray) -> Int {
    let vocab = nemotronLogitsVocab(logits)
    guard vocab > 0, logits.count > 0 else { return 0 }
    let stride = max(1, logits.strides.last?.intValue ?? 1)
    switch logits.dataType {
    case .float32:
        let ptr = logits.dataPointer.bindMemory(to: Float.self, capacity: (vocab - 1) * stride + 1)
        var maxVal: Float = -Float.infinity
        var maxIdx: vDSP_Length = 0
        vDSP_maxvi(ptr, vDSP_Stride(stride), &maxVal, &maxIdx, vDSP_Length(vocab))
        // vDSP_maxvi reports the element offset (index * stride)
        return Int(maxIdx) / stride
    case .float16:
        let ptr = logits.dataPointer.bindMemory(to: UInt16.self, capacity: (vocab - 1) * stride + 1)
        var bestIdx = 0
        var bestVal = nemotronHalfBitsToFloat(ptr[0])
        for v in 1..<vocab {
            let val = nemotronHalfBitsToFloat(ptr[v * stride])
            if val > bestVal { bestVal = val; bestIdx = v }
        }
        return bestIdx
    case .double:
        let ptr = logits.dataPointer.bindMemory(to: Double.self, capacity: (vocab - 1) * stride + 1)
        var bestIdx = 0
        var bestVal = ptr[0]
        for v in 1..<vocab where ptr[v * stride] > bestVal { bestVal = ptr[v * stride]; bestIdx = v }
        return bestIdx
    default:
        // Unknown element type: go through MLMultiArray's own (slow, but bounds-safe) accessor.
        var bestIdx = 0
        var bestVal = -Float.infinity
        let rank = logits.shape.count
        for v in 0..<vocab {
            var key = [NSNumber](repeating: 0, count: max(rank, 1))
            key[key.count - 1] = NSNumber(value: v)
            let val = logits[key].floatValue
            if val > bestVal { bestVal = val; bestIdx = v }
        }
        return bestIdx
    }
}

/// Read one vocab entry of the first row of `logits`, honouring dtype and stride.
@inline(__always)
internal func nemotronLogit(_ logits: MLMultiArray, _ index: Int) -> Float {
    let vocab = nemotronLogitsVocab(logits)
    guard index >= 0, index < vocab else { return -Float.infinity }
    let stride = max(1, logits.strides.last?.intValue ?? 1)
    switch logits.dataType {
    case .float32:
        return logits.dataPointer.bindMemory(to: Float.self, capacity: (vocab - 1) * stride + 1)[index * stride]
    case .float16:
        return nemotronHalfBitsToFloat(
            logits.dataPointer.bindMemory(to: UInt16.self, capacity: (vocab - 1) * stride + 1)[index * stride])
    case .double:
        return Float(logits.dataPointer.bindMemory(to: Double.self, capacity: (vocab - 1) * stride + 1)[index * stride])
    default:
        var key = [NSNumber](repeating: 0, count: max(logits.shape.count, 1))
        key[key.count - 1] = NSNumber(value: index)
        return logits[key].floatValue
    }
}
