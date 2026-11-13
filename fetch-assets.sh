#!/bin/sh
# Download the newest CI "release-assets" artifact into .release/ and verify it.
#
# The repository has no published GitHub release, but its CI job uploads the
# same prebuilt kernel, GPU bundle, loader, overlay and host tools as an
# artifact. Artifacts need a GitHub login:
#
#   ./.tools/bin/gh auth login
#   ./fetch-assets.sh

set -eu

cd "$(dirname "$0")"

REPO="brunostjohn/ios-on-switch-lmao"
GH="$PWD/.tools/bin/gh"
VERSION=$(sed -n 's/^[[:space:]]*version = "\(.*\)",.*/\1/p' MODULE.bazel | head -1)

[ -x "$GH" ] || { echo "error: $GH is missing" >&2; exit 1; }
"$GH" auth status >/dev/null 2>&1 || {
  echo "error: GitHub CLI is not logged in." >&2
  echo "       Run: $GH auth login" >&2
  exit 1
}

TMP=$(mktemp -d .release.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

"$GH" api "repos/$REPO/actions/artifacts?per_page=100" > "$TMP/artifacts.json"
RUN=$(python3 - "$TMP/artifacts.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
artifacts = [
    a for a in data.get('artifacts', [])
    if a.get('name') == 'release-assets' and not a.get('expired')
]
artifacts.sort(key=lambda a: a['created_at'], reverse=True)
print(artifacts[0]['workflow_run']['id'] if artifacts else '')
PY
)

[ -n "$RUN" ] || { echo "error: no unexpired release-assets artifact found" >&2; exit 1; }

echo "Downloading release-assets from run $RUN..."
"$GH" run download "$RUN" -n release-assets -D "$TMP/assets"

[ -f "$TMP/assets/SHA256SUMS" ] || {
  echo "error: the artifact has no SHA256SUMS" >&2
  exit 1
}

(cd "$TMP/assets" && shasum -a 256 -c SHA256SUMS)

# The CI's host tools are arm64. On Intel, swap in the apfs_tool and lz4
# built here; the image builder executes both.
if [ "$(uname -m)" != arm64 ]; then
  HOST_TAR=$(find "$TMP/assets" -maxdepth 1 -name '*host-tools*.tar' | head -1)
  if [ -z "$HOST_TAR" ]; then
    echo "warning: no host-tools tar in the artifact; leaving it as is" >&2
  elif [ ! -x .tools/bin/apfs_tool ] || [ ! -x .tools/bin/lz4 ]; then
    echo "warning: missing x86_64 host tools; run ./build-host-tools.sh first" >&2
    echo "         the dry run will work, the real image will not" >&2
  else
    echo "Replacing the arm64 host tools with this Mac's x86_64 builds..."
    mkdir -p "$TMP/host"
    tar -xf "$HOST_TAR" -C "$TMP/host"
    for TOOL in apfs_tool lz4; do
      if [ ! -f "$TMP/host/$TOOL" ]; then
        echo "error: the host-tools tar has no $TOOL" >&2
        exit 1
      fi
      cp ".tools/bin/$TOOL" "$TMP/host/$TOOL"
      chmod 755 "$TMP/host/$TOOL"
    done
    (cd "$TMP/host" && tar -cf "$TMP/host-tools.tar" apfs_tool lz4 shader)
    mv "$TMP/host-tools.tar" "$HOST_TAR"
    SUM=$(shasum -a 256 "$HOST_TAR" | awk '{print $1}')
    python3 - "$TMP/assets/SHA256SUMS" "$(basename "$HOST_TAR")" "$SUM" <<'PY'
import sys

path, name, digest = sys.argv[1], sys.argv[2], sys.argv[3]
lines = []
found = False
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
fi

rm -rf .release
mv "$TMP/assets" .release

INPUTS_TAR=$(find .release -maxdepth 1 -name '*image-inputs.tar' | head -1)
if [ -n "$INPUTS_TAR" ]; then
  mkdir -p .release/inputs
  tar -xf "$INPUTS_TAR" -C .release/inputs
fi

# Bazel caches a repository rule's result, so a replaced host-tools tar would
# otherwise stay the old one. Drop that external repo and its marker.
if [ -x .tools/bin/bazelisk ]; then
  ./.tools/bin/bazelisk shutdown >/dev/null 2>&1 || true
  OUTPUT_BASE=$(./.tools/bin/bazelisk info output_base --lockfile_mode=off 2>/dev/null | tail -1 || true)
  if [ -n "$OUTPUT_BASE" ]; then
    rm -rf "$OUTPUT_BASE/external/+release+switch_release" \
      "$OUTPUT_BASE/external/@+release+switch_release.marker"
  fi
fi

echo
echo "Release assets are in .release/. Now run:"
echo "  ./run-image.sh --dry-run"
echo "  ./run-image.sh --out out/sd"
