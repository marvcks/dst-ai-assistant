local GLOBAL = GLOBAL
local json = GLOBAL.require("json")
local State = require("dst_ai_state")

local NAMESPACE = "dst_ai_assistant"
local SERVICE_PORT = GetModConfigData("service_port") or 8765
local SERVICE_URL = "http://127.0.0.1:" .. GLOBAL.tostring(SERVICE_PORT)
local MAX_ANNOUNCEMENT_LENGTH = 240
local RESPONSE_FILE = "../mods/" .. (modname or "dst_ai_assistant") .. "/response.lua"
local last_response_version = 0

local function trim(value)
    return GLOBAL.string.match(value or "", "^%s*(.-)%s*$") or ""
end

local function announce_segments(player_name, text)
    text = GLOBAL.string.gsub(text or "", "[\r\n]+", " ")
    text = trim(text)
    if text == "" then
        text = "未能获取回答，请稍后重试。"
    end
    local prefix = "[AI→" .. (player_name or "玩家") .. "] "
    local first_limit = MAX_ANNOUNCEMENT_LENGTH - prefix:utf8len()
    local remaining = text
    local index = 1
    while remaining:utf8len() > 0 and index <= 4 do
        local limit = index == 1 and first_limit or MAX_ANNOUNCEMENT_LENGTH
        local chunk = remaining:utf8sub(1, limit)
        remaining = trim(remaining:utf8sub(chunk:utf8len() + 1))
        GLOBAL.TheNet:Announce((index == 1 and prefix or "[AI] ") .. trim(chunk))
        index = index + 1
    end
end

local function is_admin(player)
    if player == nil or player.Network == nil then
        return false
    end
    if player.Network.IsServerAdmin ~= nil then
        return player.Network:IsServerAdmin()
    end
    local userid = player.userid or player.Network:GetUserID()
    for _, client in ipairs(GLOBAL.TheNet:GetClientTable() or {}) do
        if client.userid == userid then
            return client.admin == true
        end
    end
    return false
end

local function send_client(player, handler, ...)
    local userid = player ~= nil and (player.userid or (player.Network ~= nil and player.Network:GetUserID())) or nil
    if userid ~= nil then
        SendModRPCToClient(handler, userid, ...)
    end
end

local function query(path, method, payload, callback)
    local body = payload ~= nil and json.encode(payload) or nil
    local ok, err = GLOBAL.pcall(function()
        GLOBAL.TheSim:QueryServer(SERVICE_URL .. path, callback, method, body)
    end)
    if not ok then
        print("[DST_AI_ASSISTANT] HTTP query failed to start: " .. GLOBAL.tostring(err))
        callback("", false, 0)
    end
end

local function emit_state(reason)
    local player = nil
    for _, candidate in ipairs(GLOBAL.AllPlayers or {}) do
        if candidate:IsValid() then
            player = candidate
            break
        end
    end
    local ok, state = GLOBAL.pcall(State.Build, player)
    if ok then
        print("[DST_AI_STATE] " .. json.encode({ reason = reason, state = state }))
    else
        print("[DST_AI_STATE_ERROR] " .. GLOBAL.tostring(state))
    end
end

AddSimPostInit(function()
    local world = GLOBAL.TheWorld
    if world == nil or not world.ismastersim then
        return
    end

    local poll_generation = 0
    local function start_polling()
        poll_generation = poll_generation + 1
        local generation = poll_generation
        local function poll_response()
            if generation ~= poll_generation then
                return
            end
            local ok, data = GLOBAL.pcall(GLOBAL.dofile, RESPONSE_FILE)
            if ok and type(data) == "table"
                and type(data.version) == "number"
                and data.version > last_response_version then
                last_response_version = data.version
                if type(data.answer) == "string" then
                    announce_segments(data.player_name, data.answer)
                    print("[DST_AI_ASSISTANT] Announced response version=" .. tostring(data.version))
                end
            end
            world:DoTaskInTime(2, poll_response)
        end
        world:DoTaskInTime(0.5, poll_response)
    end

    emit_state("startup")
    world:DoTaskInTime(2, function()
        query("/health", "GET", nil, function(_, successful, status_code)
            if successful and status_code == 200 then
                print("[DST_AI_ASSISTANT] Companion health check passed")
            else
                print("[DST_AI_ASSISTANT] Companion health check failed")
            end
        end)
    end)
    world:DoPeriodicTask(30, function() emit_state("periodic") end, 5)
    world:ListenForEvent("ms_playerjoined", function()
        start_polling()
        world:DoTaskInTime(1, function() emit_state("player_joined") end)
    end)
    world:ListenForEvent("ms_playerleft", function()
        world:DoTaskInTime(1, function() emit_state("player_left") end)
    end)
    start_polling()
end)

AddModRPCHandler(NAMESPACE, "get_config", function(player)
    if not is_admin(player) then
        send_client(player, CLIENT_MOD_RPC[NAMESPACE]["config_error"], "只有服务器管理员可以配置 AI。")
        return
    end
    query("/v1/config", "GET", nil, function(result, successful, status_code)
        if not successful or status_code ~= 200 then
            send_client(player, CLIENT_MOD_RPC[NAMESPACE]["config_error"], "无法连接本机 AI 服务。")
            return
        end
        local ok, data = GLOBAL.pcall(json.decode, result or "")
        if not ok or type(data) ~= "table" then
            send_client(player, CLIENT_MOD_RPC[NAMESPACE]["config_error"], "AI 服务配置响应无效。")
            return
        end
        send_client(player, CLIENT_MOD_RPC[NAMESPACE]["config_data"], data.base_url or "", data.model or "", data.has_api_key == true)
    end)
end)

AddModRPCHandler(NAMESPACE, "save_config", function(player, base_url, model, api_key)
    if not is_admin(player) then
        send_client(player, CLIENT_MOD_RPC[NAMESPACE]["config_error"], "只有服务器管理员可以保存配置。")
        return
    end
    base_url = GLOBAL.string.sub(trim(base_url), 1, 500)
    model = GLOBAL.string.sub(trim(model), 1, 200)
    api_key = GLOBAL.string.sub(trim(api_key), 1, 500)
    query("/v1/config", "POST", {
        base_url = base_url,
        model = model,
        api_key = api_key,
    }, function(result, successful, status_code)
        if not successful or status_code ~= 200 then
            send_client(player, CLIENT_MOD_RPC[NAMESPACE]["config_error"], "保存失败，请检查 URL、模型和本机服务日志。")
            return
        end
        send_client(player, CLIENT_MOD_RPC[NAMESPACE]["config_saved"], "AI 配置已保存。")
    end)
end)

local function notice(title, message)
    if GLOBAL.TheNet:IsDedicated() then
        return
    end
    local PopupDialogScreen = GLOBAL.require("screens/redux/popupdialog")
    GLOBAL.TheFrontEnd:PushScreen(PopupDialogScreen(title, message, {
        { text = "确定", cb = function() GLOBAL.TheFrontEnd:PopScreen() end },
    }))
end

AddClientModRPCHandler(NAMESPACE, "config_data", function(base_url, model, has_api_key)
    if not GLOBAL.TheNet:IsDedicated() then
        local AIConfigScreen = require("screens/dst_ai_config_screen")
        local config = { base_url = base_url, model = model, has_api_key = has_api_key }
        GLOBAL.TheFrontEnd:PushScreen(AIConfigScreen(config, function(new_url, new_model, new_key)
            SendModRPCToServer(MOD_RPC[NAMESPACE]["save_config"], new_url, new_model, new_key)
        end))
    end
end)

AddClientModRPCHandler(NAMESPACE, "config_error", function(message)
    notice("DST AI Assistant", message or "配置操作失败。")
end)

AddClientModRPCHandler(NAMESPACE, "config_saved", function(message)
    notice("DST AI Assistant", message or "配置已保存。")
end)

if not GLOBAL.TheNet:IsDedicated() then
    AddUserCommand("aiconfig", {
        prettyname = "配置 DST AI Assistant",
        desc = "打开服务器端 LLM 配置界面",
        permission = GLOBAL.COMMAND_PERMISSION.USER,
        slash = true,
        usermenu = false,
        servermenu = false,
        params = {},
        vote = false,
        localfn = function()
            SendModRPCToServer(MOD_RPC[NAMESPACE]["get_config"])
        end,
    })
end

print("[DST_AI_ASSISTANT] Loaded; service=" .. SERVICE_URL .. ", prefix=@ai")
