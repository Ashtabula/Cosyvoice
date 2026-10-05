# Public release identity

Updated: 2026-10-03.

Formal external/public CosyVoice3 SDK releases use the namespace **actacomes**.

- Public GitHub target: `actacomes/Cosyvoice`.
- Public Hugging Face asset repository: `actacomes/CosyVoice-assets`.
- Canonical public maintainer/submitter: `actacomes <developer@actacomes.com>`.
- Development/validation/provenance repositories retain their historical commit objects and exact SHA-bound evidence; history is not rewritten merely to normalize author metadata.
- A public Git repository is created from the reviewed SDK snapshot with fresh one-commit history. The snapshot tool does not push or create a remote.
- Publication scripts fail closed rather than silently publishing under a different authenticated namespace.

Historical references to `Ashtabula/Cosyvoice`, `Ashtabula/CosyVoice3_NPU`, upstream model repositories and exact private validation commits may remain when they are explicitly provenance. They are not the public release identity.

Run the repository identity gate with:

```bash
python3 tools/check_public_identity.py
```

Create a fresh public SDK snapshot only after the non-license Production preflight passes:

```bash
bash tools/create_public_snapshot.sh /path/to/Cosyvoice-public
```

The public snapshot exports the explicit consumer SDK scope in `ios/public_snapshot_paths.txt`, flattens the `ios/` package directory to repository root, copies the repository Apache license, creates a fresh Git repository, and commits as `actacomes <developer@actacomes.com>`. It does not publish assets and does not authorize public redistribution.

# Code purpose: canonical public release identity and fresh-history policy for the CosyVoice3 SDK.
# Runtime environment: release engineering documentation only.
# Generated time: 2026-10-03 America/New_York.
