# UX audit and redesign

Date: 2026-10-04. Scope: the settings window, the menu bar item, first run, and where settings
live. References: Apple Human Interface Guidelines for macOS settings windows, toolbar tabs,
labels and terminology; the way Finder, Safari and System Settings arrange their preferences.

## What was wrong

1. **Too many controls, flat.** Four tabs held about fifty controls at one level: effect sliders,
   capture settle frames and debug slow motion sat next to the effect picker. HIG: show the few
   settings most people change, fold the rest away.
2. **Jargon.** "Eager start", "settle window", "predictive start", "intercept", "dim amount",
   "workspace" and "Space" mixed. HIG: say what happens, in the user's words, and use Apple's
   term, Spaces.
3. **No first run.** A new user met a window full of switches with no transition playing, because
   the two permissions were missing and only a line in the last tab said so.
4. **A popup for the main choice.** The transition, the one thing everyone changes, was one item in
   a twelve-entry popup. Apple shows such choices as a gallery (wallpapers, screen savers).
5. **Numbers instead of words.** Duration in milliseconds, dim in percent. Most people want
   Slow, Normal, Fast.
6. **Diagnostics in the open.** Switch timings and capture state in the main window, next to the
   launch-at-login toggle.
7. **Settings in an opaque blob.** A JSON blob in UserDefaults: not shareable, not editable, not
   versionable. Tiling users expect a file in `~/.config`.
8. **Menu bar menu** mixed a status line, a debug action and a toggle whose label ("Animate
   switches") did not say what off means.

## What changed

- **Four toolbar tabs** with icons, like Finder and Safari: General, Transition, Shortcuts,
  Advanced. Each tab has the few controls that belong there; fine tuning is a folded section.
- **Transition tab** leads with the live preview and a gallery of twelve cards. Speed is Slow,
  Normal, Fast or Custom. Direction is phrased as where the new Space arrives from.
- **Shortcuts tab** reads like System Settings > Keyboard: an action, a field. A Presets menu
  does the three common setups in one click. Trackpad is one choice: leave to macOS, switch
  instantly, follow my fingers. Mouse is two toggles.
- **General** holds what people look for first: menu bar, Spaces bar, Space names, login.
  Permissions appear here only while missing, as a banner with buttons.
- **Advanced** holds the config file (path, reveal, reload, export, import, warnings), the
  switching internals in plain sentences, and diagnostics.
- **First run** is one sheet: the two permissions with live status, then one choice of how to
  switch (keys, arrows or trackpad). Done.
- **Words**: Space, not workspace. "Start moving before macOS has switched", not predictive start.
  "Click when the swipe will switch", not haptic feedback. "Pause Transitions" in the menu.
- **Configuration file** at `~/.config/spacewalk/config.toml`, written with comments by the app
  on every change and reloaded on save. The old UserDefaults blob migrates once.

## Still open

- A real icon. The menu bar uses a symbol.
- The Spaces bar and the Overview use fixed sizes; they should scale with the display's text size.
- Accessibility: the Overview is keyboard-driven but has no VoiceOver labels on its cards.
