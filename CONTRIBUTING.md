# Contributing to Spacewalk

Spacewalk is a menu bar app for macOS 26 on Apple Silicon, maintained by one person in their
spare time. This guide is the contract for everyone who writes code here, human or agent.

## Before you write code

**Open an issue first.** Bugs, features and questions all start in
[Issues](https://github.com/tornikegomareli/Spacewalk/issues). A pull request implements an
issue. One that arrives with no issue behind it may be closed, however good the code is: design
belongs in the issue, where it is cheap to change.

Search before you post. React to an existing issue instead of writing "+1". Comment when you
have something to add, such as a reproduction, a diagnosis, or a case the issue does not cover.

### What a bug report needs

Spacewalk sits on top of the window server, ScreenCaptureKit, the Dock's gesture pipeline and
the Accessibility API, so "it did not work" is never enough to act on. Include:

- macOS version and Mac model, and how many displays are connected
- Spacewalk version, from Settings > General
- The output of `spacewalk status` right after the problem happened
- The effect, the trigger (hotkey, trackpad, mouse, CLI) and what you expected to see
- A screen recording for anything about a transition's look
- For a crash: the report from Console > Crash Reports

### What a feature request needs

- The case you are trying to solve, not the solution you have in mind
- How you work around it today

## Building and testing

```sh
swift build                        # everything
swift test                         # unit tests (Swift Testing)
Scripts/install-from-source.sh     # build, sign, install to /Applications, link the CLI, launch
```

`Scripts/package_app.sh` signs with `APP_IDENTITY` when that certificate is in your keychain and
ad-hoc otherwise. Ad-hoc signatures change on every build, and macOS forgets the Screen
Recording grant each time, so a real development certificate makes iterating much faster.

Offscreen diagnostics need no permissions: `spacewalk render <dir>|scrub|36` writes 36 PNGs of
the current effect, and `spacewalk snapshot <path>|settings` captures the settings window alone.
`docs/AUDIT.md` records the performance budget every transition is held to.

## Code style

Read the code around your change and match it: naming, comment density, file size, test style.
A patch that argues with its surroundings gets sent back, even when it is correct.

- Comments explain why, in plain English. The code already says what.
- No new dependencies. Sparkle is the only third-party code, confined to
  `Sources/Spacewalk/Updates/`; nothing else imports it.
- No new private API. The SkyLight calls and the Dock gesture fields in `SpacewalkCore` are the
  whole list; a change that needs more is a design discussion first.
- Every transition must stay smooth at 100 Hz with no flicker. Measure with `spacewalk render`
  and `spacewalk status` before and after.
- Settings are read from and written to `~/.config/spacewalk/config.toml`. A new setting gets a
  TOML key, a comment in `ConfigFile.render`, a default, and a round-trip test.

### Tests

Pure logic (timing curves, direction rules, TOML, key names, Dock event encoding) lives in
`SpacewalkCore` and is tested in `Tests/SpacewalkCoreTests`. Add a test with every change to it.
Anything that needs a display or a permission is verified by hand and the pull request says how.

## Branches and pull requests

Branch from `main`: `fix/<issue>-short-name` or `feat/<issue>-short-name`. One pull request per
issue, titled like a commit subject, with the issue linked in the body and a note on how you
tested it on real hardware. CI builds, tests and packages an ad-hoc signed app; it must be green.

Commits are small and say why. Pull requests are squash-merged.

## AI usage

Agents are welcome to write code here, and the maintainer uses them too. The person opening the
pull request is responsible for every line in it, has run it on a Mac, and says in the body that
an agent was involved. A pull request that nobody has run is closed.

## Decisions already made

Reopen one with an issue, not a pull request.

- Native macOS Spaces only. No window manager dependency, no SIP changes, no code injection.
- The Dock performs the switch; Spacewalk only renders the transition. State stays consistent
  because the Dock's own pipeline commits it.
- Twelve effects, each one perfect, over many configurable ones. Blur was tried and dropped: it
  cannot hold a 100 Hz frame on a 5K picture.
- Updates come from `appcast.xml` on `main`, signed with EdDSA. There is no server.

## Licensing

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
