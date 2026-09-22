# Secret Wall Hints

Isaac Repentance(+) Lua mod. After you visit a room, the minimap gets a small rock on each **outer edge** that cannot hide a secret room:

- no door slot (void / disabled wall)
- no walkable path to that wall (rocks, pits, spikes, poop, fires, grimaces, …)

Requires **[MiniMAPI](https://steamcommunity.com/sharedfiles/filedetails/?id=1978904635)**. Put this folder _below_ MiniMAPI in the mods list.

## Install

Copy `secret_wall_hints` into:

`Documents\My Games\Binding of Isaac Repentance+\mods\`

(or `...\Binding of Isaac Repentance\mods\` if you are not on Repentance+).

Enable both mods, restart Isaac. After Lua edits: `luamod secret_wall_hints`.

# TODO

- Use real rock sprite (per floor)
- Fix rock position
- Use default map UI
- Show rock on room reveal, not enter (e.g. should work with mapping items)
