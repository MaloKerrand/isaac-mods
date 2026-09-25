# Secret Wall Hints

Isaac Repentance(+) Lua mod. After you walk into a room, the minimap gets a small rock on each **outer edge** that cannot hide a secret room:

- no door slot (void / disabled wall)
- no walkable path to that wall (rocks, pits, spikes, poop, fires, grimaces, …)

A room that is only drawn on the map, from the room next door or from a map item, stays unmarked until you enter it. A room can gain rocks the moment you walk in.

No dependency, the rocks are drawn on the vanilla minimap. The icon is the
Basement tinted rock, reskinned in the color of the floor you are on.

## Install

Copy `secret_wall_hints` into:

`Documents\My Games\Binding of Isaac Repentance+\mods\`

(or `...\Binding of Isaac Repentance\mods\` if you are not on Repentance+).

Enable the mod, restart Isaac. After Lua edits: `luamod secret_wall_hints`.

## Map calibration

The game exposes nothing about where it draws the minimap, so the layout at the
top of `main.lua` is measured by hand. If the rocks are off, the debug console
(`~`) can move them.

Repentance+ does not run mod console commands (`MC_EXECUTE_CMD` is never
called), so these go through the built-in `lua` command. On Repentance without
the plus, `swh ...` works the same way without the `lua` wrapper.

- `lua swh("center")` — draws a rock on the middle of the map viewport, it
  should land on the room you are in. Easiest to read in a 1x1 room.
- `lua swh(2, -1)` — moves the whole map origin by that many pixels.
- `lua swh()` — prints the current offset, to copy into `VIEW_PAD`.
- `lua swh("reset")` — back to the values in the file.

# Steam

Paste this into the workshop description. Steam uses its own markup, not Markdown.

```
[h1]Secret Wall Hints[/h1]
Add a small rock mark in the minimap on wall which cannot lead to a secret room.

[list]
[*]The wall has no door slot (a void or a disabled wall)
[*]you cannot walk up to it (rocks, pits, spikes, poop, fires, grimaces, etc.)
[/list]

TODO: add image

[h1]Notes[/h1]
[list]
[*]This is my first mod, so I almost all of the mod was whitten with AI.
[*]The idea came from roomdle
[*]A big thanks to MinimapAPI code for helping understand how map works.
[/list]
- This is my first mod, so I almost all of the mod was whitten with AI. A big thanks to MinimapAPI code for helping understand how map works.

[h1]Dependances[/h1]
This mod was made with Repentance+, no other dependancies!
```
