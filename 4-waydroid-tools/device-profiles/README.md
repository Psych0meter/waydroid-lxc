# Device profiles

Each `*.prop` file here is a device identity Waydroid can be spoofed as,
selected with `apply-spoof.sh --device <name>` (the filename without
`.prop`) or the `SPOOF_DEVICE_PROFILE` environment variable - both
default to `pixel-5`. `apply-spoof.sh --list` (or `0-deploy-all.sh
--list-devices`) prints the available profiles with their description.

## Format

Plain `key=value` lines - a `waydroid_base.prop` fragment. `#` comments
and blank lines are ignored; the file's second line is used as the
profile's one-line description in `--list` output.

Every profile should define the same set of property keys as
`pixel-5.prop`. `apply-spoof.sh` deduplicates the result by key when
applying (keeping the latest value), so switching from one profile to
another only replaces cleanly if the new one covers every key the old
one did - a profile missing a key leaves the previous profile's value
for it in place.

## pixel-5.prop

The only profile shipped by default. Its values are vendored from
[Quackdoc/waydroid-scripts](https://github.com/Quackdoc/waydroid-scripts)'
`spoof-device.sh` (GPLv3) instead of being downloaded from GitHub at
install time - all credit for this property set goes to that project.

## pixel-7-pro.prop

Identity/build-fingerprint fields only, adapted from
[yubunus/DeviceSpoofLab-Hooks](https://github.com/yubunus/DeviceSpoofLab-Hooks)'
`device_profile.conf`. That project is an LSPosed module that spoofs
identifiers at the app layer via runtime hooks - a different mechanism
entirely from this repo's `waydroid_base.prop` injection - so its config
file is not itself a valid profile here: only the same key set as
`pixel-5.prop` was kept from it. The rest of that file (hardware/HAL,
CPU/GPU, security-state, and dozens of other non-Android-property keys)
must never be appended to `waydroid_base.prop` - several of those keys
(`ro.hardware`, `ro.boot.hardware`, `ro.hardware.vulkan`/`gralloc`/`power`/`egl`,
`ro.board.platform`) override values Waydroid's own image depends on to
find its binder HAL modules, which is exactly what happened the first
time this file was vendored verbatim: the container booted, but
`waydroidplatform` never came up (`journalctl -u waydroid-session`
looping on "Failed to get service waydroidplatform, trying again...").
`ro.adb.secure=1`, also present in the upstream file, would separately
have silently re-locked headless adb, undoing `enable-adb.sh`. See the
comment block in `pixel-7-pro.prop` itself for the full list.

## Adding another device

A search for other maintained, verifiable Waydroid device-spoof profiles
didn't turn up anything worth vendoring by default alongside it. What
exists instead: Quackdoc's own repo has only ever shipped this one Pixel
5 script (no other branches, tags, or profiles); a couple of other
repos turned up in search are tools for spoofing a *rooted physical*
Android device via Magisk/LSPosed hooks, a different mechanism entirely
from editing `waydroid_base.prop` before Waydroid boots, so they don't
apply here; and the rest were either low-quality (one disables adb
entirely, which would break this repo's GPS and screen control, and
references undefined shell variables) or offered fingerprints for
newer Pixel hardware that conflicted with each other between sources
with no way to verify which, if either, was accurate.

To add a real device yourself: pull `ro.build.fingerprint` and the
other keys above from a device you trust - `adb shell getprop
<key>` on a real phone, or an official Google factory image - copy
`pixel-5.prop` to `<name>.prop`, and replace every value, keeping the
same set of keys.
