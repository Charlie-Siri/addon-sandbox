# Writing use cases

A use case is a short scripted demo of one addon feature. The sandbox plays it like a guided tour: a cursor moves to the addon's real buttons and clicks them, and a caption explains what is happening. The same file is a test: its checks pass or fail, and `npm run check` runs it without a browser. Any use case can be exported as an .mp4.

This guide is written so an LLM can write use cases from it alone. The JSON Schema is in [usecase.schema.json](usecase.schema.json).

## The loop

1. **Learn the addon:** `npm run surface -- <Addon>` prints its slash commands, events, SavedVariables, the world, and every text on screen after login and after each slash command, with a ready-to-use target for each. Add `--run "/cmd args"` to look at other screens, `--setup <Addon>/<usecase>` to see the screens in an existing use case's fixtures, or `--fresh` for a new install.
2. **Write** `profile/usecases/<Addon>/<name>.usecase.json`. The name is lower-case words with dashes, like `vendor-flips`.
3. **Check:** `npm run check -- --usecase <Addon>/<name> --report`. Each step prints ✓ or ✗. On a failure, `--report` prints the step, the error, the closest matches, every visible text with its position and what a click there would hit, the tooltip, chat and Lua errors. Fix the file and run it again until it passes.
4. **Watch:** in the sandbox page, open the Use cases tab and press ▶. Back, Next and clicking a step help to look at one part closely.
5. **Export:** the Export button, or `npm run video -- <Addon>/<name>`. The video goes to `profile/videos/<Addon>/<name>.mp4`.

## The file

```json
{
  "title": "Recipes that make money at a vendor",
  "summary": "VendorPrinter lists the recipes you can craft and sell to a vendor for profit, then builds a shopping list.",
  "addons": ["VendorPrinter"],
  "setup": {
    "world": "fixtures/sample.world.json",
    "savedVariables": {
      "VendorPrinter": {
        "account": "fixtures/sample.VendorPrinter.account.lua",
        "character": "fixtures/sample.VendorPrinter.character.lua"
      }
    }
  },
  "steps": [
    { "say": "Type /vp to open VendorPrinter.", "slash": "/vp" },
    { "expect": { "shown": { "text": "Vendor Printer" } } },
    { "hover": { "text": "Longjaw Mud Snapper" }, "say": "Hover a recipe to see what each reagent costs." },
    { "expect": { "tooltip": ["Reagents per craft", "Profit per craft"] } },
    { "click": { "text": "Longjaw Mud Snapper" }, "say": "Click it for a shopping list." },
    { "expect": { "chat": "Shopping list for 10x Longjaw Mud Snapper" } }
  ]
}
```

| Field | Required | What it is |
| --- | --- | --- |
| `title` | yes | Shown on the title card and in the list. A short phrase that names the benefit, not the button. |
| `summary` | no | One sentence under the title. |
| `addons` | yes | Addon folder names to load. Their dependencies load automatically. |
| `setup` | no | The world and SavedVariables to start from (below). |
| `steps` | yes | What happens, in order. |
| `allowErrors` | no | `true` lets the use case pass even if Lua errors happen. Off by default: any Lua error fails the step it happened in. |

### Setup

Every use case starts from its own state, so it plays the same way every time and never touches the user's real data.

- `world`: `"default"` (a level 60 Tauren druid in Orgrimmar with Mark of the Wild and Thorns, a small bag, one merchant, a few AH listings, Cooking), a fixture path such as `"fixtures/sample.world.json"`, or `{"base": "default" | "<fixture path>", "set": {"dotted.path": value}}` to change a few values. Paths in `set` are world paths: `"player.zone": "The Barrens"`, `"player.money": 50000`, `"auras": [{"spellId": 9910, "remaining": 140}]`.
- `savedVariables`: per addon, `account` and `character` as fixture paths ending in `.lua`, or inline Lua text. Addons not listed start with no SavedVariables (a fresh install).
- `run`: Lua run right after login.
- `wait`: seconds between login and step 1 (default 3). The video's title card shows meanwhile.

Fixture paths are relative to the addon's use case folder. `npm run surface` lists the fixtures that exist. Make new ones in the sandbox page: the World tab's "Save world as fixture" and "Save SavedVariables as fixture" buttons save the running session's state. Record mode saves both automatically.

World fields the addons read: `player` (name, realm, class, race, level, money, zone, subZone, inCombat, resting), `items`, `bags`, `merchants`, `auctions` (itemID to `[[unitPrice, quantity], ...]`), `loot`, `mail`, `professions`, `spells` (`{"id": {"name", "icon", "aura": seconds, "known": false}}`), `auras` (`[{spellId, remaining, count}]`, counting down in game time), `equipment` (`{"16": itemID}`), `weaponEnchants` (`{"16": {remaining, charges}}`), `party` (`[{name, class, health, healthMax, inCombat, target: enemyId, leader, role: "TANK", talents: [pointsTree1, pointsTree2, pointsTree3], auras: [{spellId, remaining}], aggro, far}]` as party1–4; talents answer inspects, `aggro` makes UnitThreatSituation report them tanking) and `enemies` (`[{id, name, health, healthMax, inCombat, nameplate: true, threat: ["party1"], marker}]`; the ones with `nameplate` are nameplate1, nameplate2, ...). Addons can't ping by themselves (`C_Ping.SendMacroPing` fires ADDON_ACTION_FORBIDDEN unless `client.addonPings` is true); a `/ping` in a clicked macro works and prints a ping line in chat.

### Steps

Each step does one thing. A step with only `say` is a caption.

| Step | Example | What it does |
| --- | --- | --- |
| `say` | `{"say": "...", "at": {"text": "Profit"}}` | A caption, pointing at `at` if given (the rest of the screen dims). Holds for reading time, or `hold` seconds. |
| `slash` | `{"slash": "/vp"}` | Types the command into a chat box on screen, then runs it. Fails if no loaded addon registered the command. |
| `click` | `{"click": {"text": "AH sale"}}` | Moves the cursor there and clicks. Options: `"button": "RightButton"`, `"shift"`, `"ctrl"`, `"alt"`, `"double": true`. |
| `hover` | `{"hover": {"text": "Coyote Steak"}, "hold": 2}` | Moves the cursor there and waits, so tooltips show. |
| `drag` | `{"drag": {"text": "drag to move"}, "to": {"dx": 0, "dy": 300}}` | Press, move, release. `to` is an offset in UI units (positive dy = down) or another target. Modifiers work. |
| `scroll` | `{"scroll": {"frame": "MyList"}, "delta": -3}` | Mouse wheel over a target. Negative = down. |
| `type` | `{"type": "20"}` | Types into whatever has keyboard focus (click an edit box first). |
| `key` | `{"key": "ENTER"}` | One key: ENTER, ESCAPE, TAB, BACKSPACE, DELETE, arrows, HOME, END, F1–F12, a letter or digit. Modifiers work. |
| `world` | `{"world": {"open": "ah"}}` | Changes the game world (below). |
| `event` | `{"event": "PLAYER_REGEN_DISABLED", "args": "\"player\""}` | Fires an event. `args` is a list of Lua literals as text. |
| `wait` | `{"wait": 80}` or `{"wait": {"for": {"chat": "Done"}, "timeout": 60}}` | Lets game time pass. Waits over 3 s play fast in the video with a "1 min later" badge. A `for` wait polls a check each frame and fast-forwards after a second. |
| `run` | `{"run": "MyAddon:Reset()"}` | Lua, for anything the steps can't do. |
| `expect` | `{"expect": {"shown": {"text": "Done"}}}` | A check (below). Takes no time and isn't shown in videos. |

Any action step can carry a `say`. The caption shows while the step runs and points at the step's target, and the step lasts at least as long as the caption needs to be read. On a click, the cursor arrives, waits part of the reading time, then clicks.

`world` actions: `{"open": "merchant", "name": "Shan'ti"}` (or `"index": 1`), `{"open": "ah"}`, `{"open": "loot", "name": "Wolf"}`, `{"open": "profession", "name": "Cooking"}`, `{"open": "mail"}`, `{"open": "bags"}`, `{"close": "merchant"}` (any of those), `{"combat": true}`, `{"money": 50000}` (copper), `{"give": {"item": 2589, "count": 20}}`, `{"take": {"item": 2589, "count": 5}}`, `{"buy": {"item": 2589, "count": 20}}` (AH, must be open), `{"sell": {"item": 2589, "count": 5, "price": 30}}` (AH sale; the invoice arrives by mail), `{"aura": {"add": 1126, "remaining": 60}}`, `{"aura": {"remove": 1126}}`, `{"cast": 1126}`, `{"hit": {"from": "party1", "to": "enemy:2", "amount": 300}}` (one hit: health, combat state, threat, the combat log and UNIT_HEALTH; units are `player`, `party1`–`party4` and `enemy:<id>`) and `{"set": {"player.level": 30}}`.

### Targets: how steps find things

Point at things the way a viewer would: by the text on them.

| Target | Example | Use it for |
| --- | --- | --- |
| text | `{"text": "AH sale"}` | Almost everything. Colour codes are ignored. An exact match (case and punctuation ignored, so `"Vendor"` matches `[Vendor]`) wins over a partial match. `"Coyote Steak"` matches the row `Coyote Steak (451 listed)`. |
| text + within | `{"text": "10", "within": "VendorPrinterFrame"}` | The same text appears elsewhere. `within` is a global frame name or dotted path. |
| text + nth | `{"text": "CAST", "nth": 2}` | Several matches: the nth, top to bottom then left to right. |
| frame | `{"frame": "StackYourBuffsButton1"}` | A named frame, especially when its text changes (a countdown). |
| path | `{"path": "MyAddonFrame.Tabs.2"}` | A frame without a name: a named ancestor, then parentKeys. Numbers index child lists. |
| point | `{"point": [683, 400]}` | A last resort: UI units from the top-left of a 1365×768 screen. |

For clicks and hovers, text that nothing clickable is under (a tooltip line) loses to text inside a control. A label that sits outside its button, like a caption under an icon, clicks its button. If a target matches nothing, or several different things, the step fails and the report lists the candidates.

### Checks

Use them generously: they turn a demo into a test, and they catch the moment a demo stops showing what its captions claim.

| Check | Example | Passes when |
| --- | --- | --- |
| `shown` | `{"shown": {"text": "AH net"}}` | The target is visible (several matches are fine). |
| `hidden` | `{"hidden": {"frame": "StackYourBuffsButton1"}}` | Nothing matches. With `nth`: fewer than nth matches. |
| `tooltip` | `{"tooltip": ["Reagents per craft", "Profit"]}` | A tooltip is showing and contains every string. |
| `noTooltip` | `{"noTooltip": true}` | No tooltip is showing. |
| `chat` | `{"chat": "Shopping list for 10x"}` | Some chat line since the start contains it. |
| `lua` | `{"lua": "MyAddonDB.count", "equals": 3}` | The expression is truthy, or equals the JSON value. |
| `noErrors` | `{"noErrors": true}` | No Lua errors so far. |

Several checks in one `expect` must all pass.

## Making good demos

- **One feature per use case**, 30 to 60 seconds and 6 to 15 steps. A tour of everything belongs in several files.
- **Captions say what to notice, not what the cursor does.** "Hover a recipe to see each reagent and where to buy it" is better than "Now we hover the first row". Keep them under 25 words, in plain language for a player, not a developer.
- **Show, then click.** A caption on the step before a click (a `say` with `at`) gives the viewer time to find the button.
- **Check every claim.** After a caption that says a tooltip shows something, `expect` the tooltip. After a click that should print a list, `expect` the chat.
- **End on the result**, with a closing caption that holds about 3 seconds.
- **Start where the feature matters.** If the addon behaves differently in town, set `player.zone` and `player.resting`. For a buff that is about to run out, add it to `auras` with a small `remaining`. Prefer a fixture over long setup steps.
- **Long waits are fine:** they fast-forward in the video. Use `{"wait": {"for": ...}}` for things that finish on their own, like scans.
- **Chat output shows on screen** in a chat frame at the bottom left, so captions can point to it.

## Reading failures

| Error | Usual fix |
| --- | --- |
| `No visible text matches "X"` | Look at "Visible text on screen" in the report. The window may not be open yet, the text may differ (money is shown as `2s 13c`), or a step before failed to do what you assumed. |
| `"X" matches 3 things on screen` | Add `nth` or `within`. The report lists each match with its position and what it clicks. |
| `is shown, but nothing clickable is under it` | Click the control rather than a label, or use `frame`. |
| `/foo is not a slash command` | The report lists the registered ones. Check `addons`. |
| `Nothing has keyboard focus` | Click the edit box before `type`. |
| `No tooltip is showing` | Hover first, and check right after the hover. Moving the mouse closes it. |
| `Lua error: ...` | A real addon bug, or the sandbox doesn't emulate something yet. The APIs tab and `npm run check -- <Addon>` show unemulated calls. Set `allowErrors` only when the error is expected. |
| `Waited 30 s and still: ...` | The thing never happened. Raise `timeout` if it is slow. |

## Commands

```sh
npm run surface -- VendorPrinter                               # what is on screen, with targets
npm run surface -- VendorPrinter --run "/vp" --setup VendorPrinter/vendor-flips
npm run check -- --usecase VendorPrinter/vendor-flips --report  # one use case
npm run check -- --usecases VendorPrinter                       # all of an addon's
npm run check -- --usecases                                     # all
npm run video -- VendorPrinter/vendor-flips                     # .mp4 into profile/videos/
npm run schema                                                  # regenerate docs/usecase.schema.json
```

Exporting needs Google Chrome or Chromium (`SANDBOX_CHROME=/path` to choose) and ffmpeg with libx264. Rendering takes about 1.7 s per second of video at 1080p and 30 fps.
