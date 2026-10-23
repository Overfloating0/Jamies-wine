-- SPDX-License-Identifier: AGPL-3.0-only
local effects = require("jellymod.effects")
local adapter = require("jellymod.sf6_adapter")
local targets = require("jellymod.targets")
local throw_probe = require("jellymod.throw_probe")
local throw_shrink = require("jellymod.throw_shrink")
local config = require("jellymod.config")
local clock = require("jellymod.clock").new(os.clock)
local hotkeys = require("jellymod.hotkeys").new(function(key) return reframework:is_key_down(key) end)
local VERSION = "0.2.0"
local background = require("jellymod.background").new(adapter, VERSION)
local PREFIX = "[JamiesWine][" .. VERSION .. "] "
local prefs, config_error = config.load(json)
local settings = prefs.rhythm
local requested = { prefs.p1, prefs.p2 }
local enabled = prefs.auto_start and prefs.enabled
local config_dirty = false
local function tr(zh, en) return prefs.language == "zh" and zh or en end
local manager = targets.new(adapter.write)
local shrink = throw_shrink.new()
local shrink_enabled, shrink_command = prefs.shrink, nil
local anchor, session_key, last_round, last_frame = nil, nil, nil, nil
local anchor_command, restore_command, save_command, capture_command
local body_commands, hotkey_error, hotkey_fault = {}, nil, false
local last_drinks
local preview = { name = "Waiting", players = {} }
local status = tr("效果关闭，可先设置参数。", "Effects OFF. Presets can be edited here.")
local parameter_error, capture_status = nil, "Idle"
local session = os.date("%Y%m%d-%H%M%S") .. "-" .. math.floor(os.clock() * 1000)
local probe = throw_probe.new(adapter, VERSION, session)
local output = "jamieswine_" .. session .. ".json"
local report = { version = VERSION, session = session, clock = clock.source,
    events = {}, errors = {}, captures = {}, callbacks = 0, seeks = 0 }
local capture, last_preview, last_save, faulted = nil, -1, -1, false
local performance = { stages = {}, frame_intervals = {}, waiting_skips = 0,
    timing = "Windows os.clock, 1ms resolution; callback intervals are not rendered FPS" }
report.performance = performance
local previous_frame_time, previous_frame_enabled
local function elapsed_cost(stage, started)
    local ms = (os.clock() - started) * 1000
    if ms < 0 then return end
    local p = performance.stages[stage] or { calls = 0, total_ms = 0, max_ms = 0, over_4ms = 0 }
    p.calls, p.total_ms = p.calls + 1, p.total_ms + ms
    p.max_ms = math.max(p.max_ms, ms)
    if ms > 4 then p.over_4ms = p.over_4ms + 1 end
    performance.stages[stage] = p
end

local function copy_settings()
    local result = {}
    for k, v in pairs(settings) do result[k] = v end
    return result
end

local function wants_transform(slot)
    return enabled and (requested[slot] or prefs.body[slot].enabled or shrink_enabled and shrink:height(slot) < 1)
end

local function event(kind, detail)
    if #report.events < 500 then
        table.insert(report.events, { kind = kind, detail = detail, round = preview.round, frame = preview.frame })
    else report.events_capped = true end
end

local function save()
    local started = os.clock()
    report.settings, report.anchor = copy_settings(), anchor
    report.monotonic_clock = clock:diagnostics()
    report.intent = { enabled = enabled, p1 = requested[1], p2 = requested[2] }
    report.body, report.hotkeys = prefs.body, prefs.hotkeys
    report.drinks = { enabled = prefs.drink_link, players = preview.drinks,
        amplitude = preview.amplitude, issue = preview.drink_issue }
    -- Recorded so a locked panel can be diagnosed from the exported file alone.
    report.preview = { mode = preview.name, allowed = preview.allowed, replay = preview.replay,
        flow = preview.flow_name, flow_id = preview.flow_id, game_mode = preview.game_mode,
        rule_mode = preview.rule_mode, network_mode = preview.network_mode, local_versus = preview.local_versus,
        clock = preview.clock, round = preview.round, frame = preview.frame, ready = preview.ready,
        reason = preview.reason, players = preview.players }
    report.throw_shrink = { enabled = enabled and shrink_enabled, requested = shrink_enabled, status = shrink.status, events = shrink.events,
        p1 = { count = shrink:count(1), height = shrink:height(1), stomps = shrink:stomps(1) },
        p2 = { count = shrink:count(2), height = shrink:height(2), stomps = shrink:stomps(2) } }
    report.stats = { writes = manager.writes, refreshed_bases = manager.refreshed,
        retained_bases = manager.retained, restores = manager.restores,
        pending_p1 = manager.slots[1] ~= nil and not wants_transform(1),
        pending_p2 = manager.slots[2] ~= nil and not wants_transform(2) }
    report.targets = {}
    for slot = 1, 2 do
        local state = manager.slots[slot]
        if state then report.targets[slot] = { base = state.base, last_write = state.last, uncertain = state.uncertain } end
    end
    local ok, result = pcall(json.dump_file, output, report, 0)
    elapsed_cost("diagnostic save", started)
    last_save = os.clock()
    if not ok or not result then status = "Log export failed; use Save diagnostics to retry." end
end

local function stop_capture(reason)
    if not capture then return end
    capture.stopped = true
    capture.meta.reason, capture.meta.samples = reason, #capture.samples
    capture.meta.elapsed = os.clock() - capture.started
    capture.meta.wall_ended_utc = os.time()
    local ok, result = pcall(json.dump_file, capture.meta.file,
        { version = VERSION, meta = capture.meta, samples = capture.samples }, 0)
    if ok and result then
        capture_status = "Saved " .. capture.meta.samples .. " samples."
        capture.meta.saved = true
        capture = nil
    else capture_status = "Export failed. Stop / Save recording retries with data retained." end
    save()
end

local function restore_slot(slot)
    if not manager.slots[slot] then return true end
    local state = manager.slots[slot]
    local ok, result, actual = pcall(function()
        return manager:restore(slot, adapter.resolve(slot, adapter.mode(), true))
    end)
    if ok then event("restore P" .. slot, { result = result, base = state.base, actual = actual })
    else
        status = "P" .. slot .. " recovery pending: " .. tostring(result) .. ". Use Restore all to retry."
        log.error(PREFIX .. status)
    end
    return ok
end

local function stop_all(reason)
    background:restore()
    enabled, shrink_command = false, nil
    shrink:clear()
    local a, b = restore_slot(1), restore_slot(2)
    if a and b then status = reason else faulted = true end
    event("stop", reason)
end

local function failure(where, err)
    local label = where .. ": " .. tostring(err)
    if not faulted then
        if #report.errors < 100 then table.insert(report.errors, label) end
        log.error(PREFIX .. label)
    end
    faulted = true
    prefs.enabled, config_dirty = false, true
    stop_all("Stopped: " .. label)
    if capture and not capture.stopped then stop_capture("error: " .. where) end
    save()
end

local function guarded(where, fn)
    local started = os.clock()
    local ok, err = pcall(fn)
    elapsed_cost(where, started)
    if not ok then failure(where, err) end
end

local function start_capture(label)
    if faulted or capture or #report.captures >= 6 or not preview.replay or not preview.ready then return end
    if label == "baseline" then stop_all("Recording baseline; effects OFF.") end
    if manager.slots[1] and not wants_transform(1) or manager.slots[2] and not wants_transform(2) then return end
    local meta = { label = label, clock = clock.source, wall_started_utc = os.time(),
        file = "jamieswine_" .. session .. "_capture_" .. (#report.captures + 1) .. ".json" }
    table.insert(report.captures, meta)
    capture = { meta = meta, samples = {}, started = os.clock(), segment = 1 }
    capture_status = "Recording " .. label .. " (max 5 minutes / 40000 samples)."
    save()
end

-- The panel shows the first unmet requirement instead of a silently greyed-out row.
local function lock_reason(mode, contexts)
    if faulted then return status end
    if not mode.allowed then
        return tr("等待进入本地训练、一对一对战或回放。", "Waiting for local training, versus or replay.")
    end
    for slot = 1, 2 do
        local c = contexts[slot]
        if not c.ready then return "P" .. slot .. tr(" 等待角色：", " waiting for character: ") .. tostring(c.issue or "unknown reason") end
    end
end

local function update(write_effect)
    local now = clock:now()
    -- A motion update is already a fresh scene check. Do not repeat it in on_frame.
    last_preview = now
    if enabled and not anchor then anchor = { seconds = now, peak = false } end
    if anchor_command then
        anchor = { seconds = now, peak = anchor_command == "peak" }
        anchor_command = nil
        event("anchor", anchor)
        save_command = true
    end
    local mode = adapter.mode()
    local contexts = { adapter.resolve(1, mode), adapter.resolve(2, mode) }
    local drinks, drink_issue
    if prefs.drink_link and mode.allowed then
        local ok, result = pcall(adapter.drinks)
        if ok then drinks = result else drink_issue = tostring(result) end
    end
    local amplitude, unavailable = effects.drink_strength(settings.amplitude, prefs.drink_link, drinks)
    drink_issue = drink_issue or unavailable
    if drinks then
        local signature = table.concat({ tostring(drinks[1].character), tostring(drinks[1].level),
            tostring(drinks[2].character), tostring(drinks[2].level), tostring(drink_issue) }, ":")
        if signature ~= last_drinks then
            event("drink levels", { players = drinks, amplitude = amplitude, round = mode.round, frame = mode.frame })
            last_drinks, save_command = signature, true
        end
    else last_drinks = nil end
    local multiplier, phase, period, active_slot = effects.at_time(now, anchor or { seconds = now }, settings, amplitude)
    assert(multiplier, phase)
    local clock_valid = effects.finite(mode.frame) and mode.frame >= 0 and mode.frame % 1 == 0
        and effects.finite(mode.round) and mode.round >= 0 and mode.round % 1 == 0
    local reason = lock_reason(mode, contexts)
    local ready = reason == nil
    preview = { name = mode.name, allowed = mode.allowed, replay = mode.replay, clock = clock_valid,
        flow_name = mode.flow_name, flow_id = mode.flow_id, game_mode = mode.game_mode,
        rule_mode = mode.rule_mode, network_mode = mode.network_mode, local_versus = mode.local_versus,
        frame = mode.frame, round = mode.round, ready = ready, reason = reason, players = {},
        monotonic_now = now, phase = phase, period = period, multiplier = multiplier, anchor = anchor,
        drinks = drinks, drink_issue = drink_issue, amplitude = amplitude }
    for slot, c in ipairs(contexts) do
        preview.players[slot] = { name = c.name, character = c.character, ready = c.ready, issue = c.issue }
    end
    if not ready then
        if session_key or manager.slots[1] or manager.slots[2] then
            local a, b = restore_slot(1), restore_slot(2)
            if not a or not b then error("Scene exit recovery pending") end
            shrink:clear()
            session_key, last_round, last_frame = nil, nil, nil
            event("scene released", "Preferences and real-time beat retained")
            save_command = true
        end
        if not faulted then status = (enabled and tr("已开启；", "Enabled; ") or tr("已关闭；", "OFF; ")) .. reason end
        if capture and not capture.stopped then stop_capture("left supported scene") end
        return
    end
    -- Ownership changes release old writes, while the real-time beat and intent survive.
    local identity = mode.key .. ":" .. contexts[1].owner .. ":" .. contexts[1].joint_key
        .. ":" .. contexts[2].owner .. ":" .. contexts[2].joint_key
    if identity ~= session_key then
        if session_key then
            local a, b = restore_slot(1), restore_slot(2)
            if not a or not b then error("Character change recovery pending") end
            -- One player may retain its object while the other respawns. Its pre-restore
            -- context still contains our old output; read the restored base before applying.
            contexts = { adapter.resolve(1, mode), adapter.resolve(2, mode) }
            if capture and not capture.stopped then stop_capture("scene identity changed") end
        end
        shrink:clear()
        session_key, last_round, last_frame = identity, nil, nil
        event("new scene", "Real-time anchor retained; throw history reset")
    end
    if clock_valid and last_round ~= nil and (mode.round ~= last_round or mode.frame < last_frame) then
        report.seeks = report.seeks + 1
        event("round or seek", { from_round = last_round, from_frame = last_frame })
        if capture then capture.segment = capture.segment + 1 end
    end
    if clock_valid then last_round, last_frame = mode.round, mode.frame end
    if not write_effect then return end
    if targets.conflict(contexts[1], contexts[2]) then
        error("Targets overlap: duplicate/parent-child hierarchy rejected")
    end
    local snapshot = (enabled and shrink_enabled and clock_valid or capture and not capture.stopped)
        and adapter.throw_snapshot() or nil
    if enabled and shrink_enabled then
        if not clock_valid then
            -- Unknown event time cannot safely retain or accumulate a height reduction.
            shrink:clear()
        else
            for _, reduction in ipairs(shrink:update(mode.round, mode.frame, mode.replay, snapshot)) do
                event(reduction.family == "Power Stomp" and "stomp shrink" or "throw shrink", reduction)
                save_command = true
            end
        end
    end
    local results = {}
    for slot = 1, 2 do
        if wants_transform(slot) then
            assert(not (capture and capture.meta.label == "baseline"), "Baseline capture must keep effects off")
            local jelly_active = requested[slot] and (not prefs.alternate or slot == active_slot)
            local combined = effects.body_multiplier(prefs.body[slot], shrink:height(slot), jelly_active and multiplier or nil)
            results[slot] = manager:apply(slot, contexts[slot], combined)
        elseif manager.slots[slot] then
            -- Round/training resets may remove the last shrink on this very callback.
            if not restore_slot(slot) then error("Recovery pending") end
        end
    end
    report.latest = { round = mode.round, frame = mode.frame, monotonic_now = now,
        callback = report.callbacks, phase = phase, period = period,
        multiplier = multiplier, amplitude = amplitude, drinks = drinks, p1 = results[1], p2 = results[2] }
    if enabled and shrink_enabled and not clock_valid then status = tr("果冻按真实时间运行；缩矮等待游戏帧数据。", "Real-time jelly; shrink waiting for game frame data.")
    elseif enabled and prefs.alternate then status = tr("交替变形；当前轮到 P", "Alternating; current turn: P") .. active_slot
    elseif enabled then status = tr("已开启；双方共用真实时间节拍。", "Enabled; P1/P2 share the real-time beat.")
    else status = tr("效果关闭，参数已就绪。", "Effects OFF. Presets ready.") end
    if capture and not capture.stopped then
        if not mode.replay then stop_capture("left replay"); return end
        table.insert(capture.samples, { round = mode.round, frame = mode.frame, segment = capture.segment,
            elapsed = now - capture.started, monotonic_now = now, callback = report.callbacks,
            frame_callbacks = report.frame_callbacks, settings = copy_settings(), anchor = anchor,
            phase = phase, period = period, multiplier = multiplier, p1 = results[1], p2 = results[2],
            throw_heights = { shrink:height(1), shrink:height(2) },
            body = { { enabled = prefs.body[1].enabled, height = prefs.body[1].height, width = prefs.body[1].width },
                { enabled = prefs.body[2].enabled, height = prefs.body[2].height, width = prefs.body[2].width } },
            amplitude = amplitude, drinks = drinks,
            combat = adapter.combat(), actors = snapshot })
        if #capture.samples >= 40000 or os.clock() - capture.started >= 300 then stop_capture("recording limit") end
    end
end

re.on_application_entry("UpdateMotion", function()
    report.callbacks = report.callbacks + 1
    probe:tick()
    if faulted then return end
    -- Game object writes run in the stage-2-verified post-animation callback.
    if enabled and (preview.ready or os.clock() - last_preview >= 0.25)
        or anchor_command or manager.slots[1] or manager.slots[2] or capture and not capture.stopped then
        guarded("UpdateMotion", function()
            -- Process OFF requests before any other slot can be written again.
            for slot = 1, 2 do
                if not wants_transform(slot) and manager.slots[slot] then
                    if not restore_slot(slot) then error("Recovery pending") end
                end
            end
            update(true)
        end)
    elseif enabled then
        -- Unsupported scenes / loading have no targets to animate. Poll at 4Hz;
        -- owned targets and pending recovery always bypass this waiting path.
        performance.waiting_skips = performance.waiting_skips + 1
    end
end)

local function set_enabled(value)
    enabled, prefs.enabled = value, value
    last_preview = -1 -- explicit user action takes effect on the next callback
    if value and not anchor then anchor_command = "start" end
    if not value then shrink:clear() end
    config_dirty, save_command = true, true
end

re.on_frame(function()
    local frame_time = os.clock()
    if previous_frame_time and previous_frame_enabled == enabled then
        local dt = frame_time - previous_frame_time
        if dt > 0 then
            local label = enabled and "enabled" or "disabled"
            local p = performance.frame_intervals[label] or { count = 0, total_seconds = 0, max_seconds = 0, over_25ms = 0 }
            p.count, p.total_seconds = p.count + 1, p.total_seconds + dt
            p.max_seconds = math.max(p.max_seconds, dt)
            if dt > 0.025 then p.over_25ms = p.over_25ms + 1 end
            performance.frame_intervals[label] = p
        end
    end
    previous_frame_time, previous_frame_enabled = frame_time, enabled
    report.frame_callbacks = (report.frame_callbacks or 0) + 1
    probe:frame()
    if reframework and not hotkey_fault then
        local ok, command = pcall(function() return hotkeys:poll(prefs.hotkeys, reframework:is_drawing_ui()) end)
        if not ok then hotkey_error, hotkey_fault = tostring(command), true
        elseif command == "restore" then enabled, restore_command = false, true
        elseif command == "toggle" and not faulted and not (capture and capture.meta.label == "baseline") then
            set_enabled(not enabled)
        end
    end
    -- Stop/recovery also works if animation callbacks do not run while paused.
    if restore_command then
        restore_command, anchor_command = nil, nil
        stop_all(tr("效果关闭，已恢复。公共节拍保留。", "Effects OFF; restored. Beat retained."))
        prefs.enabled, config_dirty = false, true
        faulted = manager.slots[1] ~= nil or manager.slots[2] ~= nil
        save_command = true
    end
    guarded("background", function()
        background:frame(not faulted and clock:now() or nil, anchor, settings, enabled and not faulted)
    end)
    if shrink_command and not faulted then
        local command = shrink_command
        shrink_command = nil
        shrink:clear()
        if command ~= "reset" then
            shrink_enabled = command == "on"
            prefs.shrink, config_dirty = shrink_enabled, true
        end
        -- Remove the old composite even while paused. Any enabled jelly resumes
        -- from the clean base on the next post-animation callback.
        for slot = 1, 2 do
            if not restore_slot(slot) then failure("throw height reset", "Recovery pending"); break end
        end
        event("throw shrink control", command)
        save_command = true
    end
    if not faulted then
        for slot = 1, 2 do
            if body_commands[slot] then
                if not restore_slot(slot) then failure("body change", "Recovery pending"); break end
            end
        end
        body_commands = {}
        for slot = 1, 2 do
            if faulted then break end
            if not wants_transform(slot) and manager.slots[slot] then
                if not restore_slot(slot) then failure("restore", "Recovery pending"); break end
            end
        end
        if not faulted and (anchor_command or os.clock() - last_preview >= 0.25) then
            last_preview = os.clock()
            guarded("scene check", function() update(false) end)
        end
    end
    if capture_command then
        local command = capture_command
        capture_command = nil
        if command == "stop" then stop_capture("manual stop") else start_capture(command) end
    end
    if capture and not capture.stopped and os.clock() - capture.started >= 300 then stop_capture("recording timeout") end
    if config_dirty then
        local ok, err = config.save(json, prefs)
        config_error, config_dirty = err, false
        if not ok then log.error(PREFIX .. tostring(err)) end
    end
    if save_command or os.clock() - last_save >= 10 and enabled then
        save_command = nil
        save()
    end
end)

local mode_index, beats_index, align_index = settings.mode == "bpm" and 2 or 1, 2, 1
for i, beat in ipairs({ 0.5, 1, 2, 4 }) do if settings.beats == beat then beats_index = i end end
local bpm_text, offset_text = tostring(settings.bpm), tostring(settings.offset_ms)
local font, font_attempted, font_error
local function changed_preferences()
    prefs.p1, prefs.p2 = requested[1], requested[2]
    config_dirty, save_command = true, true
end
local function draw_panel()
    if not imgui.tree_node(tr("杰米的酒", "Jamie's Wine") .. "###SF6Jelly") then return end
    local changed, value = imgui.combo("语言 / Language", prefs.language == "zh" and 1 or 2, { "中文", "English" })
    if changed then prefs.language = value == 1 and "zh" or "en"; changed_preferences() end
    changed, value = imgui.slider_float(tr("界面字号", "Font size") .. "###font_size", prefs.font_size, 18, 40)
    if changed then prefs.font_size = math.floor(value + 0.5); changed_preferences() end
    imgui.text("v" .. VERSION .. " | " .. status)
    if font_error then imgui.text(font_error) end
    if config_error then
        imgui.text(tr("配置未保存或已回退默认值：", "Settings warning: ") .. config_error)
        if imgui.button(tr("重试保存配置", "Retry saving settings") .. "###save_settings") then config_dirty = true end
    end
    background:draw()
    local locked = faulted or capture and capture.meta.label == "baseline"
    imgui.begin_disabled(locked and true or false)
    changed, value = imgui.checkbox(tr("总开关", "Enable effects") .. "###enabled", enabled)
    if changed then
        set_enabled(value)
        changed_preferences()
    end
    for slot = 1, 2 do
        changed, value = imgui.checkbox("P" .. slot .. tr(" 果冻", " jelly") .. "###p" .. slot, requested[slot])
        if changed then requested[slot] = value; changed_preferences() end
    end
    changed, value = imgui.checkbox(tr("双人交替变形", "Alternate P1 / P2") .. "###alternate", prefs.alternate)
    if changed then prefs.alternate = value; changed_preferences() end
    if prefs.alternate then
        imgui.text(tr("每个周期换一方，默认一拍一次；勾选双方果冻。重启周期从 P1 开始。",
            "One player per cycle (default: one beat). Enable both jelly switches. Restart cycle begins with P1."))
    end
    changed, value = imgui.checkbox(tr("桑吉尔夫投技 / 踩踏缩矮", "Zangief throw / stomp shrink") .. "###shrink", shrink_enabled)
    if changed then shrink_command = value and "on" or "off" end
    if imgui.button(tr("重置双方缩矮", "Reset throw heights") .. "###reset_heights") then shrink_command = "reset" end
    imgui.end_disabled()
    if faulted then imgui.text(tr("异常已停止写入，请恢复后再开启。", "Writes stopped after an error. Restore before enabling.")) end
    if preview.reason then imgui.text(preview.reason) end
    if imgui.button(tr("全部恢复 / 重试恢复", "Restore all / Retry recovery") .. "###restore") then
        enabled, restore_command = false, true
    end
    imgui.text(string.format(tr("投技缩矮：P1 %.0f%% | P2 %.0f%%", "Throw height factors: P1 %.0f%% | P2 %.0f%%"),
        shrink:height(1) * 100, shrink:height(2) * 100))
    changed, value = imgui.slider_float(tr("果冻强度", "Strength") .. "###strength", settings.amplitude, 0, 1)
    if changed then settings.amplitude = value; changed_preferences() end
    if imgui.button(tr("默认强度 0.75", "Default strength 0.75") .. "###default_strength") then
        settings.amplitude = 0.75; changed_preferences()
    end
    if imgui.button(tr("原版强度 0.5", "Original strength 0.5") .. "###original_strength") then
        settings.amplitude = 0.5; changed_preferences()
    end
    changed, value = imgui.checkbox(tr("强度随杰米酒数增加", "Increase strength with Jamie drink level") .. "###drink_link", prefs.drink_link)
    if changed then prefs.drink_link = value; changed_preferences() end
    if prefs.drink_link then
        local d = preview.drinks or {}
        imgui.text(string.format(tr("P1 酒数 %s | P2 酒数 %s | 当前强度 %.2f", "P1 drinks %s | P2 drinks %s | strength %.2f"),
            d[1] and d[1].ready and tostring(d[1].level) or "?",
            d[2] and d[2].ready and tostring(d[2].level) or "?", preview.amplitude or settings.amplitude))
        imgui.text(tr("每级增加 0.03，双方相加，上限 1。",
            "+0.03 per level across both players, capped at 1."))
        if preview.drink_issue then imgui.text(tr("酒数暂不可读，使用基础强度。", "Drink level unavailable; using base strength.")) end
    end
    if imgui.tree_node(tr("自定义体型", "Custom body") .. "###body") then
        imgui.begin_disabled(locked and true or false)
        for slot = 1, 2 do
            local b = prefs.body[slot]
            changed, value = imgui.checkbox("P" .. slot .. tr(" 自定义体型", " custom body") .. "###body_enabled" .. slot, b.enabled)
            if changed then b.enabled = value; body_commands[slot] = true; changed_preferences() end
            changed, value = imgui.slider_float("P" .. slot .. tr(" 身高 %", " height %") .. "###height" .. slot, b.height * 100, 50, 150)
            if changed then b.height = value / 100; body_commands[slot] = true; changed_preferences() end
            changed, value = imgui.slider_float("P" .. slot .. tr(" 体宽 %", " width %") .. "###width" .. slot, b.width * 100, 50, 150)
            if changed then b.width = value / 100; body_commands[slot] = true; changed_preferences() end
            if imgui.button("P" .. slot .. tr(" 体型恢复 100%", " reset body to 100%") .. "###body_reset" .. slot) then
                b.height, b.width = 1, 1
                body_commands[slot] = true; changed_preferences()
            end
        end
        imgui.end_disabled()
        imgui.text(tr("体宽同时调整两条横轴；100% 只重置自定义体型。全部恢复关闭总效果。",
            "Width affects both horizontal axes. 100% resets custom body only. Restore all disables all effects."))
        imgui.tree_pop()
    end
    changed, value = imgui.combo(tr("节奏", "Rhythm") .. "###rhythm", mode_index,
        { tr("原版（0.65 秒）", "Original (0.65 seconds)"), "BPM" })
    if changed then mode_index = value end
    changed, value = imgui.input_text("BPM", bpm_text)
    if changed then bpm_text = value end
    changed, value = imgui.combo(tr("每周期拍数", "Beats per cycle") .. "###beats", beats_index, { "0.5", "1", "2", "4" })
    if changed then beats_index = value end
    changed, value = imgui.input_text(tr("偏移毫秒（正数延后）", "Offset ms (positive = later)") .. "###offset", offset_text)
    if changed then offset_text = value end
    if imgui.button(tr("应用节奏与偏移", "Apply rhythm / offset") .. "###apply_rhythm") then
        local candidate = { mode = mode_index == 1 and "original" or "bpm", bpm = tonumber(bpm_text),
            beats = ({ 0.5, 1, 2, 4 })[beats_index], offset_ms = tonumber(offset_text) }
        local t, err = effects.period(candidate.mode, candidate.bpm, candidate.beats)
        if not effects.finite(candidate.bpm) or candidate.bpm <= 0 then
            parameter_error = tr("BPM 需要为正数。", "BPM must be positive and finite.")
        elseif not t then parameter_error = tr("周期须为 0.2 至 3 秒，请调整 BPM 或拍数。", err)
        elseif not effects.finite(candidate.offset_ms) or math.abs(candidate.offset_ms) > 3600000 then
            parameter_error = tr("偏移须在正负 3600000 毫秒内。", "Offset must be within +/-3600000 ms.")
        else
            for k, v in pairs(candidate) do settings[k] = v end
            parameter_error = nil
            event("settings", copy_settings())
            changed_preferences()
        end
    end
    if parameter_error then imgui.text(parameter_error) end
    imgui.text(string.format(tr("当前周期 %.9f 秒 | 偏移 %.3f 毫秒", "Active period %.9f s | offset %.3f ms"),
        effects.period(settings.mode, settings.bpm, settings.beats), settings.offset_ms))
    changed, value = imgui.combo(tr("对齐位置", "Align to") .. "###align", align_index,
        { tr("最矮点", "Main squash peak"), tr("周期起点", "Cycle start") })
    if changed then align_index = value end
    imgui.begin_disabled(faulted)
    if imgui.button(tr("将当前时刻设为节拍基准", "Align beat to now") .. "###anchor") then
        anchor_command = align_index == 1 and "peak" or "start"
    end
    if imgui.button(tr("从现在重启周期", "Restart cycle now") .. "###restart_beat") then anchor_command = "start" end
    imgui.end_disabled()
    imgui.text(tr("暂停、变速与换回合保持真实时间节奏。对齐后仍叠加偏移。",
        "Pause, speed changes and new rounds keep the real-time beat. Offset still applies after alignment."))
    imgui.text(tr("退场与临时关闭保留节拍；重置脚本后重新计时。", "Scene exit and temporary OFF retain the beat; script reset starts a new clock anchor."))
    changed, value = imgui.checkbox(tr("加载脚本时自动恢复已保存的总开关", "Restore saved enable state on script load") .. "###auto_start", prefs.auto_start)
    if changed then prefs.auto_start = value; changed_preferences() end
    if imgui.tree_node(tr("快捷键", "Hotkeys") .. "###hotkeys") then
        local labels = { tr("禁用", "Disabled") }
        for i = 1, 12 do labels[#labels + 1] = "F" .. i end
        for _, name in ipairs({ "toggle", "restore" }) do
            local key = prefs.hotkeys[name]
            changed, value = imgui.combo((name == "toggle" and tr("总开关键", "Toggle key") or tr("恢复键", "Restore key"))
                .. "###key_" .. name, key == 0 and 1 or key - 110, labels)
            if changed then
                local candidate = value == 1 and 0 or value + 110
                local other = name == "toggle" and "restore" or "toggle"
                if candidate ~= 0 and candidate == prefs.hotkeys[other] then
                    hotkey_error = tr("两个快捷键应不同，请重新选择。", "Choose two different hotkeys.")
                else
                    prefs.hotkeys[name] = candidate
                    hotkey_error, hotkey_fault = nil, false; hotkeys:reset(); changed_preferences()
                end
            end
        end
        imgui.text(tr("默认 F6 总开关、F7 全部恢复。隐藏 REFramework 面板后生效，长按只触发一次。",
            "Default F6 toggles effects; F7 restores all. Works with the REFramework panel hidden, once per press."))
        if hotkey_error then imgui.text(hotkey_error) end
        imgui.tree_pop()
    end
    if imgui.tree_node(tr("高级：规则与诊断", "Advanced: rules and diagnostics") .. "###advanced") then
        imgui.text(tr("投技档位：85% / 70% / 50% / 30%；SA3 / CA 计两次。",
            "Throw heights: 85% / 70% / 50% / 30%; SA3 / CA count twice."))
        imgui.text(tr("身高不高于 50% 时，能量踩踏每次命中再减 1 个百分点，最低 30%。",
            "At 50% or below, each Power Stomp hit removes one percentage point, minimum 30%."))
        imgui.text(tr("SA2 仅砸地派生计数；新回合与训练重置恢复身高。",
            "SA2 counts the slam only; new rounds and training resets restore height."))
        if imgui.button(tr("保存诊断", "Save diagnostics") .. "###diagnostics") then save_command = true end
        imgui.text("reframework/data/" .. output)
        imgui.tree_pop()
    end
    imgui.tree_pop()
end
re.on_draw_ui(function()
    if not font_attempted then
        font_attempted = true
        local ok, result = pcall(function() return imgui.load_font("NotoSansSC.ttf", prefs.font_size) end)
        if ok and type(result) == "number" and result >= 0 then font = result
        else
            font_error = "Chinese font unavailable. Install reframework/fonts/NotoSansSC.ttf and reset scripts."
            prefs.language = "en"
        end
    end
    if font then imgui.push_font(font, prefs.font_size) end
    local ok, err = pcall(draw_panel)
    if font then imgui.pop_font() end
    if not ok then failure("UI", err) end
end)

re.on_script_reset(function()
    if config_dirty then
        local ok, err = config.save(json, prefs)
        if not ok then log.error(PREFIX .. tostring(err)) end
    end
    background:stop()
    probe:stop("script reset")
    stop_all("Script reset")
    stop_capture("script reset")
    report.ended_by = "script_reset"
    save()
end)
log.info(PREFIX .. "loaded; effects " .. (enabled and "ON (saved opt-in)" or "OFF") .. " -> reframework/data/" .. output)
return { version = VERSION }
