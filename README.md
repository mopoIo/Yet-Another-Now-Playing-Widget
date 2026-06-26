<div align="center">

<h1>Yet Another Now Playing Widget</h1>

<p>Shows whatever you're playing as a browser source. No Spotify API keys, no logins, no setup - it just reads what's already playing.</p>


https://github.com/user-attachments/assets/2882c64a-93f3-48f0-8b30-ce33a525cf96


<p><b><a href="https://github.com/mopoIo/Yet-Another-Now-Playing-Widget/releases/latest">Don't care about the technical stuff and just want to download it? Click here.</a></b></p>

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Windows · .NET 9](https://img.shields.io/badge/Windows-.NET_9-512BD4)](https://dotnet.microsoft.com/download)
[![macOS · Swift](https://img.shields.io/badge/macOS-Swift-F05138)](https://www.swift.org)

</div>

## About

Most now-playing overlays make you register a Spotify app, paste in API keys, or
wire up some account login. This one doesn't: album art, title, artist, and
progress all come straight from your system, so there's nothing to set up. You just
run it and it works, with any media player rather than one specific service.

The look and animations are inspired by
[adarhef/NowPlaying](https://github.com/adarhef/NowPlaying) - I fell in love with
it but found it a bit much to set up and run, so this is my lighter weekend take
on the same idea.

On Windows it leans on the GlobalSystemMediaTransportControls (GSMTC) API: the
helper reads every media session, runs a local web server, and pushes live
updates to the overlay over a WebSocket. Anything that reports to Windows works:
Spotify, any browser, VLC, foobar2000, Apple Music, and so on. It barely uses any
CPU.

There's also a **[macOS build](macos/)** that serves the exact same overlay - see
[below](#macos).

## Features

- **Latch onto one source** - pin the overlay to one app so a new YouTube tab
  can't steal it. If that app isn't running yet, the overlay waits for it instead
  of grabbing whatever's playing.
- **Works with any media player** - anything your system knows about shows up, or
  use follow mode to just mirror whatever's current.
- **Animated** - art and text slide in, track changes cross-fade, and it bows out
  cleanly when playback stops.
- **Per-overlay tweaks** - accent colour, animation speed, and a forced layout
  via URL params; your latch, layout, and toggles persist across restarts.
- **Out of the way** - tucks into the system tray (the menu bar on macOS).
- **Lightweight** - no JS/CSS libraries, no third-party dependencies.

## Getting started (Windows)

Needs the [.NET SDK 9](https://dotnet.microsoft.com/download) on Windows 10 (build
19041) or newer. From this folder, in a Windows terminal:

```cmd
run.cmd
```

It opens the control panel and runs from the system tray. Right-click the tray icon
to copy the overlay URL or quit; double-click to reopen the control panel.

- **Control panel** - `http://localhost:8787/control`
- **OBS overlay** - `http://localhost:8787/overlay`

Use `--port 9090` if 8787 is taken, or `--no-open` to skip auto-opening the control panel.

## macOS

There's a native build in [`macos/`](macos/) - a single dependency-free Swift file
that serves the same overlay and control panel over the same WebSocket, so
everything below works the same.

Grab the **[`.app` from the latest release](https://github.com/mopoIo/Yet-Another-Now-Playing-Widget/releases/latest)**
and double-click it; it drops a music note in the menu bar (control panel, overlay
URL, launch at login, quit). It isn't signed with an Apple Developer ID, so the
first time you'll need to **right-click it -> Open** to get past Gatekeeper. Or
build it yourself with the Xcode command line tools (`xcode-select --install`):

```sh
macos/run.command        # compile and run from the terminal
macos/build-app.command  # or bundle the double-clickable .app + release zip
```

macOS only lets Apple-signed apps read the system-wide "now playing" feed, so this
build asks **Spotify** and **Apple Music** directly over AppleScript - which is why
it's per-app rather than "anything that's playing". It asks to control those apps on
first run (say yes, or set it later under Privacy & Security -> Automation) and never
launches them itself. Settings live in `~/Library/Application Support/nowplaying`.

## Using it

The control panel lists every media source it finds, with live art and a
*current* / *playing* badge.

- Click a source to **latch** the overlay onto it - it'll only ever show that app.
  If it isn't running yet, the panel shows a "waiting for..." hint.
- Click **Follow current (auto)** to go back to mirroring whatever's currently
  playing.
- Pick a **layout** and an **accent colour**, and toggle **Show source app** or
  **Hide when paused** (fades the overlay out while paused).
- Flip **Launch at login** (also in the tray/menu bar) to start it automatically
  when you log in.

Your choices are remembered across restarts (saved to
`%LOCALAPPDATA%\nowplaying\settings.json`, or `~/Library/Application Support/nowplaying`
on macOS).

## Adding it to OBS

OBS -> **Sources** -> **+** -> **Browser** -> URL: `http://localhost:8787/overlay`

The background is transparent and the overlay fills the whole source, so placing
it is just dragging the box. It scales to any size - a wide strip (e.g. 900x140)
looks best, but go tall and portrait and the layout stacks vertically.

## Overlay URL options

You normally pick the layout in the control panel, but you can override it per
source with query params on the overlay URL (handy for two differently-styled
overlays):

| Param | Example | Effect |
|---|---|---|
| `layout` | `?layout=full`   | force a layout (`classic`/`progress`/`full`) |
| `accent` | `?accent=ff5500` | accent colour (hex, no `#` needed) |
| `speed`  | `?speed=1.5`     | animation speed multiplier (higher is snappier) |

## Making your own layouts

A layout is just **HTML + CSS**, no JavaScript. Add an entry to the `LAYOUTS`
object in `wwwroot/overlay.html` as `{ label, css, html }`, tag elements with
`data-np="..."` hooks, and the engine wires up the rest:

| Hook | What the engine does |
|---|---|
| `data-np="art"`      | sets the album art, hidden when there's none |
| `data-np="title"` / `"artist"` | sets the text and applies the scrolling marquee |
| `data-np="app"`      | sets the source name (when "Show source app" is on) |
| `data-np="elapsed"` / `"duration"` | live `m:ss` time |
| `data-np="progress"` | engine sets its `width` % every frame |

Animate elements with `data-in` / `data-out` (e.g. `fadeInUp`), `data-seq` sets
reveal order, and colours live in the `:root` variables at the top of
`overlay.html`. Add a matching chip to `control.html` so it shows in the picker.
No build step. If you send a PR, keep it dependency-free - that's the whole point.

## Portable build (Windows)

Want a standalone exe you can drop anywhere (no `dotnet run`)?

```cmd
dotnet publish -c Release -r win-x64 -p:PublishSingleFile=true -o publish
```

Then run `publish\nowplaying.exe` and it drops straight into the system tray. Add
`--self-contained true` to bundle the runtime so it works on machines without .NET.

## Thanks

- [adarhef/NowPlaying](https://github.com/adarhef/NowPlaying) for the look and the
  animations this borrows from.
- [dremin/RetroBar](https://github.com/dremin/RetroBar) - poking around its source
  is what first got me into messing with Windows internals.

## License

MIT - see [LICENSE](LICENSE). Forks and themes welcome; the license just asks that
the copyright notice stays in copies, so credit travels with the code.
