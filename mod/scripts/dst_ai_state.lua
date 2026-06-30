local M = {}
local NEXT_SEASON = {
    autumn = "winter",
    winter = "spring",
    spring = "summer",
    summer = "autumn",
}
local BASE_ANCHORS = {
    firepit = true,
    coldfirepit = true,
    researchlab = true,
    researchlab2 = true,
    researchlab3 = true,
    researchlab4 = true,
}
local BASE_RADIUS = 40
local BASE_RADIUS_SQ = BASE_RADIUS * BASE_RADIUS

local function round(value, digits)
    if type(value) ~= "number" then
        return nil
    end
    local scale = 10 ^ (digits or 0)
    return math.floor(value * scale + 0.5) / scale
end

local function component_value(component, field)
    return component ~= nil and round(component[field], 1) or nil
end

local function stack_size(item)
    local stackable = item ~= nil and item.components ~= nil and item.components.stackable or nil
    return stackable ~= nil and stackable:StackSize() or 1
end

local function item_status(slot, item)
    local components = item.components or {}
    local finiteuses = components.finiteuses
    local fueled = components.fueled
    local armor = components.armor
    local perishable = components.perishable
    return {
        slot = slot,
        prefab = item.prefab or "unknown",
        count = stack_size(item),
        uses_percent = finiteuses ~= nil and round(finiteuses:GetPercent() * 100, 1) or nil,
        fuel_percent = fueled ~= nil and round(fueled:GetPercent() * 100, 1) or nil,
        armor_percent = armor ~= nil and round(armor:GetPercent() * 100, 1) or nil,
        perish_percent = perishable ~= nil and round(perishable:GetPercent() * 100, 1) or nil,
    }
end

local function inventory_status(player)
    local inventory = player.components ~= nil and player.components.inventory or nil
    if inventory == nil then
        return nil
    end
    local items = {}
    for slot, item in pairs(inventory.itemslots or {}) do
        items[#items + 1] = item_status(slot, item)
    end
    table.sort(items, function(a, b) return a.slot < b.slot end)
    local equipped = {}
    for slot, item in pairs(inventory.equipslots or {}) do
        equipped[#equipped + 1] = item_status(slot, item)
    end
    table.sort(equipped, function(a, b) return tostring(a.slot) < tostring(b.slot) end)
    return { items = items, equipped = equipped }
end

local function player_status(player)
    if player == nil or not player:IsValid() then
        return nil
    end
    local components = player.components or {}
    local x, _, z = player.Transform:GetWorldPosition()
    return {
        name = player.name or "unknown",
        character = player.prefab or "unknown",
        position = { x = round(x, 1), z = round(z, 1) },
        health = components.health ~= nil and {
            current = component_value(components.health, "currenthealth"),
            max = round(components.health:GetMaxWithPenalty(), 1),
        } or nil,
        hunger = components.hunger ~= nil and {
            current = component_value(components.hunger, "current"),
            max = component_value(components.hunger, "max"),
        } or nil,
        sanity = components.sanity ~= nil and {
            current = component_value(components.sanity, "current"),
            max = round(components.sanity:GetMaxWithPenalty(), 1),
        } or nil,
        inventory = inventory_status(player),
    }
end

local function threat_status()
    local world = TheWorld
    local hounded = world.components ~= nil and world.components.hounded or nil
    local seconds = hounded ~= nil and hounded:GetTimeToAttack() or nil
    return {
        hounds = type(seconds) == "number" and seconds > 0 and {
            seconds = round(seconds, 1),
            days = round(seconds / TUNING.TOTAL_DAY_TIME, 2),
        } or nil,
    }
end

local function boss_status()
    local bosses = {}
    for _, entity in pairs(Ents or {}) do
        if entity:IsValid()
            and entity:HasTag("epic")
            and entity.components ~= nil
            and entity.components.health ~= nil
            and not entity.components.health:IsDead() then
            local x, _, z = entity.Transform:GetWorldPosition()
            bosses[#bosses + 1] = {
                prefab = entity.prefab or "unknown",
                position = { x = round(x, 1), z = round(z, 1) },
                health = {
                    current = component_value(entity.components.health, "currenthealth"),
                    max = round(entity.components.health:GetMaxWithPenalty(), 1),
                },
            }
        end
    end
    return bosses
end

local function is_structure(entity)
    return entity:IsValid()
        and entity.Transform ~= nil
        and entity.prefab ~= nil
        and not entity:HasTag("INLIMBO")
        and (entity:HasTag("structure") or BASE_ANCHORS[entity.prefab] == true)
end

local function base_status(player)
    local structures = {}
    local anchors = {}
    for _, entity in pairs(Ents or {}) do
        if is_structure(entity) then
            local x, _, z = entity.Transform:GetWorldPosition()
            local entry = { entity = entity, x = x, z = z }
            structures[#structures + 1] = entry
            if BASE_ANCHORS[entity.prefab] then
                anchors[#anchors + 1] = entry
            end
        end
    end

    local center = nil
    local score = -1
    for _, anchor in ipairs(anchors) do
        local current = 0
        for _, structure in ipairs(structures) do
            local dx, dz = structure.x - anchor.x, structure.z - anchor.z
            if dx * dx + dz * dz <= BASE_RADIUS_SQ then
                current = current + 1
            end
        end
        if current > score then
            center, score = anchor, current
        end
    end
    if center == nil and player ~= nil and player:IsValid() then
        local x, _, z = player.Transform:GetWorldPosition()
        center = { x = x, z = z }
    end
    if center == nil then
        return { radius = BASE_RADIUS, structures = {} }
    end

    local counts = {}
    for _, structure in ipairs(structures) do
        local dx, dz = structure.x - center.x, structure.z - center.z
        if dx * dx + dz * dz <= BASE_RADIUS_SQ then
            local prefab = structure.entity.prefab
            counts[prefab] = (counts[prefab] or 0) + 1
        end
    end
    local result = {}
    for prefab, count in pairs(counts) do
        result[#result + 1] = { prefab = prefab, count = count }
    end
    table.sort(result, function(a, b) return a.prefab < b.prefab end)
    return {
        center = { x = round(center.x, 1), z = round(center.z, 1) },
        radius = BASE_RADIUS,
        structures = result,
    }
end

function M.Build(player)
    local state = TheWorld.state
    local players = {}
    for _, candidate in ipairs(AllPlayers or {}) do
        if candidate:IsValid() then
            players[#players + 1] = player_status(candidate)
        end
    end
    return {
        world = {
            day = (state.cycles or 0) + 1,
            phase = state.phase,
            season = state.season,
            next_season = NEXT_SEASON[state.season],
            elapsed_days_in_season = state.elapseddaysinseason,
            remaining_days_in_season = state.remainingdaysinseason,
            temperature = round(state.temperature, 1),
            precipitation = state.precipitation,
            wetness = round(state.wetness, 1),
            moon_phase = state.moonphase,
        },
        players = players,
        bosses = boss_status(),
        threats = threat_status(),
        base = base_status(player),
    }
end

return M
