# License and redistribution status

Source revision: `074ca6dc9e80a2f424f1f74b48bdd7d3fea531cc`. Root `LICENSE` declares Apache-2.0. Matcha-TTS submodule revision `dd9105b34bf2be2230f4aa1e4769fb586a3c824e` includes its MIT license in `third_party/Matcha-TTS/LICENSE`.

Pinned model revision `29e01c4e8d000f4bcd70751be16fa94bf3d85a18` declares `license: apache-2.0` in its model card. This snapshot has no separate LICENSE file. This records the publisher's checkpoint-level declaration; separate component provenance/attribution for bundled CAMPPlus, speech tokenizer and Qwen-derived weights still needs release review. Do not infer that the source license alone establishes every bundled asset's terms.

Runtime/conversion dependency license metadata and installed versions are captured in `validation/provenance/dependency-license-metadata.json`. Those Python packages are baseline/conversion dependencies, not all ios shipping dependencies. The prospective ios ONNX Runtime binary/version and its third-party notices are not yet selected, so its final distribution audit is pending. Accelerate/Core ML are platform frameworks governed by the Apple SDK terms.

The user supplied `asset/leijun-1.wav` and matching transcript for local validation. They are not authorized as redistributed package assets and are excluded from the shipping plan. No reference audio or pretrained weights are committed as part of this work.

Release license gate: OPEN. Retain Apache and MIT notices; complete component and final ios binary notices before distribution.
