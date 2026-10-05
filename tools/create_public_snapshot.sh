#@title create_public_snapshot.sh
# Requirement: export the reviewed CosyVoice3 public Swift SDK scope into a fresh Git repository with canonical actacomes author/committer identity; do not push or publish assets.
#!/usr/bin/env bash
set -u -o pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; IOS="$ROOT/ios"; DEST="${1:-}"; PUBLIC_NAME="actacomes"; PUBLIC_EMAIL="developer@actacomes.com"
[ -n "$DEST" ] || { printf 'Usage: bash tools/create_public_snapshot.sh /path/to/output\n'; exit 2; }
case "$DEST" in /*) ;; *) DEST="$(pwd)/$DEST";; esac
cd "$ROOT" || exit $?
[ -z "$(git status --porcelain)" ] || { printf '[COSYVOICE3-PUBLIC-SNAPSHOT] ERROR source worktree is not clean\n'; git status --short; exit 3; }
python3 tools/check_public_identity.py || exit $?
python3 ios/validation/check_production_nonlicense.py || exit $?
python3 ios/validation/record_release_tree_reproducibility.py --check-only || exit $?
if [ -e "$DEST" ]; then [ -d "$DEST" ] && [ -z "$(find "$DEST" -mindepth 1 -maxdepth 1 -print -quit)" ] || { printf '[COSYVOICE3-PUBLIC-SNAPSHOT] ERROR destination must be an empty directory\n'; exit 4; }; else mkdir -p "$DEST" || exit $?; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git archive --format=tar HEAD -- ios LICENSE | tar -xf - -C "$TMP" || exit $?
while IFS= read -r spec; do
    case "$spec" in ""|"#"*) continue;; esac
    src="$TMP/ios/$spec"; dst="$DEST/$spec"
    [ -e "$src" ] || { printf '[COSYVOICE3-PUBLIC-SNAPSHOT] ERROR archived path missing: %s\n' "$spec"; exit 5; }
    mkdir -p "$(dirname "$dst")" || exit $?
    if [ -d "$src" ]; then mkdir -p "$dst"; cp -R "$src"/. "$dst"/ || exit $?; else cp "$src" "$dst" || exit $?; fi
done < "$IOS/public_snapshot_paths.txt"
cp "$TMP/LICENSE" "$DEST/LICENSE" || exit $?
git -C "$DEST" init -b main || exit $?
git -C "$DEST" config user.name "$PUBLIC_NAME"; git -C "$DEST" config user.email "$PUBLIC_EMAIL"; git -C "$DEST" add -A || exit $?
GIT_AUTHOR_NAME="$PUBLIC_NAME" GIT_AUTHOR_EMAIL="$PUBLIC_EMAIL" GIT_COMMITTER_NAME="$PUBLIC_NAME" GIT_COMMITTER_EMAIL="$PUBLIC_EMAIL" git -C "$DEST" commit -m "Initial public CosyVoice3 iOS SDK snapshot" || exit $?
EXPECTED="$PUBLIC_NAME <$PUBLIC_EMAIL>"; AUTHOR="$(git -C "$DEST" log -1 --format='%an <%ae>')"; COMMITTER="$(git -C "$DEST" log -1 --format='%cn <%ce>')"
[ "$AUTHOR" = "$EXPECTED" ] && [ "$COMMITTER" = "$EXPECTED" ] || { printf '[COSYVOICE3-PUBLIC-SNAPSHOT] ERROR identity mismatch\n'; exit 6; }
printf '[COSYVOICE3-PUBLIC-SNAPSHOT] PASS sourceHead=%s publicCommit=%s author=%s\n' "$(git rev-parse HEAD)" "$(git -C "$DEST" rev-parse HEAD)" "$AUTHOR"
# Code purpose: create the fresh-history public Swift SDK tree after non-license Production gates; no remote creation, push, asset visibility change or license approval.
# Upstream source: ios/public_snapshot_paths.txt and current reviewed private release tree.
# Runtime environment: POSIX shell, Git, tar, Python 3.
# Generated time: 2026-10-03 America/New_York.

# Changes 2026-10-03: public identity policy stays in the private release-engineering repository; the external consumer snapshot contains only the explicit Swift SDK scope plus Apache LICENSE.

# Changes 2026-10-05: quote the # pattern in the public snapshot path filter so bash -n does not parse it as a shell comment and truncate the case arm.
