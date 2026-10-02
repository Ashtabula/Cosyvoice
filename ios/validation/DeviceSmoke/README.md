# CosyVoice3 physical-device smoke host

This app imports only the standalone public `CosyVoice3Core` package. It does not import `StatefulLLMBench` or any internal runtime type.

Validation sequence:

`CosyVoice3Engine(assetRoot:)` -> `capabilities()` -> `validateReference(...)` -> `synthesize(...)` -> finite, non-silent mono Float32 PCM at 24 kHz.

The app auto-runs once at launch, writes `Documents/reference-smoke-receipt.json`, plays the PCM, and exposes the receipt JSON for copying.

The canonical asset root is never prematurely promoted. `prepare_device_smoke_assets.py` requires a `PASS_HOST_PARITY` receipt, copies the runtime into `GeneratedAssets/Runtime`, and changes only that staged copy to the post-promotion status so the unchanged public API can be exercised. The source asset root remains unmodified.

Set:

```bash
export DEVELOPMENT_TEAM=...
export DEVICE_ID=...
export COSYVOICE3_ASSET_ROOT=/absolute/path/to/runtime
export COSYVOICE3_HOST_PARITY_RECEIPT=/absolute/path/to/reference_host_parity_receipt.json
export COSYVOICE3_REFERENCE_WAV=/absolute/path/to/reference.wav
export COSYVOICE3_REFERENCE_TRANSCRIPT=/absolute/path/to/reference.txt
bash validation/install_device_smoke.sh
```

After PASS, copy `reference-smoke-receipt.json` from the app Documents container and formally promote a new manifest:

```bash
python3 tools/promote_reference_assets.py \
  --manifest /absolute/path/to/runtime/cosyvoice3_fixed225.json \
  --host-receipt /absolute/path/to/reference_host_parity_receipt.json \
  --device-receipt /absolute/path/to/reference-smoke-receipt.json \
  --output /absolute/path/to/promoted/cosyvoice3_fixed225.json
```

A conversion success alone is never sufficient for promotion.
