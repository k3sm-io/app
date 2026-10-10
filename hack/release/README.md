# Release scripts

These scripts turn a built `k3sm.app` into the notarized disk image users
download. The signing identity and the notary credential are held by a
person, so the signing step always runs attended.

## Order

1. Sign the staged k3sm tree inside out with the Developer ID Application
   identity, the hardened runtime and a secure timestamp, and verify it.
2. `hack/build-app.sh --version <x.y.z> --payload <signed-tree> <outdir>`
   builds the app around that tree and writes the payload's SHA-256 manifest.
   Check that the manifest matches the one published with the curl tarball.
3. `hack/release/sign-and-notarize.sh <outdir>/k3sm.app <out.dmg> <identity> <team-id>`
   checks the payload signatures, signs the app inside out, notarizes and
   staples it, then builds the disk image with `make-dmg.sh`, signs it,
   notarizes it and staples it, and prints its SHA-256.
4. Upload the image and its hash to the draft release, promote the release,
   then open the Homebrew cask pull request.

`make-dmg.sh <k3sm.app> <out.dmg>` also works on an unsigned or ad-hoc
signed app, for local testing.

## Credentials

- The Developer ID Application identity is non-exportable and set to prompt
  on use, in a keychain the unattended loop does not unlock.
- The notary credential is an App Store Connect API key stored under the
  keychain profile `k3sm-notary`. Scripts name the profile; they never read
  the key.
- `sign-and-notarize.sh` refuses to run when `CLAUDECODE` or `K3SM_AUTO` is
  set, or when stdin is not a terminal. Do not work around the refusal.
