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

The game code is **embedded in the file** (v2), so nothing is downloaded for
the game logic — the game boots instantly. Only images and music stream
lazily from the asset CDN on first use (cached on disk).

> No internet at all? The game still boots and plays text-only (images stay
> hidden, audio stays silent) — that is a supported mode, not a crash.

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
    cache/...  (downloaded images & audio)
```

Game code is no longer written here (it is embedded in the script since v2).

Delete that folder to fully reset the game (also mentioned in the in-game
Help menu). Re-running the script while it is already running safely cleans
up the previous session first.

## What's inside

```
DDLC-LOVE-Roblox.lua   <- the port (~2.1 MB, single file, ALL game code
                          embedded — the only file you need to run)
game/                  <- original DDLC-LOVE v1.2.2 source (ddlclove branch)
                          unmodified; identical copies of these files are
                          embedded into the single file at build time
```

### Self-hosting

All 75 game modules are embedded in the single file, so there is nothing to
self-host for game code anymore. Only assets matter: images and music come
from the archived `LukeZGD/DDLC-LOVE-Assets` repo (jsDelivr as a fallback
CDN). To use your own asset mirror, edit `ASSET_BASES` at the top of
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
* v2 embeds every game module in the file (injected by `build_embedded.py`),
  so `require()` never touches the network. This fixes the reported bug where
  pressing New Game left a black screen with only `require: keyboard` in the
  console — the name-entry keyboard module used to be downloaded from GitHub
  at that exact moment, and if the fetch failed the error was swallowed.
* Errors in input handlers are now reported (console + on-screen status)
  instead of being silently discarded.
* Verified headless: boot → language → first-run warnings → splash → title →
  name entry → chapter 0 dialogue → poem minigame (full round) → poem
  display/scroll → acts 2/3 → s_kill_early → credits → quit, plus a
  second-boot test with existing saves, the Drawing-API fallback backend,
  and offline tests (cold boot with GitHub blocked, and a total network
  blackout).

## Troubleshooting

* **Black screen after pressing New Game, console shows `require: keyboard`**
  — that was the v1 bug (failed download of the keyboard module); fixed in
  v2. Make sure you are running the updated file: on startup the console
  must print `[DDLC-LOVE] Roblox port ready (v2, game code embedded)`.
* **Missing images / no music** — the asset CDN is unreachable from your
  network; the game itself still runs. Music/images appear once the CDN is
  reachable (cached on disk afterwards).

## Credits

* **Doki Doki Literature Club** by Team Salvato (https://ddlc.moe)
* **DDLC-LOVE** by LukeZGD (github.com/LukeZGD/DDLC-LOVE) — the game engine
  port this is based on
* Roblox compatibility layer: this repository
