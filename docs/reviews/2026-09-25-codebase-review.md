**Echo codebase review and improvement plan — 25 September 2026**

Echo has several application-level defects that can explain missing output, inconsistent text, and apparent slowness without changing Whisper's weights. The first release should fix short-clip decoding and warm-up, protect text delivery, and make text transformations deterministic. Subsequent quality and speed work should be selected using the same audio and the same model artifact.

This review covers the 46 Swift application files, existing checks, build/release configuration, previous optimization designs, and the locally resolved WhisperKit implementation. Application commit: `211d95d`. Local Argmax/WhisperKit version: `0.18.0`, revision `e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef`. The repository does not currently lock that dependency for other builds.

The existing suite built and passed **173 checks, zero failures**, on Apple Silicon, macOS 26.3, Xcode 26.5. No application code or unit tests were changed. Disposable command-line probes exercised existing production text/store code and AVAudioConverter. No personal recordings, history, or dictionaries were inspected. Real microphone accuracy, live paste delivery, cold-start speed, and device-specific failures were not benchmarked; those remain explicit validation work.

Evidence labels below distinguish **source-confirmed behavior**, **reproduced behavior**, and **risks requiring device validation**. Source-confirmed does not mean a complete real-world reproduction has been performed. P1 means address before performance tuning; P2 means the next quality/reliability increment; P3 means later maintenance or a measured experiment.

**What is already implemented.** Keep the existing capture-generation isolation, bounded in-flight callback finalization, conservative edge trimming, compiled replacement/snippet rules, background ordered history persistence, and approximately 30 Hz waveform coalescing. These are useful foundations. The existing [benchmark protocol](/Users/michael/echo/docs/benchmarks/transcription-capture-benchmark.md:1) defines comparisons but contains no measured results. Recommending these optimizations again would miss the remaining problems.

**Prioritized findings and changes**

1. **P1 — Short recordings can bypass decoding entirely; the warm-up has the same flaw.** Source-confirmed integration defect in the locally resolved version.

   Echo accepts 0.3-second audio in [CaptureConfiguration.swift](/Users/michael/echo/Echo/Audio/CaptureConfiguration.swift:30). [TranscriptionService.swift](/Users/michael/echo/Echo/Transcription/TranscriptionService.swift:66) leaves `windowClipTime` at its default of one second. The dependency's decoder loop runs only while `seek < clipEnd - windowPadding`; audio-array input is not padded before that check. Consequently, selected clips from 0.3 through 1.0 seconds never enter the main audio/decoder loop. Trimming can move an otherwise longer recording into this range. This is a credible explanation for missing short replies and names, not a limitation of the model weights. The relevant upstream code is [DecodingOptions](https://github.com/argmaxinc/argmax-oss-swift/blob/e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef/Sources/WhisperKit/Core/Configurations.swift#L186-L214) and [TranscribeTask](https://github.com/argmaxinc/argmax-oss-swift/blob/e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef/Sources/WhisperKit/Core/TranscribeTask.swift#L106-L160).

   The 0.1-second throwaway inference at [TranscriptionService.swift](/Users/michael/echo/Echo/Transcription/TranscriptionService.swift:52) also skips the main feature extraction, encoder, and decoding loop. Model loading/prewarming and decoder preparation still occur, but the claimed full inference warm-up does not.

   Change: define an explicit short-dictation decoding policy, with a first-window rule or appropriate padding, and make warm-up execute an actual inference window. Do not globally disable tail safeguards without checking long recordings and silence. Keep recorded duration separate from any synthetic padding.

   Acceptance: replay known speech at 0.3, 0.5, 0.8, 1.0, and 1.2 seconds, including clips shortened by the trimmer. Verify decoder-run counters, short-word recovery, and no new silence hallucinations. Measure first versus subsequent dictation after relaunch and model reload.

2. **P1 — Clipboard restoration can destroy newer clipboard content.** Source-confirmed.

   With “Copy transcript to clipboard” disabled, [TextInserter.swift](/Users/michael/echo/Echo/Insertion/TextInserter.swift:143) snapshots the clipboard, writes the transcript, and unconditionally restores the snapshot 0.7 seconds later. Copying something else during that interval loses the new clipboard content. An initially empty clipboard is never restored to empty because `restore` returns early. If secure input becomes active after the preliminary check, `insert` writes the transcript before returning its fallback result, leaving it on the clipboard even with the setting disabled.

   Change: make insertion an owned clipboard transaction, using a transaction ID and the pasteboard [changeCount](https://developer.apple.com/documentation/appkit/nspasteboard/changecount). Restore only while Echo still owns the current contents; restore an empty snapshot correctly; handle secure-input fallback before changing contents. Coordinate overlapping restores and explicit Copy actions. A fixed delay is not proof that the destination consumed the paste.

   Acceptance: initially empty/text/image/file clipboard; copy a different item during the restore delay; two rapid dictations; click Copy while restoration is pending; secure input appearing between checks. Newer user clipboard content must survive every case.

3. **P1 — A delayed transcript can paste into a different app or field.** Source-confirmed targeting gap; live application compatibility needs validation.

   The `frontApp` captured at [DictationController.swift](/Users/michael/echo/Echo/DictationController.swift:334) is used for statistics only. The eventual insertion uses whatever currently has focus. Switching apps or fields while decoding can therefore direct a transcript somewhere unintended. The inserter also treats unknown accessibility targets as pasteable.

   Change: capture the intended app and available focused-element identity when recording starts; revalidate before dispatch. If the target changed, preserve the result and offer Copy/explicit insertion. Do not force focus back unexpectedly. Retain the permissive compatibility path for apps with incomplete accessibility trees only when the target app is still the intended one.

   Acceptance: change apps and fields during inference, close the destination, switch browser tabs, use a password field, and exercise native, Electron, and browser editors. Never paste automatically into a different known target.

4. **P1 — Lifecycle recovery can show Ready while dictation is unusable; inference cannot be cancelled.** Source-confirmed, with scheduling races requiring controlled reproduction.

   A startup model failure returns before `hotkeyMonitor.start()` at [DictationController.swift](/Users/michael/echo/Echo/DictationController.swift:133). A later successful model switch sets `.idle` without starting the monitor. If both switching and rollback fail, a delayed error reset can likewise show Ready without a usable model. There is no same-model retry action. Once inference starts, there is no user cancellation or timeout; the 120-second limit bounds recording only. Delayed copy/error tasks are not owned by a session and can dismiss newer state.

   Change: use one dictation session ID and explicit readiness prerequisites. Model readiness, permission state, and hotkey monitoring must be established together. Add Retry setup, Cancel recording/transcription, bounded inference recovery, and session-scoped timers/progress/results. Propagate cancellation into inference and detached processing. A timed-out worker must not later insert text or run concurrently on the same unsafe engine; do not merely race a sleep against work and declare it stopped. Snapshot language, model, rules, vocabulary, and relevant behavior settings once per session.

   Acceptance: launch offline without assets, retry the same model, switch after a startup failure, fail both switch and rollback, revoke permissions, stall inference, cancel then dictate again, and let an old result complete. Only the current valid session may insert or alter state.

5. **P1 — Modifier handling can lose key release and continue recording.** Source-confirmed event logic; physical keyboard matrix still required.

   [HotkeyMonitor.swift](/Users/michael/echo/Echo/Hotkey/HotkeyMonitor.swift:47) filters for the right-side key code but reads the aggregate Option/Command flag. Hold the left modifier, press and release the right hotkey, then release the left: the right release can still look pressed, and the left release is ignored. Changing the selected hotkey while recording also replaces the key being observed without ending/resetting the held state.

   Change: track the selected physical key's state, freeze the binding during capture, reset held state on monitor restart/session interruption, and provide an explicit stop/cancel path. Recheck permissions when reactivating the app and before sensitive operations.

   Acceptance: both left/right modifier combinations, other simultaneous modifiers, changing settings while held, lost key-up, sleep/wake, and permission revocation. Release must reliably end capture without waiting for the duration cap.

6. **P1 — Dictionary and snippet processing can corrupt otherwise correct recognition.** Reproduced using production functions.

   [ReplacementProcessor.swift](/Users/michael/echo/Echo/Processing/ReplacementProcessor.swift:13) and [SnippetProcessor.swift](/Users/michael/echo/Echo/Processing/SnippetProcessor.swift:26) repeatedly search the already-modified output. With `my signature → Best, Alexander` and `Alexander → PRIVATE EXPANSION`, the standalone trigger produces `Best, Alexander`, while `Please insert my signature here` produces `Please insert Best, PRIVATE EXPANSION here`. Saved expansion text is not consistently literal.

   Both rule types use unconditional `\b` boundaries in [CompiledTextRule.swift](/Users/michael/echo/Echo/Processing/CompiledTextRule.swift:13). Probes confirmed that `C++` fails inside `use C++ today`, a Chinese term fails within contiguous Chinese text, and an `email` rule can rewrite the local part of `email@example.com`. [DictionaryStore.swift](/Users/michael/echo/Echo/Dictionary/DictionaryStore.swift:141) also accepts one misspelling with multiple destinations; two rules for `Eric` silently compete.

   Change: find matches against each stage's original input, resolve overlaps deterministically, and apply selected edits once. Treat inserted snippet expansions as opaque. Preserve intentional dictionary-to-snippet behavior while preventing recursion within each stage. Validate alias conflicts; make punctuation/language boundaries explicit; protect URLs, emails, and code by default, with intentional overrides. Normalize Unicode consistently. Show a rule preview so users can see matching behavior before saving.

   Acceptance: standalone versus inline equivalence, overlapping and chained rules, duplicate aliases, `C++`, `.NET`, apostrophes, CJK, Unicode variants, literal `$`/backslashes/newlines, URLs and email addresses, and 1,000-rule workloads.

7. **P1/P2 — Model availability is weaker than the UI's “downloaded/ready” claim.** Source-confirmed validation gap; corruption/offline cases require an asset fixture.

   [WhisperModelCatalog.swift](/Users/michael/echo/Echo/Transcription/WhisperModelCatalog.swift:69) checks only the existence of four artifact paths. Empty or incomplete compiled-model directories pass. Tokenizer readiness is not checked. `download: false` in the service does not independently guarantee offline tokenizer loading: the resolved dependency falls back to fetching a tokenizer when local loading fails. See [ModelUtilities](https://github.com/argmaxinc/argmax-oss-swift/blob/e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef/Sources/WhisperKit/Utilities/ModelUtilities.swift#L19-L85).

   Change: unify model acquisition/validation/activation behind one owner; track downloading, validating, installed, loaded, and failed separately. Verify required files and tokenizer assets before marking installed; publish an installation marker after success; provide Repair/Retry and clean recovery from partial downloads. Pin asset identity/revision where supported. Validate an installed model through a fully offline load. Avoid hashing all model files on every dictation.

   Acceptance: interrupted download, empty compiled directories, corrupt config, missing tokenizer, low disk space, offline restart, and failed switch/rollback. The active model must be recoverable without manually deleting folders.

8. **P2 — Capture readiness, boundaries, and device reporting need one consistent contract.** Mixed evidence.

   “Mic ready” currently means RMS exceeded `0.0001`, not that transport started, at [CaptureAccumulator.swift](/Users/michael/echo/Echo/Audio/CaptureAccumulator.swift:87). A working silent mic can look broken, while background noise looks ready. The controller gates finalized audio on a UI flag updated by an untagged asynchronous callback ([DictationController.swift](/Users/michael/echo/Echo/DictationController.swift:94)); callback/finalization ordering can reject valid audio or update a later session. That race is source-identified, not reproduced here.

   Finalization drains callbacks that registered before stopping; it does not admit a subsequent hardware tap or flush resampler output. The warm engine also reuses a converter after skipping all idle buffers ([AudioRecorder.swift](/Users/michael/echo/Echo/Audio/AudioRecorder.swift:128)). A disposable 48→16 kHz converter probe reproduced **11 nonzero output samples** from previous input in the next silent buffer, versus zero with a fresh converter. This is a small carry-over, about 0.7 ms in that configuration, not evidence of whole-word contamination. Hardware-tail loss and cold Bluetooth onset loss still need device measurement.

   Change: distinguish transport ready, speech present, and recording validity; include generation-tagged readiness in finalized capture metadata. Reset/drain converter state at explicit boundaries on its owning execution context. Measure a short bounded tail-capture policy before adopting it. Observe device/format/disconnect events, report the actual selected/fallback mic, and refresh device UI dynamically. Silent fallback to the default mic should be visible. Evaluate the existing 45-second warm-engine policy against Bluetooth wake latency, power, and audio routing.

   Acceptance: first/last plosives, immediate key release, rapid warm recordings, cold recordings after 45 seconds, 16/44.1/48 kHz inputs, quiet speech, Bluetooth handoff, USB disconnect/reconnect, and system-default changes. No older-session audio/readiness may reach a later capture.

9. **P2 — Silence/noise handling and result quality need explicit application policy.** Source-confirmed gaps; thresholds and benefit remain experimental.

   [VoiceActivityTrimmer.swift](/Users/michael/echo/Echo/Audio/VoiceActivityTrimmer.swift:41) retains original audio when speech detection is inconclusive. This protects quiet speech, but it is not a no-speech gate. The service then returns only joined text, discarding segment metadata and decoder timings. In this exact dependency version, `noSpeechProb` is hard-coded to zero in [TextDecoder.swift](https://github.com/argmaxinc/argmax-oss-swift/blob/e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef/Sources/WhisperKit/Core/TextDecoder.swift#L984-L993). Tuning `noSpeechThreshold` alone will therefore not provide the expected protection.

   Change: return a structured transcription result with text, segments, supported quality signals, and timings. Separate confidently empty/invalid audio from ambiguous quiet speech. Use acoustic evidence together with supported log-probability/repetition signals, calibrated on the corpus; do not describe them as calibrated confidence probabilities. A limited retry using original audio or a smaller vocabulary prompt can be evaluated for suspicious results. Never silently delete a plausible quiet utterance just to improve speed. Preserve a recoverable result and explain “no speech detected” when applicable.

   Acceptance: silence, fan/keyboard noise, music, background conversation, quiet speech, repeated speech, and prompt-heavy dictionaries. Measure false insertions and false rejection of real speech separately.

10. **P2 — Language and vocabulary behavior should be intentional.** Source-confirmed behavior; accuracy improvements require evaluation.

    [TranscriptionService.swift](/Users/michael/echo/Echo/Transcription/TranscriptionService.swift:68) always supplies English. This is appropriate for the default English-optimized artifact, but prevents the application from honoring other language choices when an already-selected model supports them. It must not be presented as multilingual dictation. Under the fixed-model constraint, an English-only artifact remains English-only; application code cannot create missing language capability.

    The prompt includes dictionary words in starred/newest order, up to 200 tokens; [VocabularyPrompt.swift](/Users/michael/echo/Echo/Processing/VocabularyPrompt.swift:20) repeatedly tokenizes candidate prompts for every dictation. Unrelated words can bias recognition, useful older words can fall out of budget, and users cannot see what was included. There is also a concrete inference cost: the resolved [TextDecoder](https://github.com/argmaxinc/argmax-oss-swift/blob/e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef/Sources/WhisperKit/Core/TextDecoder.swift#L351-L355) bypasses its prefill cache whenever prompt tokens are present, and processes forced prompt tokens through its sequential prediction loop. Encoding-cache improvements alone will not remove that inference work.

    Change: expose language/capability honestly; allow explicit language or measured auto-detection only where the selected unchanged artifact supports it. Cache prompt tokens by model/tokenizer, dictionary revision, and language. Offer scoped vocabulary sets and visibility into the active prompt budget. Keep recognition hints distinct from guaranteed replacements. Compare no prompt, curated prompt, and current prompt using identical audio.

    Acceptance: names, acronyms, identifiers, accented English, supported language/code-switch samples, and 0/100/1,000-entry dictionaries. Compare prompt budgets of 0/25/50/100/200 tokens, including output truncation and latency. Measure term recall and unwanted insertions, not just aggregate WER. Do not simply enable `usePrefillCache`: it is already enabled by default and deliberately bypassed for prompts in this version.

11. **P2 — Storage errors can masquerade as successful edits; history deletion lacks shutdown durability.** Store failures reproduced; shutdown race source-identified.

    [SnippetStore.swift](/Users/michael/echo/Echo/Snippets/SnippetStore.swift:140) and [DictionaryStore.swift](/Users/michael/echo/Echo/Dictionary/DictionaryStore.swift:204) load corrupt JSON as empty and ignore write failures. A production-code probe confirmed that a successful add overwrites a corrupt file; making the target path unwritable caused add to return success but reload to lose the entry. This makes personalization unreliable.

    History uses ordered background writes correctly, but [TranscriptStore.swift](/Users/michael/echo/Echo/History/TranscriptStore.swift:74) has no production shutdown flush; [MenuContentView.swift](/Users/michael/echo/Echo/MenuContentView.swift:21) quits immediately. An immediate quit after Add/Clear can outrun persistence. A logged write error does not tell the user that deletion failed.

    Change: preserve/quarantine corrupt data, distinguish missing from unreadable data, expose pending/error/retry status, and retain a last-good backup where appropriate. Add bounded termination coordination and durable completion for explicit clear operations without putting ordinary history writes back on the paste path. Make transcript retention, usage statistics, and clipboard retention separate, accurately described controls.

    Acceptance: unwritable directory, full disk, corrupt/truncated file, clear then immediate quit, add then immediate quit, and relaunch. A failed deletion must not be shown as durably completed.

12. **P2 — Current metrics cannot tell whether the user received the text or where time was spent.** Source-confirmed.

    [TextInserter.swift](/Users/michael/echo/Echo/Insertion/TextInserter.swift:154) returns `.pasted` after posting events; event creation can fail silently, and successful posting is not verified delivery. [DictationController.swift](/Users/michael/echo/Echo/DictationController.swift:393) records `.success` for automatic paste, clipboard-only output, and an unclicked copy offer. Timing stops around dispatch, not visible text in the destination. History persistence duration is deliberately separate and currently captured through a signpost rather than the originating usage row.

    Change: distinguish recognized, paste dispatched, copied, awaiting copy, cancelled, no speech, failed, and verified delivery where observable. Add key-down→transport-ready, startup/model loading, prompt construction, feature/encoder/decoder, retry counts, trim reason, and release→dispatch measurements. Use a monotonic clock throughout. Keep benchmark-only visible-delivery measurements distinct from application telemetry. Record app/build/dependency/config identity with measurements. Keep content out of operational metrics.

    Validate dependency counters before treating them as ground truth. In the resolved [fallback bookkeeping](https://github.com/argmaxinc/argmax-oss-swift/blob/e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef/Sources/WhisperKit/Core/TranscribeTask.swift#L363-L376), the first retry can still report zero, and the count is assigned rather than accumulated across windows. Count actual attempts/windows in evaluation instrumentation or correct the adapter metric before tuning fallback budgets.

    Acceptance: a known failure must not count as delivered text; cancelled and copy-only sessions must be distinguishable; measured stages must explain wall-clock latency. Export aggregate distributions without exposing audio, transcript, prompt, or clipboard content.

13. **P2 — Builds are not reproducible, and release packaging has no validation gate.** Source-confirmed.

    [project.yml](/Users/michael/echo/project.yml:8) allows Argmax versions from 0.9.0 upward within its package constraint. The generated project, including `Package.resolved`, is ignored by [.gitignore](/Users/michael/echo/.gitignore:31). This checkout happens to resolve 0.18.0; a clean build can resolve differently. [.github/workflows/release.yml](/Users/michael/echo/.github/workflows/release.yml:46) builds and publishes without running the existing suite. The local build also emits Swift concurrency warnings in controller/store initialization, overlay callbacks, and capture locking; these are maintenance findings, not proof of current crashes.

    Change: track the resolved package lock independently of the ignored generated project, restore it during project generation, and require CI to use those pins. Record asset revisions; run existing checks plus an audio-replay smoke gate before packaging; document the supported Xcode version. Fix concurrency warnings around touched code before a separate Swift-language-mode migration. Validate the release artifact, including signing/permissions, on a clean supported machine.

    Acceptance: clean builds resolve the reviewed versions; packaging cannot silently skip required checks; Debug and Release share the same transcription policy and asset identity.

**Speed work, in recommended order**

| Order | Change | Why it is worth measuring | Boundary / tradeoff |
|---|---|---|---|
| 1 | Correct the inference warm-up and short-clip policy | Removes a verified integration mistake; potentially improves first-use latency and restores missing output | Measure launch-to-ready as well as first dictation; doing real work at startup increases startup work |
| 2 | Bound accessibility IPC and simplify target checks | [TextInserter.swift](/Users/michael/echo/Echo/Insertion/TextInserter.swift:87) makes several synchronous AX calls on the main actor, including diagnostic subrole/PID work | Use an explicit messaging deadline and safe fallback; instrument slow/hung destination apps; avoid unsafe detached use of AppKit objects |
| 3 | Budget relevant vocabulary and cache tokenization; move remaining storage work off the main actor | Large prompts add sequential decoder work and bypass the prefill cache; main-actor SQLite writes/queries also remain | Measure vocabulary accuracy versus prompt length; cache invalidation must include tokenizer/model and dictionary revision; preserve ordered persistence |
| 4 | Make decoder policy explicit and evaluate bounded fallbacks | The current dependency permits five temperature fallbacks; bad audio may pay multiple decode attempts | First measure actual fallback counts; reducing them can reduce accuracy. Do not cap tokens in a way that truncates valid speech |
| 5 | Evaluate trimming/no-speech improvements using actual decoder work | Fewer samples do not imply proportional inference savings: this implementation pads each entered window to the model window size | Show a measured latency benefit; do not trade quiet/boundary words for a smaller input array |
| 6 | Prototype incremental processing for longer dictations only if latency is still dominated by decoding | Work can begin before key release with the same weights | Larger effort: overlap/context reconciliation, CPU/power, cancellation, and repeated-word handling. Show provisional text in Echo; insert final text once |

Keep the current Whisper weights fixed through these comparisons. A later optional formatting layer should preserve names, numbers, identifiers, and meaning and expose the unmodified transcript. Spoken punctuation/newline commands and app-specific formatting are useful product work after the core text contract is reliable; the current cleanup collapses all whitespace.

**Secondary usability work**

- Make every Copy fallback visible even with clipboard retention enabled, and retain a recoverable recent result when history is disabled. Users should not interpret “returned to idle” as lost speech.
- Derive Home's Today counts from the same usage source as Insights. Currently Home uses retained history, so disabling/clearing history changes those counts while Insights continues counting. Count recognized words separately from snippet-expanded output; a short trigger should not look like hundreds of spoken words. Define language-appropriate counting if multilingual use is supported.
- Compute the all-time longest streak separately from the 20-week heatmap query in [InsightsView.swift](/Users/michael/echo/Echo/UI/InsightsView.swift:20), or label it as a recent-period statistic. Older records and ongoing streaks longer than that window are currently excluded.
- Add full-transcript detail, per-entry deletion, and a reviewed correction-to-dictionary flow. [TranscriptRow.swift](/Users/michael/echo/Echo/UI/TranscriptRow.swift:18) truncates History entries to three lines, and Add to Dictionary opens a blank editor. Optional raw/final comparison and applied-rule provenance would help identify whether recognition or processing caused an error; keep retention opt-in.
- Batch dictionary imports into one validated mutation/save rather than rebuilding and writing for every line in [DictionaryView.swift](/Users/michael/echo/Echo/UI/DictionaryView.swift:201). Offer import for an empty dictionary and check file size before loading it. Preserve literal snippet edge whitespace when saving; currently the store trims it despite the editor's verbatim-content promise. Add standalone-only/bypass modes for triggers users also need to discuss literally.
- Update error navigation: “try another input in the Echo menu” points to a menu that only contains Open/Quit; link directly to microphone settings. Refresh the microphone list and actual fallback name on hardware changes.
- Add keyboard/VoiceOver actions to [SnippetRow.swift](/Users/michael/echo/Echo/UI/SnippetRow.swift:39) and model rows. Snippet edit/delete controls are hover-only, and the accessibility element ignores its children. Model rows similarly hide child controls without equivalent actions.
- Clarify that model/tokenizer installation requires network access, while transcription runs locally. Avoid an unconditional “no network calls” claim. Distinguish keeping the mic engine warm from retaining audio; make microphone activity understandable.
- Explain and control usage retention separately: app identifiers, timestamps, and statistics remain stored with transcript history disabled. Add clear/export/retention choices without placing user content in operational metrics.
- Make the start-at-login toggle reflect actual system status and surface registration failures. Audit auto-dismiss timers and same-text repeated Copy offers using session IDs.

**Implementation sequence and decision gates**

Effort is relative: S is a focused local change, M spans several components, L needs device work or a new processing path. These are scope estimates, not promised speedups or dates.

| Increment | Deliverable | Effort | Depends on | Gate before moving on |
|---|---|---|---|---|
| A — Establish the baseline | Pin dependencies/assets, add aggregate export/replay instrumentation, select the local evaluation corpus | M | None | Reproducible build and recorded quality/latency baseline for the unchanged model |
| B — Fix correctness | Short clips/warm-up, clipboard ownership, target identity, session cancellation/recovery, physical hotkey tracking, one-pass rules | L; split into separate reviewable changes | A's version identity; baseline measurements can run alongside fixes | No deterministic loss/corruption in the scenarios above; existing checks pass |
| C — Recover reliably | Model validation/repair, finalized capture readiness, route handling, durable data edits/deletion, truthful outcomes | M–L | B's session ownership | Offline/permission/device/failure matrix has actionable recovery and no stale insertion |
| D — Tune quality and latency | Calibrated speech policy, vocabulary/language policy, prompt cache, bounded AX work, decoder experiments | M–L | A measurements, B/C correctness | Fixed-model paired comparisons improve the intended metric without quality regression |
| E — Optional long-dictation work | Incremental inference and final reconciliation prototype | L | D shows decode remains the dominant wait | Meaningful release-to-result improvement with unchanged final-output quality and acceptable memory/power |

Recommended first implementation batch: **reproducible dependency pinning, short-clip/warm-up repair, session identity followed by clipboard/target ownership, and non-recursive text rules**. Within increment B, introduce session identity before implementing transactions, cancellation, or owned timers; short-clip and text-rule fixes can proceed independently. Follow immediately with complete lifecycle/hotkey recovery. These have direct evidence and can be split into reviewable changes; the current evidence does not justify promising a percentage improvement in transcription accuracy or speed.

**Evaluation and release criteria**

Use the existing local benchmark protocol as the starting point. Keep model weights, artifact revision, language, dictionary contents, device/gain, and room conditions fixed for paired comparisons. Run a representative subset first, then the device matrix. Add at least the following scenarios:

| Dimension | Required scenarios | Observe |
|---|---|---|
| Short speech | 0.3–1.2 seconds, one-word replies, names, first/last plosives, trimmed short utterances | Empty-output rate, decoder runs, boundary omissions |
| Normal speech | 3–8 seconds, accents, numbers, technical vocabulary, punctuation | Raw and final WER/CER, exact names/numbers, unwanted rule edits |
| Long speech | Near 29/30/31 and 59/60/61 seconds; pauses; 120-second recording cap | Missing/duplicate boundaries, truncation, memory, release latency |
| Audio conditions | Quiet speech, noise, silence, music, background voices | False insertion and false rejection separately |
| Devices | Built-in, USB, Bluetooth; cold/warm; disconnect; format/default-route changes | Key-down-to-ready, onset/tail preservation, fallback correctness |
| Target/clipboard | Native, Electron, browser, terminal, password/no-field, app switch, overlapping copy | Correct destination, clipboard preservation, truthful outcome |
| Lifecycle | Cancellation, stalled decode, permission changes, startup/switch/rollback failure, sleep/wake | Recovery time, stale results, false Ready state |
| Data/rules | 0/100/1,000 rules, conflicting/cascading rules, corrupt files, failed writes, quit after clear | Determinism, durability, processor/UI latency |

Report p50 and p95 end-to-end and stage latency, separated into cold and warm runs and duration buckets. Report real-time factor, decoder retry counts, memory and power for larger changes. Distinguish release-to-dispatch from release-to-visible-text measured in controlled destinations. Collect enough repeated samples before interpreting tail percentiles.

Quality gates: no overall WER/CER regression on the fixed corpus; no increase in first/last-word omission or quiet-speech rejection; no meaning-changing formatting regressions; reduced false insertions on non-speech when changing speech policy. A quality fix may legitimately perform work that the old implementation incorrectly skipped, so compare latency only for equivalent successful output.

Reliability gates: zero wrong-known-target pastes, overwritten newer clipboard contents, recursive snippet corruption, or stale-session insertion in the controlled scenario matrix; no permanent busy state after cancellation/failure; clear operations persist across normal quit/relaunch or visibly report failure.

Performance gate: require a repeatable improvement in the intended p95 metric and report any launch-time, quality, memory, or power tradeoff. Do not treat faster empty output as an improvement. Use existing checks, audio replay, integration scenarios, manual device/application checks, and Instruments; **do not add unit tests**, per project instructions.

Keep audio and reference transcripts local and explicitly collected for evaluation. Operational export should contain aggregate metrics and configuration identity. Retaining raw/final text for diagnosis should be an opt-in local evaluation feature, not a new default history policy.

**Validation record**

Disposable probes loaded the existing production Swift definitions into `swift -` on macOS; store probes used temporary directories. No probe was added to the repository as a unit test. These are the inputs and observed outputs needed to repeat the cases:

| Probe | Input/setup | Observed result |
|---|---|---|
| Snippet recursion | Compile `my signature → Best, Alexander` and `Alexander → PRIVATE EXPANSION`; process standalone `my signature.` and inline `Please insert my signature here.` | Standalone: `Best, Alexander`; inline: `Please insert Best, PRIVATE EXPANSION here.` |
| Alias collision | Add dictionary entries with canonical words `Erik` and `Erick`, both with misspelling `Eric` | Both additions return success; the newer alias shadows the older one |
| Boundaries | Apply a `C++` rule to `use C++ today`; a `微信` rule to `请发到微信里面`; `email → REPLACED` to `email@example.com` | First two do not match; third becomes `REPLACED@example.com` |
| Corrupt store | Put malformed JSON at a temporary store's `snippets.json`; initialize `SnippetStore`; add a valid snippet | Loads zero entries; add returns success and replaces the corrupt original |
| Failed store write | Create a directory named `snippets.json` in a temporary store directory; initialize, add, then reload | Add returns success; reload contains zero entries |
| Converter carry-over | AVAudioConverter, mono Float32 48→16 kHz, same one-input-buffer/`.noDataNow` pattern as the recorder; feed four 1,024-frame buffers of `0.5`, then a 1,024-frame zero buffer; compare zero input on a fresh converter | Reused converter's zero buffer: 11 nonzero output samples, peak 0.53538; fresh converter: zero nonzero samples |

These probes establish the specified edge cases, not their frequency in normal use or their measured effect on recognition accuracy. The converter result is specific to this configuration and OS.

Executed against the existing generated project and cached resolved packages:

```sh
xcodebuild -project Echo.xcodeproj -scheme Echo -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/echo-review-20260925 \
  -clonedSourcePackagesDirPath /Users/michael/echo/build/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

Result: `TEST SUCCEEDED`; 173 existing checks, zero failures. [Build/check log](/tmp/echo-review-20260925-xcodebuild.log). The passing suite uses fakes for the transcription/controller paths and does not establish real ASR accuracy, device behavior, or successful cross-app paste. Release configuration, notarized-install permissions, actual model inference, and real-audio speed remain to be validated during the proposed work.
