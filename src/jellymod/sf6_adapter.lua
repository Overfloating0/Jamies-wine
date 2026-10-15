-- SPDX-License-Identifier: AGPL-3.0-only
-- SF6 1.0.0.34 paths established in stage 1/2. MMDK research attribution in notices.
local M = {}
local fields = {}
local battle_type = sdk.find_type_definition("gBattle")
local function field(obj, name)
    if not obj then return nil end
    local td = obj:get_type_definition()
    local id = td:get_full_name() .. "." .. name
    if fields[id] == nil then fields[id] = td:get_field(name) or false end
    if fields[id] then return fields[id]:get_data(obj) end
end
local function battle(name)
    local f = battle_type and battle_type:get_field(name)
    return f and f:get_data(nil)
end
local function get(obj, name) return obj and obj:call(name) end
local function scalar(v)
    if type(v) == "number" or type(v) == "boolean" then return v end
    if v then return field(v, "mValue") or field(v, "value__") end
end
local function key(obj) return obj and tostring(obj:get_address()) or "nil" end
local function vector(v) return v and { x = v.x, y = v.y, z = v.z } end

-- Same read path / EGameMode values as REFramework's SF6Utility. TrainingManager's
-- _GameMode is a different enum and may retain its old value outside training.
local function battle_rule_mode()
    local hud = field(sdk.get_managed_singleton("app.GuiManager"), "<Hud>k__BackingField")
    local list = field(hud, "mHudManagerList")
    if not list then return nil end
    for _, manager in pairs(list:get_elements()) do
        if manager and manager:get_type_definition():get_full_name() == "app.BattleHudManager" then
            local desc = field(manager, "<BattleDesc>k__BackingField")
            return scalar(field(field(desc, "Rule"), "GameMode")), key(desc)
        end
    end
end

local function network_rule_mode()
    local network = sdk.get_managed_singleton("app.network.NetworkManager")
    local session = field(network, "<Session>k__BackingField")
    local match = field(session, "<FGBattle>k__BackingField")
    return scalar(field(field(match, "<BattleRule>k__BackingField"), "GameMode"))
end

function M.mode()
    local flow = field(field(sdk.get_managed_singleton("app.bFlowManager"), "m_flow_work"), "_FlowMap")
    local id = scalar(field(flow, "_ID"))
    local name = flow and flow:get_type_definition():get_full_name()
    local training = scalar(field(sdk.get_managed_singleton("app.training.TrainingManager"), "_GameMode"))
    local replay = id == 10 and training == 6 and name == "app.battle.ReplayFlowMap"
    local practice = id == 3 and training == 1 and name == "app.battle.TrainingFlowMap"
    local rule, desc_key = battle_rule_mode()
    local network = network_rule_mode()
    local online = type(network) == "number" and network >= 14 and network <= 18
    local versus = (rule == 3 or rule == 4) and name == "app.battle.VersusFlowMap" and id == 2 and not online
    return { allowed = replay or practice or versus, replay = replay,
        name = replay and "Replay" or practice and "Training" or versus and (rule == 3 and "Local 2P" or "Local CPU") or "Waiting",
        flow_name = name or "unknown", flow_id = id, game_mode = training,
        rule_mode = rule, network_mode = network, local_versus = versus,
        key = table.concat({ tostring(id), tostring(training), key(flow), tostring(rule), desc_key or "nil" }, ":"),
        frame = scalar(field(battle("Game"), "stage_timer")),
        round = scalar(field(battle("Round"), "RoundNo")) }
end

function M.resolve(slot, mode, restoring)
    local c = { ready = false, ancestors = {} }
    if not mode.allowed and not restoring then c.issue = "waiting for local training, versus or replay"; return c end
    local players = battle("Player")
    local actors, types = field(players, "mcPlayer"), field(players, "mPlayerType")
    local bodies = field(battle("PBManager"), "Players")
    local contains = bodies and bodies:get_type_definition():get_method("ContainsKey")
    local body
    if contains and contains:call(bodies, slot - 1) then body = bodies[slot - 1] end
    local actor = actors and actors[slot - 1]
    local character = scalar(types and types[slot - 1])
    local go = get(body, "get_GameObject")
    local root = get(go, "get_Transform")
    c.character, c.name = character, get(go, "get_Name")
    c.root_key = key(root)
    c.owner = table.concat({ key(actor), key(body), key(root), tostring(character) }, ":")
    if not root then c.issue = "player model is not spawned"; return c end
    local joint = root:call("getJointByName", "Root")
    if not joint or joint:get_type_definition():get_full_name() ~= "via.Joint"
        or get(joint, "get_Name") ~= "Root" or get(joint, "get_Parent") ~= nil then
        c.issue = "rig has no writable Root joint"
        return c
    end
    c.joint, c.joint_key, c.scale = joint, "joint:" .. key(joint), vector(get(joint, "get_LocalScale"))
    local parent, seen = get(root, "get_Parent"), { [c.root_key] = true }
    while parent do
        local id = key(parent)
        assert(not seen[id] and #c.ancestors < 32, "Unexpected player parent hierarchy")
        seen[id] = true
        table.insert(c.ancestors, id)
        parent = get(parent, "get_Parent")
    end
    -- Any character rig with a writable Root joint is accepted. Zangief/Jamie are the
    -- rigs verified on screen so far; the throw/stomp rules stay Zangief-only.
    c.ready = mode.allowed and actor ~= nil and body ~= nil
    return c
end

function M.write(context, scale)
    context.joint:call("set_LocalScale", Vector3f.new(scale.x, scale.y, scale.z))
    return vector(get(context.joint, "get_LocalScale"))
end

function M.combat()
    local actors = field(battle("Player"), "mcPlayer")
    local result = {}
    for i = 0, 1 do
        local actor = actors and actors[i]
        local pos = field(actor, "pos")
        local engine = field(field(field(actor, "mpActParam"), "ActionPart"), "_Engine")
        result[i + 1] = { x = field(field(pos, "x"), "v"), y = field(field(pos, "y"), "v"),
            facing = scalar(field(actor, "rl_dir")), vital = scalar(field(actor, "vital_new")),
            action = scalar(get(engine, "get_ActionID")) }
    end
    return result
end

-- mStyleNo is present in the captured SF6 type metadata. Jamie's move-set style
-- corresponds to drink level (0-4); on-screen 0-4 / SA2 validation is still required.
function M.drinks()
    local players = battle("Player")
    local actors, types = field(players, "mcPlayer"), field(players, "mPlayerType")
    local result = {}
    for i = 0, 1 do
        local actor = actors and actors[i]
        local character = scalar(types and types[i])
        local p = { character = character, ready = actor ~= nil and character ~= nil and character ~= 255 }
        if character == 21 then
            p.level = scalar(field(actor, "mStyleNo"))
            p.source = "mStyleNo"
            p.ready = p.ready and type(p.level) == "number" and p.level >= 0 and p.level <= 4 and p.level % 1 == 0
        else p.level = 0 end
        result[i + 1] = p
    end
    return result
end

-- Read-only throw/knockdown observations. References are converted to player slots,
-- and no scene address or retained engine object is written to the trace.
function M.throw_snapshot()
    local players = battle("Player")
    local actors, types = field(players, "mcPlayer"), field(players, "mPlayerType")
    local function slot_of(ref)
        if not ref then return nil end
        for i = 0, 1 do
            if actors and actors[i] and key(ref) == key(actors[i]) then return i + 1 end
        end
    end
    local result = {}
    for i = 0, 1 do
        local actor = actors and actors[i]
        local engine = field(field(field(actor, "mpActParam"), "ActionPart"), "_Engine")
        local frame = get(engine, "get_ActionFrame")
        local raw = frame and type(frame) ~= "number" and field(frame, "v")
        result[i + 1] = {
            character = scalar(types and types[i]), action = scalar(get(engine, "get_ActionID")),
            action_frame = type(frame) == "number" and frame or type(raw) == "number" and raw / 65536 or nil,
            unique = scalar(field(actor, "mActUniqueId")), vital = scalar(field(actor, "vital_new")),
            vital_old = scalar(field(actor, "vital_old")),
            act_st = scalar(field(actor, "act_st")), pose_st = scalar(field(actor, "pose_st")),
            damage_st = scalar(field(actor, "damage_st")), jump_st = scalar(field(actor, "pl_jump_st")),
            floor_hit = scalar(field(actor, "floor_hit_flag")), to_go_down = scalar(field(actor, "to_go_down")),
            catch_flag = scalar(field(actor, "catch_flag")),
            catch_player = slot_of(field(actor, "catch_pl_add")), catch_work = slot_of(field(actor, "catch_add")),
            damage_player = slot_of(field(actor, "damage_pl_add")),
            hit_player = slot_of(field(actor, "hit_add")),
            hit_st = scalar(field(actor, "hit_st")), hit_st_old = scalar(field(actor, "hit_st_old")),
            hit_kind = scalar(field(actor, "hit_kind")), hit_kind_vs = scalar(field(actor, "hit_kind_vs")),
            hit_stop = scalar(field(actor, "hit_stop")), uniq_hit_id = scalar(field(actor, "uniq_hit_id")),
            combo_cnt = scalar(field(actor, "combo_cnt")), combo_dm_cnt = scalar(field(actor, "combo_dm_cnt")),
            guard_st = scalar(field(actor, "guard_st")), damage_type = scalar(field(actor, "damage_type")),
        }
    end
    return result
end

function M.throw_enums()
    local result = {}
    for _, name in ipairs({ "nBattle.ACT_ID", "nBattle.ACT_ST.ID", "nBattle.nHit.DAMAGE_ST",
        "nBattle.nHit.HIT_ST", "nBattle.nHit.HIT", "nBattle.nHit.DM", "nBattle.nHit.GUARD_ST" }) do
        local td = sdk.find_type_definition(name)
        local entries = {}
        result[name] = entries
        if td then
            for _, f in ipairs(td:get_fields()) do
                if f:is_static() then
                    local ok, value = pcall(function() return scalar(f:get_data(nil)) end)
                    if ok and type(value) == "number" and (name ~= "nBattle.ACT_ID" or value < 700) then
                        entries[f:get_name()] = value
                    end
                end
            end
        end
    end
    return result
end

return M
