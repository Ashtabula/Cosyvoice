# CosyVoice3 physical-device smoke host

This app imports only the standalone public `CosyVoice3Core` package. It does not import `StatefulLLMBench` or any internal runtime type.

Validation sequence:

`CosyVoice3Engine(assetRoot:)` -> `capabilities()` -> `validateReference(...)` -> `synthesize(...)` -> finite, non-silent mono Float32 PCM at 24 kHz.

The app auto-runs once at launch, writes `Documents/reference-smoke-receipt.json`, plays the PCM, and exposes the receipt JSON for copying.

The canonical asset root is never prematurely promoted. `prepare_device_smoke_assets.py` requires a schema-2 `PASS_HOST_PARITY` receipt, copies the runtime into `GeneratedAssets/Runtime`, merges the host-approved reference candidate models/tables into that staged copy, and changes only the staged manifest to the post-promotion status so the unchanged public API can be exercised. The source asset root remains unmodified.

The installer defaults to the publication work products already produced by the host gate:

- base runtime: `ios/.work/device-runtime`;
- host receipt: `ios/.work/reference-release/parity/reference_host_parity_receipt.json`;
- reference candidates: `ios/.work/reference-release/coreml`;
- migration source assets: `/Volumes/WD/Codes/CosyVoice3_NPU`.

If the base runtime does not exist, the installer calls `assemble_fixed225_runtime_from_migration.py` to create it from the already validated LLM/Flow/HiFT/F0 migration artifacts and the pinned checkpoint. The source repository is read-only.

Set only signing/device identity plus a real reference WAV and its exact transcript:

```bash
export DEVELOPMENT_TEAM=...
export DEVICE_ID=...
export COSYVOICE3_REFERENCE_WAV=/absolute/path/to/reference.wav
export COSYVOICE3_REFERENCE_TRANSCRIPT=/absolute/path/to/reference.txt
bash validation/install_device_smoke.sh
```

Override `COSYVOICE3_SOURCE_ROOT`, `COSYVOICE3_ASSET_ROOT`, `COSYVOICE3_HOST_PARITY_RECEIPT`, or `COSYVOICE3_REFERENCE_CANDIDATE_DIR` only when intentionally using non-default locations.

After PASS, copy `reference-smoke-receipt.json` from the app Documents container and formally promote a new manifest:

```bash
python3 tools/promote_reference_assets.py \
  --manifest /absolute/path/to/runtime/cosyvoice3_fixed225.json \
  --host-receipt /absolute/path/to/reference_host_parity_receipt.json \
  --device-receipt /absolute/path/to/reference-smoke-receipt.json \
  --output /absolute/path/to/promoted/cosyvoice3_fixed225.json
```

A conversion success alone is never sufficient for promotion.

## Finalize an accepted device run

After the app reports PASS and the audible result has been accepted, the promotion helper can pull the machine receipt directly from the installed app container. It validates the host/device receipt binding, promotes the six host-approved reference assets into the canonical fixed225 runtime, re-runs the asset validator with `--require-reference`, updates tracked custom-reference evidence, commits as `actacomes <developer@actacomes.com>`, and pushes `main`.

```bash
export DEVICE_ID=00008150-000A05CA1440401C
bash validation/finalize_reference_device_promotion.sh
```

The helper promotes only the custom-reference lane to `PASS_DEVICE_PARITY`. It deliberately leaves the overall SDK release status at `development` while unrelated Candidate blockers remain.
