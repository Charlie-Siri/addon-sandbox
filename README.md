# Addon Sandbox

Runs WoW Forever addons in the browser, without the game client. It loads them straight from the client's `Interface/AddOns` folder, runs their Lua in a real Lua 5.1 VM with the WoW API mocked, draws their frames, and fakes the game world (money, bags, merchants, Auction House, loot, professions) so you can test addons while the game is busy or closed.

Build plan and progress: [WoW Forever Addon Sandbox — Build Plan](https://claude.ai/artifact/5cMv4dQMj8tus9ZoA9tSL5).

## Run it

```sh
npm install
npm run dev          # http://127.0.0.1:5199
```

- Reload: the Reload button, Ctrl+R in the page, or `/reload`. Saving any `.lua`, `.xml` or `.toc` of a loaded addon reloads automatically (about 0.3 s).
- Chat box: addon slash commands work as in game, plus `/run`, `/dump`, `/fstack` and `/etrace`.
- `?run=/vp` in the URL runs commands after the first load.
- Another install location: `SANDBOX_WOW_DIR=/path/to/_forever_ npm run dev`.

## Your files

The sandbox never writes to the WoW install. SavedVariables come from your real `WTF` folder the first time an addon loads (pick the character in the Addons tab). After that, the sandbox reads and writes its own copy in `profile/WTF/...`. "Re-seed from WTF" in the Addons tab drops that copy. The fake world lives in `profile/world.json`.

## The panels

| Tab | What it does |
| --- | --- |
| World | Player, money and combat state. Opens the stand-in merchant, AH, loot, profession, mailbox and bags windows. Buys on the AH and "sells" bag items there (the sale invoice arrives by mail). Edits the world JSON. Imports world data from VendorPrinter or from a client dump. |
| Events | Fires any event with Lua arguments. Lists the events loaded code has registered. Shows a filterable event log, including `PlaySound` calls. |
| Frames | `/fstack`-style inspector (frames under the cursor, with outlines). An option outlines every region. |
| Addons | Character choice and which addons to load (dependencies load automatically). Shows where each addon's SavedVariables came from. |
| APIs | Real WoW APIs that loaded code called but the sandbox only stubs, plus runtime warnings. |
| Use cases | Scripted demos of addon features: play them (play, pause, step, back, speed), check them, export them as .mp4, or record a new one from what you do. |

Errors are listed BugSack-style (deduplicated, with counts and stacks).

## Use cases (scripted demos)

A use case is a JSON script in `profile/usecases/<Addon>/<name>.usecase.json` that plays like a guided demo: a cursor clicks the addon's real buttons while captions explain each feature. It starts from its own world and SavedVariables (fixtures in `profile/usecases/<Addon>/fixtures/`), so it never touches your session and plays the same way every time. Its `expect` steps make it a test too.

- **Play:** Use cases tab, ▶. Your session is saved first and comes back when you press Exit. Back and clicking a step rewind (the use case replays up to there instantly). Editing the use case or the addon restarts it.
- **Check:** the Check button, or `npm run check -- --usecase VendorPrinter/vendor-flips --report` (`--usecases` for all). A failure prints the step, the closest matches, everything on screen, the tooltip, chat and Lua errors: paste it to an LLM.
- **Export:** the Export button (progress in the tab), or `npm run video -- VendorPrinter/vendor-flips`. 1080p H.264 at 30 fps, a title card and one chapter per caption, in `profile/videos/<Addon>/`. Frames are rendered one by one in headless Chrome with fake time, so none are dropped; it takes about 1.7 s per second of video. Needs Google Chrome or Chromium and ffmpeg with libx264.
- **Record:** "Record a new use case" turns your clicks, drags, mouse wheel, typing, slash commands and World tab actions into a draft, with your current world and SavedVariables saved as its fixtures.
- **Fixtures:** World tab, "Save world as fixture" and "Save SavedVariables as fixture".
- **Ask an LLM:** give it [docs/USECASES.md](docs/USECASES.md) and the output of `npm run surface -- <Addon>` (slash commands, events, SavedVariables, the world, and every text on screen after each command, with ready-made targets). It writes the file, runs the check until it passes, and you watch it.

## Real client data (SandboxDump)

Item names, sell prices and icons don't exist in the sandbox until you export them from the game:

1. `tools/SandboxDump/install.sh` links the dumper addon into AddOns (once).
2. In game: `/sbdump`, wait for "Done", then `/reload`.
3. In the sandbox: World tab, "Import client dump".

The dump also records the build, interface number, every global function and `C_` namespace, `Enum` values and widget methods. On every load after the first it prints "SavedVariables read back OK".

## Headless

```sh
npm run check -- VendorPrinter --run "/vp debug" --run "/vp" --frames   # load, run commands, print errors/chat/render list
npm run check -- --dir tools/SandboxDump --run /sbdump --seconds 30      # an addon folder outside AddOns
npm test                                                                 # parsers, runtime self-tests, XML, VendorPrinter, use cases
npm run surface -- VendorPrinter                                         # what an LLM needs to write use cases
npm run check -- --usecases                                              # every use case, pass or fail per step
```

None of these write anything (`npm run video` writes only the .mp4).

## How it works

```
server/            Vite plugin = dev server: /api routes over AddOns, WTF (read-only) and profile/ (read-write), file watcher
src/core/          shared by browser and Node: Sandbox (VM + host bridge), TOC and XML parsers, load order, default world,
                   use case format and validation (usecase.ts) and the use case runner (runner.ts)
src/runtime/*.lua  the WoW environment, all in Lua inside the VM:
  00_base          WoW's Lua dialect (strsplit, wipe, bit, ...), error handler, securecall/hooksecurefunc, JSON
  10_widgets       widget object model, anchor layout, strata/levels/layers, render list, mouse/keyboard input
  20_ui            fonts, colors, money text, stand-ins for Blizzard templates, GameTooltip, chat/slash, popups, menus, pools, Settings
  30_api           timers, frame loop, addon loading and login events, SavedVariables writer, units, C_AddOns, CVars, enums
  40_game          items (async loading), bags, money, merchant, loot, Auction House, professions + their windows
  45_spells        known spells, player auras with expiry, casting, secure action buttons, item use, weapon enchants
  47_group         party members, enemies with nameplates and threat, combat log, raid markers, pings, secure snippets
  50_xml           XML frames, virtual templates, inherits, mixins, parentKey, scripts, fonts
  60_usecase       visible text and frames, finding targets by their text, what is under a point (record mode)
src/renderer.ts    render list -> absolutely positioned DOM (only changed elements are touched)
src/usecases.ts    Use cases tab: player, check, export, record mode, fixtures; the video recorder page API
src/ucview.ts      the demo layer: cursor, ripples, captions with spotlight, chat frame, title card
scripts/           check (headless runs and use cases), surface, video (Chrome + ffmpeg), schema, test
docs/USECASES.md   how to write use cases (for people and LLMs); usecase.schema.json
src/main.ts        session lifecycle, frame loop, input, panels
tools/SandboxDump  in-game exporter for real client data
```

Server actions (buying, selling, crafting, taking mail) complete about 0.1 s later, like the client: money and bags change after the call returns, so `hooksecurefunc` hooks see the state before the change.

Each animation frame, the page calls `SANDBOX.Frame(dt)`. That runs due timers and `OnUpdate`, and returns a JSON render list when anything changed. Input goes the other way: the page sends raw mouse and keys, and Lua does the hit testing, `OnEnter`/`OnLeave`, clicks, drags, edit boxes and Escape.

Blizzard's art isn't bundled. Stand-in templates (`UIPanelButtonTemplate`, `BasicFrameTemplateWithInset`, `UICheckButtonTemplate`, `InputBoxTemplate`, `UIPanelScrollFrameTemplate`, `BackdropTemplate`, ...) are real frames drawn with CSS styles, and icons are tinted placeholder tiles.

## Known limits

- No taint, secret values or combat lockdown errors yet (phase 6). `InCombatLockdown()` follows the World tab toggle.
- `LoadAddOn` only succeeds for addons that are already loaded. Load-on-demand addons aren't preloaded.
- Items missing from the world get placeholder names and made-up sell prices until a client dump is imported.
- `UIDropDownMenu`/`MenuUtil` menus and the Settings API are basic: options pages open, but vertical-layout settings aren't drawn.
- Strings go through UTF-8 between JS and Lua, so SavedVariables holding invalid UTF-8 bytes would not survive a save.
