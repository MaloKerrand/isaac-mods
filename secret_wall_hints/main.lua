local mod = RegisterMod("Secret Wall Hints", 1)

local MAP_W = 13
local PATH, BLOCK, EMPTY, DOOR = 1, 2, 3, 4
local DIR_L, DIR_U, DIR_R, DIR_D = 0, 1, 2, 3

-- Vanilla minimap layout. The game exposes none of it, so these are measured
-- values: VIEW is the map viewport at the top right of the screen, PAD its
-- distance to the screen corner, STEP the distance between two room cells and
-- CELL the size of one cell (cells overlap on the wall they share).
-- The "swh" console command adjusts them in game, see README.
local VIEW_SIZE = Vector(47, 47)
local VIEW_PAD = Vector(6, 6)
local CELL_STEP = Vector(8, 7)
local CELL_SIZE = Vector(9, 8)
local SCROLL_SPEED = 0.3 -- the map slides when moving to another room
local ROCK_PIVOT = Vector(4, 4) -- rock_icon.anm2
local ROCK_SIZE = Vector(8, 8)

local game = Game()
local rockSprite = nil
local snapshots = {} -- [ListIndex] = walkable grid (row -> col -> PATH/BLOCK/EMPTY)
local cachedHints = {} -- [ListIndex] = { {cellIdx, dir}, ... }
local rooms = {dim = -1, size = -1, list = {}, occ = {}} -- rooms of the dimension we are in
local viewCenter = nil -- cell the map is centered on, slides towards the current room
local nudge = Vector(0, 0) -- console offset on VIEW_PAD
local markCenter = false -- console: draw a rock on the middle of the viewport

local SKIP_TYPES = {
	[RoomType.ROOM_DUNGEON] = true,
	[RoomType.ROOM_ERROR] = true,
	[RoomType.ROOM_BLACK_MARKET] = true,
	[RoomType.ROOM_SECRET] = true,
	[RoomType.ROOM_SUPERSECRET] = true,
	[RoomType.ROOM_ULTRASECRET] = true,
}

local EXTRA_BLOCK_ENTS = {
	[EntityType.ENTITY_FIREPLACE] = true,
	[EntityType.ENTITY_MOVABLE_TNT] = true,
	[EntityType.ENTITY_STONEHEAD] = true,
	[EntityType.ENTITY_GAPING_MAW] = true,
	[EntityType.ENTITY_BROKEN_GAPING_MAW] = true,
	[EntityType.ENTITY_CONSTANT_STONE_SHOOTER] = true,
	[EntityType.ENTITY_QUAKE_GRIMACE] = true,
	[EntityType.ENTITY_BOMB_GRIMACE] = true,
	[EntityType.ENTITY_BRIMSTONE_HEAD] = true,
	[EntityType.ENTITY_STONE_EYE] = true,
}

-- Occupied 1x1 cells relative to GridIndex (LTL gap is GridIndex itself).
local SHAPE_OFFSETS = {
	[RoomShape.ROOMSHAPE_1x1] = {0},
	[RoomShape.ROOMSHAPE_IH] = {0},
	[RoomShape.ROOMSHAPE_IV] = {0},
	[RoomShape.ROOMSHAPE_1x2] = {0, 13},
	[RoomShape.ROOMSHAPE_2x1] = {0, 1},
	[RoomShape.ROOMSHAPE_2x2] = {0, 1, 13, 14},
	[RoomShape.ROOMSHAPE_LTL] = {1, 13, 14},
	[RoomShape.ROOMSHAPE_LTR] = {0, 13, 14},
	[RoomShape.ROOMSHAPE_LBL] = {0, 1, 14},
	[RoomShape.ROOMSHAPE_LBR] = {0, 1, 13},
}

SHAPE_OFFSETS[RoomShape.ROOMSHAPE_IIV or -1] = {0, 13}
SHAPE_OFFSETS[RoomShape.ROOMSHAPE_IIH or -1] = {0, 1}

-- Inward floor tiles (row, col) that must be walkable for a secret wall.
-- Coords match game grids: 1x1 is 9x15, 2x1 is 9x28, 1x2 is 16x15, 2x2 is 16x28.
local function inwardTiles(shape, slot)
	local L0, U0, R0, D0 = DoorSlot.LEFT0, DoorSlot.UP0, DoorSlot.RIGHT0, DoorSlot.DOWN0
	local L1, U1, R1, D1 = DoorSlot.LEFT1, DoorSlot.UP1, DoorSlot.RIGHT1, DoorSlot.DOWN1
	local t = {
		[RoomShape.ROOMSHAPE_1x1] = {
			[L0] = {{4, 1}}, [U0] = {{1, 7}}, [R0] = {{4, 13}}, [D0] = {{7, 7}},
		},
		[RoomShape.ROOMSHAPE_IH] = {
			[L0] = {{4, 1}}, [R0] = {{4, 13}},
		},
		[RoomShape.ROOMSHAPE_IV] = {
			[U0] = {{1, 7}}, [D0] = {{7, 7}},
		},
		[RoomShape.ROOMSHAPE_2x1] = {
			[L0] = {{4, 1}}, [R0] = {{4, 26}},
			[U0] = {{1, 7}}, [U1] = {{1, 20}},
			[D0] = {{7, 7}}, [D1] = {{7, 20}},
		},
		[RoomShape.ROOMSHAPE_1x2] = {
			[U0] = {{1, 7}}, [D0] = {{14, 7}},
			[L0] = {{4, 1}}, [L1] = {{11, 1}},
			[R0] = {{4, 13}}, [R1] = {{11, 13}},
		},
		[RoomShape.ROOMSHAPE_2x2] = {
			[L0] = {{4, 1}}, [L1] = {{11, 1}},
			[U0] = {{1, 7}}, [U1] = {{1, 20}},
			[R0] = {{4, 26}}, [R1] = {{11, 26}},
			[D0] = {{14, 7}}, [D1] = {{14, 20}},
		},
		[RoomShape.ROOMSHAPE_LTR] = {
			[L0] = {{4, 1}}, [L1] = {{11, 1}},
			[U0] = {{1, 7}},
			[R0] = {{4, 13}, {8, 20}},
			[R1] = {{11, 26}},
			[D0] = {{14, 7}}, [D1] = {{14, 20}},
		},
		[RoomShape.ROOMSHAPE_LTL] = {
			[L1] = {{11, 1}},
			[L0] = {{4, 14}, {8, 7}},
			[U1] = {{1, 20}},
			[R0] = {{4, 26}}, [R1] = {{11, 26}},
			[D0] = {{14, 7}}, [D1] = {{14, 20}},
		},
		[RoomShape.ROOMSHAPE_LBR] = {
			[L0] = {{4, 1}}, [L1] = {{11, 1}},
			[U0] = {{1, 7}}, [U1] = {{1, 20}},
			[R0] = {{4, 26}},
			[R1] = {{11, 13}, {7, 20}},
			[D0] = {{14, 7}},
		},
		[RoomShape.ROOMSHAPE_LBL] = {
			[L0] = {{4, 1}},
			[L1] = {{7, 7}, {11, 14}},
			[U0] = {{1, 7}}, [U1] = {{1, 20}},
			[R0] = {{4, 26}}, [R1] = {{11, 26}},
			[D1] = {{14, 20}},
		},
	}
	t[RoomShape.ROOMSHAPE_IIH or -1] = t[RoomShape.ROOMSHAPE_2x1]
	t[RoomShape.ROOMSHAPE_IIV or -1] = t[RoomShape.ROOMSHAPE_1x2]
	local byShape = t[shape]
	if not byShape then
		return t[RoomShape.ROOMSHAPE_1x1][slot]
	end
	return byShape[slot]
end

-- Inner corner of L-rooms (no DoorSlot); a secret can still sit in the missing cell.
local function innerLTiles(shape, lx, ly, dir)
	if shape == RoomShape.ROOMSHAPE_LTL and ((lx == 1 and ly == 0 and dir == DIR_L) or (lx == 0 and ly == 1 and dir == DIR_U)) then
		return {{4, 14}, {8, 7}}
	end
	if shape == RoomShape.ROOMSHAPE_LTR and ((lx == 0 and ly == 0 and dir == DIR_R) or (lx == 1 and ly == 1 and dir == DIR_U)) then
		return {{4, 13}, {8, 20}}
	end
	if shape == RoomShape.ROOMSHAPE_LBR and ((lx == 1 and ly == 0 and dir == DIR_D) or (lx == 0 and ly == 1 and dir == DIR_R)) then
		return {{11, 13}, {7, 20}}
	end
	if shape == RoomShape.ROOMSHAPE_LBL and ((lx == 0 and ly == 0 and dir == DIR_D) or (lx == 1 and ly == 1 and dir == DIR_L)) then
		return {{7, 7}, {11, 14}}
	end
	return nil
end

local function slotForCellDir(lx, ly, dir)
	if dir == DIR_L then
		if lx == 0 and ly == 0 then return DoorSlot.LEFT0 end
		if lx == 0 and ly == 1 then return DoorSlot.LEFT1 end
		return nil
	elseif dir == DIR_U then
		if ly == 0 and lx == 0 then return DoorSlot.UP0 end
		if ly == 0 and lx == 1 then return DoorSlot.UP1 end
		return nil
	elseif dir == DIR_R then
		if lx == 0 and ly == 0 then return DoorSlot.RIGHT0 end -- overwritten if 2-wide uses (1,0)
		if lx == 1 and ly == 0 then return DoorSlot.RIGHT0 end
		if lx == 1 and ly == 1 then return DoorSlot.RIGHT1 end
		if lx == 0 and ly == 1 then return DoorSlot.RIGHT1 end
		return nil
	else
		if ly == 0 and lx == 0 then return DoorSlot.DOWN0 end
		if ly == 0 and lx == 1 then return DoorSlot.DOWN1 end
		if ly == 1 and lx == 0 then return DoorSlot.DOWN0 end
		if ly == 1 and lx == 1 then return DoorSlot.DOWN1 end
		return nil
	end
end

local function slotAllowed(doors, slot)
	if slot == nil then
		return false
	end
	return doors & (1 << slot) ~= 0
end

local function neighborIndex(idx, dir)
	local x = idx % MAP_W
	local y = math.floor(idx / MAP_W)
	if dir == DIR_L then
		if x == 0 then return nil end
		return idx - 1
	elseif dir == DIR_U then
		if y == 0 then return nil end
		return idx - MAP_W
	elseif dir == DIR_R then
		if x == MAP_W - 1 then return nil end
		return idx + 1
	else
		if y == MAP_W - 1 then return nil end
		return idx + MAP_W
	end
end

-- Frames of rock_icon.png: the in game rock of every floor, shrunk to map size.
-- Floors that dig up the same rock share a frame (Chest and Home use the
-- Basement one, Dark Room the Sheol one, Necropolis the Depths one, ...).
local ROCK = {
	BASEMENT = 0, BURNING = 1, CELLAR = 2, DOWNPOUR = 3, DROSS = 4,
	CAVES = 5, CATACOMBS = 6, FLOODED = 7, ASHPIT = 8, MINES = 9,
	DEPTHS = 10, WOMB = 11, UTERO = 12, SCARRED = 13, BLUE_WOMB = 14,
	MAUSOLEUM = 15, GEHENNA = 16, SHEOL = 17, CATHEDRAL = 18, CORPSE = 19,
}

-- One row per chapter, indexed by StageType + 1.
local CHAPTER_ROCKS = {
	-- original      wotl            afterbirth     greed          repentance      repentance b
	{ROCK.BASEMENT, ROCK.CELLAR,    ROCK.BURNING,  ROCK.BASEMENT, ROCK.DOWNPOUR,  ROCK.DROSS},
	{ROCK.CAVES,    ROCK.CATACOMBS, ROCK.FLOODED,  ROCK.CAVES,    ROCK.MINES,     ROCK.ASHPIT},
	{ROCK.DEPTHS,   ROCK.DEPTHS,    ROCK.DEPTHS,   ROCK.DEPTHS,   ROCK.MAUSOLEUM, ROCK.GEHENNA},
	{ROCK.WOMB,     ROCK.UTERO,     ROCK.SCARRED,  ROCK.WOMB,     ROCK.CORPSE,    ROCK.CORPSE},
}

local function floorRock()
	local level = game:GetLevel()
	local stage, styp = level:GetStage(), level:GetStageType()
	if stage == LevelStage.STAGE4_3 then
		return ROCK.BLUE_WOMB
	elseif stage == LevelStage.STAGE5 then
		return styp == StageType.STAGETYPE_WOTL and ROCK.CATHEDRAL or ROCK.SHEOL
	elseif stage == LevelStage.STAGE6 then
		return styp == StageType.STAGETYPE_WOTL and ROCK.BASEMENT or ROCK.SHEOL -- Chest / Dark Room
	elseif stage == LevelStage.STAGE8 then
		return ROCK.BASEMENT -- Home
	end
	-- Greed mode runs one floor per chapter, the others two.
	local chapter = CHAPTER_ROCKS[game:IsGreedMode() and stage or math.ceil(stage / 2)]
	if not chapter then
		return ROCK.SHEOL -- Void, greed mode Sheol and shop
	end
	return chapter[styp + 1] or chapter[1]
end

local function ensureSprite()
	if not rockSprite then
		rockSprite = Sprite()
		rockSprite:Load("gfx/secret_wall_hints/rock_icon.anm2", true)
	end
	rockSprite:SetFrame("Idle", floorRock())
	return rockSprite
end

local function isBlockingGrid(gridType)
	return gridType ~= GridEntityType.GRID_NULL
		and gridType ~= GridEntityType.GRID_DECORATION
		and gridType ~= GridEntityType.GRID_SPIDERWEB
		and gridType ~= GridEntityType.GRID_DOOR
		and gridType ~= GridEntityType.GRID_PRESSURE_PLATE
		and gridType ~= GridEntityType.GRID_TELEPORTER
end

local function snapshotCurrentRoom()
	local room = game:GetRoom()
	local desc = game:GetLevel():GetCurrentRoomDesc()
	if desc.GridIndex < 0 then
		return
	end
	local width = room:GetGridWidth()
	local height = room:GetGridHeight()
	local grid = {}
	for r = 0, height - 1 do
		grid[r] = {}
		for c = 0, width - 1 do
			grid[r][c] = EMPTY
		end
	end

	for i = 0, room:GetGridSize() - 1 do
		local ge = room:GetGridEntity(i)
		if ge then
			local r = math.floor(i / width)
			local c = i % width
			if ge:GetType() == GridEntityType.GRID_DOOR then
				grid[r][c] = DOOR
			elseif isBlockingGrid(ge:GetType()) then
				grid[r][c] = BLOCK
			end
		end
	end

	for _, ent in ipairs(Isaac.GetRoomEntities()) do
		if EXTRA_BLOCK_ENTS[ent.Type] or ent:IsActiveEnemy(false) then
			local gi = ent.SpawnGridIndex
			if gi and gi >= 0 then
				local r = math.floor(gi / width)
				local c = gi % width
				if grid[r] and grid[r][c] ~= DOOR then
					grid[r][c] = BLOCK
				end
			end
		end
	end

	local queue = {}
	for r = 0, height - 1 do
		for c = 0, width - 1 do
			if grid[r][c] == DOOR then
				local nr, nc = r, c
				if r == 0 then nr = r + 1
				elseif r == height - 1 then nr = r - 1
				elseif c == 0 then nc = c + 1
				elseif c == width - 1 then nc = c - 1
				end
				if grid[nr] and grid[nr][nc] == EMPTY then
					grid[nr][nc] = PATH
					queue[#queue + 1] = {nr, nc}
				end
			end
		end
	end

	if #queue == 0 then
		local cr, cc = math.floor(height / 2), math.floor(width / 2)
		if grid[cr] and grid[cr][cc] == EMPTY then
			grid[cr][cc] = PATH
			queue[1] = {cr, cc}
		end
	end

	local i = 1
	while i <= #queue do
		local r, c = queue[i][1], queue[i][2]
		i = i + 1
		local nbs = {{r - 1, c}, {r + 1, c}, {r, c - 1}, {r, c + 1}}
		for n = 1, 4 do
			local nr, nc = nbs[n][1], nbs[n][2]
			if grid[nr] and grid[nr][nc] == EMPTY then
				grid[nr][nc] = PATH
				queue[#queue + 1] = {nr, nc}
			end
		end
	end

	snapshots[desc.ListIndex] = grid
	cachedHints[desc.ListIndex] = nil
end

local function currentDimension()
	local level = game:GetLevel()
	local desc = level:GetCurrentRoomDesc()
	for dim = 0, 2 do
		if GetPtrHash(level:GetRoomByIdx(desc.SafeGridIndex, dim)) == GetPtrHash(desc) then
			return dim
		end
	end
	return 0
end

-- Rooms of the dimension we are in, with the cells they occupy: the mirror
-- dimension and the mineshaft sit on the same grid indices, and only one of
-- them is on the map at a time. Rebuilt when a room is added (red rooms).
local function currentRooms()
	local level = game:GetLevel()
	local list = level:GetRooms()
	local dim = currentDimension()
	if rooms.dim == dim and rooms.size == list.Size then
		return rooms
	end
	rooms = {dim = dim, size = list.Size, list = {}, occ = {}}
	cachedHints = {}
	for i = 0, list.Size - 1 do
		local desc = list:Get(i)
		if desc and desc.Data and desc.GridIndex >= 0
			and GetPtrHash(level:GetRoomByIdx(desc.SafeGridIndex, dim)) == GetPtrHash(desc)
		then
			rooms.list[#rooms.list + 1] = desc
			for _, off in ipairs(SHAPE_OFFSETS[desc.Data.Shape] or {0}) do
				rooms.occ[desc.GridIndex + off] = desc
			end
		end
	end
	return rooms
end

local function tilesReachable(grid, tiles)
	if not grid or not tiles then
		return false
	end
	for _, tile in ipairs(tiles) do
		local r, c = tile[1], tile[2]
		if not grid[r] or grid[r][c] ~= PATH then
			return false
		end
	end
	return true
end

local function computeHints(desc, occ)
	local hints = cachedHints[desc.ListIndex]
	if hints then
		return hints
	end
	hints = {}
	if desc.GridIndex < 0 or not desc.Data then
		cachedHints[desc.ListIndex] = hints
		return hints
	end
	local shape = desc.Data.Shape
	local doors = desc.Data.Doors
	local offsets = SHAPE_OFFSETS[shape] or {0}
	local inRoom = {}
	for _, off in ipairs(offsets) do
		inRoom[desc.GridIndex + off] = true
	end

	local forceBlock = desc.Data.Type == RoomType.ROOM_BOSS

	for _, off in ipairs(offsets) do
		local cell = desc.GridIndex + off
		local lx = (cell % MAP_W) - (desc.GridIndex % MAP_W)
		local ly = math.floor(cell / MAP_W) - math.floor(desc.GridIndex / MAP_W)
		if shape == RoomShape.ROOMSHAPE_LTL then
			lx = (cell % MAP_W) - (desc.GridIndex % MAP_W)
			ly = math.floor(cell / MAP_W) - math.floor(desc.GridIndex / MAP_W)
		end
		for dir = 0, 3 do
			local nidx = neighborIndex(cell, dir)
			if not inRoom[nidx] then
				local other = nidx and occ[nidx]
				if other == nil then
					local slot = slotForCellDir(lx, ly, dir)
					local tiles = inwardTiles(shape, slot) or innerLTiles(shape, lx, ly, dir)
					local blocked = forceBlock
					if not blocked then
						if slot == nil and tiles == nil then
							blocked = true
						elseif slot ~= nil and not slotAllowed(doors, slot) then
							blocked = true
						else
							-- No snapshot: we have never been in that room, so we
							-- know where its doors can go but not what stands in
							-- front of them. The wall stays a maybe until we visit.
							local grid = snapshots[desc.ListIndex]
							if grid then
								blocked = not tilesReachable(grid, tiles)
							end
						end
					end
					if blocked then
						hints[#hints + 1] = {cell = cell, dir = dir}
					end
				end
			end
		end
	end

	cachedHints[desc.ListIndex] = hints
	return hints
end

-- Screen size in render coordinates; there is no API for it either.
local function screenSize()
	local room = game:GetRoom()
	local pos = room:WorldToScreenPosition(Vector.Zero) - room:GetRenderScrollOffset() - game.ScreenShakeOffset
	return Vector((pos.X + 60 * 26 / 40) * 2 + 13 * 26, (pos.Y + 140 * 26 / 40) * 2 + 7 * 26)
end

-- Top-left pixel of the map viewport.
local function viewOrigin()
	local hud = Options.HUDOffset * 10
	return Vector(
		screenSize().X - hud * 2.2 - VIEW_PAD.X - VIEW_SIZE.X + nudge.X,
		hud * 1.2 + VIEW_PAD.Y + nudge.Y)
end

local function shapeCells(shape)
	local w, h = 1, 1
	for _, off in ipairs(SHAPE_OFFSETS[shape] or {0}) do
		w = math.max(w, off % MAP_W + 1)
		h = math.max(h, math.floor(off / MAP_W) + 1)
	end
	return w, h
end

-- The map is centered on the middle of the room the player is in, and slides
-- there instead of jumping when the room changes.
local function updateViewCenter()
	local desc = game:GetLevel():GetCurrentRoomDesc()
	if desc.GridIndex < 0 or not desc.Data then
		return nil -- off grid (dungeon, black market): the map is not ours to draw on
	end
	local w, h = shapeCells(desc.Data.Shape)
	local target = Vector(desc.GridIndex % MAP_W + w * 0.5, math.floor(desc.GridIndex / MAP_W) + h * 0.5)
	if not viewCenter or viewCenter:DistanceSquared(target) < 0.0001 then
		viewCenter = target
	else
		viewCenter = target * SCROLL_SPEED + viewCenter * (1 - SCROLL_SPEED)
	end
	return viewCenter
end

-- Rock center, relative to the top-left of the cell. It sits on the wall itself:
-- a hinted wall never has a room behind it, so the outer half covers empty map.
local function edgeOffset(dir)
	if dir == DIR_L then
		return Vector(0.5, CELL_SIZE.Y * 0.5)
	elseif dir == DIR_U then
		return Vector(CELL_SIZE.X * 0.5, 0.5)
	elseif dir == DIR_R then
		return Vector(CELL_SIZE.X - 0.5, CELL_SIZE.Y * 0.5)
	end
	return Vector(CELL_SIZE.X * 0.5, CELL_SIZE.Y - 0.5)
end

local function hintPosition(cell, dir, origin, center)
	local edge = edgeOffset(dir)
	return origin + VIEW_SIZE * 0.5 + Vector(
		((cell % MAP_W) - center.X) * CELL_STEP.X + edge.X,
		(math.floor(cell / MAP_W) - center.Y) * CELL_STEP.Y + edge.Y)
end

-- Rooms are cut off at the edge of the viewport, rocks have to be as well.
local function renderRock(spr, pos, origin)
	local iconTL = pos - ROCK_PIVOT - origin
	local tlcut = -iconTL
	local brcut = iconTL + ROCK_SIZE - VIEW_SIZE
	if tlcut.X >= ROCK_SIZE.X or tlcut.Y >= ROCK_SIZE.Y or brcut.X >= ROCK_SIZE.X or brcut.Y >= ROCK_SIZE.Y then
		return
	end
	tlcut:Clamp(0, 0, ROCK_SIZE.X, ROCK_SIZE.Y)
	brcut:Clamp(0, 0, ROCK_SIZE.X, ROCK_SIZE.Y)
	spr:Render(pos, tlcut, brcut)
end

local function mapHeld()
	for i = 0, game:GetNumPlayers() - 1 do
		if Input.IsActionPressed(ButtonAction.ACTION_MAP, Isaac.GetPlayer(i).ControllerIndex) then
			return true
		end
	end
	return false
end

local function resetFloor()
	snapshots = {}
	cachedHints = {}
	rooms = {dim = -1, size = -1, list = {}, occ = {}}
	viewCenter = nil
end

local function onNewLevel()
	resetFloor()
end

local function onNewRoom()
	local desc = game:GetLevel():GetCurrentRoomDesc()
	if desc.GridIndex < 0 then
		return
	end
	local rtype = game:GetRoom():GetType()
	if rtype == RoomType.ROOM_DUNGEON or rtype == RoomType.ROOM_ERROR or rtype == RoomType.ROOM_BLACK_MARKET then
		return
	end
	if snapshots[desc.ListIndex] == nil then
		snapshotCurrentRoom()
	end
end

local function onRender()
	if not game:GetHUD():IsVisible() or game:GetSeeds():HasSeedEffect(SeedEffect.SEED_NO_HUD) then
		return
	end
	-- Nothing to draw on: the curse replaces the map with a question mark, and
	-- the expanded map (map button held) is drawn at another scale.
	if game:GetLevel():GetCurses() & LevelCurse.CURSE_OF_THE_LOST ~= 0 or mapHeld() then
		return
	end

	local center = updateViewCenter()
	if not center then
		return
	end

	local spr = ensureSprite()
	local origin = viewOrigin()
	local floor = currentRooms()

	-- Every room the map draws a box for, visited or not: a room we only saw
	-- through a mapping item still tells us where its doors cannot go.
	for _, desc in ipairs(floor.list) do
		if desc.DisplayFlags & 1 ~= 0 and not SKIP_TYPES[desc.Data.Type] then
			local hints = computeHints(desc, floor.occ)
			for h = 1, #hints do
				renderRock(spr, hintPosition(hints[h].cell, hints[h].dir, origin, center), origin)
			end
		end
	end

	if markCenter then
		renderRock(spr, origin + VIEW_SIZE * 0.5, origin)
	end
end

-- Map layout calibration, the game gives us no way to read it back.
-- "swh" prints the offset, "swh <x> <y>" moves the map origin by that many
-- pixels, "swh center" marks the middle of the viewport, "swh reset" clears it.
local function onCommand(_, cmd, params)
	if cmd ~= "swh" then
		return
	end
	if params == "center" then
		markCenter = not markCenter
	elseif params == "reset" then
		nudge = Vector(0, 0)
		markCenter = false
	else
		local x, y = params:match("^%s*(-?%d+%.?%d*)%s+(-?%d+%.?%d*)%s*$")
		if x then
			nudge = Vector(tonumber(x), tonumber(y))
		end
	end
	print(string.format("[Secret Wall Hints] nudge %g %g, center mark %s", nudge.X, nudge.Y, tostring(markCenter)))
end

mod:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, onNewLevel)
mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, onNewRoom)
mod:AddCallback(ModCallbacks.MC_POST_RENDER, onRender)
mod:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, resetFloor)
mod:AddCallback(ModCallbacks.MC_EXECUTE_CMD, onCommand)
