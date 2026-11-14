#!/bin/sh
# Download the newest "Build iOS 27 inputs" run's artifacts into .release-ios27/.
#
# The run must be in a fork that carries .github/workflows/build-ios27.yml:
#
#   ./.tools/bin/gh auth login
#   ./fetch-ios27.sh [run-id]
#
# SWITCH_FORK=<owner>/ios-on-switch-lmao overrides the fork the default run is
# looked up in.

set -eu

cd "$(dirname "$0")"

GH="$PWD/.tools/bin/gh"
VERSION=$(sed -n 's/^[[:space:]]*version = "\(.*\)",.*/\1/p' MODULE.bazel | head -1)
FORK=${SWITCH_FORK:-}

[ -x "$GH" ] || { echo "error: $GH is missing" >&2; exit 1; }
"$GH" auth status >/dev/null 2>&1 || {
  echo "error: GitHub CLI is not logged in." >&2
  echo "       Run: $GH auth login -s repo,workflow,read:org" >&2
  exit 1
}

if [ -z "$FORK" ]; then
  OWNER=$("$GH" api user -q .login)
  FORK="$OWNER/ios-on-switch-lmao"
fi

RUN=${1:-}
if [ -z "$RUN" ]; then
  RUN=$("$GH" run list -R "$FORK" --workflow build-ios27.yml --limit 1 \
    --json databaseId,status,conclusion \
    | python3 -c 'import json,sys; runs=json.load(sys.stdin); print(runs[0]["databaseId"] if runs else "")')
fi
[ -n "$RUN" ] || { echo "error: no build-ios27.yml run found in $FORK" >&2; exit 1; }

TMP=$(mktemp -d .release-ios27.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading ios27-assets from $FORK run $RUN..."
"$GH" run download "$RUN" -R "$FORK" -n ios27-assets -D "$TMP/assets"

[ -f "$TMP/assets/SHA256SUMS" ] || {
  echo "error: the artifact has no SHA256SUMS" >&2
  exit 1
}
(cd "$TMP/assets" && shasum -a 256 -c SHA256SUMS)

if [ "$(uname -m)" != arm64 ]; then
  HOST_TAR=$(find "$TMP/assets" -maxdepth 1 -name '*host-tools*.tar' | head -1)
  if [ -z "$HOST_TAR" ]; then
    echo "error: the artifact has no host-tools tar" >&2
    exit 1
  fi
  if [ ! -x .tools/bin/apfs_tool ] || [ ! -x .tools/bin/lz4 ]; then
    echo "error: missing x86_64 host tools; run ./build-host-tools.sh first" >&2
    exit 1
  fi
  echo "Replacing the arm64 host tools with this Mac's x86_64 builds..."
  mkdir -p "$TMP/host"
  tar -xf "$HOST_TAR" -C "$TMP/host"
  for TOOL in apfs_tool lz4; do
    cp ".tools/bin/$TOOL" "$TMP/host/$TOOL"
    chmod 755 "$TMP/host/$TOOL"
  done
  (cd "$TMP/host" && tar -cf "$TMP/host-tools.tar" apfs_tool lz4 shader)
  mv "$TMP/host-tools.tar" "$HOST_TAR"
  python3 - "$TMP/assets/SHA256SUMS" "$(basename "$HOST_TAR")" "$(shasum -a 256 "$HOST_TAR" | awk '{print $1}')" <<'PY'
import sys

path, name, digest = sys.argv[1], sys.argv[2], sys.argv[3]
lines, found = [], False
for line in open(path).read().splitlines():
    fields = line.split()
    if len(fields) == 2 and fields[1].lstrip('*') == name:
        lines.append(f'{digest}  {name}')
        found = True
    else:
        lines.append(line)
if not found:
    lines.append(f'{digest}  {name}')
open(path, 'w').write('\n'.join(lines) + '\n')
PY
  (cd "$TMP/assets" && shasum -a 256 -c SHA256SUMS)
fi

INPUTS_TAR=$(find "$TMP/assets" -maxdepth 1 -name '*image-inputs.tar' | head -1)
[ -n "$INPUTS_TAR" ] || { echo "error: the artifact has no image-inputs tar" >&2; exit 1; }
mkdir -p "$TMP/assets/inputs"
tar -xf "$INPUTS_TAR" -C "$TMP/assets/inputs"

echo "Downloading ios27-kernel from $FORK run $RUN..."
if "$GH" run download "$RUN" -R "$FORK" -n ios27-kernel -D "$TMP/kernel"; then
  KERNEL=$(find "$TMP/kernel" -name 'kernel.macho' | head -1)
  if [ -n "$KERNEL" ]; then
    cp "$KERNEL" "$TMP/assets/kernel.macho"
  else
    echo "warning: ios27-kernel has no kernel.macho; the iOS 27 prelink needs a pinned report" >&2
  fi
else
  echo "warning: no ios27-kernel artifact; the iOS 27 prelink needs a pinned report" >&2
fi

echo "Downloading ios27-seed from $FORK run $RUN..."
if "$GH" run download "$RUN" -R "$FORK" -n ios27-seed -D "$TMP/seed"; then
  SEED_TAR=$(find "$TMP/seed" -name 'ios27-seed.tar*' | head -1)
  if [ -n "$SEED_TAR" ]; then
    mkdir -p "$TMP/assets/seed"
    tar -xf "$SEED_TAR" -C "$TMP/assets/seed"
  else
    echo "warning: ios27-seed has no ios27-seed.tar*; building without it" >&2
  fi
else
  echo "warning: no ios27-seed artifact; building without the seed" >&2
fi

rm -rf .release-ios27
mv "$TMP/assets" .release-ios27

if [ -x .tools/bin/bazelisk ]; then
  ./.tools/bin/bazelisk shutdown >/dev/null 2>&1 || true
  OUTPUT_BASE=$(./.tools/bin/bazelisk info output_base --lockfile_mode=off 2>/dev/null | tail -1 || true)
  if [ -n "$OUTPUT_BASE" ]; then
    rm -rf "$OUTPUT_BASE/external/+release+switch_release" \
      "$OUTPUT_BASE/external/@+release+switch_release.marker"
  fi
fi

echo
echo "iOS 27 inputs are in .release-ios27/."
if [ -d .release-ios27/seed/tree ]; then
  echo "The Metal shader seed is in .release-ios27/seed/."
fi
if [ -f .release-ios27/kernel.macho ]; then
  echo "The prelinked kernel is in .release-ios27/kernel.macho."
fi
echo "Now run:"
echo "  ./run-image.sh --ios27 --dry-run"
echo "  ./run-image.sh --ios27 --out out/sd"
