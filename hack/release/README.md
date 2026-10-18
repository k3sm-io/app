# Release scripts

These scripts turn a signed k3sm tree into the notarized disk image users
download, and publish it with the k3sm release. The signing identity and the
notary credential are held by a person, so a release always runs attended.

## The release: `release.sh`

`hack/release/release.sh` is the one entry for a full release. Run it
yourself, in a terminal, from a clean k3sm checkout at the release tag:

```sh
hack/release/release.sh --version vX.Y.Z --stage-dir <dir> \
  --cp-build <dir> --ldflags <flags> \
  --identity "Developer ID Application: <name> (<TEAMID>)" --team-id <TEAMID> \
  --notes-file <file> [--repo <owner/name>] [--k3sm-dir <k3sm checkout>]
```

`--k3sm-dir` defaults to `../k3sm` beside this repo. In order, it:

1. runs the k3sm checkout's `hack/release/publish.sh --through-verify`,
   which stages, signs, verifies and packages the k3sm tree at
   `<stage-dir>`, then seals it
2. checks that the staged `k3sm` reports the tag's version and that the
   seal names the tree's `PAYLOAD-SHA256`
3. runs `hack/build-app.sh --version <x.y.z> --team-id <TEAMID> --payload
   <stage-dir> <stage-dir>.app-build`; `x.y.z` is the tag's core version, so
   `vX.Y.Z-rc.N` builds `X.Y.Z`
4. checks every file under the app's `payload/` against the tree's
   `PAYLOAD-SHA256`: exactly the listed files and the manifest itself, byte
   for byte, and nothing else; then the app's version and bundle id
5. runs `sign-and-notarize.sh`, which signs, notarizes and staples the app,
   then builds, signs, notarizes and staples
   `<stage-dir>.app-build/k3sm_<version>_darwin_arm64.dmg`
6. checks the image: its exact name; `codesign` against the Developer ID
   requirement, `stapler validate` and `spctl`; then, mounted read-only, a
   root holding only `k3sm.app` and the `Applications` link, the checks of
   step 4 again, the app's signature, staple and compiled Team ID pin, and no
   `K3smTeamID` in its `Info.plist`
7. runs `publish.sh --upload --disk-image <the image>`, which checks the
   seal, the tree and the image again before the draft release, then
   verifies the draft and promotes it

Any failure stops the run before the upload. `publish.sh --upload` repeats
every image check itself, so the checks here fail early and with a clearer
message; they are not the only ones. After the release is promoted, check
what users download with `verify-release.sh <tag>` (below).

## The rehearsal: `release.sh --rehearsal`

The unsigned mode the autonomous loop and the lab use:

```sh
hack/release/release.sh --rehearsal --version vX.Y.Z \
  [--k3sm-dir <dir>] [--ldflags <flags>] [--out-dir <dir>] [--stub-payload]
```

It runs the k3sm checkout's `hack/release/stage.sh` (ad-hoc signed, stamped
with the version), builds the app with `hack/build-app.sh --rehearsal` (bundle
id `io.k3sm.app.rehearsal`, no Team ID), builds the image with `make-dmg.sh`,
and runs the same payload and mount checks. In place of the signed checks
it requires an ad-hoc signature (`codesign -dv` reports `Signature=adhoc`, no
`Authority` and no Team ID) and no compiled Team ID stamp. Last, it writes
`k3sm_<version>_checksums.txt` beside the image, holding the image's line in
the release's checksums format (`<sha256>  <name>`), and runs
`verify-release.sh --image` on the two. Every script it
starts runs under `env -i` with only `PATH`, `HOME`, `TMPDIR`,
`DEVELOPER_DIR` and the Go toolchain locations, so no identity, Team ID,
notary or keychain setting reaches them. The output is
`k3sm_<version>_darwin_arm64-unsigned.dmg` and its checksums file in a fresh
directory under the workspace's `k3sm-io.scratch` (or `--out-dir`).

Two rehearsals of the same tree give the same layout, the same app and the
same payload, but not the same image bytes: `hdiutil create` writes fresh
volume UUIDs and timestamps into every image. The image's sha256 is therefore
recorded per build, in the checksums file, and the image is checked by its
contents, never by comparing digests across builds.

The rehearsal has no path to `publish.sh`, `gh`, `sign-and-notarize.sh` or a
Developer ID signature. Its app pins no Team ID, so the app's root step
refuses to install from it; install the staged tree through the CLI instead
(`sudo <out-dir>/stage/k3sm install`).

## Checking a published release: `verify-release.sh`

```sh
hack/release/verify-release.sh vX.Y.Z [--repo <owner/name>] [--team-id <TEAMID>]
hack/release/verify-release.sh --image <file.dmg> --checksums <file> [--team-id <TEAMID>]
hack/release/verify-release.sh --stable-url [--repo <owner/name>]
hack/release/verify-release.sh --self-test [<k3sm.app>]
```

With a tag it downloads `k3sm_<version>_darwin_arm64.dmg` and
`k3sm_<version>_checksums.txt` from the release (https only, no credential)
into a fresh private temporary directory and checks, failing on any miss:

1. the image's exact name, and exactly one checksums line for it whose sha256
   matches
2. the image's Developer ID signature (`codesign --verify --strict` against
   the Developer ID requirement, and `--team-id` when given), `spctl -a -t
   open --context context:primary-signature` and `stapler validate`
3. mounted read-only without browsing: the volume name `k3sm`, a root holding
   exactly `k3sm.app` and an `Applications` symlink to `/Applications`
4. the app's bundle id, version and `codesign --verify --strict --deep`; for a
   release, its Developer ID team, staple and compiled Team ID pin

`--stable-url` checks the latest release's stable link instead (network; the
self-test uses fixtures): the release carries both `k3sm_<version>_darwin_arm64.dmg`
and `k3sm_darwin_arm64.dmg`, the checksums file has exactly one line for each
with the same sha256, the release's asset digests match it, and a HEAD request
for `releases/latest/download/k3sm_darwin_arm64.dmg` redirects to that tag.

Nothing is mounted until 1 and 2 pass. `--image` runs the same checks on a
local image; an image named `-unsigned.dmg` is a rehearsal and must instead be
unsigned with an ad-hoc app. `--self-test` builds real images, a good
rehearsal image and broken copies (wrong checksum, no `Applications` link, an
extra root entry, the wrong volume name, a modified app and more), and
checks that only the good one passes; the Developer ID branch runs with fake
`codesign`, `spctl` and `stapler`. `hack/ci.sh` runs it around its rehearsal
app. The script signs, notarizes and uploads nothing.

## The pieces

- `hack/build-app.sh --version <x.y.z> --payload <tree> <outdir>` builds the
  app around a tree and writes the payload's SHA-256 manifest.
- `sign-and-notarize.sh <k3sm.app> <out.dmg> <identity> <team-id>` checks the
  payload signatures and the Team ID pin, signs the app inside out, notarizes
  and staples it, then builds the disk image with `make-dmg.sh`, signs it,
  notarizes it and staples it, and prints its SHA-256. It signs every Mach-O
  file under `Contents/MacOS`, `Contents/Helpers` and `Contents/Frameworks`,
  found by its magic number rather than by name or extension, deepest first
  and the main executable last, and verifies each against the Developer ID
  requirement for the team right after signing it. A file that fails is named
  and the run stops before the bundle is sealed; the main executable is
  verified with the bundle, right after the seal. A nested bundle (a
  `.framework` or a helper `.app`) is not signed as a bundle, so the bundle's
  `--deep` check fails on one and stops the run. Before signing anything it
  stops, naming the cause, if a directory cannot be listed in full or a
  Mach-O file has more than one hard link.
- `sign-and-notarize.sh --self-test` builds a fixture bundle in a temporary
  directory with an extra executable in `Contents/MacOS` and checks, with
  ad-hoc signatures and a requirement they satisfy, that every Mach-O is found
  (and no script, text file, symlink or `Contents/Resources` file), that each
  signs and verifies, and that an extra executable left unsigned or with
  another signature fails the run by name, with codesign's reason. It also
  checks that an unreadable directory and a hard-linked executable stop the
  run before any file is signed. It needs no identity, notary profile or
  terminal. `hack/ci.sh` runs it.
- `make-dmg.sh <k3sm.app> <out.dmg>` builds the image from an unsigned or
  ad-hoc signed app too, for local testing.
- `release.sh --self-test` runs every step above with fakes for `codesign`,
  `notarytool`, `stapler`, `spctl`, `hdiutil`, `gh`, `verify-release.sh` and
  the k3sm scripts.

## Credentials

- The Developer ID Application identity is non-exportable and set to prompt
  on use, in a keychain the unattended loop does not unlock. `release.sh`
  takes its name as an argument and never reads it.
- The notary credential is an App Store Connect API key stored under the
  keychain profile `k3sm-notary`. Scripts name the profile; they never read
  the key.
- `release.sh` (outside `--rehearsal` and `--self-test`),
  `sign-and-notarize.sh` (outside `--self-test`) and `publish.sh` refuse to
  run when `CLAUDECODE` or `K3SM_AUTO` is set, or without a terminal. Do not
  work around the refusal.
