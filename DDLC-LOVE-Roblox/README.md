# DDLC-LOVE for Roblox

A single-file Roblox (executor) port of **DDLC-LOVE** (LukeZGD's LÖVE port of
Doki Doki Literature Club). It runs the *original, unmodified* DDLC-LOVE game
code on top of a Love2D compatibility layer written for Roblox executors.

> Unofficial fan project. Not affiliated with Team Salvato.
> Support the official game: https://ddlc.moe / https://ddlc.plus
> (Team Salvato IP guidelines: fan projects must stay non-commercial.)

---

## How to run

### Option A — one line (loadstring)

Host `DDLC-LOVE-Roblox.lua` anywhere that serves plain text
(GitHub raw file, a paste site, your own server), then run in your executor:

```lua
loadstring(game:HttpGet("https://YOUR-HOST/DDLC-LOVE-Roblox.lua"))()
```

### Option B — paste the file

Open `DDLC-LOVE-Roblox.lua`, copy everything, paste it into your executor's
editor and press Execute.

First run downloads the game code and assets (a few seconds, cached on disk);
after that it boots in about a second.

## Requirements

* A Roblox **executor** with HTTP access (`game:HttpGet` or `request`).
* **Recommended** (full graphics + music): `writefile`/`readfile`/`isfile` +
  `getcustomasset` — Wave, Swift, Synapse Z, Delta, Fluxus, Xeno, etc. all
  have these. Renderer used: Roblox `ScreenGui` with `ImageLabel`/`TextLabel`.
* **Fallback**: if `getcustomasset` is unavailable but the `Drawing` API is,
  the game runs on the Drawing renderer (images still load via URLs; music and
  sound effects are disabled).
* Touch devices automatically get an on-screen D-pad + A/B/MENU buttons.

## Controls

| Key                  | Action                                        |
|----------------------|-----------------------------------------------|
| Space / Enter / Tap  | Advance text, confirm menu choice             |
| Esc / Backspace      | Cancel, hide text window                      |
| 1 (or Shift)         | Pause menu (save / load / settings / history) |
| 2                    | Skip toggle                                   |
| 3                    | Auto-forward toggle                           |
| Arrow keys           | Menu navigation, poem scrolling               |
| Mouse click          | Advance text (same as Space)                 |

The first time you start a new game you type your name with the built-in
on-screen keyboard (arrow keys + Space), just like the console versions.

## Save data

Saves, settings and the persistent file live in your executor's **workspace**
folder, under `DDLC-LOVE/`:

```
<executor workspace>/DDLC-LOVE/
    settings.sav, persistent, save01-0.sav, ...
    scripts/... (cached game code)
    cache/...  (downloaded images & audio)
```

Delete that folder to fully reset the game (also mentioned in the in-game
Help menu). Re-running the script while it is already running safely cleans
up the previous session first.

## What's inside

```
DDLC-LOVE-Roblox.lua   <- the port (this is the only file you need to run)
game/                  <- original DDLC-LOVE v1.2.2 source (ddlclove branch)
                          unmodified; the loader normally fetches the identical
                          files from GitHub at runtime
```

### Self-hosting the game code

The loader fetches the game code from
`raw.githubusercontent.com/LukeZGD/DDLC-LOVE/ddlclove/game/...` and assets
from the archived `LukeZGD/DDLC-LOVE-Assets` repo (with jsDelivr as a
fallback CDN). To run fully from your own copy, host the `game/` folder and
edit `CODE_BASES` (and optionally `ASSET_BASES`) at the top of
`DDLC-LOVE-Roblox.lua`.

## Technical notes

* Implements the LÖVE 0.10 API subset DDLC-LOVE uses: `love.graphics`
  (draw/print/printf/rectangle/colors/fonts/transform), `love.audio`,
  `love.filesystem`, `love.math`, `love.timer`, `love.keyboard`, input
  callbacks and the frame loop on `RunService.Heartbeat`.
* Colors are 0–255 (cindy is skipped by reporting LÖVE 0.10.2).
* DDLC's TTF fonts can't be loaded in Roblox, so each font is approximated
  (Aller → Nunito, Riffic → FredokaOne, the poem fonts → Bangers /
  Fondamento / IndieFlower / FredokaOne, act-2 "edited" → SpecialElite).
* The 20 language menu-button sheets that are not part of the public assets
  repo are re-drawn natively (same labels, positions and colors).
* Assets are downloaded lazily (only what a scene needs), parsed for their
  real pixel dimensions, cached on disk and mounted via `getcustomasset`.
* Verified headless: boot → language → first-run warnings → splash → title →
  name entry → chapter 0 dialogue → poem minigame (full round) → poem
  display/scroll → acts 2/3 → s_kill_early → credits → quit, plus a
  second-boot test with existing saves and the Drawing-API fallback backend.

## Credits

* **Doki Doki Literature Club** by Team Salvato (https://ddlc.moe)
* **DDLC-LOVE** by LukeZGD (github.com/LukeZGD/DDLC-LOVE) — the game engine
  port this is based on
* Roblox compatibility layer: this repository
