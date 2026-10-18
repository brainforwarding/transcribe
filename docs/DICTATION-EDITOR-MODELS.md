# Dictation editor measurements

18 October 2026. Local measurements supporting the optional Faster dictation
setting in release 2.0.11. Owner approved publication after trial.

## Controlled four-minute text comparison

The same 13 saved, nonoverlapping turns from the owner's 252.95-second recording
were submitted to each editor. The ordinary formatter received their joined text;
assembly received the same words with chunk timing metadata. Three serial requests
per configuration, alternating order, measured complete request latency on the
owner's Mac. No microphone, history changes or automatic insertion were involved.

| Editor | Request times (seconds) | Median |
| --- | --- | --- |
| Luna, ordinary punctuation prompt | 5.157, 4.914, 5.165 | 5.157 |
| Luna, assembly + punctuation | 4.875, 5.609, 5.248 | 5.248 |
| Luna Fast, assembly + punctuation | 3.241, 3.301, 3.201 | 3.241 |
| Groq GPT-OSS 20B, same assembly prompt, low reasoning | 1.131, 1.287, 1.159 | 1.159 |
| Groq GPT-OSS 120B, same assembly prompt, low reasoning | 1.803, 2.661, 3.510 | 2.661 |

These are editor-only measurements, not whole-recording recognition or end-to-end
latency. The plain and assembly medians differ by 0.091 seconds, within the
observed run-to-run spread. The extra stitching instruction did not add a large
delay in this test. Fast reduced the assembly median by 38%. Responses confirmed
`service_tier=fast`; Luna used zero reasoning tokens. Assembly inputs were 1,551
tokens and outputs about 613; ordinary input was 786 tokens. Assembly and Fast
each had a cold first request and two cached-input requests. Ordinary input was
below the caching threshold. These small samples do not establish tail latency.

The ordinary formatter returned the original text unchanged after its existing
fidelity checks. Luna and Groq 20B removed one repeated "in" from the historical
nonoverlapping turns. One 120B run made additional word changes. Thus request speed
alone is insufficient evidence to replace the editor or guarantee word preservation.

The owner's original bad run spent 34.592 seconds on retired audio boundary review,
5.688 seconds on the ordinary editor and about 0.834 seconds on the recognition
tail, totaling 41.118 seconds. That recheck stage is removed. The original audio was
already deleted under the previous retention setting, so an exact original-flow
versus current-flow four-minute audio comparison is unavailable.

Private reports are under ignored `TranscribeBar/build/editor-comparison-corrected-2026-10-18`
and `editor-model-owner-2026-10-18`. Earlier `editor-comparison-2026-10-18` results
are invalid: a benchmark transport body-forwarding bug caused rejected requests.
They were not used in any latency claims. No app state or credentials were changed
by the benchmark. Iliad's existing, owner-authorized development Groq credential
was consumed from its provisioned, ignored owner-only file and passed to the
isolated benchmark through stdin, without copying or displaying its value.

## Actual overlapping audio samples

All editors received identical saved overlapping chunks. English, Spanish and
deliberate spoken-correction fixtures each have a forced 20-second cut with two
seconds of repeated audio. Only case/punctuation and explicit seventeen/17 and
seventy/70 equivalents are normalized for scoring.

| Editor | English edit seconds / word errors | Spanish | Correction |
| --- | --- | --- | --- |
| Luna Standard | 1.473 / 0 | 1.993 / 2 | 1.836 / 0 |
| Luna Fast | 1.770 / 0 | 1.627 / 2 | 1.211 / 0 |
| Groq 20B | 1.121 / 6 | 0.733 / 2 | 0.636 / 0 |
| Groq 120B | 1.062 / 0 | 1.294 / 2 | 0.834 / 5 |

Spanish's two differences are the existing orthographic word-splitting differences
in ASR, also present in whole-recording transcription. All tested protected
negations, intentional repetitions and quantity counts survived these editor calls.
However, Groq 20B repeated a six-word overlapping phrase in English, and 120B
repeated a phrase in the correction fixture. Neither alternative is selected for
the app on this evidence. Further provider-specific prompt evaluation is needed.
The original saved chunks and outputs remain under ignored
`TranscribeBar/build/editor-model-comparison-2026-10-18`.

New end-to-end replays with the corrected prompt and Standard-tier assembly gave
2.78 seconds English, 2.78 correction, 2.39 language-switch and 2.40 pause-control,
with no normalized word errors or missing protected phrases. Fresh ordinary-flow
runs were 4.14, 4.20, 4.21 and 2.82 seconds respectively. These short public
synthetic fixtures show savings in successful background recognition, not a
guarantee for long real speech. They predate the final Fast-tier selection.

## Failure case and correction

The Spanish replay encountered a real background service failure. Missing-only
recovery split `diecisiete` at the 20-second boundary into incorrect numbers. It
took 5.91 seconds after stop, compared with 4.02 seconds for ordinary full-file
transcription and formatting. Adding two seconds of recovery context still
produced a duplicate/wrong number in the assembled result. This tested approach
was discarded; no recovery-context schema or additional audio-check stage remains.

Dictation now falls back to the established whole-recording transcription plus
ordinary formatter only when background recognition is incomplete. It preserves
the original turns for diagnosis. Successful background recognition still has one
assembly request and no extra audio uploads. The failing Spanish boundaries were
reproduced from the public fixture with the new fallback, preserving diecisiete
and setenta. Historical retry never inserts automatically. Incomplete fallback
and cancellation retain audio and cannot insert late or uncertain output. Meeting
missing-only recovery is unchanged.

## Selected local experiment and alternatives

Luna Fast is enabled only in the assembly path selected by the existing Faster
dictation experiment. Turning that switch off uses the unchanged ordinary flow.
There is no additional model selector. [OpenAI documents Fast mode](https://developers.openai.com/api/docs/guides/fast-mode)
and [Luna's rates](https://developers.openai.com/api/docs/models/gpt-6-luna): Fast
costs twice Standard. Without cache discounts, this sample's assembly request
costs about $0.000923 on Fast versus $0.000462 on Standard. The compact UI estimate
is explicitly an audio-cost estimate; it does not claim that all token prices
increase by only 1.1×.

[Groq's model catalog](https://console.groq.com/docs/models) advertises about
1,000 tokens/second for GPT-OSS 20B and 500 for 120B. The actual request times and
quality failures above take precedence over those advertised generation rates.
[Cerebras's catalog](https://inference-docs.cerebras.ai/models/overview) advertises
about 3,000 tokens/second for GPT-OSS 120B, making it another candidate; it has not
been benchmarked here. Network delay, prompt processing and reasoning still count
toward complete request time. No provider switch or public deployment was made.

The compile-only signed benchmark supports `format-record`, `assemble-record`,
`fast-assemble-record`, `groq20-assemble-record`, `groq120-assemble-record` and
`recover-record`. Groq modes read their key from stdin. Normal packaged builds
exclude this entire entry point and transport.
