# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Releases are
tagged `v<build>`, where `<build>` is the build number `YYMMDDNNN`: it is the `<version>` of both
drivers and the `?v=` of the webview assets, so a release, its two `.c4z` files and the driver
version shown in Composer carry the same number.

## [Unreleased]

## [v261015001] - 2026-10-15

First public release.

### Controller (`daylight_circadian_controller`)
- Multi-instance engine: one schedule per group of Light V2 tunable-white lights.
- 3–10 switchpoints, each at a fixed time or relative to Sunrise, Solar Noon, Sunset or Solar
  Midnight (offset ±180 min); astronomical times are computed from the project latitude and
  longitude with the system time zone and DST, and recalculated every midnight.
- Monotone cubic interpolation over a cyclic day for brightness and colour temperature; colour
  temperature limits per controller and per lamp.
- Scheduler modes: Brightness + Colour Temperature, Brightness Only, Colour Temperature Only.
- Smart Light Level Monitoring: a manual change puts that light in override (brightness is left
  alone, colour temperature keeps following the curve); re-align when the light is turned on or
  when it matches the schedule again; configurable debounce and fade time.
- Colour at turn-on: the new property **Preset Colour While Lights Are Off** (default `Off`) keeps
  the colour temperature of switched-off lights up to date so they come on already at the schedule
  colour; with `Off`, the colour is resent 3 s and 8 s after a turn-on. The initial level of every
  light is read at startup so the first turn-on is recognised.
- Brightness is not resent at every tick when a lamp reports 1 % less than commanded.
- Preview of the whole day in about two minutes; Pause / Resume / Follow All Lights; Composer
  actions, events, variables, conditionals and programming commands; Copy Schedule between
  controllers; state persisted across restarts; Log Mode and Log Level.

### Webview (`daylight_circadian_webview`)
- Singleton UI for touch panels (tuned on a T4 8") and the iOS/Android app, IT / EN, no remote
  resources.
- 24 h SVG curve (drawn from the samples computed by the controller) with draggable switchpoint
  markers sent on release, temporal colour-temperature gradient with press-and-hold, switchpoint
  editor, colour-temperature limit sliders, preview mode, controller selector, skeleton / empty /
  error / connection-lost states, help dialog.
- Reliable page ↔ driver channel: early acknowledgements are buffered, startup retries on slow
  panels, error toasts only for user actions (8 s timeout, at most one per operation every 30 s);
  `?debug=1` and `[HUB]` / `[COMMS]` log lines for field diagnosis.

### Requirements
- Control4 OS 3.3.0 or later (tested on 3.4.3 with Composer Pro 3.4.3).
- Lights on the Light V2 proxy with `supports_color_correlated_temperature`.
- Project latitude and longitude set, for astronomical switchpoints.
- Some light drivers may turn a light on when they receive a colour while it is off: try
  **Preset Colour While Lights Are Off** on one light first.

### Known limitations
- The Light V2 proxy reports no colour-temperature feedback: the controller compares against the last
  value it sent.
- Copy Schedule and several controllers bound to one webview are covered by offline tests; they have
  not been verified on hardware with two controllers.
- The time shown on the page is the clock of the device displaying it.

[Unreleased]: https://github.com/DidyMond/Control4-Daylight-Circadian/compare/v261015001...HEAD
[v261015001]: https://github.com/DidyMond/Control4-Daylight-Circadian/releases/tag/v261015001
