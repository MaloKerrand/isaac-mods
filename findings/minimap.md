# Minimap notes for the next agent

Binding of Isaac: Repentance+ v1.9.7.17.J460. The mod is `secret_wall_hints`. The game loads the same folder the repo has (Steam `mods/secret_wall_hints`). Reload with `luamod secret_wall_hints`. This is vanilla Lua, not Repentogon. Repentogon callbacks such as `MC_HUD_RENDER` (1022) do not exist here. Vanilla `ModCallbacks` stop at `MC_PRE_MOD_UNLOAD = 73`.

Exe: `C:\Program Files (x86)\Steam\steamapps\common\The Binding of Isaac Rebirth\isaac-ng.exe`

32-bit, image base `0x400000`. `.text` VA `0x1000`, raw `0x400`, so VA = `0x400C00 + file_offset`. `.rdata` VA `0x718000`, raw `0x716600`. Log: `Documents\My Games\Binding of Isaac Repentance+\log.txt` (rewritten on launch). `Isaac.DebugString` goes there. `Isaac.ConsoleOutput` is the on-screen console.

## Console

`MC_EXECUTE_CMD` (id 22) is never called. `Console::RunCommand` is VA `0x68cdc0`. Unknown commands are dropped. `luamod` takes only the folder name. A non-nil return from `MC_EXECUTE_CMD` crashes.

Working path is a global, run with the built-in `lua` command:

- `lua swh()` prints the nudge of the map that is open
- `lua swh(2, -1)` sets it
- `lua swh("reset")` clears it
- `lua swh("center")` toggles a mark on the middle of the small-map viewport

`swh` writes `nudge` on the small map and `bigNudge` while the expanded map is open. They do not share a value. Both reset on `luamod`. The small-map calibration the player accepted is baked into `VIEW_PAD`, so `nudge` stays `0, 0` there.

## Draw order

`MC_POST_RENDER` (`LuaEngine::PostRender`, function `0x863680`, called from `Game::Render` `0x6fbc10` at `0x6fc0a6`) runs before `HUD::Render` (`0x9a3eb0`, called at `0x6fc39f`). A sprite drawn in `POST_RENDER` ends up under the minimap.

`HUD::Render` bails out when the visibility byte at HUD+`0x54cc` is 0 (`SetVisible` is `0x4aaee0`, `IsVisible` is `0x85e1c0`). `Sprite:Render` is immediate (`0x40a0d0`), not a later queue. `MC_GET_SHADER_PARAMS` runs after the HUD but only when a shader is active, and it binds an offscreen target first, so it is the wrong place to draw.

The mod draws the HUD itself inside `MC_POST_RENDER` (priority `LATE`, so other mods' sprites stay under it), paints the rocks, then `SetVisible(false)`. Visibility comes back at the start of `onRender` and in `MC_POST_UPDATE` (priority `EARLY`). HUD Update (`0x9a2990`) and PostUpdate (`0x9a2b30`) do not look at the flag, so hiding it does not freeze the map.

There is a second mod in the log, `planetarium chance`, that draws HUD text from `POST_RENDER`. Late priority keeps our HUD pass after that text.

## Small map (player signed off on this)

No API exposes the minimap. Layout is measured.

| Constant | Value | Where it came from |
|---|---|---|
| `VIEW_SIZE` | 47, 47 | `0x98b570` returns 47, 47 when the large-map alpha is ~0 |
| `VIEW_PAD` | 8, 3 | Player nudge of -2, -3 baked into the old pad of 6, 6. X grows when the nudge is negative, Y shrinks |
| `CELL_STEP` | 8, 7 | Minimap root +`0x148` = 1, +`0x13c` = 7, +`0x140` = 6. Step is 1+gap |
| `CELL_SIZE` | 9, 8 | Step plus the 1px shared wall |
| `ROCK_SCALE` | 0.25 | 8px source, pivot at the center, so 2px on screen. Player rejected 1.0 and 0.5 |
| Rock inset | `rock * 0.5 + 0.5` | 1.5px for the 2px rock: one pixel inside the room, off the black border |

`viewOrigin` is `mapCorner` minus the viewport width, plus `nudge`. Corner is `screenW - HUDOffset*10*2.2 - padX`, `HUDOffset*10*1.2 + padY`. The exe's own frame is `screenW - 80 + (1-h)*24`, `16 + (1-h)*(-14)` (floats `0xbaa89c` = 24, `0xbaadd4` = -14, `0xbaa454` = 1). At HUD offset 0 that is `screenW-56, y=2`; ours is `screenW-55, y=3`. Leave it. The player calibrated this.

The small map is a 7x7 window (`root+0x14c/+0x150`) centered on the current room. Scroll was eased at 0.3 and the rocks lagged the vanilla map by a frame. The player asked to snap. `updateViewCenter` assigns the target every frame. There is no API for the minimap scroll.

Rocks are skipped for secret rooms, dungeon, error, black market, boss (`ROOM_BOSS`), and thin shapes IH, IV, IIH, IIV. Boss used to force every wall blocked. That was removed. Curse of the Lost, `SEED_NO_HUD`, and a hidden HUD skip the whole draw.

`screenSize()` is the WorldToScreen formula (same one MinimapAPI uses). `Isaac.GetScreenPointScale` exists (`0x870df0`, reads `0xbf93e8`) but the layout is in render pixels, not screen pixels.

Sprite scale works. A flag at `0xc7977d` multiplies scale by `0.5 * [manager+0x7240]` only around individual C++ draws and is cleared after. `Sprite:Render` clamps are in unscaled source pixels, so screen-space cuts are divided by `ROCK_SCALE`.

## Expanded map

Cell step is 17 by 15. On the minimap root, parallel to the small config but +`0x160`: +`0x29c` = 16, +`0x2a0` = 14, +`0x2a8` = 1. Step = 1+gap. `BIG_CELL` is 18 by 16 (step+1, same pattern as 9 = 8+1). Confirmed on a 1024-wide screenshot of Caves I: one cell was 33 by 28 screenshot pixels, the next cell started 34 pixels to the right and about 30 down. That is 2x render space, so 17 by 15. Do not change the step because a rock looks shifted inside its room. A wrong step walks the error across the floor. MinimapAPI agrees (`largeRoomSize = Vector(17, 15)`, `largeRoomAnimPivot = Vector(-4, -4)`).

Visible count is 13 (`+0x2ac/+0x2b0`), so the large map does not scroll: every grid cell is in range. The mod packs the bounding box of rooms with `DisplayFlags & 1` into the same top-right corner as the small map. Boss, thin, and secret rooms count toward that box when the map draws them, and still do not get rocks.

`BIG_ROCK_SCALE` is 0.5 (4px on screen). `BIG_PAD` is 2, 3. A first guess of -4, -2 was too far up-left; the player set `lua swh(6, 5)` on top of that and signed off, and 6-4, 5-2 is the baked pad. `lua swh(x, y)` while the big map is up replaces `bigNudge` (added on top of `BIG_PAD`) and prints `big map nudge`. Copy a good value into `BIG_PAD` and set `bigNudge` back to 0.

Large-map alpha is minimap+`0x2d0`. Small-map alpha is +`0x170`. The state machine is `0x98dba0`, called from `0x6fb527` and `0x6fb91e`. Mode is `[edi+0]`, a flag is `[edi+4]`, the hold counter is `[edi+8]`.

- Mode 0: small map. A press goes to mode 1.
- Mode 1: button is down, big map fades in (alpha +0.1/frame, float `0xbaa120`). Release before the counter reaches 9 latches mode 2 and sets the flag. Release at 9 or later returns to mode 0. The next press (flag already set) is the other way around: a short release returns to the small map, a long one stays latched.
- Mode 2: big map stays while the button is up. A press goes back to mode 1, and mode 2 zeroes the counter first so the new press is timed from scratch.

Nine frames at 60fps is about 150ms. A tap leaves the full map up. `Input.IsActionPressed(ACTION_MAP)` is already false by then, which is why a single Tab used to draw the small-map rocks on the full map. `updateMapMode` copies this machine. `mapState ~= 0` means draw the big layout. The counter only advances in `MC_POST_UPDATE`. Do not also advance it in `onRender` or a press is counted twice.

Mode 2's exit back to small, besides the short second press above, was not fully traced. Writes that set the mode to 1 or 2 were not found as plain `mov dword [reg], 1/2` inside `0x98b000-0x98f800`; the transitions are the ones listed above (`0x98e063`, `0x98e083`, `0x98e0be`, `0x98e0fc`, `0x98e15f`).

The screen anchor of large-map local (0, 0) is only partly traced. `0x98e4d0` draws the frame. The small frame is `screenW - 80 + shake + (1-h)*24`, `16 + shake + (1-h)*(-14)`. The large path (`0x98eb6e`, taken when large alpha > 0) starts from `screenW + hudX` and `hudY`, then subtracts the content min (`root+0x2c0` / `+0x2c4`, which are largeLayer+`0x148` / `+0x14c`) and adds 14 and -24. Those mins are the extent of the rooms in local pixels, filled by the room loop, not a screen position. Layers: small is minimap+`0x18`, large is +`0x178`. HUD's minimap root is game+`0x25ecc`.

`BIG_PAD` will be wrong if that anchor is not the small map's corner. Calibrate with `swh` rather than changing `BIG_STEP`.

## Still open

- Exact screen position of large-map cell (0, 0). `BIG_PAD` is the stand-in.
- Whether a press of exactly 9 frames matches the exe on every machine. If a normal tap returns to the small map while our rocks stay big, or the reverse, the `< 9` split in `updateMapMode` is the place to look.
- Game hud math uses `(1-h)*24` and `(1-h)*(-14)`. Ours uses `h*22` and `h*12`. They match within a pixel at h = 0. The small map was calibrated at the player's HUD offset, so do not "fix" it.
- `0xc78dc4` is the runtime screen width. `0xc3793c/0xc37940` are the screen scale (1, 1). Minimap shake/scroll lives at minimap+`0x620/+0x624` and starts at 0.
