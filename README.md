# Secret Wall Hints

Isaac Repentance(+) Lua mod. After you walk into a room, the minimap gets a small rock on each **outer edge** that cannot hide a secret room:

- no door slot (void / disabled wall)
- no walkable path to that wall (rocks, pits, spikes, poop, fires, grimaces, …)

A room that is only drawn on the map, from the room next door or from a map item, stays unmarked until you enter it. A room can gain rocks the moment you walk in.

No dependency, the rocks are drawn on the vanilla minimap. The icon is the in
game rock of the floor you are on, shrunk to map size: 20 of them, one per rock
art the game has, from the Basement one to the Corpse one. `art/` holds the
source art, `rock_icon.png` is the 8px sheet the mod loads.

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

# TODO

- Fix other ui mods breaking, the planetarium icon is flickering
- Use only one squared rock
- Add description for steam (thanks AI, minimap api, my first mod)
