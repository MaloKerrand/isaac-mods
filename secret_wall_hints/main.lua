local mod = RegisterMod("Secret Wall Hints", 1)

local MAP_W = 13
local PATH, BLOCK, EMPTY, DOOR = 1, 2, 3, 4
local DIR_LEFT, DIR_UP, DIR_RIGHT, DIR_DOWN = 0, 1, 2, 3

-- Vanilla minimap layout. The game exposes none of it, so these are measured
-- values: VIEW is the small map viewport at the top right of the screen, PAD
-- its distance to the screen corner, STEP the distance between two room cells
-- and CELL the size of one cell (cells overlap on the wall they share).
-- The "swh" console command adjusts whichever map is on screen.
local VIEW_SIZE = Vector(47, 47)
local VIEW_PAD = Vector(8, 3)
local CELL_STEP = Vector(8, 7)
local CELL_SIZE = Vector(9, 8)
-- floor_rock.anm2 is the basement rock, 8x8, pivot at the center, one
-- frame per floor. A quarter of that is 2px on the small map. New filename
-- so the game does not reuse a cached sheet.
local ROCK_SCALE = 0.25
local ROCK_PIVOT = Vector(1, 1)
local ROCK_SIZE = Vector(2, 2)

-- Expanded map. A short press of the map button leaves it up; holding it
-- longer and letting go returns to the small one. Cells are a little over
-- twice as wide, and the rock grows with them.
-- BIG_PAD is the player's calibration: swh(6, 5) on top of an earlier
-- (-4, -2) guess, so the rocks sit 2px right and 3px down from the corner.
-- swh adds bigNudge on top of it.
local BIG_STEP = Vector(17, 15)
local BIG_CELL = Vector(18, 16)
local BIG_PAD = Vector(2, 3)
local BIG_ROCK_SCALE = 0.5
local BIG_ROCK = 4

local game = Game()
local rockSprites = {} -- "small" / "big". One sprite each; a shared one kept the other map's size.
local rockFrame = {} -- floor frame last loaded into that sprite
local spriteEpoch = 0 -- bumped on a new floor so the sprites are built again
local builtEpoch = -1
local snapshots = {} -- [ListIndex] = walkable grid (row -> col -> PATH/BLOCK/EMPTY)
local cachedRockPositions = {} -- [ListIndex] = { {cell, direction}, ... }
local rooms = {dim = -1, size = -1, list = {}, occupiedCells = {}} -- rooms of the dimension we are in
local viewCenter = nil -- cell the map is centered on, the room the player is in
local nudge = Vector(0, 0) -- console offset on the small map
local bigNudge = Vector(0, 0) -- console offset on the expanded map
local markCenter = false -- console: draw a rock on the middle of the viewport
-- Expanded-map mode, copied from the game's own machine so a tap keeps it open.
-- 0 small, 1 button down, 2 latched open. mapFlag is which way the next release goes.
local mapState = 0
local mapFlag = false
local mapFrames = 0
-- Large-map alpha, in tenths. The game adds or subtracts 0.1 a frame (float
-- 0xbaa120), so the two maps overlap for the whole fade, not one snapped frame.
local bigAlpha = 0
local hudSuppressed = false -- we hid the HUD so its later pass does not cover the rocks
local renderPlan = nil -- set once the HUD has been drawn, before other UI mods

local SKIP_TYPES = {
	[RoomType.ROOM_DUNGEON] = true,
	[RoomType.ROOM_ERROR] = true,
	[RoomType.ROOM_BLACK_MARKET] = true,
	[RoomType.ROOM_SECRET] = true,
	[RoomType.ROOM_SUPERSECRET] = true,
	[RoomType.ROOM_ULTRASECRET] = true,
	[RoomType.ROOM_BOSS] = true,
}

-- Thin layouts (IH, IV and the long ones). No secret room on those.
local SMALL_SHAPES = {
	[RoomShape.ROOMSHAPE_IH] = true,
	[RoomShape.ROOMSHAPE_IV] = true,
	[RoomShape.ROOMSHAPE_IIH] = true,
	[RoomShape.ROOMSHAPE_IIV] = true,
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

-- Added to GridIndex to reach each 1x1 subroom (LTL's gap is GridIndex itself).
local SUBROOM_INDEX_OFFSETS = {
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

SUBROOM_INDEX_OFFSETS[RoomShape.ROOMSHAPE_IIV or -1] = {0, 13}
SUBROOM_INDEX_OFFSETS[RoomShape.ROOMSHAPE_IIH or -1] = {0, 1}

-- Inward floor tiles (row, col) that must be walkable for a secret wall.
-- Coords match game grids: 1x1 is 9x15, 2x1 is 9x28, 1x2 is 16x15, 2x2 is 16x28.
local function inwardTiles(shape, doorSlot)
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
		return t[RoomShape.ROOMSHAPE_1x1][doorSlot]
	end
	return byShape[doorSlot]
end

-- Inner corner of L-rooms (no DoorSlot); a secret can still sit in the missing cell.
local function innerCornerTiles(shape, shapeX, shapeY, direction)
	if shape == RoomShape.ROOMSHAPE_LTL and ((shapeX == 1 and shapeY == 0 and direction == DIR_LEFT) or (shapeX == 0 and shapeY == 1 and direction == DIR_UP)) then
		return {{4, 14}, {8, 7}}
	end
	if shape == RoomShape.ROOMSHAPE_LTR and ((shapeX == 0 and shapeY == 0 and direction == DIR_RIGHT) or (shapeX == 1 and shapeY == 1 and direction == DIR_UP)) then
		return {{4, 13}, {8, 20}}
	end
	if shape == RoomShape.ROOMSHAPE_LBR and ((shapeX == 1 and shapeY == 0 and direction == DIR_DOWN) or (shapeX == 0 and shapeY == 1 and direction == DIR_RIGHT)) then
		return {{11, 13}, {7, 20}}
	end
	if shape == RoomShape.ROOMSHAPE_LBL and ((shapeX == 0 and shapeY == 0 and direction == DIR_DOWN) or (shapeX == 1 and shapeY == 1 and direction == DIR_LEFT)) then
		return {{7, 7}, {11, 14}}
	end
	return nil
end

local function doorSlotForCell(shapeX, shapeY, direction)
	if direction == DIR_LEFT then
		if shapeX == 0 and shapeY == 0 then return DoorSlot.LEFT0 end
		if shapeX == 0 and shapeY == 1 then return DoorSlot.LEFT1 end
		return nil
	elseif direction == DIR_UP then
		if shapeY == 0 and shapeX == 0 then return DoorSlot.UP0 end
		if shapeY == 0 and shapeX == 1 then return DoorSlot.UP1 end
		return nil
	elseif direction == DIR_RIGHT then
		if shapeX == 0 and shapeY == 0 then return DoorSlot.RIGHT0 end -- overwritten if 2-wide uses (1,0)
		if shapeX == 1 and shapeY == 0 then return DoorSlot.RIGHT0 end
		if shapeX == 1 and shapeY == 1 then return DoorSlot.RIGHT1 end
		if shapeX == 0 and shapeY == 1 then return DoorSlot.RIGHT1 end
		return nil
	else
		if shapeY == 0 and shapeX == 0 then return DoorSlot.DOWN0 end
		if shapeY == 0 and shapeX == 1 then return DoorSlot.DOWN1 end
		if shapeY == 1 and shapeX == 0 then return DoorSlot.DOWN0 end
		if shapeY == 1 and shapeX == 1 then return DoorSlot.DOWN1 end
		return nil
	end
end

local function doorSlotEnabled(doorMask, doorSlot)
	if doorSlot == nil then
		return false
	end
	return doorMask & (1 << doorSlot) ~= 0
end

local function neighborIndex(cell, direction)
	local x = cell % MAP_W
	local y = math.floor(cell / MAP_W)
	if direction == DIR_LEFT then
		if x == 0 then return nil end
		return cell - 1
	elseif direction == DIR_UP then
		if y == 0 then return nil end
		return cell - MAP_W
	elseif direction == DIR_RIGHT then
		if x == MAP_W - 1 then return nil end
		return cell + 1
	else
		if y == MAP_W - 1 then return nil end
		return cell + MAP_W
	end
end

-- Frames of floor_square.png: the basement rock, reskinned to each floor.
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

local function ensureSprite(scale)
	-- A new floor reloads animations. The sprite loaded on the previous floor
	-- then draws at the other map's size and stays there, so build a new one.
	if builtEpoch ~= spriteEpoch then
		rockSprites = {}
		rockFrame = {}
		builtEpoch = spriteEpoch
	end
	local key = scale == BIG_ROCK_SCALE and "big" or "small"
	local frame = floorRock()
	local spr = rockSprites[key]
	if not spr or rockFrame[key] ~= frame then
		spr = Sprite()
		spr:Load("gfx/secret_wall_hints/floor_rock.anm2", true)
		-- Idle is one frame per floor. Left running it walks off the frame we
		-- set and writes the anm2 scale back over Scale.
		spr.PlaybackSpeed = 0
		rockSprites[key] = spr
		rockFrame[key] = frame
	end
	-- SetFrame applies the anm2 scale and wipes Scale. On the big-to-small
	-- switch that lands on the first small frame, and the rock is clipped away.
	spr:SetFrame("Idle", frame)
	spr.Scale = Vector(scale, scale)
	return spr
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
	cachedRockPositions[desc.ListIndex] = nil
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

-- Downpour and Dross draw the mirror world with a negative X scale. The
-- mineshaft uses the same dimension and is not flipped.
local function inMirrorDimension(dim)
	if dim ~= 1 then
		return false
	end
	local level = game:GetLevel()
	local stage, styp = level:GetStage(), level:GetStageType()
	if styp ~= StageType.STAGETYPE_REPENTANCE and styp ~= StageType.STAGETYPE_REPENTANCE_B then
		return false
	end
	if stage == LevelStage.STAGE1_2 then
		return true
	end
	return stage == LevelStage.STAGE1_1 and level:GetCurses() & LevelCurse.CURSE_OF_LABYRINTH ~= 0
end

local function mirrorX(pos, axis)
	return Vector(axis * 2 - pos.X, pos.Y)
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
	rooms = {dim = dim, size = list.Size, list = {}, occupiedCells = {}}
	cachedRockPositions = {}
	for i = 0, list.Size - 1 do
		local desc = list:Get(i)
		if desc and desc.Data and desc.GridIndex >= 0
			and GetPtrHash(level:GetRoomByIdx(desc.SafeGridIndex, dim)) == GetPtrHash(desc)
		then
			rooms.list[#rooms.list + 1] = desc
			for _, subroomIndexOffset in ipairs(SUBROOM_INDEX_OFFSETS[desc.Data.Shape] or {0}) do
				rooms.occupiedCells[desc.GridIndex + subroomIndexOffset] = desc
			end
		end
	end
	return rooms
end

local function entranceTilesWalkable(walkGrid, entranceTiles)
	if not walkGrid or not entranceTiles then
		return false
	end
	for _, tile in ipairs(entranceTiles) do
		local row, col = tile[1], tile[2]
		if not walkGrid[row] or walkGrid[row][col] ~= PATH then
			return false
		end
	end
	return true
end

local function computeRockPositions(roomDesc, occupiedCells)
	local rockPositions = cachedRockPositions[roomDesc.ListIndex]
	if rockPositions then
		return rockPositions
	end
	rockPositions = {}
	if roomDesc.GridIndex < 0 or not roomDesc.Data then
		cachedRockPositions[roomDesc.ListIndex] = rockPositions
		return rockPositions
	end
	local shape = roomDesc.Data.Shape
	local doorMask = roomDesc.Data.Doors
	local subroomIndexOffsets = SUBROOM_INDEX_OFFSETS[shape] or {0}
	local roomCells = {}
	for _, subroomIndexOffset in ipairs(subroomIndexOffsets) do
		roomCells[roomDesc.GridIndex + subroomIndexOffset] = true
	end

	for _, subroomIndexOffset in ipairs(subroomIndexOffsets) do
		local cell = roomDesc.GridIndex + subroomIndexOffset
		local shapeX = (cell % MAP_W) - (roomDesc.GridIndex % MAP_W)
		local shapeY = math.floor(cell / MAP_W) - math.floor(roomDesc.GridIndex / MAP_W)
		if shape == RoomShape.ROOMSHAPE_LTL then
			shapeX = (cell % MAP_W) - (roomDesc.GridIndex % MAP_W)
			shapeY = math.floor(cell / MAP_W) - math.floor(roomDesc.GridIndex / MAP_W)
		end
		for direction = 0, 3 do
			local neighborCell = neighborIndex(cell, direction)
			if not roomCells[neighborCell] then
				local neighborRoom = neighborCell and occupiedCells[neighborCell]
				if neighborRoom == nil then
					-- Both checks need the room we walked into. The door mask
					-- and the grid are on the descriptor before that, and using
					-- them paints rocks on rooms that are only drawn on the map.
					local walkGrid = snapshots[roomDesc.ListIndex]
					if walkGrid then
						local doorSlot = doorSlotForCell(shapeX, shapeY, direction)
						local entranceTiles = inwardTiles(shape, doorSlot) or innerCornerTiles(shape, shapeX, shapeY, direction)
						local placeRock = false
						if doorSlot == nil and entranceTiles == nil then
							placeRock = true
						elseif doorSlot ~= nil and not doorSlotEnabled(doorMask, doorSlot) then
							placeRock = true
						else
							placeRock = not entranceTilesWalkable(walkGrid, entranceTiles)
						end
						if placeRock then
							rockPositions[#rockPositions + 1] = {cell = cell, direction = direction}
						end
					end
				end
			end
		end
	end

	cachedRockPositions[roomDesc.ListIndex] = rockPositions
	return rockPositions
end

-- Screen size in render coordinates; there is no API for it either.
local function screenSize()
	local room = game:GetRoom()
	local pos = room:WorldToScreenPosition(Vector.Zero) - room:GetRenderScrollOffset() - game.ScreenShakeOffset
	return Vector((pos.X + 60 * 26 / 40) * 2 + 13 * 26, (pos.Y + 140 * 26 / 40) * 2 + 7 * 26)
end

-- Top-right corner the maps sit against, after the HUD offset.
local function mapCorner()
	local hud = Options.HUDOffset * 10
	local screen = screenSize()
	return Vector(screen.X - hud * 2.2 - VIEW_PAD.X, hud * 1.2 + VIEW_PAD.Y)
end

-- Same corner, shifted by the expanded-map correction and the console nudge.
local function bigCorner()
	local corner = mapCorner()
	return Vector(corner.X + BIG_PAD.X + bigNudge.X, corner.Y + BIG_PAD.Y + bigNudge.Y)
end

-- Top-left pixel of the small map viewport. nudge is the console offset.
local function viewOrigin()
	local corner = mapCorner()
	return Vector(corner.X - VIEW_SIZE.X + nudge.X, corner.Y + nudge.Y)
end

local function shapeCells(shape)
	local w, h = 1, 1
	for _, subroomIndexOffset in ipairs(SUBROOM_INDEX_OFFSETS[shape] or {0}) do
		w = math.max(w, subroomIndexOffset % MAP_W + 1)
		h = math.max(h, math.floor(subroomIndexOffset / MAP_W) + 1)
	end
	return w, h
end

-- The map is centered on the middle of the room the player is in. The game
-- does not expose its scroll, so the rocks jump there the same frame.
local function updateViewCenter()
	local desc = game:GetLevel():GetCurrentRoomDesc()
	if desc.GridIndex < 0 or not desc.Data then
		return nil -- off grid (dungeon, black market): the map is not ours to draw on
	end
	local w, h = shapeCells(desc.Data.Shape)
	viewCenter = Vector(desc.GridIndex % MAP_W + w * 0.5, math.floor(desc.GridIndex / MAP_W) + h * 0.5)
	return viewCenter
end

-- Rock center, relative to the top-left of the cell. Half a pixel in from the
-- wall plus the move onto the room, so the icon sits inside instead of on the
-- black border. `rockSize` is the on-screen size.
local function edgeOffset(direction, cellSize, rockSize)
	local inset = rockSize * 0.5 + 0.5
	if direction == DIR_LEFT then
		return Vector(inset, cellSize.Y * 0.5)
	elseif direction == DIR_UP then
		return Vector(cellSize.X * 0.5, inset)
	elseif direction == DIR_RIGHT then
		return Vector(cellSize.X - inset, cellSize.Y * 0.5)
	end
	return Vector(cellSize.X * 0.5, cellSize.Y - inset)
end

local function rockScreenPosition(cell, direction, origin, center)
	local edge = edgeOffset(direction, CELL_SIZE, ROCK_SIZE.X)
	return origin + VIEW_SIZE * 0.5 + Vector(
		((cell % MAP_W) - center.X) * CELL_STEP.X + edge.X,
		(math.floor(cell / MAP_W) - center.Y) * CELL_STEP.Y + edge.Y)
end

-- Cells the map is showing, as a box in grid units. The expanded map packs
-- that box into the corner instead of scrolling with the player.
local function shownBounds(floor)
	local minX, minY, maxX, maxY = MAP_W, MAP_W, 0, 0
	for _, desc in ipairs(floor.list) do
		if desc.DisplayFlags & 1 ~= 0 and desc.Data then
			local gx = desc.GridIndex % MAP_W
			local gy = math.floor(desc.GridIndex / MAP_W)
			local w, h = shapeCells(desc.Data.Shape)
			if gx < minX then minX = gx end
			if gy < minY then minY = gy end
			if gx + w > maxX then maxX = gx + w end
			if gy + h > maxY then maxY = gy + h end
		end
	end
	if maxX <= minX then
		return nil
	end
	return minX, minY, maxX, maxY
end

-- Rock center on the expanded map. The right of the rightmost room and the
-- top of the topmost one sit on the same corner as the small map.
local function bigRockScreenPosition(cell, direction, corner, minY, maxX)
	local edge = edgeOffset(direction, BIG_CELL, BIG_ROCK)
	local gx = cell % MAP_W
	local gy = math.floor(cell / MAP_W)
	return Vector(
		corner.X + (gx - maxX) * BIG_STEP.X - (BIG_CELL.X - BIG_STEP.X) + edge.X,
		corner.Y + (gy - minY) * BIG_STEP.Y + edge.Y)
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
	-- Clamps are in the 8px frame, the on-screen size is ROCK_SCALE of that.
	spr:Render(pos, tlcut / ROCK_SCALE, brcut / ROCK_SCALE)
end

local function mapButtonDown()
	for i = 0, game:GetNumPlayers() - 1 do
		if Input.IsActionPressed(ButtonAction.ACTION_MAP, Isaac.GetPlayer(i).ControllerIndex) then
			return true
		end
	end
	-- Keyboard and the pads. A player's ControllerIndex is not always the one
	-- the map button is read from.
	for c = 0, 3 do
		if Input.IsActionPressed(ButtonAction.ACTION_MAP, c) then
			return true
		end
	end
	return false
end

-- The game keeps the expanded map up after a short press (under 9 frames,
-- about 150ms) and drops back to the small map when a longer press is
-- released. While it is up the button is not held, so checking
-- IsActionPressed draws the small-map rocks on top of the big map.
-- States match the machine at 0x98dba0: mode in minimap+0, flag in +4,
-- hold length in +8. State 2 clears the counter, so a press that starts
-- there is measured from scratch.
local function updateMapMode()
	local down = mapButtonDown()
	if down then
		mapFrames = mapFrames + 1
	end

	if mapState == 0 then
		if down then
			mapState = 1
		else
			mapFrames = 0
		end
	elseif mapState == 2 then
		mapFrames = 0
		if down then
			mapState = 1
		end
	elseif not down then
		if mapFrames < 9 then
			if mapFlag then
				mapState = 0
				mapFlag = false
			else
				mapState = 2
				mapFlag = true
			end
		elseif mapFlag then
			mapState = 2
		else
			mapState = 0
		end
		mapFrames = 0
	end
end

local function bigMapOpen()
	return mapState ~= 0
end

-- Same step as the minimap: toward 1 while the expanded map is up, toward 0
-- once it closes. Held in tenths so 0.1 does not drift.
local function stepBigAlpha()
	if mapState ~= 0 then
		if bigAlpha < 10 then
			bigAlpha = bigAlpha + 1
		end
	elseif bigAlpha > 0 then
		bigAlpha = bigAlpha - 1
	end
end

local function setRockAlpha(spr)
	spr.Color = Color(1, 1, 1, 1)
end

local function restoreHud()
	if hudSuppressed then
		game:GetHUD():SetVisible(true)
		hudSuppressed = false
	end
end

local function onUpdate()
	restoreHud()
	updateMapMode()
	stepBigAlpha()
end

local function resetFloor()
	restoreHud()
	snapshots = {}
	cachedRockPositions = {}
	rooms = {dim = -1, size = -1, list = {}, occupiedCells = {}}
	viewCenter = nil
end

local function onNewLevel()
	resetFloor()
	spriteEpoch = spriteEpoch + 1
end

-- The game's minimap machine lives on the HUD and survives leaving a run.
-- Clearing ours here left the next run drawing the other map's rocks.
local function onExit()
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

-- True when this frame will paint rocks, so the HUD has to be drawn by us.
local function prepareOverlay()
	local hud = game:GetHUD()
	if not hud:IsVisible() or game:GetSeeds():HasSeedEffect(SeedEffect.SEED_NO_HUD) then
		return false
	end
	-- The curse replaces the map with a question mark.
	if game:GetLevel():GetCurses() & LevelCurse.CURSE_OF_THE_LOST ~= 0 then
		return false
	end

	-- The expanded map fades out over about ten frames. Its rocks do not fade,
	-- so they were still on screen for the last five of those, after the map
	-- itself was already gone, and the small rocks only started once that
	-- leftover ended. Drop the big rocks five frames sooner and start the
	-- small ones eight frames sooner. Opening holds the small rocks two
	-- frames longer and waits one frame before the big rocks come in.
	local closing = mapState == 0
	local showBig = (closing and bigAlpha > 7) or (not closing and bigAlpha > 1)
	local showSmall = (closing and bigAlpha <= 7) or (not closing and bigAlpha <= 2)
	local center = nil
	if showSmall then
		center = updateViewCenter()
		if not center and not showBig then
			return false
		end
	end
	if not showBig and not showSmall then
		return false
	end
	return true, showBig, showSmall, center
end

-- Before other mods' POST_RENDER. MC_POST_RENDER runs before the minimap, so
-- the rocks have to be painted over a HUD we drew ourselves. Drawing it here,
-- and hiding the game's own pass only after every other callback, leaves UI
-- mods (planetarium chance checks IsVisible and draws in this callback) on
-- top of that HUD instead of under a second copy of it.
local function onRenderHud()
	restoreHud()
	renderPlan = nil
	local ok, showBig, showSmall, center = prepareOverlay()
	if not ok then
		return
	end
	game:GetHUD():Render()
	renderPlan = {showBig = showBig, showSmall = showSmall, center = center}
end

local function onRender()
	local plan = renderPlan
	renderPlan = nil
	if not plan then
		return
	end
	local showBig, showSmall, center = plan.showBig, plan.showSmall, plan.center

	local floor = currentRooms()
	local mirror = inMirrorDimension(floor.dim)
	if showBig then
		local minX, minY, maxX = shownBounds(floor)
		if minX then
			local spr = ensureSprite(BIG_ROCK_SCALE)
			setRockAlpha(spr)
			local corner = bigCorner()
			-- Flip around the middle of the packed map, so the right edge
			-- stays on the corner and each rock lands on the mirrored wall.
			local axis = nil
			if mirror then
				local span = (minX - maxX) * BIG_STEP.X - (BIG_CELL.X - BIG_STEP.X)
				axis = corner.X + span * 0.5
			end
			for _, desc in ipairs(floor.list) do
				if desc.DisplayFlags & 1 ~= 0 and not SKIP_TYPES[desc.Data.Type] and not SMALL_SHAPES[desc.Data.Shape] then
					local rockPositions = computeRockPositions(desc, floor.occupiedCells)
					for _, rockPosition in ipairs(rockPositions) do
						local pos = bigRockScreenPosition(rockPosition.cell, rockPosition.direction, corner, minY, maxX)
						if axis then
							pos = mirrorX(pos, axis)
						end
						spr:Render(pos)
					end
				end
			end
		end
	end
	if showSmall and center then
		local spr = ensureSprite(ROCK_SCALE)
		setRockAlpha(spr)
		local origin = viewOrigin()
		local axis = origin.X + VIEW_SIZE.X * 0.5

		-- Rooms we have walked into. A box the map drew from next door, or from
		-- a map item, has no snapshot yet and gets no rocks.
		for _, desc in ipairs(floor.list) do
			if desc.DisplayFlags & 1 ~= 0 and not SKIP_TYPES[desc.Data.Type] and not SMALL_SHAPES[desc.Data.Shape] then
				local rockPositions = computeRockPositions(desc, floor.occupiedCells)
				for _, rockPosition in ipairs(rockPositions) do
					local pos = rockScreenPosition(rockPosition.cell, rockPosition.direction, origin, center)
					if mirror then
						pos = mirrorX(pos, axis)
					end
					renderRock(spr, pos, origin)
				end
			end
		end

		if markCenter then
			renderRock(spr, origin + VIEW_SIZE * 0.5, origin)
		end
	end

	hudSuppressed = true
	game:GetHUD():SetVisible(false)
end

-- Map layout calibration, the game gives us no way to read it back.
-- Moves the map that is on screen: the expanded one while it is open, the
-- small one otherwise. "swh" prints that offset, "swh <x> <y>" sets it,
-- "swh center" marks the middle of the small viewport, "swh reset" clears
-- the offset of the map that is open.
local function applyCommand(params)
	params = params or ""
	local big = bigMapOpen()
	if params == "center" then
		markCenter = not markCenter
	elseif params == "reset" then
		if big then
			bigNudge = Vector(0, 0)
		else
			nudge = Vector(0, 0)
			markCenter = false
		end
	else
		local x, y = params:match("^%s*(-?%d+%.?%d*)%s+(-?%d+%.?%d*)%s*$")
		if x then
			if big then
				bigNudge = Vector(tonumber(x), tonumber(y))
			else
				nudge = Vector(tonumber(x), tonumber(y))
			end
		end
	end
	local active = big and bigNudge or nudge
	local which = big and "big" or "small"
	local msg = string.format("[Secret Wall Hints] %s map nudge %g %g, center mark %s", which, active.X, active.Y, tostring(markCenter))
	-- DebugString is log.txt only. ConsoleOutput is the on-screen console.
	Isaac.DebugString(msg)
	Isaac.ConsoleOutput(msg .. "\n")
	return msg
end

local function onCommand(_, cmd, params)
	if cmd ~= "swh" then
		return nil
	end
	applyCommand(params)
	-- A non-nil return from this callback crashes the game.
	return nil
end

-- Repentance+ v1.9.7.17 never calls MC_EXECUTE_CMD (unknown commands are
-- dropped in the console). The built-in `lua` command still runs Lua.
-- The numbers move the map that is open (expanded map while it is up):
--   lua swh("center")
--   lua swh(2, -1)
--   lua swh("reset")
rawset(_G, "swh", function(a, b)
	if type(a) == "number" and type(b) == "number" then
		return applyCommand(a .. " " .. b)
	end
	return applyCommand(a == nil and "" or tostring(a))
end)

mod:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, onNewLevel)
mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, onNewRoom)
-- Earlier than default, so UI mods draw after the HUD. Later than EARLY.
mod:AddPriorityCallback(ModCallbacks.MC_POST_RENDER, -50, onRenderHud)
-- After other mods' POST_RENDER, so the rocks stay above their icons.
mod:AddPriorityCallback(ModCallbacks.MC_POST_RENDER, CallbackPriority.LATE, onRender)
mod:AddPriorityCallback(ModCallbacks.MC_POST_UPDATE, CallbackPriority.EARLY, onUpdate)
mod:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, onExit)
mod:AddCallback(ModCallbacks.MC_EXECUTE_CMD, onCommand)
