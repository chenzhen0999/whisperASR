# Word alignment and diarization validation

2026-10-16

The comparison uses one fresh ASR result for all three local diarizers. The before column reproduces the previous longest-individual-turn assignment. The after column uses word timings and splits at speaker changes. Both columns use FluidAudio 0.17.7; this isolates the transcript projection change rather than comparing library versions.

Projection error is frame-level DER against the same engine's raw turns, with no collar. It measures information lost when attaching speaker labels to text, including silence and overlap. It does **not** establish that an engine identified the real people correctly. Cross-engine projection errors cannot rank acoustic accuracy because each engine supplies its own reference.

## User-supplied failing MP3

Full 36 min 34 s recording, Whisper large-v3-turbo ASR, 1,575 original segments. All 1,575 retained timings, totaling 4,042 words. The transcription and all diarization ran locally. Each engine started without known-voice references, to isolate speaker separation from identity matching.

| Local engine | Speakers | Raw turns | Before projection error | After projection error | Result segments |
| --- | ---: | ---: | ---: | ---: | ---: |
| Legacy | 4 | 597 | 17.65% | 13.73% | 1,711 |
| VBx | 3 | 419 | 12.06% | 8.97% | 1,697 |
| Nemotron 3 | 3 | 1,346 | 29.20% | 26.53% | 1,856 |

The word-alignment change reduced projection loss for all three engines. There are no human speaker annotations for this recording, so these numbers do not prove which speaker count or acoustic assignment is correct. Nemotron's controlled-fixture result does not establish that it is better on this recording. Existing model preferences remain unchanged.

Private review artifacts are saved in `/private/tmp/whisperasr-speaker-comparison/`: `legacy.srt`, `vbx.srt`, `nemotron.srt`, each corresponding `-before.srt`, and timed JSON. These artifacts are temporary and are not committed.

## Existing short recording

61.68 seconds, Whisper small, 21 ASR segments. All 21 retained timings, totaling 119 words.

| Local engine | Speakers | Before projection error | After projection error | Result segments |
| --- | ---: | ---: | ---: | ---: |
| Legacy | 2 | 9.90% | 7.55% | 23 |
| VBx | 2 | 5.04% | 5.04% | 21 |
| Nemotron 3 | 2 | 8.74% | 8.43% | 22 |

## Chinese recording with Nemotron ASR

Approximately 98 seconds, Nemotron 3.5 multilingual ASR, 12 original segments. All 12 retained timings, totaling 333 words. This also caught and fixed whitespace spanning multiple SentencePiece tokens, which initially caused most segments to lose timing metadata.

| Local engine | Speakers | Before projection error | After projection error | Result segments |
| --- | ---: | ---: | ---: | ---: |
| Legacy | 4 | 38.11% | 19.45% | 32 |
| VBx | 1 | 9.65% | 8.36% | 19 |
| Nemotron 3 | 3 | 38.29% | 29.29% | 47 |

The differing speaker counts need listening review. A lower projection error alone cannot establish whether VBx's single-speaker result is correct.

## Controlled synthetic voices

31.86 seconds generated locally with Daniel and Samantha system voices, alternating four turns. Whisper small produced nine segments with 100 words. Reference speaker intervals follow the generated clips after trimming quiet edges. DER uses a 250 ms collar; utterance-internal silence is included in these synthetic reference intervals.

| Local engine | Raw engine DER | Transcript DER before | Transcript DER after |
| --- | ---: | ---: | ---: |
| Legacy | 42.62% | 45.96% | 40.64% |
| VBx | 13.14% | 11.45% | 11.45% |
| Nemotron 3 | 0.00% | 0.40% | 0.40% |

Nemotron found the two voices and four turns correctly on this controlled example. This is a smoke check with synthetic voices, not a general accuracy benchmark. Word alignment can preserve a diarizer's decisions; it cannot repair acoustic speaker confusion. A deterministic alignment regression separately verifies an A-B-A exchange improves from 25% labeling error to 0% when the turns and word timings are correct.

## Reproducing a comparison

Run the opt-in `DiarizationComparisonTests` described in the README. It downloads models when needed and keeps audio local. Set `DIARIZATION_TEST_OUTPUT_DIRECTORY` to a private directory to export each engine's original and split SRTs and timed JSON. Reports contain counts and scores; subtitles and JSON contain the recording's transcript and should remain outside Git.

Regression checks cover lossless multilingual text, subword merging, UTF-8 fragments, timing persistence, old transcript decoding, cumulative turn overlap, duplicate windows, exclusive enrollment regions, ambiguous identities, overlapping voices, fragmented speakers, settings backups, and remote-provider precedence.

Final regression run: 13 tests, 12 passed and the opt-in full comparison skipped; zero failures. The full comparison passed separately on the user-supplied MP3. Actual VBx and Nemotron voice-reference recognition checks passed.
