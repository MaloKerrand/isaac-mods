# Secret Wall Hints

Isaac Repentance(+) Lua mod. The minimap gets a small rock on each **outer edge** that cannot hide a secret room:

- no door slot (void / disabled wall), as soon as the room is drawn on the map,
  so a Treasure Map fills in the whole floor at once
- no walkable path to that wall (rocks, pits, spikes, poop, fires, grimaces, …),
  this one needs you to have been in the room, so a room can gain rocks when you
  walk into it

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
(`~`) can move them:

- `swh center` — draws a rock on the middle of the map viewport, it should land
  on the room you are in. Easiest to read in a 1x1 room.
- `swh <x> <y>` — moves the whole map origin by that many pixels, e.g. `swh 2 -1`.
- `swh` — prints the current offset, to copy into `VIEW_PAD`.
- `swh reset` — back to the values in the file.

# TODO

- Show rocks on the expanded map (map button held)
