# Contributing to Nearside

Thanks for helping! Bug reports, device reports and pull requests are all welcome.

## Reporting a bug

Open an issue with:

- your computer (Mac model and macOS version, or PC and Windows version) and phone (model,
  Android version);
- what you did, what you expected and what happened;
- logs if you can: the helper's log (`adb shell cat /data/local/tmp/nearside-helper.log`), and
  the Mac app's (`log show --last 10m --predicate 'process == "Nearside"'`) or the Windows app's
  (`%LOCALAPPDATA%\Nearside\nearside.log`).

Reports from phones other than the Pixel 9 Pro, and from real Windows PCs, are especially
useful: phone apps in windows rely on Android internals that vary between versions and
manufacturers.

## Building

See [Build it yourself](README.md#build-it-yourself) and [docs/development.md](docs/development.md),
with its pages for the [Mac](docs/development-mac.md) and [Windows](docs/development-windows.md).
A development loop on the Mac:

```sh
(cd android && ./gradlew assembleDebug) && adb install -r android/app/build/outputs/apk/debug/app-debug.apk
adb shell 'kill $(pidof nearside-helper)'     # the Mac starts the new helper
(cd core && swift test) && (cd mac && swift test) && mac/scripts/bundle.sh && open mac/build/Nearside.app
```

The Mac app has test hooks driven by environment variables (`NEARSIDE_OPEN_APP`,
`NEARSIDE_TRACE`, `NEARSIDE_TEST_INPUT`…), and the Windows app has test switches (`--demo`…);
they're in each platform's development page. Bringing Nearside to another system, such as
Linux? Start with [docs/adding-a-platform.md](docs/adding-a-platform.md).

## Feature parity

The Mac and Windows apps always have the same features. A change that adds or changes
something users see does it on both, or says in its description why one has to wait (see
[Feature parity](docs/development.md#feature-parity)).

## Pull requests

- Keep changes focused: one fix or feature per pull request.
- Run `swift test` in `core/` and `mac/` (or build `windows/` and its app for a Windows change)
  and build the Android app before opening it. CI runs all of them.
- Match the style around you: small functions, comments that say *why*, plain names.
- Anything that touches security (authentication, the helper's permissions, what the phone
  exposes) needs a short explanation of the threat it handles in the description.
- Agree to the [Contributor License Agreement](CLA.md) by ticking its box in the pull
  request. You keep the copyright in your work. You allow the project to ship it under the
  [GNU Affero General Public License v3.0 or later](LICENSE), and also under other terms,
  such as a commercial licence. Your work always stays available as open source.

Code adapted from other projects must keep its licence notice in the file and be added to
[NOTICE](NOTICE).
