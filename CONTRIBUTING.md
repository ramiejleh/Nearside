# Contributing to Nearside

Thanks for helping! Bug reports, device reports and pull requests are all welcome.

## Reporting a bug

Open an issue with:

- your Mac (model, macOS version) and phone (model, Android version);
- what you did, what you expected and what happened;
- logs if you can: the helper's log (`adb shell cat /data/local/tmp/nearside-helper.log`)
  and the Mac app's (`log show --last 10m --predicate 'process == "Nearside"'`).

Reports from phones other than the Pixel 9 Pro are especially useful: phone apps on the Mac
rely on Android internals that vary between versions and manufacturers.

## Building

See [Build it yourself](README.md#build-it-yourself). For a development loop:

```sh
(cd android && ./gradlew assembleDebug) && adb install -r android/app/build/outputs/apk/debug/app-debug.apk
adb shell 'kill $(pidof nearside-helper)'     # the Mac starts the new helper
(cd mac && swift test) && mac/scripts/bundle.sh && open mac/build/Nearside.app
```

The Mac app has test hooks driven by environment variables (`NEARSIDE_OPEN_APP`,
`NEARSIDE_TRACE`, `NEARSIDE_TEST_INPUT`…); they're documented in
[`docs/development.md`](docs/development.md), with how the code is organised.

## Pull requests

- Keep changes focused: one fix or feature per pull request.
- Run `swift test` in `mac/` and build the Android app before opening it.
- Match the style around you: small functions, comments that say *why*, plain names.
- Anything that touches security (authentication, the helper's permissions, what the phone
  exposes) needs a short explanation of the threat it handles in the description.
- Agree to the [Contributor License Agreement](CLA.md) by ticking its box in the pull
  request. You keep the copyright in your work. You allow the project to ship it under the
  [GNU Affero General Public License v3.0 or later](LICENSE), and also under other terms,
  such as a commercial licence. Your work always stays available as open source.

Code adapted from other projects must keep its licence notice in the file and be added to
[NOTICE](NOTICE).
