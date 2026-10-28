# WhisperASR patches on FluidAudio 0.17.7 (upstream commit 503b4bd1)

1. `StreamingNemotronMultilingualAsrManager+BlankRescue.swift`: skip the blank-span rescue when the
   accumulators shrank during the trial decode (fixed the 2026-10-21 "Range requires lowerBound <= upperBound" trap).
2. `NemotronLogitsArgmax.swift` (new) + `findMaxIndex` in `StreamingNemotronMultilingualAsrManager+Buffers.swift`
   and `StreamingNemotronAsrManager+Pipeline.swift` + `selectToken` in `NemotronVocabularyBias.swift`:
   logits are read with their real dtype (Float32 / Float16 / Double) and last-axis stride, over the vocab
   axis only, instead of binding the buffer as contiguous Float32 over `logits.count` (heap over-read →
   EXC_BAD_ACCESS in vDSP_maxvi, crashes 2026-10-26 23:06, 10-28 23:07 and 23:19).

To re-sync with upstream: diff this folder against a fresh FluidAudio checkout and re-apply the two patches.
