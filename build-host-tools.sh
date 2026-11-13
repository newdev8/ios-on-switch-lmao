#!/bin/sh
# Build the host tools the image builder runs, for this Mac. The CI release
# carries arm64 builds; on an Intel Mac, swap these in with ./fetch-assets.sh.

set -eu

cd "$(dirname "$0")"
mkdir -p .tools/bin .tools/src

# apfs_tool: measures and packs the APFS container.
clang -O2 -std=c11 -Wall -Wextra -Iboot/installer \
  boot/installer/apfs.c boot/installer/apfs_tool.c \
  -o .tools/bin/apfs_tool

# lz4 1.10.0, the version the boot package's `lz4 -12` is qualified with.
LZ4=lz4-1.10.0
if [ ! -x .tools/bin/lz4 ]; then
  if [ ! -f ".tools/src/$LZ4.tar.gz" ]; then
    curl -fL -o ".tools/src/$LZ4.tar.gz" \
      "https://github.com/lz4/lz4/releases/download/v1.10.0/$LZ4.tar.gz"
  fi
  echo '537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b  .tools/src/lz4-1.10.0.tar.gz' \
    | shasum -a 256 -c -
  [ -d ".tools/src/$LZ4" ] || tar -xf ".tools/src/$LZ4.tar.gz" -C .tools/src
  (cd ".tools/src/$LZ4" && clang -O3 -arch x86_64 -pthread \
    -DXXH_NAMESPACE=LZ4_ -DLZ4IO_MULTITHREAD -Ilib -Iprograms \
    lib/lz4.c lib/lz4hc.c lib/lz4frame.c lib/xxhash.c \
    programs/lz4cli.c programs/lz4io.c programs/bench.c programs/lorem.c \
    programs/threadpool.c programs/timefn.c programs/util.c \
    -o ../../bin/lz4)
fi

file .tools/bin/apfs_tool .tools/bin/lz4
.tools/bin/apfs_tool 2>&1 | head -1 || true
.tools/bin/lz4 --version
