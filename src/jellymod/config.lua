-- SPDX-License-Identifier: AGPL-3.0-only
local effects = require("jellymod.effects")
local hotkeys = require("jellymod.hotkeys")
local M = { PATH = "SF6Jelly_settings.json" }
function M.defaults()
    return { schema = 1, language = "zh", font_size = 40, auto_start = false, enabled = false,
        p1 = true, p2 = true, shrink = false, alternate = false, continuous = true,
        drink_link = false, hotkeys = { toggle = 117, restore = 118, start = 219, single1 = 221, single2 = 220 },
        body = { { enabled = false, height = 1, width = 1 }, { enabled = false, height = 1, width = 1 } },
        rhythm = { mode = "bpm", bpm = 130, beats = 1, amplitude = 0.75, offset_ms = 0 } }
end
-- Accept only this schema's fields. No engine objects, anchors or diagnostics are persisted.
function M.validate(raw)
    local p = M.defaults()
    if raw == nil then return p end
    if type(raw) ~= "table" or raw.schema ~= 1 then return p, "Unsupported settings schema" end
    for _, k in ipairs({ "enabled", "auto_start", "p1", "p2", "shrink" }) do
        if type(raw[k]) ~= "boolean" then return p, "Invalid setting: " .. k end
        p[k] = raw[k]
    end
    if raw.language ~= "zh" and raw.language ~= "en" then return M.defaults(), "Invalid language" end
    if raw.continuous ~= nil then
        if type(raw.continuous) ~= "boolean" then return M.defaults(), "Invalid continuous setting" end
        p.continuous = raw.continuous
    end
    if raw.alternate ~= nil then
        if type(raw.alternate) ~= "boolean" then return M.defaults(), "Invalid alternating setting" end
        p.alternate = raw.alternate
    end
    if raw.drink_link ~= nil then
        if type(raw.drink_link) ~= "boolean" then return M.defaults(), "Invalid drink link setting" end
        p.drink_link = raw.drink_link
    end
    if raw.hotkeys ~= nil then
        if type(raw.hotkeys) ~= "table" then return M.defaults(), "Invalid hotkeys" end
        local used = {}
        for _, name in ipairs(hotkeys.actions) do
            local key = raw.hotkeys[name]
            if key == nil and name ~= "toggle" and name ~= "restore" then key = p.hotkeys[name] end
            if not hotkeys.index(key) then
                return M.defaults(), "Invalid hotkey"
            end
            if key ~= 0 and used[key] then return M.defaults(), "Hotkeys must be different" end
            if key ~= 0 then used[key] = true end
            p.hotkeys[name] = key
        end
    end
    if raw.body ~= nil then
        if type(raw.body) ~= "table" then return M.defaults(), "Invalid body settings" end
        for slot = 1, 2 do
            local b = raw.body[slot]
            if type(b) ~= "table" or type(b.enabled) ~= "boolean"
                or not effects.finite(b.height) or b.height < 0.5 or b.height > 1.5
                or not effects.finite(b.width) or b.width < 0.5 or b.width > 1.5 then
                return M.defaults(), "Body height and width must be 50-150%"
            end
            p.body[slot] = { enabled = b.enabled, height = b.height, width = b.width }
        end
    end
    -- 0.0.19 settings did not include a font size; keep all other saved preferences.
    if raw.font_size ~= nil then
        if not effects.finite(raw.font_size) or raw.font_size < 18 or raw.font_size > 40 then
            return M.defaults(), "Font size must be between 18 and 40"
        end
        p.font_size = math.floor(raw.font_size + 0.5)
    end
    local r = raw.rhythm
    if type(r) ~= "table" or not effects.finite(r.bpm) or r.bpm <= 0
        or (r.beats ~= 0.5 and r.beats ~= 1 and r.beats ~= 2 and r.beats ~= 4)
        or not effects.period(r.mode, r.bpm, r.beats)
        or not effects.finite(r.amplitude) or r.amplitude < 0 or r.amplitude > 1
        or not effects.finite(r.offset_ms) or math.abs(r.offset_ms) > 3600000 then
        return M.defaults(), "Invalid rhythm settings"
    end
    p.language = raw.language
    for k in pairs(p.rhythm) do p.rhythm[k] = r[k] end
    return p
end
function M.load(api)
    local ok, raw = pcall(api.load_file, M.PATH)
    if not ok then return M.defaults(), "Settings could not be read; defaults loaded" end
    local p, err = M.validate(raw)
    if err then return M.defaults(), err end
    return p
end
function M.save(api, prefs)
    local clean, err = M.validate(prefs)
    if err then return false, err end
    local ok, result = pcall(api.dump_file, M.PATH, clean, 0)
    if not ok or not result then return false, "Settings save failed; retry from the panel" end
    return true
end
return M
