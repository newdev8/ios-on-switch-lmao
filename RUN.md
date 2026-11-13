# Running this checkout

Prepared 2026-11-12. HEAD `b2bbe4d`, module version `0.1.0`.

## Quick start

```sh
./run-image.sh --dry-run                  # the plan, about 30 s
./run-image.sh --out out/sd               # the image: downloads the IPSW's members, ~35 GB free
./run-image.sh --out out/sd --to-card disk4 --yes   # when the Switch SD card is attached
```

`disk4` is an example; use the card's disk from `diskutil list`. Without
`--to-card`, merge `out/sd` onto the card's FAT partition with `ditto`:

```sh
ditto --norsrc --noextattr out/sd "/Volumes/SWITCH SD"
```

Then boot hekate, open **Payloads**, run `install-ios.bin`, and choose
**More Configs -> iOS** after it finishes.

On Intel, `run-image.sh` also skips the Metal shader seed (its
`precompile`/`rawpack` tools are arm64-only) and says so. The GPU bundle is
staged without the m2v cache; shaders compile on first use.

## Built

`out/sd` is complete: iPadOS 17.7.11 (21H461), 8.7 GB in three parts.

```text
switchroot/ios/IOS17.SII.001   4.0G
switchroot/ios/IOS17.SII.002   4.0G
switchroot/ios/IOS17.SII.003   735M
bootloader/payloads/install-ios.bin
bootloader/ini/ios.ini
bootloader/res/icon_ios_hue.bmp
```

SHA-256:

```text
c18cbde12cc400ebb3c65d0ddd814a940e1d789bb1214bdf2a9d571a9424a415  IOS17.SII.001
d78ca2b3bddf6f3114a19aa8b2394caf210484822df296e3b470f701d72bfd1a  IOS17.SII.002
6279d05123df810cd484188476a15563c6adc118168529a7e31270c5d641bfeb  IOS17.SII.003
7586db8a16a429e6bafe5a1a81d8c7c828e3a19a97a6374a4951b6d74e0ad2b9  install-ios.bin
```

The image needs an iOS partition of **17150 MiB (16.7 GiB) or more**.

With the card attached:

```sh
diskutil list external
./run-image.sh --out out/sd --to-card disk4          # read-only plan
./run-image.sh --out out/sd --to-card disk4 --yes    # write and eject
```

`--to-card` asks for `sudo` in the terminal, so run it there rather than from
an agent. It only writes the FAT partition and never repartitions the card.

## What is set up

- `.tools/bin/bazelisk` 1.30.0, using Bazel 9.3.1.
- `.tools/bin/gh` 2.103.3.
- `.tools/bin/apfs_tool` and `.tools/bin/lz4`, built x86_64 for this Mac.
- `.release/`: the CI `release-assets` artifact, SHA-256 verified, with its
  arm64 `apfs_tool` and `lz4` replaced by the x86_64 builds and `SHA256SUMS`
  updated to match. Its `shader/` tools stay arm64; Intel builds skip the seed.
  `image-inputs.tar` is extracted at `.release/inputs/` for `--gpu-base`.
- `build-host-tools.sh` rebuilds both host tools.
- `fetch-assets.sh` downloads the CI artifact again and does the same swaps.
- `run-image.sh` wraps the image builder: release directory, lockfile, Xcode
  bypass, disk gate, and `image_to_card`.

The prebuilt kernel, GPU bundle, loader, overlay and host tools come from the
CI artifact because GitHub has no release for `0.1.0`. The artifact is from run
`42730816090`, built from this checkout's commit.

## Notes

- Switch **OLED only**. It needs a hekate setup and a microSD with a 32 GB or
  larger partition for iOS. Copy the card's contents somewhere safe first.
- The installation docs mention `bazel run //:image -- --copy-to-card`, but
  this checkout's `tools/install/image.py` does not implement that flag. Use
  `//:image_to_card` through `run-image.sh --to-card`.
- The checked-in `MODULE.bazel.lock` is stale for `install/release.bzl`;
  `run-image.sh` passes `--lockfile_mode=off`.
- A release build runs no Xcode tool, but the repository rule checks the
  selected Xcode. `run-image.sh` sets `SWITCH_ALLOW_UNPINNED_XCODE=1` for
  `--release`; a source build still needs Xcode 27.2 (`--local`).
- Bazel caches the external release repository. After replacing files in
  `.release/`, shut Bazel down and remove
  `<output_base>/external/@+release+switch_release.marker`; `fetch-assets.sh`
  does this itself.
- `run-image.sh` refuses under 35 GiB by default. The builder's own
  `space.check_run` is exact; override with `SWITCH_MIN_FREE_GB=<n>` when the
  disk is known to be large enough.
