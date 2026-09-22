local mod = RegisterMod("Secret Wall Hints", 1)

local MAP_W = 13
local PATH, BLOCK, EMPTY, DOOR = 1, 2, 3, 4
local DIR_L, DIR_U, DIR_R, DIR_D = 0, 1, 2, 3

local game = Game()
local rockSprite = nil
local warnedMinimap = false
local snapshots = {} -- [ListIndex] = walkable grid (row -> col -> PATH/BLOCK/EMPTY)
local cachedHints = {} -- [ListIndex] = { {cellIdx, dir}, ... }

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

local function ensureSprite()
	if rockSprite then
		return rockSprite
	end
	rockSprite = Sprite()
	rockSprite:Load("gfx/secret_wall_hints/rock_icon.anm2", true)
	rockSprite:Play("Idle", true)
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

local function buildOccupancy()
	local occ = {}
	local rooms = game:GetLevel():GetRooms()
	for i = 0, rooms.Size - 1 do
		local desc = rooms:Get(i)
		if desc.GridIndex >= 0 and desc.Data then
			local offsets = SHAPE_OFFSETS[desc.Data.Shape] or {0}
			for _, off in ipairs(offsets) do
				occ[desc.GridIndex + off] = desc
			end
		end
	end
	return occ
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

local function cellPixels()
	if not MinimapAPI then
		return 9, 8
	end
	local rooms = MinimapAPI:GetLevel()
	if rooms then
		for i = 1, #rooms do
			local a = rooms[i]
			if a.RenderOffset and a.Position then
				for j = i + 1, #rooms do
					local b = rooms[j]
					if b.RenderOffset then
						local dx = a.Position.X - b.Position.X
						local dy = a.Position.Y - b.Position.Y
						local sx = a.RenderOffset.X - b.RenderOffset.X
						local sy = a.RenderOffset.Y - b.RenderOffset.Y
						if math.abs(dx) >= 1 and math.abs(sx) > 2 then
							local px = math.abs(sx / dx)
							local py = px
							if math.abs(dy) >= 1 and math.abs(sy) > 2 then
								py = math.abs(sy / dy)
							end
							if px > 2 and px < 80 then
								return px, py
							end
						end
					end
				end
			end
		end
	end
	return 9, 8
end

local function edgeOffset(dir, pw, ph)
	if dir == DIR_L then
		return Vector(1, ph * 0.5)
	elseif dir == DIR_U then
		return Vector(pw * 0.5, 1)
	elseif dir == DIR_R then
		return Vector(pw - 1, ph * 0.5)
	end
	return Vector(pw * 0.5, ph - 1)
end

local function resetFloor()
	snapshots = {}
	cachedHints = {}
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
	if not MinimapAPI then
		if not warnedMinimap then
			warnedMinimap = true
			print("[Secret Wall Hints] Enable MiniMAPI (workshop id 1978904635).")
		end
		return
	end
	if MinimapAPI.Config.Disable then
		return
	end
	if game:GetHUD():IsVisible() == false and not MinimapAPI.Config.DisplayOnNoHUD then
		return
	end

	local spr = ensureSprite()
	local pw, ph = cellPixels()
	local occ = buildOccupancy()
	local rooms = game:GetLevel():GetRooms()

	for i = 0, rooms.Size - 1 do
		local desc = rooms:Get(i)
		if desc.GridIndex >= 0 and desc.Data and not SKIP_TYPES[desc.Data.Type] then
			if desc.VisitedCount > 0 then
				local mini = MinimapAPI:GetRoomByIdx(desc.SafeGridIndex)
				if mini and mini.RenderOffset and mini:IsVisible() then
					local hints = computeHints(desc, occ)
					local origin = mini.Position
					for h = 1, #hints do
						local cell = hints[h].cell
						local dir = hints[h].dir
						local mx = cell % MAP_W
						local my = math.floor(cell / MAP_W)
						local localX = mx - origin.X
						local localY = my - origin.Y
						local pos = mini.RenderOffset
							+ Vector(localX * pw, localY * ph)
							+ edgeOffset(dir, pw, ph)
						spr:Render(pos, Vector.Zero, Vector.Zero)
					end
				end
			end
		end
	end
end

mod:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, onNewLevel)
mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, onNewRoom)
mod:AddCallback(ModCallbacks.MC_POST_RENDER, onRender)
mod:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, resetFloor)
