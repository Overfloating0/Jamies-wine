-- SPDX-License-Identifier: AGPL-3.0-only
-- Manual, read-only timing capture. Does not enable jelly or modify combat state.
local M = {}
function M.new(adapter, version, session)
    local self = { run = nil, command = nil, status = "Throw timing: idle", sequence = 0 }
    local function save(reason)
        local run = self.run
        if not run then return true end
        run.data.reason = reason
        local ok, result = pcall(json.dump_file, run.file, run.data, 0)
        if not ok or not result then
            self.status = "Throw trace export failed. Stop / Save retries with data retained."
            return false
        end
        run.saved_at = os.clock()
        return true
    end
    function self:stop(reason)
        if not self.run then return end
        self.run.stopped = true
        if save(reason) then
            self.status = "Saved " .. #self.run.data.samples .. " throw timing samples: " .. self.run.file
            self.run = nil
        end
    end
    function self:tick()
        local run = self.run
        if not run or run.stopped then return end
        local ok, err = pcall(function()
            local mode = adapter.mode()
            if not mode.allowed then self:stop("left training/replay"); return end
            local players = adapter.throw_snapshot()
            if not players[1].action or not players[2].action then return end
            if run.last and (mode.round ~= run.last.round or mode.frame < run.last.frame) then
                run.segment = run.segment + 1
            end
            local signature = { tostring(mode.round), tostring(run.segment) }
            for _, p in ipairs(players) do
                for _, name in ipairs({ "character", "action", "unique", "vital", "act_st", "pose_st", "damage_st",
                    "jump_st", "floor_hit", "to_go_down", "catch_flag", "catch_player", "catch_work", "damage_player",
                    "hit_player", "hit_st", "hit_st_old", "hit_kind", "hit_kind_vs", "hit_stop", "uniq_hit_id",
                    "combo_cnt", "combo_dm_cnt", "guard_st", "damage_type" }) do
                    table.insert(signature, tostring(p[name]))
                end
            end
            signature = table.concat(signature, ":")
            local sample = { round = mode.round, frame = mode.frame, segment = run.segment,
                elapsed = os.clock() - run.started, players = players }
            -- Keep EVERY state transition, plus a sample every six simulation frames.
            local stomp = false
            for _, p in ipairs(players) do
                if p.action >= 678 and p.action <= 680 then stomp = true end
            end
            if stomp or signature ~= run.signature or not run.last_saved or math.abs(mode.frame - run.last_saved) >= 6 then
                table.insert(run.data.samples, sample)
                run.signature, run.last_saved = signature, mode.frame
            end
            run.last = sample
            if #run.data.samples >= 6000 or os.clock() - run.started >= 300 then self:stop("capture limit") end
        end)
        if not ok then
            run.data.error = tostring(err)
            self:stop("capture error")
            self.status = "Throw capture error: " .. tostring(err)
        end
    end
    function self:frame()
        if self.command == "start" and not self.run then
            self.sequence = self.sequence + 1
            self.run = { file = "SF6Jelly_throws_" .. session .. "_" .. self.sequence .. ".json",
                started = os.clock(), saved_at = os.clock(), segment = 1,
                data = { version = version, session = session, samples = {} } }
            local ok, result = pcall(adapter.throw_enums)
            if ok then self.run.data.enums = result else self.run.data.enum_error = tostring(result) end
            self.status = "Recording throw timing; up to 5 minutes. Perform moves, then Stop / Save."
            save("recording")
        elseif self.command == "stop" then self:stop("manual stop") end
        self.command = nil
        if self.run and not self.run.stopped then
            if os.clock() - self.run.started >= 300 then self:stop("capture timeout")
            elseif os.clock() - self.run.saved_at >= 10 then save("recording") end
        end
    end
    function self:draw(ready)
        if not imgui.tree_node("Throw timing (read only)") then return end
        imgui.text(self.status)
        imgui.text("Record Zangief throws and knockdown/get-up timing. Recording does not enable any effects.")
        imgui.begin_disabled(not ready or self.run ~= nil)
        if imgui.button("Record throw timing") then self.command = "start" end
        imgui.end_disabled()
        imgui.begin_disabled(self.run == nil)
        if imgui.button("Stop / Save throw timing") then self.command = "stop" end
        imgui.end_disabled()
        if self.run then imgui.text("Samples: " .. #self.run.data.samples .. " / 6000") end
        imgui.tree_pop()
    end
    return self
end
return M
