# CosyVoice3 HTP public API

Status: **NO PUBLIC HTP API IMPLEMENTATION EXISTS**.

No developer-facing CosyVoice3 HTP engine facade is currently implemented in this repository. Consequently there is no supported Android/HTP synthesis API, no documented asset-root ABI, and no normal-synthesis QNN tensor/graph interface that application developers should call.

A future implementation must expose a high-level engine contract analogous in responsibility—not necessarily language/API shape—to the iOS `CosyVoice3Engine`: target text, model-required reference audio/transcript and user-meaningful options in; finite PCM/audio out. Graph names, tensors, QNN context selection, HTP lifecycle and SoC planning must remain engine-private.

Until such an implementation is accepted, consumers must treat CosyVoice3 HTP as unavailable rather than silently falling back to CPU, another engine or the iOS implementation.

# Code purpose: fail-closed HTP API status and future public-boundary requirement.
# Runtime environment: documentation only.
# Generated time: 2026-10-04 America/New_York.
