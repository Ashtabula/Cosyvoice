# SDK Release Checklist

Updated: 2026-10-04.

This is the canonical cross-engine release checklist for the mobile speech engines consumed by the Demo applications. The project shorthand **检查单** means this file.

## Authority and synchronization

The canonical source is:

```text
Ashtabula/NPU_engines_Demo/SDK_RELEASE.md
```

All engine/platform mirrors listed below must remain byte-for-byte identical to this canonical file:

```text
Ashtabula/Zipvoice/iOS/SDK_RELEASE.md
Ashtabula/Zipvoice/HTP/SDK_RELEASE.md
Ashtabula/OmniVoice/iOS/SDK_RELEASE.md
Ashtabula/OmniVoice/HTP/SDK_RELEASE.md
Ashtabula/Cosyvoice/ios/SDK_RELEASE.md
Ashtabula/Cosyvoice/HTP/SDK_RELEASE.md
Ashtabula/VoxCPM_NPU/ios/SDK_RELEASE.md
Ashtabula/VoxCPM_NPU/HTP/SDK_RELEASE.md
```

A compatibility mirror may also exist at `Ashtabula/Zipvoice/SDK_RELEASE.md`; when present it must be identical too.

`检查单.md` is an alias of the local `SDK_RELEASE.md`. Do not maintain a second checklist body under the alias.

Only the canonical Demo copy is edited directly. Use the synchronization tooling in `NPU_engines_Demo/tools/` to update mirrors. Engine-specific implementation notes, current blockers, benchmark numbers, model names, runtime profiles, optimization experiments, device notes and release status belong in that engine's `README.md`, `API.md`, `ASSETS.md`, `VALIDATION.md`, `BENCHMARK.md`, manifest and committed receipts; they must not fork this checklist.

Demo-specific application gates live in `Ashtabula/NPU_engines_Demo/DEMO_RELEASE_CHECKLIST.md`. That file is subordinate to this canonical checklist and must never replace, truncate or redefine `SDK_RELEASE.md`.

The presence of this file in a platform directory does not assert that the platform implementation exists or has reached Development, Candidate or Production.

Performance measurements are recorded for comparison and regression tracking. This checklist does not impose a numerical speed threshold.

## Release levels

**Development** means the platform package has a build/package entry, non-empty implementation when the platform is claimed as implemented, basic metadata, and no false Candidate/Production claim.

**Candidate** means the package is independently consumable through its public API, has a complete fail-closed asset contract, reproducible build inputs, host/parity evidence where applicable, physical-device text-to-PCM evidence, benchmark evidence and a machine-readable release receipt.

**Production** means Candidate plus human audio review, clean-room consumer integration, release-tree reproducibility, redistribution/license review, public identity review, and immutable release asset publication when assets are distributed.

A platform may remain Development while other platforms for the same engine advance independently.

## Source isolation

- [ ] Runtime source is self-contained within the engine/platform package.
- [ ] Runtime does not depend on another engine implementation.
- [ ] Runtime does not depend on Demo application source, product UI, reader/player code or another Ashtabula repository.
- [ ] No developer-specific absolute path is required at build time or runtime.
- [ ] Runtime does not require Python.
- [ ] Maintainer-only conversion, optimization, benchmark and asset-build tools are separated from runtime source.
- [ ] A clean consumer can add the package/library without editing engine source.

Acceptance evidence should include a source-isolation audit, clean build evidence, or the equivalent check in `validation/release_receipt.json`.

## Public API boundary

- [ ] Developer-facing API accepts target text plus only user-meaningful parameters actually supported by the engine.
- [ ] Voice-cloning engines expose an explicit reference-audio/reference-transcript path when required by the model contract.
- [ ] Developer-facing API returns PCM/audio data with documented sample-rate/channel semantics.
- [ ] Engine selection in a consumer is by engine identity and public interface only.
- [ ] Model filenames, graph names, tensor names, token IDs, sequence buckets, scheduler steps, cache topology, worker count, compute-unit selection, accelerator lifecycle and optimization revision remain private implementation details.
- [ ] Internal optimization changes do not require Demo/consumer changes when the public contract is unchanged.
- [ ] Errors identify missing/incompatible assets or unsupported public inputs without requiring the caller to know internal model structure.
- [ ] No silent fallback to a different TTS/voice-cloning engine is permitted.

Acceptance evidence:

```text
API.md
public package/library source
clean-room or independent consumer receipt
```

## Asset contract

- [ ] Production-scale model binaries are distributed outside the ordinary source bundle unless intentionally small.
- [ ] The engine owns its asset manifest and required-file contract; consumers pass only the documented asset root.
- [ ] Every required asset has deterministic identity/hash metadata.
- [ ] Immutable prebuilt assets and locally rebuilt assets converge on the same runtime contract and validator.
- [ ] Asset validation fails closed on missing, malformed, hash-mismatched, wrong-platform or incompatible assets.
- [ ] Partially downloaded/staged assets cannot become active.
- [ ] Asset package identity records engine, platform, asset version, source-model revision and runtime/compiler identity where material.
- [ ] SoC-specific assets record and enforce compatible SoC/runtime identity where applicable.
- [ ] Repeated downloads/staging may reuse only a previously verified cache.
- [ ] Public hosting occurs only after required parity/device/clean-room/license gates.

Acceptance evidence:

```text
ASSETS.md
asset manifest / assets.txt equivalent
fetch/stage path
validate_assets or equivalent
asset receipt referenced by release_receipt.json
```

## Build and dependency reproducibility

- [ ] Platform build/package entry exists and is documented.
- [ ] Maintainer dependencies are pinned.
- [ ] Source model/revision is recorded.
- [ ] Conversion/compiler/runtime tool versions are recorded when they can affect compatibility.
- [ ] Required external source/model inputs are pinned or hash-bound.
- [ ] Failure to reproduce a required dependency stops the build instead of silently selecting an unverified substitute.
- [ ] A one-command or clearly bounded rebuild entry exists for the supported release path.
- [ ] Rebuild tooling uses project-local environments and does not silently mutate unrelated global developer state.
- [ ] Canonical release rebuilds record the exact environment used for the published asset.

## Development, build, validation and consumer environment

The canonical release-engineering and clean-room host for this project is **macOS on Apple Silicon**. The current reference clean-room machine is **Mac mini (M4)**. Candidate and Production release paths must be reproducible from a clean checkout on that Mac environment, or on a later macOS/Apple-Silicon host that has been explicitly revalidated as equivalent. Historical Linux/Windows workstations may remain in provenance notes, but they are not part of the supported release path and must not be required to build, stage, validate or consume a Candidate/Production release.

**Canonical macOS Development / Build Environment**

- [ ] The supported release build/bootstrap/packaging path runs on macOS Apple Silicon without requiring a Linux VM, container, remote Linux host or developer-specific workstation.
- [ ] The release receipt records the clean-room Mac hardware model/chip, exact macOS version/build, and the exact toolchain versions used for the validated build.
- [ ] Apple builds record Xcode version/build, Apple SDK version, Swift language mode and deployment target.
- [ ] Android/HTP builds record Android/JDK/Gradle/NDK/CMake versions when material, plus the exact QNN/QAIRT runtime SDK identity used by the Mac-hosted build.
- [ ] External accelerator/compiler/runtime SDK inputs required by the release path are usable from the canonical Mac host and are pinned by exact product/version/build identity.
- [ ] Maintainer-only model conversion/export/AOT steps that cannot run on macOS are not part of the Candidate/Production clean-room path. Their output must instead be represented by immutable, hash-bound release assets with recorded provenance and Mac-side validation.
- [ ] A Candidate/Production release is blocked if any required release step still depends on an unpublished Linux-only toolchain, an inaccessible historical `/home/...` tree, or another maintainer machine.
- [ ] Source archives, installers and vendor SDK packages required by the Mac clean-room path are pinned to an official source/release identity and SHA-256 when a stable archive is available.
- [ ] Build/bootstrap tooling uses project-local state and documented caches only; it does not silently depend on global developer state from prior experiments.

**Canonical macOS Validation Environment**

- [ ] Clean-room validation starts from a clean checkout on the Mac mini (M4) reference host, or an explicitly revalidated compatible macOS Apple-Silicon host.
- [ ] The full release-consumer sequence succeeds on that Mac: obtain/verify required assets -> build/package -> stage/install -> execute the public API on the physical target device -> finite non-empty PCM.
- [ ] Physical validation device model, SoC, OS version/build and relevant accelerator/runtime/driver identity are recorded.
- [ ] Validation records the exact public package/library source commit, immutable asset identity and clean-room Mac environment used.
- [ ] Clean-room validation must not read source, SDKs, converted models or caches from another workstation merely because they existed during development.
- [ ] A historical Ubuntu/Linux conversion environment may be recorded as provenance for an already frozen asset, but clean-room PASS requires the released Mac path to consume that immutable asset without rerunning the Linux-only conversion.
- [ ] A PASS applies only to the macOS clean-room path and target/device combinations actually validated; broader compatibility requires separate evidence.

**Consumer / Runtime Requirements**

- [ ] The documented release/clean-room integration path is Mac-first and is known to pass on macOS Apple Silicon.
- [ ] Public SDK consumers are not told to reproduce historical Linux-only conversion environments when the release provides immutable validated assets.
- [ ] Required vendor SDK closure is enumerated by logical component and exact ABI/accelerator subdirectory when material; the Mac clean-room fetch/bootstrap path obtains only what the Candidate/Production build actually needs.
- [ ] A supported bootstrap path first accepts an explicit local SDK root when provided and otherwise may obtain a pinned official archive, verify SHA-256, and extract only the required closure on macOS.
- [ ] Bootstrap/build code fails closed on version/hash mismatch and never silently substitutes a newer vendor SDK or runtime.
- [ ] Consumer build/run paths contain no developer-specific absolute path and do not depend on the original development machine.
- [ ] Additional non-Mac consumer hosts may be documented only when independently supported/validated; they are not required for the canonical release gate.

Recommended environment metadata belongs in `README.md`, `ASSETS.md`, `VALIDATION.md`, `BENCHMARK.md` and the machine-readable release receipt as applicable. Engine-specific version numbers, archive URLs and closure paths remain in engine-owned documentation/receipts rather than this engine-independent checklist.

## Correctness

- [ ] Host/source-model parity is validated where applicable.
- [ ] Runtime numerical validation is preserved across conversion/compilation where applicable.
- [ ] Real text reaches real PCM on a physical target device.
- [ ] Output PCM is non-empty and finite.
- [ ] Output sample-rate/channel contract matches the public API.
- [ ] Reference-conditioned output works when voice cloning is supported.
- [ ] Repeated synthesis does not require process restart.
- [ ] Cache/reuse paths do not change the accepted public output contract.
- [ ] Stop/EOS semantics and other termination rules are validated against the engine's source contract.
- [ ] No synthetic benchmark path may be presented as the production text-to-PCM path.

Acceptance evidence should be committed under `validation/` and referenced from the release receipt.

## Target runtime/backend execution

- [ ] iOS executes through the documented Apple/Core ML runtime path.
- [ ] HTP executes through the documented Qualcomm QNN/HTP runtime path.
- [ ] Requested/delegated/partition/residency claims are distinguished.
- [ ] Silent CPU or alternate-backend fallback is not reported as accelerator execution.
- [ ] Public claims do not exceed evidence exposed by platform tooling.
- [ ] Backend/compute placement remains private to the engine unless it is intentionally exposed as a public user control.

Allowed descriptive accelerator evidence levels include:

```text
none
not-claimed
requested
delegated
aot-full-partition
residency-proven
```

## Benchmark evidence

- [ ] A repeatable physical-device benchmark exists.
- [ ] Device model, SoC where relevant, OS/runtime version, SDK/source identity and asset identity are recorded.
- [ ] Cold initialization/reference setup and warmed repeated synthesis are distinguishable when both are measured.
- [ ] Benchmark corpus/workload is documented and frozen for comparisons.
- [ ] Generated audio duration uses the engine's returned native sample rate.
- [ ] Synthesis timing wraps the public synthesis call, not a private shortcut.
- [ ] Memory, thermal state and process energy/power may be recorded when available.
- [ ] Results and raw/summary receipts are preserved for regression comparison.
- [ ] Benchmark results are measurements, not release grades unless a separate explicit product requirement says otherwise.

Acceptance evidence:

```text
BENCHMARK.md
committed benchmark receipt / summary
release_receipt.json -> checks.benchmarkRecorded
```

## Clean-room integration

- [ ] Start from a clean checkout or independent consumer project on the canonical macOS Apple-Silicon clean-room host.
- [ ] Consume only the public package/library API.
- [ ] Obtain assets only through the documented public/staging path.
- [ ] Build on macOS Apple Silicon without another engine repository's source, Linux VM/container, remote Linux host or maintainer workstation being required.
- [ ] Install on a physical target device.
- [ ] Synthesize real text through the public API to finite non-empty PCM.
- [ ] No engine-source modification is required.
- [ ] The clean-room receipt records the exact engine source and asset identity.

A multi-engine Demo may provide consumer evidence only when each engine is invoked exclusively through its public API. Demo success does not override a missing engine-owned Candidate/Production gate.

## Audio review

- [ ] Human listening review is completed for the release path.
- [ ] Voice-cloned output is reviewed when voice cloning is supported.
- [ ] No known catastrophic clipping, non-finite output, empty output or severe termination defect remains undisclosed.
- [ ] Known quality limitations are documented rather than hidden.

## Licensing and notices

- [ ] Wrapper/source license is documented.
- [ ] Model weights/runtime assets have separately reviewed redistribution terms.
- [ ] Third-party notices are included where required.
- [ ] Commercial-use, attribution, non-commercial, gated-download or other restrictions are explicit.
- [ ] Distributed asset identities match the assets covered by the license review.
- [ ] `LICENSES.md` or equivalent is consistent with the actual release payload.

## Public release identity and provenance

- [ ] Development/validation/provenance history is preserved; historical commit SHAs are not rewritten merely to normalize identity.
- [ ] Formal external/public release author/committer/maintainer/submitter identity is `actacomes <developer@actacomes.com>`.
- [ ] A fresh public snapshot/history is created from the frozen accepted source when the public repository is established.
- [ ] Public identity gate scans documentation, scripts, package metadata and release artifacts for unintended personal identity residue.
- [ ] Source SHA, asset identity, device evidence and validation receipts remain traceable after publication.

## iOS platform gate

- [ ] `Package.swift` or the documented standalone Apple package entry exists.
- [ ] Runtime `Sources/` is sufficient for the public package.
- [ ] Public engine facade hides Core ML model/graph selection, sequence planning, scheduler details, cache policy and compute placement.
- [ ] Asset root is supplied through the public contract; the consumer does not inspect private model filenames.
- [ ] Reference preprocessing/enrollment is owned by the engine package when required.
- [ ] Physical iPhone smoke executes the same public API used by external consumers.
- [ ] Returned PCM is finite, non-empty and matches documented native sample-rate/channel semantics.
- [ ] Core ML/ANE claims are phrased at the evidence level actually proven.
- [ ] Release evidence records the exact Xcode version/build, Apple SDK version, Swift language mode and deployment target used for the validated package/device build.
- [ ] Consumer requirements distinguish ordinary Swift-package/app integration from maintainer-only model conversion or Core ML generation steps.
- [ ] Large assets can be staged/downloaded outside the base app bundle without changing the public synthesis API.

Acceptance sequence:

```text
clean checkout
-> obtain immutable assets OR rebuild from pinned inputs
-> validate canonical asset contract
-> add Swift package
-> install physical iPhone app
-> public validate/reference path
-> public synthesize call
-> finite PCM
-> committed receipts
```

## HTP platform gate

- [ ] Standalone Android library/module entry exists when HTP support is claimed.
- [ ] Public engine facade owns frontend/reference preparation, planning, bucket/model selection, QNN lifetime, decoder lifetime and PCM assembly.
- [ ] App developer does not call low-level graph/tensor/delegate methods to perform normal synthesis.
- [ ] QNN/QAIRT/runtime identity is recorded with exact vendor version/build identifier.
- [ ] SoC-specific asset identity is recorded and incompatible assets fail closed.
- [ ] The Candidate/Production HTP packaging/build/stage/validation path is reproducible on the canonical macOS Apple-Silicon clean-room host for each supported SoC/runtime family.
- [ ] Linux-only converter/AOT tooling may remain historical provenance for frozen assets, but it is not a supported release dependency. If a required asset cannot be supplied immutably and validated from the Mac clean-room path, Candidate/Production is blocked.
- [ ] The minimum QNN/QAIRT closure needed by the Mac-hosted build is documented, including required headers, Android target libraries and DSP/HTP libraries/architecture when applicable.
- [ ] When an official QAIRT/QNN archive is acquired automatically on macOS, its release identity and SHA-256 are pinned and only the required closure is extracted; hash/version mismatch fails closed.
- [ ] `QNN_SDK_ROOT` or equivalent explicit SDK-root override is supported when documented; Mac fallback acquisition must not silently select a different SDK version.
- [ ] Physical Qualcomm device execution is preserved as committed evidence.
- [ ] QNN/HTP execution claims are distinct from residency claims when tooling cannot prove both.
- [ ] Large assets are external to the base application package and consumed through the same public engine facade.

Acceptance sequence:

```text
clean macOS Apple-Silicon checkout
-> validated source graph
-> pinned Mac-side QNN/QAIRT runtime closure
-> SoC-specific runtime package
-> host/numerical validation
-> clean Android consumer
-> validate/stage compatible assets
-> install physical Qualcomm phone
-> public synthesize call
-> target-runtime evidence
-> finite PCM
-> committed receipts
```

## All-SDK clean-room rebuild gate

The canonical batch release check is repository-driven and fail closed. `SDK_CLEANROOM_MATRIX.json` must enumerate every engine/platform pair represented by the synchronized checklist mirrors. The one-command entrypoint is `bash scripts/rebuild_validate_all_sdks.sh`.

- [ ] Before every batch run, delete the entire tool-owned `.work/all-sdk-cleanroom` workspace and recreate it empty. The batch must never delete developer working trees, committed evidence or unrelated caches.
- [ ] Fresh clone every selected engine repository from its configured remote/ref into the disposable workspace; do not consume sibling `/Volumes/...` developer checkouts or previously staged clean-room source trees.
- [ ] Record the exact resolved Git commit for every fresh clone and require its platform `SDK_RELEASE.md` mirror to be byte-identical to the canonical Demo checklist before build/validation.
- [ ] Rebuild every available SDK from that fresh clone on the canonical macOS Apple-Silicon host before running device validation.
- [ ] Full validation must use only immutable/pinned asset acquisition or a release-documented Mac rebuild path. A local historical model/output directory may not silently satisfy a Candidate/Production clean-room gate.
- [ ] Each engine/platform entry is evaluated independently. A missing implementation, missing immutable asset path, missing clean-room entrypoint, missing device gate or incomplete release contract is reported as explicit `BLOCKED`; it is never silently skipped or counted as PASS.
- [ ] The batch must continue through every SDK after an individual FAIL/BLOCKED result so one broken engine cannot hide the state of later engines.
- [ ] iOS full gates use a physical iPhone and a real Apple Developer Team ID derived from certificate `subject.OU`; certificate display-name suffixes/Team Member IDs are not valid `DEVELOPMENT_TEAM` substitutes.
- [ ] HTP full gates use a physical compatible Qualcomm device and the exact pinned QNN/QAIRT runtime closure required by the Mac-hosted Candidate path.
- [ ] The batch writes per-SDK logs plus one aggregate `all_sdk_cleanroom_receipt.json` containing host identity, canonical checklist hash, source SHAs, build status, clean-room status and exact blocker/failure reason.
- [ ] Aggregate full validation returns nonzero unless every selected SDK is PASS. Host-only diagnostic mode must be labeled as such and must not be promoted to Candidate/Production evidence.
- [ ] The batch validator does not commit, push, publish, upload or promote evidence automatically. Publication remains a separate explicit release action after review of the aggregate and engine-owned receipts.

Current repository readiness is allowed to be mixed. The all-SDK batch is therefore both a release gate and a top-down gap detector: Development or not-yet-migrated platforms remain visible as `BLOCKED` until their engine-owned build/asset/device clean-room path is implemented.

Acceptance evidence:

```text
SDK_CLEANROOM_MATRIX.json
scripts/rebuild_validate_all_sdks.sh
scripts/rebuild_validate_all_sdks.py
.work/all-sdk-cleanroom-results/<run>/all_sdk_cleanroom_receipt.json
per-SDK logs referenced by that aggregate receipt
```

## Demo consumer integration gate

The two Demo applications are independent consumers, not engine implementation repositories.

- [ ] `VoiceBenchmark` and `RealtimeRadioPodcast` link engines only through their public package products.
- [ ] Demo registry contains only stable engine identity, public SDK-facing consumer metadata, a generic staging key, and public SDK factory/adapter information.
- [ ] Allowed registry metadata is limited to consumer-facing facts such as package product, documented/nominal public output format, reference support and public streaming support; Demo source contains no engine-private model filename, runtime profile, compute placement or optimization-revision selection.
- [ ] Demo asset staging uses only the generic `VoiceAssets/<engine-id>` container contract; the engine SDK validates the contents of its own asset root.
- [ ] Each Demo has its own sandbox asset copy or documented system-hosted asset path.
- [ ] Benchmark measures the common public synthesis boundary for every registered engine.
- [ ] Radio/Podcast uses the same public synthesis boundary and preserves the engine-returned native PCM sample rate.
- [ ] Demo PASS/FAIL receipts identify engine/source/asset identities but do not relabel an engine's release status.
- [ ] Demo README files link back to this checklist and the corresponding engine-owned evidence.

## Machine-readable release receipt

Candidate and Production should use:

```text
<platform>/validation/release_receipt.json
```

Minimum structure:

~~~json
{
  "schemaVersion": 1,
  "engine": "EngineName",
  "platform": "iOS-or-HTP",
  "releaseStatus": "candidate",
  "sourceCommit": "abcdef1234567890",
  "assetIdentity": "immutable-profile-or-tree-hash",
  "environment": {
    "cleanRoomHost": "Mac mini (M4), exact macOS version/build",
    "releaseHost": "macOS Apple Silicon",
    "toolchain": "exact Xcode, QAIRT/QNN, Android/NDK or equivalent identity used from macOS",
    "validationTarget": "physical device / SoC / OS / runtime identity",
    "historicalAssetBuildProvenance": "optional non-Mac provenance for already frozen immutable assets only",
    "consumerRequirements": "Mac clean-room integration path plus minimum target runtime/SDK closure"
  },
  "device": {
    "model": "physical device model",
    "soc": "required when material",
    "os": "OS/runtime version"
  },
  "checks": {
    "sourceIsolation": {"status": "PASS", "evidence": ["..."]},
    "standaloneBuild": {"status": "PASS", "evidence": ["..."]},
    "environmentRecorded": {"status": "PASS", "evidence": ["..."]},
    "assetValidation": {"status": "PASS", "evidence": ["..."]},
    "hostParity": {"status": "PASS", "evidence": ["..."]},
    "targetRuntimeExecution": {"status": "PASS", "evidence": ["..."]},
    "physicalDeviceExecution": {"status": "PASS", "evidence": ["..."]},
    "textToPcm": {"status": "PASS", "evidence": ["..."]},
    "benchmarkRecorded": {"status": "PASS", "evidence": ["..."]}
  },
  "accelerator": {
    "claim": "not-claimed",
    "evidence": []
  }
}
~~~

Candidate/Production receipts created or refreshed under this checklist should record the environment block above and identify the Mac clean-room host used. Historical non-Mac provenance does not need to be rewritten, but it cannot satisfy the current release-host gate by itself.

HTP Candidate receipts should additionally record SoC asset validation when SoC-specific assets are required, plus exact QNN/QAIRT version/build identity and the runtime SDK closure actually required by the Mac-hosted supported build path.

Production receipts additionally require evidence for:

```text
audioReview
cleanRoomIntegration
releaseTreeReproducible
licenseReview
publicIdentityReview
```

Every PASS check must reference committed evidence. Small machine-readable receipts are preferred over unbounded raw logs.

## Synchronization rule

The checklist body is maintained only in `Ashtabula/NPU_engines_Demo/SDK_RELEASE.md`.

When it changes:

1. run `python3 tools/sync_sdk_release.py --apply` from the Demo repository with cross-repository GitHub write credentials;
2. the tool updates every configured engine/platform mirror to the exact canonical bytes;
3. `python3 tools/sync_sdk_release.py --check` must report no drift;
4. alias files named `检查单.md` continue to point to the local `SDK_RELEASE.md`;
5. old platform-specific checklist bodies must not be recreated.

The Demo repository workflow `.github/workflows/sync-sdk-release.yml` performs the same synchronization when `SDK_RELEASE.md` changes and the cross-repository `CHECKLIST_SYNC_TOKEN` secret is configured.

## Final release rule

A platform is complete only when the gates required for its claimed release level have committed evidence. A Demo integration PASS is useful consumer evidence but does not substitute for missing engine-owned release evidence.

This checklist is intentionally engine-independent. Engine-specific implementation details belong outside this file.

# Code purpose: canonical cross-engine iOS/HTP release checklist and synchronization authority for all mobile speech-engine repositories and both Demo consumers.
# Upstream source: the ZipVoice release checklist/SDK release architecture, generalized to the public-interface-only multi-engine model.
# Runtime environment: repository/release engineering; no runtime dependency.
# Generated time: 2026-10-04 America/New_York.
# Changed lines: add the canonical all-SDK clean-room batch gate: destructive reset is limited to the Demo-owned disposable workspace, every engine/platform is fresh-cloned and rebuilt, missing/incomplete paths are explicit BLOCKED, validation continues across failures, and one aggregate fail-closed receipt records all eight SDK outcomes.
