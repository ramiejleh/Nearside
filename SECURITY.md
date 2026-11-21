# Security policy

Nearside runs a helper with `adb shell` rights on your phone and can show your phone's apps
on your Mac, so security reports matter a lot to us.

## Reporting a vulnerability

Please **don't** open a public issue. Use GitHub's private reporting instead: the
**Security** tab of this repository → **Report a vulnerability**. Include the versions you used,
the steps to reproduce and what an attacker gains.

We aim to answer within a week. Fixes are released as soon as they're ready, and you're
credited in the release notes unless you'd rather not be.

## Scope

In scope: anything that lets another app on the phone, another device on the network, or
another user on the Mac read or control what Nearside carries (clipboard, notifications,
messages, files, phone apps), or use the helper's rights.

The design and its threat model are described in [`docs/security.md`](docs/security.md).

## Supported versions

Only the latest commit on `main` is supported while Nearside is in alpha.
