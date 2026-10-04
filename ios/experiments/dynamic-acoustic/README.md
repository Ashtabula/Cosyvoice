# Independent symbolic acoustic experiment

Read `SOURCE_SHAPE_AUDIT.md`, `RESULTS.md`, and `evidence/phase1-gate.json` first. This directory does not replace any shipping exporter/runtime or Candidate asset.

Use the isolated Python3.11 environment under `ios/.work/dynamic-acoustic/venv`, installed from `requirements.txt`. Existing source/checkpoint/fixture inputs remain read-only in `ios/.work/rebuild/ios-fixed225-reference/{source,model-cache/Fun-CosyVoice3-0.5B-2512,fixture}`. The source must be pinned8789402; the exporters verify relevant Git blobs before execution. Every output directory must be new to preserve previous failure evidence.

1: `probe_symbolic_conditions.py` takes `--source-root`, `--model-dir`, `--fixture`, `--output`; uses true torch.export Dim(N), upstream interception, serialized CPU parity, independent Core ML compilation and durable failure receipts.

2: `probe_symbolic_shard0.py` takes the same inputs plus `--conditions-receipt`; only runs after the host symbolic conditions gate. Default FP16 matches the shipping compute precision; `--precision fp32` is an independent numerical control. Optional `--materialize-static-reshape-dims` uses only shape axes proven static by export metadata, preserving T. It never exports shards1-5.

3: `compare_fixed_shard0.py --dynamic <shard0 output folder> --fixed <untouched fixed shard0 package> --output <new receipt>` compares identical natural N225 inputs. Its nonzero exit currently means failure of the strict bit-exact regression control, not shape failure.

4: `stage_device_probe.py --conditions <conditions output folder> --shard0 <shard0 output folder>` creates a new `DeviceProbe/GeneratedAssets`; preserve prior staging before rerunning. It binds package/fixture/source receipt hashes and the actual Swift probe hash. Build the separate `DynamicAcousticProbe.xcodeproj` scheme `DynamicAcousticProbe` in Release, with the existing developer team and explicitly selected physical device. Xcode may redirect product paths in this user's environment; resolve the actual build product from build settings/logs instead of assuming DerivedData/Build/Products. No original DeviceSmoke resources are used.

5: Launch bundle `com.actacomes.cosyvoice3.dynamicacoustic` once with argument `CPU_ONLY`, then with `CPU_AND_NE`, using `devicectl --console` and tee to preserve logs. Retrieve Documents/dynamic-probe-<backend>.json from this bundle's appDataContainer before replacing/reinstalling. Each run reuses each loaded model at both lengths; it records compilation/loading/pending-first-prediction/error, output shapes and metrics. A process termination after completion must not be labeled an inference crash. Compute-plan preferred placement is not residency.

6: `evaluate_phase1_gate.py` takes `--conditions`, `--shard0`, `--fixed-control`, `--device-cpu`, `--device-ne`, `--output`. It separates symbolic source proof, execution, same asset family, numerical control, and unrun downstream gates. It currently exits1 and writes `phase2Allowed=false`.

The user's real early-EOS sentence is unchanged: “This is a CosyVoice3 production clean-room public API validation.” The frozen control is “This is a CosyVoice3 public API reference voice validation.” These full real-text cases are pending Phase4; no padding, EOS suppression, fixed225 fallback, model substitution or cap removal has been introduced.
