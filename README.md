<div align="center">

<h1>Yet Another Now Playing Widget</h1>

<p>Shows whatever you're playing as a browser source. No Spotify API keys, no logins, no setup - it just reads it from Windows.</p>

<video src="https://github.com/mopoIo/Yet-Another-Now-Playing-Widget/raw/main/sample.mp4" width="100%" autoplay loop muted playsinline controls></video>

<p><b><a href="https://github.com/mopoIo/Yet-Another-Now-Playing-Widget/releases/latest">Don't care about the technical stuff and just want to download it? Click here.</a></b></p>

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![.NET 9](https://img.shields.io/badge/.NET-9-512BD4)](https://dotnet.microsoft.com/download)

</div>

## About

Most now-playing overlays make you register a Spotify app, paste in API keys, or
wire up some account login. This one doesn't: album art, title, artist, and
progress all come straight from Windows, so there's nothing to set up. You just
run it and it works, with any media player rather than one specific service.

The look and animations are inspired by
[adarhef/NowPlaying](https://github.com/adarhef/NowPlaying) - I fell in love with
it but found it a bit much to set up and run, so this is my lighter weekend take
on the same idea.

It's **Windows only**, since it leans on the GlobalSystemMediaTransportControls
(GSMTC) API that only a local Windows process can read. The helper reads every
media session, runs a local web server, and pushes live updates to the overlay
over a WebSocket. Anything that reports to Windows works: Spotify, any browser,
VLC, foobar2000, Apple Music, and so on. It barely uses any CPU.

## Features

- **Latch onto one source** - pin the overlay to one app so a new YouTube tab
  can't steal it. If that app isn't running yet, the overlay waits for it instead
  of grabbing whatever's playing.
- **Works with any media player** - anything Windows knows about shows up, or use
  follow mode to just mirror whatever's current.
- **Animated** - art and text slide in, track changes cross-fade, and it bows out
  cleanly when playback stops.
- **Per-overlay tweaks** - accent colour, animation speed, and a forced layout
  via URL params; your latch, layout, and toggles persist across restarts.
- **Out of the way** - runs as a little system tray icon.
- **Lightweight** - pure .NET, no JS/CSS libraries.

## Getting started

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

## Using it

The control panel lists every media source it finds, with live art and a
*current* / *playing* badge.

- Click a source to **latch** the overlay onto it - it'll only ever show that app.
  If it isn't running yet, the panel shows a "waiting for..." hint.
- Click **Follow current (auto)** to go back to mirroring whatever Windows marks
  as active.
- Pick a **layout** and an **accent colour**, and toggle **Show source app** or
  **Hide when paused** (fades the overlay out while paused).
- Flip **Launch at login** (also in the tray menu) to start it in the tray
  automatically when you sign in to Windows.

Your choices are remembered across restarts (saved to
`%LOCALAPPDATA%\nowplaying\settings.json`).

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

## Portable build

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
