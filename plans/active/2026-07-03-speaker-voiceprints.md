# Persistent Speaker Profiles (Voiceprints) — Research Synthesis + Implementation Plan

- **Date:** 2026-07-03 (amended 2026-09-09 — see
  [Amendment](#amendment-2026-09-09))
- **Status:** READY TO IMPLEMENT. Phase 0: NO-GO on the July meeting corpus
  (pre-AEC echo contamination + only 3 usable sessions). Phase 0b (clean public
  corpus): **GO — embedding path validated** (no overlap: same-narrator
  0.05–0.23 vs different 0.47–0.84; tau/margin sweep = 100% TPR, 0% FPR across
  a 0.25–0.45 plateau). Phase 1 is **no longer corpus-blocked**: the 2026-09-09
  amendment replaces the "collect a post-AEC corpus first" gate with a local
  decision journal that produces a labelled corpus from dogfooding, so code can
  land behind a disabled flag while the product tau is confirmed. See
  `docs/research/2026-07-04-voiceprints-phase0-calibration.md` and
  `docs/research/2026-07-04-voiceprints-phase0b-clean-corpus.md`.
- **Trigger:** issue #662 (yakov0922) + a Reddit voiceprint post aimed at MacWhisper;
  related demand in #430, #106
- **Research:** 5 delegated reports in
  [`docs/research/2026-07-03-speaker-voiceprints/`](../../docs/research/2026-07-03-speaker-voiceprints/)
  (repo dive with file:line evidence · FluidAudio 0.15.4 API · matching best
  practices · competitor prior art · biometric privacy)
- **Builds on:** [`docs/plans/2026-06-14-002-speaker-diarization-world-class-architecture.md`](../../docs/plans/2026-06-14-002-speaker-diarization-world-class-architecture.md)
  (names "speaker memory" as the gap; this plan is its identity layer, made concrete)
  and [`plans/active/2026-05-speaker-diarization-quality.md`](2026-05-speaker-diarization-quality.md)

## Amendment (2026-09-09)

Re-verified against `main` (FluidAudio 0.15.6, speaker-correction layer shipped
in [PR #960](https://github.com/moona3k/macparakeet/pull/960)). Six errors, three
additions. Corrections are applied in place below.

**Scope locked:** meetings only · `rememberSpeakers` off by default and gated on
acknowledged consent · tau is a compiled constant with a hidden `UserDefaults`
override, never a user setting · calibration via a local decision journal, not an
on-demand re-diarization · literal #662 ask (recurring unknowns) out of scope, no
columns, no follow-up · permanent vectors only for enrolled people, plus short-lived
enrollment candidates that are never compared to each other (decision 9) · vectors as
`BLOB` in the user DB · no auto-apply.

**Corrections:**

1. **"Embeddings are already L2-normalized → dot product" is false, and fails
   silently.** `speakerDatabase` is the VBx *clustering centroid*, un-normalized:
   every segment of a cluster carries a copy of it
   (`OfflineReconstruction.swift:414-427`, `:302-356`), and `computeCentroids`
   (`:655-680`) never renormalizes and emits a zero vector when the denominator is
   zero. Two centroids of norm 0.85 with true similarity 0.90 score `1 − 0.85² ×
   0.90 = 0.350`, above tau: correct pairs rejected, no error, no log. Not fixable
   by moving tau — `‖centroid‖` shrinks with dispersion, so the bias is
   anti-correlated with signal quality. Phase 0b stays valid because the harness
   normalizes both vectors first (`analyze_voiceprints.py:40-45`). **Fix:**
   normalize once in `SpeakerEmbedding.init?`, rejecting norms < 1e-6.
   **Zero-vector clusters** (emitted when `computeCentroids` hits a zero denominator)
   are dropped from the embedding dictionary only: the cluster keeps its segments,
   its `SpeakerInfo` entry, its `idMapping` id and its duration total, so diarization
   output is unchanged and the cluster is simply unmatchable and un-enrollable.
   Fixture required.
2. **No per-segment embedding exists in the offline pipeline.** Duration-weighted
   re-aggregation is a no-op, and FluidAudio's responsibility-weighted centroid
   already beats duration weighting. Nothing to build here.
3. **The meeting insertion point is unreachable.** Before `finalize` the
   transcription is unpersisted (FK fails) and the fingerprint needs
   `transcriptSegments` (`TranscriptionService.swift:1503-1506`). Correct anchor:
   after `completeTranscription` returns (`:1509-1517`).
4. **Drop `transcriptions.speakerAssignments`.** `speaker_corrections` already
   owns label provenance, and `exportToJSON` encodes the whole `Transcription`
   struct (`ExportService.swift:228-234`) — the column would leak `profileId` by
   construction. Schema choice beats added redaction. Likewise no
   `.confirmVoiceProfile` command: a confirmation is an ordinary `.rename`.
5. **Model versioning was missing, and naive versioning is insufficient.** The
   centroid depends on clustering config the app already overrides, so a bump can
   move it without moving the model. Two ids: `embeddingModelId` (mismatch ⇒
   ignore) and `aggregationProfileId` (mismatch ⇒ compared at `tau − 0.05`;
   Phase 0b leaves a 0.24 gap, config drift costs hundredths). Never delete
   profiles on a bump — mark them and offer re-enrollment.
6. **The "speaker detection is opt-in, default off" premise is stale.** Both
   saved detection preferences currently resolve to `true`
   (`AppRuntimePreferences.swift:514-517`, ADR-010 July amendments). This plan
   neither relies on nor changes that: it adds `rememberSpeakers`, which stays
   off, and voiceprints never activate without it. Revisiting the detection
   default itself is an ADR-010 decision, out of scope here.

Also: `extractSpeakerEmbedding(from:)` lives on the streaming `DiarizerManager`
(`:92`), not on `OfflineDiarizerManager` — ad-hoc enrollment is not available to
us without wiring a second manager. Out of scope.

**Additions:**

1. **Mutual best match, with a margin on both sides.** The diarizer over-splits,
   so one speaker yields two clusters that each clear a cluster-side margin
   against *other* profiles — suggesting "Sarah" twice in one meeting. Mutual
   matching gives injectivity for free; the profile-side margin additionally
   rejects two clusters at 0.12 and 0.13 from the same profile as noise. Prior-art
   constants do not transfer (different model, similarity not distance); the
   policy does.
2. **Pollution guard on name-based enrollment.** Renaming to "Sarah" bypasses
   every threshold — two colleagues or one misclick merges two voices. Beyond 0.45
   from the existing profile, ask instead of merging.
3. **Decision journal replaces the corpus gate.** Log each decision locally
   (distances, gates, outcome, the label the user finally types); ~20 dogfooded
   meetings yield a labelled post-AEC corpus whose ground truth is what the user
   wrote. Diagnostic embeddings are ephemeral and never persisted as profiles.
   Lifecycle, since distances joined to labels are identifying:
   - **Owner:** `SpeakerVoiceprintService`, the only writer. No other component
     appends to it.
   - **Location:** a table in the user database, not a loose file — so it inherits
     the existing user-data deletion rules instead of needing its own.
   - **Retention:** 90 days, pruned on write. It exists to calibrate, not to
     accumulate; a rolling window is more than the ~20 meetings the calibration needs.
   - **Never leaves the machine:** excluded from exports, diagnostics and support
     bundles, like the profile tables.
   - **Deletion:** rows are purged atomically with whatever they reference — deleting
     a profile, a transcription, or all voice profiles takes its journal rows with it
     in the same transaction. No orphan row outlives its subject.

**Threshold:** start at `tau = 0.25`, not 0.30. The zero-FPR plateau runs
0.25–0.45 and the worst positive is 0.227, so 0.25 still accepts 21/21 while
buying margin against noisier post-AEC audio. A missed suggestion is a non-event;
a false one is the worst outcome this research documented.

## Verdict

Build it, phased, opt-in. The core is small because every layer below it already
exists or arrives free:

- FluidAudio's offline diarizer already returns a **256-d WeSpeaker embedding per
  detected speaker** (`DiarizationResult.speakerDatabase` — the un-normalized VBx
  clustering centroid; there is no per-segment vector, see Amendment 1-2). No new
  model, no new runtime, no added latency.
- The 2026-06-14 architecture plan already defines the guardrails (suggestions never
  silently rewrite; wrong automatic names are worse than anonymous speakers; profiles
  must be deletable; don't grow `SpeakerInfo` into a pseudo-profile).
- Of nine competitors surveyed, only Otter and Circleback ship persistent voice
  identity — both cloud-side. MacWhisper, superwhisper, Granola, Fathom, Krisp,
  Apple: none. **On-device voiceprints are open competitive whitespace** aligned
  with the private-speech-memory north star.

Two real risks, both handled: (a) embedding separation quality on compressed meeting
system audio → Phase 0 calibration spike before any product code; (b) biometric
privacy → strict enrollment-only scope + consent gate + deletion controls.

## What exists today (repo-dive report)

- Diarization is centralized: `DiarizationService.diarize(audioURL:)`
  (`Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift:101-157`),
  actor, ANEInferenceGate-wrapped, normalizes to `S1/S2` + `SpeakerInfo(id:,label:)`.
- Meeting path: mic track is identity-known (`speakerId = "microphone"` = Me); only
  the **system track** is diarized → `Others 1/2` (`TranscriptionService.swift:1266-1324`).
  Voiceprints only need to identify the *other* participants.
- File/URL path: diarize → `SpeakerMerger.mergeWordTimestampsWithSpeakers`
  (`TranscriptionService.swift:1397-1458`).
- Labels are structured, not baked into text: `transcriptions.speakers` JSON via
  `TranscriptionRepository.updateSpeakers` (`TranscriptionRepository.swift:433-439`).
  Rename UI: `TranscriptResultView.swift:2872-2990` → `TranscriptionViewModel.renameSpeaker`.
- Insertion point (meetings, v1): **after `completeTranscription` returns**
  (`TranscriptionService.swift:1509-1517`). The earlier "before `finalize`" anchor
  is unreachable — see Amendment 3.
- Audio retention (`deleteImmediately`, "Remove Audio Only") means **backfill of old
  recordings cannot be assumed** → embeddings must be captured at transcription time.
- This plan does not change the speaker-detection defaults. It adds one new
  preference, `rememberSpeakers`, which stays **off**. See Amendment 6 for the
  stale premise this replaces.

## What FluidAudio gives us vs what we build (fluidaudio-api report)

| Layer | FluidAudio 0.15.6 | We build |
|---|---|---|
| Embeddings | ✅ 256-d WeSpeaker centroid per speaker in every offline result — **not** L2-normalized (Amendment 1) | normalization on entry |
| Ad-hoc extraction | ❌ `extractSpeakerEmbedding(from:)` exists on the streaming `DiarizerManager` only, not on `OfflineDiarizerManager` | out of scope in v1 |
| Profile struct | ✅ `Speaker` + `RawEmbedding` are `Codable` (raw cap 50, centroid recompute, EMA update) | — |
| Persistence | ❌ `SpeakerManager` is in-memory only, and **explicitly unsupported with `OfflineDiarizerManager`** | GRDB store |
| Pre-matched diarization | ❌ offline labels are always fresh `S{n}` clusters | post-hoc matcher |
| Matching policy | partial (cosine *distance* utils; defaults 0.65 assign / 0.45 update) | thresholds + margin + duration gates, calibrated |

Scale warning: FluidAudio uses cosine **distance** (0 = identical; docs: <0.3
very-high confidence same speaker, 0.5–0.7 medium, >0.9 different). The Reddit
post's 0.80–0.90 same-speaker *similarity* numbers were pyannote-scale — do NOT
transplant them onto WeSpeaker. Hence Phase 0.

## Design

### Product shape (v1)

Enrollment flywheel, correction-based (the Otter/Circleback pattern, minus cloud):

0. Turning "Remember speakers" on opens the consent sheet ("I have the participants'
   permission…"). Refusing leaves the toggle off, and `rememberSpeakersEnabled`
   resolves to off until a consent date exists (Amendment, decision 9). The gate sits
   here rather than at the first enrollment because a voice is now kept at the end of
   every meeting: a gate on naming would arrive after the first write.
1. User renames "Others 1" → "Sarah" in an existing meeting transcript (existing UI).
2. If "Remember speakers" is enabled: prompt "Remember this voice as Sarah? Future
   meetings will suggest her name automatically."
3. Profile stored locally (embeddings only, never audio).
4. Next diarized recording: matcher compares detected-speaker embeddings against
   profiles → high-confidence matches surface as **suggestions** ("Looks like Sarah
   — confirm?"), never silent rewrites (2026-06-14 plan hard rule).
5. Confirmation applies the label via the existing rename path. Adding that
   meeting's embedding as a new profile sample is part of the confirm action's
   *disclosed* semantics ("Confirm and improve Sarah's voice profile") — samples
   are only ever added to already-enrolled profiles via this explicit act.
6. Unknowns stay "Others N". Below-margin matches stay unknown ("wrong automatic
   names are worse than anonymous speakers").

Scope call: v1 keeps two kinds of vector, and the difference is the whole privacy
argument.

- **Profile exemplars** are permanent and belong to a named person. Only an explicit
  enrollment or a confirmed suggestion creates one.
- **Enrollment candidates** (Amendment, decision 9) are short-lived and belong to no
  one. Step 1 above happens after the meeting, when the vector has already been
  discarded, so without them nothing can be named at all. They are consent-gated,
  capped at seven days, deleted on promotion or with their recording, and **never
  compared against each other**.

That last property is what keeps the issue's literal ask — "this voice appeared in 5
recordings, name them?" — out of scope: answering it means comparing unenrolled
vectors to one another, which is the ambient accumulation this plan refuses. Phase 3,
a separate opt-in, decided later.

### Matching policy (matching-best-practices report; numbers are pre-calibration placeholders)

- Open-set, **mutual best match** (Amendment, Addition 1): suggest only if
  `top1 distance ≤ τ`, the margin holds on **both** sides (`top2 − top1 ≥ margin`
  for the cluster *and* for the profile), and each is the other's best match.
  Ship values: τ = 0.25, margin = 0.10.
- **Singleton sides:** when a side has no second candidate (one enrolled profile, or
  one detected cluster) the margin is **vacuously satisfied**, not failed — the
  decision rests on τ alone. Failing it instead would make the feature unusable
  exactly when it matters most: the first enrolled speaker would never be suggested.
- **Ties:** if two candidates sit at an identical distance, the margin is 0 and the
  pair is rejected. No tie-break by id, insertion order, or recency — an arbitrary
  winner is precisely the "wrong automatic name" the invariant forbids. Both cases
  need explicit fixtures (singleton profile set, singleton cluster set, exact tie).
- Duration gates: embed only clean non-overlapped speech; per-speaker aggregate ≥3s
  usable, profile needs ≥15s total across ≥3 turns before it may suggest; never
  learn from <2s backchannels (snap those to the surrounding turn's label instead).
- Profiles: K ≤ 10 raw reference embeddings, **no stored centroid** (Amendment).
  Scoring is expressed in **cosine distance throughout**, so a profile scores as the
  **minimum** distance over its exemplars — the same rule the July text stated as
  "max over references" in similarity terms, restated in the shipping metric to
  remove the contradiction. It preserves per-channel modes either way. A centroid may
  be computed on the fly for display, never for scoring; samples added only on user confirmation
  (no silent EMA — poisoning/drift). **At most one sample per profile per
  recording**, and that sample is the normalized per-speaker centroid taken from
  `DiarizationResult.speakerDatabase`, rekeyed through `idMapping` — not a
  per-segment embedding, which the offline pipeline does not expose (Amendment 2).
  A recording yields one vector, so storing several would inflate `sampleCount`
  against no new evidence: K references must mean K distinct recordings.
- **At the cap, evict the oldest confirmation** (Amendment). K is a storage
  bound, not a scoring ceiling: vectors the matcher can never reach would be
  biometric data kept for nothing. Manual enrollments are spared, because
  `confirm` counts them to decide whether a profile may learn at all — evicting
  oldest-first would drop a mature profile back below that anchor for no visible
  reason. A profile holding K manual enrollments refuses further samples.
- Channel tags on every sample (`system`, `microphone`, `file`) — prefer
  same-channel references when scoring; channel mismatch is the default failure
  mode, not an edge case.

### Architecture

- **New GRDB migration `v0.39-speaker-voiceprints` + 3 tables** (raw SQL, style of
  `v0.32-speaker-corrections`, `DatabaseManager.swift:1374-1422`), joined by the
  decision journal in `v0.40` and enrollment candidates in `v0.41` (below):
  - `speaker_profiles`: id, displayName (`UNIQUE … COLLATE NOCASE`, so a second
    rename to "Sarah" adds an exemplar instead of a duplicate), embeddingModelId,
    aggregationProfileId, timestamps, lastMatchedAt, lastEvaluatedAt,
    lastEvaluatedDistance. **No `centroid` column** — scoring is `min` over
    exemplars, so a derived column would only add cache-coherency bugs.
  - `speaker_profile_exemplars`: vector `BLOB CHECK (length = 1024)`, speechSeconds,
    captureDomain, origin, the two model ids, `sourceTranscriptionId` with
    **`ON DELETE SET NULL`** (the user enrolled a person, not a recording),
    `UNIQUE (profileId, sourceTranscriptionId)` — the "one exemplar per recording"
    rule enforced by the schema rather than by code.
  - `speaker_profile_links`: (transcriptionId, speakerId, transcriptFingerprint) PK,
    profileId, status (suggested/confirmed/dismissed), distance, runnerUpDistance.
    Fingerprint-scoped like `speaker_corrections`, so a stale `dismissed` cannot
    permanently suppress a legitimate suggestion.
- **`v0.41-speaker-embedding-candidates`** (Amendment, decision 9), owned by
  `SpeakerEmbeddingCandidateRepository`: `UNIQUE (transcriptionId, speakerId,
  transcriptFingerprint)` — fingerprint-scoped for the same reason as the links, since
  after re-diarization the same id can mean another person — vector
  `BLOB CHECK (length = 1024)`, speechSeconds, captureDomain, the two model ids,
  `transcriptionId … ON DELETE CASCADE` (unlike an exemplar, a candidate *is* about
  that recording), and `expiresAt` **stored per row**, indexed, so raising the
  retention constant later cannot revive a vector promised a shorter life.
  Promotion and deletion are one transaction on the exemplar side:
  `insertExemplar` applies the cap and inserts, then the candidate row is dropped, so
  the vector is never stored twice. Writes happen only under
  `rememberSpeakersEnabled`, which requires acknowledged consent (decision 9), and
  only above `minSpeechSecondsToEnroll` — a vector that can never be promoted would
  be biometric data held for an offer never made. Never read by the matcher.
- **`SpeakerVoiceprintService`**, a `final class … @unchecked Sendable` — **not** an
  actor, aligning with its direct neighbour `SpeakerCorrectionService` (`:59`), since
  GRDB already serializes through `dbQueue`. Matching itself lives in a stateless,
  I/O-free `SpeakerVoiceprintMatcher` so it can be tested on fixtures alone. Cosine
  math on vectors normalized once at entry (Amendment 1); O(profiles × clusters),
  microseconds, no scheduler involvement.
  **Adapter prerequisite:** today `DiarizationService.diarize()` drops FluidAudio's
  `speakerDatabase`/segment embeddings when building `MacParakeetDiarizationResult`
  — Phase 1's first change is surfacing per-speaker embeddings through that
  adapter (behind the feature flag), otherwise the matcher has nothing to score.
- **Assignment provenance**: do NOT extend `SpeakerInfo`, and do NOT add a column to
  `transcriptions` (Amendment 4). `speaker_corrections` already owns label
  provenance with undo/redo and a single read model; identity metadata lives only in
  `speaker_profile_links`, which no export path touches. This also supersedes the
  2026-06-14 plan's Phase 1 step 4 ("Export `profileId`, `assignmentSource`, and
  confirmation state in JSON surfaces"): identity metadata never appears in exports.
- **Wiring**: the two insertion points above.
- **Settings**: "Remember speakers" toggle (default off, requires speaker detection
  on) + profile list with per-profile delete + "Delete all voice profiles".
- **Deletion semantics**: deleting a profile runs as **one transaction**. The
  `ON DELETE CASCADE` on `speaker_profile_exemplars.profileId` and
  `speaker_profile_links.profileId` removes every profile-owned row; transcriptions,
  their `speaker_corrections`, and any label already applied are untouched. The
  matching decision journal is purged for that profile in the same transaction.
  Tested by asserting that no row in either table references the deleted id, and that
  transcript labels survive. "Delete all voice profiles" is the same transaction over
  every profile, not a loop that can half-fail.
- **Export boundary**: `speaker_profiles`, `speaker_profile_exemplars`,
  `speaker_profile_links`, `speaker_embedding_candidates` and the decision journal are
  excluded from **every** outward surface — JSON/TXT/MD/SRT/VTT/PDF/DOCX exports,
  `ExportCommand.projectedJSON()`, diagnostics, support bundles, and any future
  database export. This holds by construction (no export path reads these tables, and
  nothing is added to `Transcription`), and PR 10 asserts it **per table on every
  surface**, so a table added later cannot inherit the exemption silently.
- **Privacy invariants**: profile store lives in the user DB, covered by existing
  user-data deletion rules.

## Privacy stance (privacy-biometrics report)

Voice embeddings built to recognize people ARE biometric data (BIPA names
"voiceprint"; GDPR Art. 9 explicit-consent territory; a 2026 Microsoft Teams BIPA
class action over speaker-ID voice data is live). Local-first flips this into a
differentiator, but honestly:

- Vendor risk (us): low — we never receive audio/embeddings/telemetry about them.
- User risk: real in workplace contexts (GDPR household exemption likely does NOT
  cover work meetings; BIPA has no household carveout). Surface it, don't bury it.
- Must-dos: (1) off-by-default + per-speaker explicit enrollment + "I have
  permission" acknowledgment; (2) local-only storage, per-profile delete, global
  wipe, excluded from every export path; (3) plain-language docs for business
  users; never claim embeddings are "anonymous"/"irreversible" (x-vector inversion
  research disproves it) — the true claim is "no audio stored, nothing leaves your
  Mac, delete anytime".

## Phases

- **Phase 0 — calibration spike (no product code, ~1–2 days).** Harness (hidden CLI
  subcommand or script) over Daniel's retained meeting corpus: run diarization,
  dump `speakerDatabase` embeddings per meeting, compute intra-/inter-speaker
  distance distributions across meetings + channels. Output: research report with
  separation evidence, chosen τ + margin, and a GO/NO-GO. Kills the feature
  cheaply if WeSpeaker can't separate on compressed system audio.
- **Phase 1 — core loop (meetings), ten independently shippable PRs.** PRs 1–6 are
  invisible to users, and the numbering matches the shipped PRs one-to-one:
  1. Surface embeddings through the diarization adapter: `SpeakerEmbedding` (normalizing
     on entry), `SpeakerCaptureDomain`, `SpeakerModelIdentity`, per-cluster speech
     durations, key remapping through `idMapping` (`DiarizationService.swift:227-234` —
     FluidAudio also uses `S1`/`S2`, so skipping the remap silently mislabels)
     ([#994](https://github.com/moona3k/macparakeet/pull/994)).
  2. Migration + `SpeakerProfileRepository`
     ([#996](https://github.com/moona3k/macparakeet/pull/996)).
  3. `SpeakerVoiceprintMatcher` — pure logic, the test-dense PR
     ([#1000](https://github.com/moona3k/macparakeet/pull/1000)).
  4. `SpeakerVoiceprintService` + decision journal + the preference, flag off
     ([#1001](https://github.com/moona3k/macparakeet/pull/1001)).
  5. Pipeline wiring: embeddings and durations through the finalizer, scoring after
     the transcript is saved, injection in `AppEnvironment`
     ([#1004](https://github.com/moona3k/macparakeet/pull/1004)). Split from 4, which
     the July plan had as one item: the service is testable on fixtures alone, while
     this touches the meeting path.
  6. Short-lived enrollment candidates (decision 9): without them nothing can be
     enrolled after the fact, because the vector is gone by the time the user types
     a name ([#1005](https://github.com/moona3k/macparakeet/pull/1005)).
  7. Consent sheet on the toggle + the enrollment prompt after a rename. The consent
     gate ships with, not after, the first surface that can turn writing on.
  8. Suggestion banner (confirm/dismiss).
  9. Voice-profile admin screen + a Reset & Cleanup row.
  10. Leak tests (export JSON, CLI `projectedJSON()`, feedback bundle), specs, ADR,
     privacy docs, telemetry allowlist.
- **Phase 2 — breadth.** File/URL-transcription path (the Reddit author's
  185-episode podcast case), profile management UI, confirmation-driven
  multi-sample updates, spec/02-features + contracts + new ADR (promote the
  2026-06-14 plan's speaker-memory section), user-facing privacy docs, CLI
  `speakers list|delete` parity.
- **Phase 3 — judged later, each its own decision.** Recurring-unknown detection
  (the issue's literal "appeared in 5 recordings" ask — still out of scope: it needs
  unenrolled vectors compared *against each other*, which decision 9's candidates
  never are, and its own opt-in); backfill scan over retained audio; live-path
  identity once live diarization (#430) ships; calendar-attendee hints (hints
  only, never authoritative).

## Decisions (Daniel, 2026-07-04)

1. **Auto-apply: strict confirm in v1.** Every match surfaces as a suggestion requiring confirmation; opt-in auto-apply (provenance chip + undo) reconsidered only after dogfooding shows precision.
2. **Ambient embeddings: NO.** v1 stores embeddings only for explicitly enrolled speakers; recurring-unknown detection remains a Phase 3 decision with its own opt-in. (Amended 2026-09-10: permanent storage is still enrollment-only, but decision 9 adds short-lived enrollment candidates — never compared to each other, so recurring-unknown detection stays out of scope.)
3. **BIPA posture: docs + consent gate only.** Permission acknowledgment plus plain-language guidance; no regional gating. (Amended 2026-09-10: the acknowledgment moved from the first enrollment to the toggle — see decision 9.)
4. **Podcast/file scope: Phase 2.** v1 is meetings-only to keep the first PR series reviewable.

## Decisions (2026-09-09)

5. **Tau is not a user setting.** Compiled constant, hidden `UserDefaults` override for
   dogfooding. A semantic three-step control is reconsidered only if calibration shows
   the right tau varies by user.
6. **Calibration by decision journal**, not by assembling a corpus or re-diarizing on
   demand. This lifts the Phase 1 corpus gate.
7. **Vectors in the user database as `BLOB`.** Not the keychain: two stores to keep in
   sync makes deletion a two-phase operation that can half-fail — the worst possible bug
   on biometric data — and keychain items are excluded from some backups.
8. **Admin screen ships with the feature, not after it.** No deletion surface means no
   right to erasure, which means not shippable. It also carries the diagnostic read-out
   that turns "this profile never matches" from a mystery into a number.

## Decisions (2026-09-10)

9. **Short-lived enrollment candidates**, revising decision 2. The flywheel needs the
   user to name a speaker in a finished transcript, but by then the vector is gone: it
   lives in memory during transcription, feeds scoring, and is discarded. The three
   alternatives are worse. Re-diarizing on demand needs audio that retention settings or
   "Remove Audio Only" may have purged, costs minutes for what reads as an instant
   action, and can re-cut the clusters — so the `speakerId` mapping may not survive, and
   a reconciliation error would enroll the wrong voice under the given name, the worst
   failure this feature has. An in-memory window makes the offer vanish on restart with
   no explanation a user could follow. Enrolling from a hand-picked excerpt needs a
   second FluidAudio manager (`extractSpeakerEmbedding` exists only on the streaming
   `DiarizerManager`) and puts the work on the user for every person.

   `speaker_embedding_candidates` therefore holds a vector per detected speaker, bounded
   on every side: written only while `rememberSpeakers` is on, only above the enrollment
   gate, never compared against each other (so this is not recurring-unknown detection),
   promoted to an exemplar and dropped on enrollment, deleted with their transcription,
   excluded from exports, stated in the consent sheet, and expiring after seven days on
   a per-row `expiresAt` so raising the constant cannot resurrect them. Anarlog keeps 45
   days; naming is a same-week action and unnamed vectors earn nothing by waiting.

   **The consent gate moves with the first write.** It sat at the first enrollment,
   which was sound while nothing was stored before one. Keeping it there now would let
   a user turn the toggle on and have vectors on disk having seen nothing, and gating
   candidate writes on a consent asked at naming time is circular — naming needs a
   candidate that would never have been written. So `rememberSpeakersEnabled` requires
   an acknowledged consent date alongside the toggle and speaker detection, and the
   sheet opens from the toggle. Amends decision 3.

   Decision 2 targeted ambient accumulation — an app that banks everyone's voice unasked.
   With the preference off by default nothing is stored until the user asks for the
   feature. But BIPA and the GDPR do not distinguish a useful print from a dormant one,
   and this is the first privacy invariant the series loosens rather than tightens, so it
   goes in the promoted ADR (Phase 2) explicitly rather than into a commit message.
