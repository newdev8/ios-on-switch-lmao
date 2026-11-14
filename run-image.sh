#!/bin/sh
# Build the iPadOS install image for a Switch OLED, or dry-run the builder.
#
#   ./run-image.sh --dry-run                 print the plan (needs release assets)
#   ./run-image.sh --out /Volumes/SSD/sd     build out/sd (needs ~35 GB free)
#   ./run-image.sh --to-card disk4 --yes     build, then write the card (needs a card)
#   ./run-image.sh --local                   build the boot package from source (needs Xcode 27.2)
#   ./run-image.sh --ios27                   build iPadOS 27 from .release-ios27/ (see fetch-ios27.sh)
#   ./run-image.sh --seed-dir DIR            use a downloaded Metal shader seed (DIR/tree)
#   ./run-image.sh --no-seed                 skip the Metal shader seed (automatic on Intel)
#
# Release assets: GitHub has no release for this checkout's version. Put the CI
# artifact's files in .release/ (see fetch-assets.sh) or let Bazel fetch a real
# release if one is published. iPadOS 27 uses .release-ios27/ instead.

set -eu

cd "$(dirname "$0")"

REPO="brunostjohn/ios-on-switch-lmao"
BAZELISK="$PWD/.tools/bin/bazelisk"
VERSION=$(sed -n 's/^[[:space:]]*version = "\(.*\)",.*/\1/p' MODULE.bazel | head -1)
PREBUILT=release
DRY_RUN=0
IOS27=0
RELEASE_DIR=${SWITCH_RELEASE_DIR:-}
SEED_DIR=${SWITCH_SEED_DIR:-}
OUT=
SCRATCH=
TO_CARD=
CARD_YES=
NO_SEED=0

usage() {
  cat <<'EOF'
Build the iPadOS install image for a Switch OLED, or dry-run the builder.

  ./run-image.sh --dry-run                 print the plan (needs release assets)
  ./run-image.sh --out /Volumes/SSD/sd     build out/sd (needs ~35 GB free)
  ./run-image.sh --to-card disk4 --yes     build, then write the card (needs a card)
  ./run-image.sh --local                   build the boot package from source (needs Xcode 27.2)
  ./run-image.sh --ios27                   build iPadOS 27 from .release-ios27/ (see fetch-ios27.sh)
  ./run-image.sh --seed-dir DIR            use a downloaded Metal shader seed (DIR/tree)
  ./run-image.sh --no-seed                 skip the Metal shader seed (automatic on Intel)

Release assets: GitHub has no release for this checkout's version. Put the CI
artifact's files in .release/ (see fetch-assets.sh) or let Bazel fetch a real
release if one is published. iPadOS 27 uses .release-ios27/ instead.
EOF
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --ios27) IOS27=1; shift ;;
    --local) PREBUILT=local; shift ;;
    --release) PREBUILT=release; shift ;;
    --release-dir) RELEASE_DIR=$2; shift 2 ;;
    --seed-dir) SEED_DIR=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --scratch) SCRATCH=$2; shift 2 ;;
    --to-card) TO_CARD=$2; shift 2 ;;
    --yes) CARD_YES=--yes; shift ;;
    --no-seed) NO_SEED=1; shift ;;
    --copy-to-card)
      echo "error: --copy-to-card is in the docs but not implemented in this checkout." >&2
      echo "       Use --to-card <disk> [--yes] instead." >&2
      exit 2
      ;;
    -h|--help) usage 0 ;;
    --) shift; break ;;
    -*) echo "error: unknown option: $1" >&2; usage 2 ;;
    *) break ;;
  esac
done

[ -x "$BAZELISK" ] || { echo "error: $BAZELISK is missing" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || { echo "error: the image builder runs on macOS only" >&2; exit 1; }
[ -n "$VERSION" ] || { echo "error: cannot read the version from MODULE.bazel" >&2; exit 1; }

if [ -z "$RELEASE_DIR" ]; then
  if [ "$IOS27" = 1 ] && [ -f .release-ios27/SHA256SUMS ]; then
    RELEASE_DIR="$PWD/.release-ios27"
  elif [ -f .release/SHA256SUMS ]; then
    RELEASE_DIR="$PWD/.release"
  fi
fi
if [ -n "$RELEASE_DIR" ]; then
  case "$RELEASE_DIR" in
    /*) ;;
    *) RELEASE_DIR="$PWD/$RELEASE_DIR" ;;
  esac
  if [ "$PREBUILT" = release ] && [ ! -d "$RELEASE_DIR/inputs/gpu" ]; then
    INPUTS_TAR=$(find "$RELEASE_DIR" -maxdepth 1 -name '*image-inputs.tar' | head -1)
    if [ -n "$INPUTS_TAR" ]; then
      mkdir -p "$RELEASE_DIR/inputs"
      tar -xf "$INPUTS_TAR" -C "$RELEASE_DIR/inputs"
    fi
  fi
fi

if [ "$PREBUILT" = release ] && [ -z "$RELEASE_DIR" ]; then
  if ! curl -fsI "https://github.com/$REPO/releases/download/$VERSION/SHA256SUMS" >/dev/null 2>&1; then
    cat >&2 <<EOF
error: GitHub has no release assets for version $VERSION.

The image builder needs the prebuilt kernel, GPU bundle, loader, overlay and
host tools. This checkout can get them from the CI artifact, but that download
needs a GitHub login:

  ./.tools/bin/gh auth login
  ./fetch-assets.sh

Or download the "release-assets" artifact from
https://github.com/$REPO/actions and unpack it into .release/ yourself.
EOF
    exit 2
  fi
fi

# The pinned Xcode is 27.2. A release build runs no Xcode tool, but the
# repository rule still checks the selected Xcode unless this is set.
if [ "$PREBUILT" = release ]; then
  export SWITCH_ALLOW_UNPINNED_XCODE=1
else
  if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: a local build needs Xcode 27.2 (27B52) and its iOS SDK" >&2
    exit 1
  fi
  XCODE_VERSION=$(xcodebuild -version 2>/dev/null | awk 'NR==1 {print $2}')
  if [ "$XCODE_VERSION" != 27.2 ]; then
    echo "error: this build needs Xcode 27.2; this Mac has Xcode ${XCODE_VERSION:-unknown}." >&2
    echo "       Use the release assets (./fetch-assets.sh) or an Apple Silicon Mac with Xcode 27.2." >&2
    exit 1
  fi
fi

free_gib() {
  dir=$1
  while [ ! -d "$dir" ]; do dir=$(dirname "$dir"); done
  df -g "$dir" | awk 'NR==2 {print $4}'
}

if [ "$DRY_RUN" = 0 ]; then
  NEED_GB=${SWITCH_MIN_FREE_GB:-35}
  CHECK_DIR=${OUT:-out/sd}
  FREE=$(free_gib "$(dirname "$CHECK_DIR")")
  if [ "$FREE" -lt "$NEED_GB" ]; then
    echo "error: ${FREE} GiB free for ${CHECK_DIR}; the builder needs about ${NEED_GB} GiB." >&2
    echo "       Use --out and --scratch on an external APFS disk, or free space first." >&2
    exit 1
  fi
  if [ -n "$SCRATCH" ]; then
    FREE=$(free_gib "$(dirname "$SCRATCH")")
    if [ "$FREE" -lt "$NEED_GB" ]; then
      echo "error: ${FREE} GiB free for ${SCRATCH}; the builder needs about ${NEED_GB} GiB." >&2
      exit 1
    fi
  fi
fi

if [ "$PREBUILT" = release ] && [ "$(uname -m)" != arm64 ]; then
  echo "note: this Mac is $(uname -m); the release host tools need x86_64 apfs_tool and lz4." >&2
  echo "      ./fetch-assets.sh and ./fetch-ios27.sh put the builds from ./build-host-tools.sh there." >&2
fi

case "$SEED_DIR" in
  "") ;;
  /*) ;;
  *) SEED_DIR="$PWD/$SEED_DIR" ;;
esac
if [ -z "$SEED_DIR" ] && [ -n "$RELEASE_DIR" ] && [ -d "$RELEASE_DIR/seed/tree" ]; then
  SEED_DIR="$RELEASE_DIR/seed"
fi

CONFIG_FLAGS=
if [ "$IOS27" = 1 ]; then CONFIG_FLAGS="--config=ios27"; fi

# On Intel the only registered execution platform is arm64, so Bazel would build the host zipper and the arm64e
# translator from source (under --//install:prebuilt=release, with the no-toolchain setting, that fails analysis).
# The host platform and its x86_64 Apple toolchain run them here instead. Xcode 14.3.1's ld predates
# -no_warn_duplicate_libraries, which apple_support adds when the pinned xcode_config says 27.2.
PLATFORM_FLAGS=
if [ "$PREBUILT" = release ] && [ "$(uname -m)" = x86_64 ]; then
  PLATFORM_FLAGS="--extra_execution_platforms=@platforms//host:host"
  PLATFORM_FLAGS="$PLATFORM_FLAGS --extra_toolchains=@@apple_support++apple_cc_configure_extension+local_config_apple_cc_toolchains//:cc-toolchain-darwin_x86_64-x86_64"
  PLATFORM_FLAGS="$PLATFORM_FLAGS --features=-no_warn_duplicate_libraries"
fi

# iOS 27's prelink reads a pinned report of Darwin 27.2's kernelcache, which this checkout does not have: a kernel
# prelinked by CI (fetch-ios27.sh puts it in the release directory) takes its place.
KERNEL_FLAGS=
if [ "$IOS27" = 1 ] && [ -n "$RELEASE_DIR" ] && [ -f "$RELEASE_DIR/kernel.macho" ]; then
  if ! cmp -s "$RELEASE_DIR/kernel.macho" "$RELEASE_DIR/inputs/kernel/kernel.macho"; then
    cp "$RELEASE_DIR/kernel.macho" "$RELEASE_DIR/inputs/kernel/kernel.macho"
    # @switch_release links the local inputs (install/release.bzl); the one fetch that predates the copy holds the
    # artifact's own kernel.
    "$BAZELISK" shutdown >/dev/null 2>&1 || true
    OUTPUT_BASE=$("$BAZELISK" info output_base --lockfile_mode=off 2>/dev/null | tail -1 || true)
    if [ -n "$OUTPUT_BASE" ]; then
      rm -rf "$OUTPUT_BASE/external/+release+switch_release" "$OUTPUT_BASE/external/@+release+switch_release.marker"
    fi
  fi
  KERNEL_FLAGS="--//install:release_kernel=@switch_release//:kernel"
  echo "note: using the prelinked kernel in $RELEASE_DIR/kernel.macho." >&2
fi

SEED_FLAGS=
SEED_TREE=
SEED_SIZE=
if [ "$NO_SEED" = 0 ] && [ -n "$SEED_DIR" ] && [ -d "$SEED_DIR/tree" ] && [ -f "$SEED_DIR/tree.size.json" ]; then
  SEED_TREE="$SEED_DIR/tree"
  SEED_SIZE="$SEED_DIR/tree.size.json"
  SEED_FLAGS="--//install:shader_seed=//install:none --//install:shader_seed_size=//install:none"
  echo "note: using the Metal shader seed in $SEED_DIR." >&2
elif [ "$PREBUILT" = release ]; then
  if [ "$NO_SEED" = 1 ] || [ "$(uname -m)" != arm64 ]; then
    SEED_FLAGS="--//install:shader_seed=//install:none --//install:shader_seed_size=//install:none"
    echo "warning: skipping the Metal shader seed." >&2
    echo "         Its precompile and rawpack tools ship arm64-only; the GPU bundle is" >&2
    echo "         staged without the m2v cache, so shaders compile on first use." >&2
  fi
fi

case "$OUT" in
  "") ;;
  /*) ;;
  *) OUT="$PWD/$OUT" ;;
esac
case "$SCRATCH" in
  "") ;;
  /*) ;;
  *) SCRATCH="$PWD/$SCRATCH" ;;
esac

set -- "$@" 
if [ -n "$OUT" ]; then set -- "$@" --out "$OUT"; fi
if [ -n "$SCRATCH" ]; then set -- "$@" --scratch "$SCRATCH"; fi
if [ "$PREBUILT" = release ] && [ -n "$RELEASE_DIR" ] && [ -d "$RELEASE_DIR/inputs/gpu" ]; then
  set -- "$@" --gpu-base "$RELEASE_DIR/inputs/gpu"
fi
if [ -n "$SEED_TREE" ]; then
  set -- "$@" --shader-seed "$SEED_TREE" --shader-seed-size "$SEED_SIZE"
fi

FLAGS="$CONFIG_FLAGS --//install:prebuilt=$PREBUILT $SEED_FLAGS $PLATFORM_FLAGS $KERNEL_FLAGS"
if [ -n "$RELEASE_DIR" ]; then
  FLAGS="$FLAGS --repo_env=SWITCH_RELEASE_DIR=$RELEASE_DIR"
fi

if [ "$DRY_RUN" = 1 ]; then
  echo "+ bazelisk run $FLAGS //:image_dry_run -- $*"
  exec "$BAZELISK" run $FLAGS //:image_dry_run -- "$@"
fi

echo "+ bazelisk run $FLAGS //:image -- $*"
"$BAZELISK" run $FLAGS //:image -- "$@"

if [ -n "$TO_CARD" ]; then
  echo "+ bazelisk run $FLAGS //:image_to_card -- $TO_CARD $CARD_YES"
  exec "$BAZELISK" run $FLAGS //:image_to_card -- "$TO_CARD" $CARD_YES
fi
