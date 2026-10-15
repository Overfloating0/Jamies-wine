-- SPDX-License-Identifier: AGPL-3.0-only
local history = require("jellymod.throw_history")
local rules = require("jellymod.throw_rules")
local stomp_detector = require("jellymod.stomp_detector")
local M = {}
function M.new()
    local self = { history = history.new(), stomp = stomp_detector.new(), active = {}, events = {}, status = "OFF" }
    function self:clear()
        self.history:clear()
        self.stomp:clear()
        self.active, self.events, self.status = {}, {}, "Waiting for a successful Zangief grab."
    end
    function self:height(slot) return self.history:height(slot) end
    function self:count(slot) return self.history:count(slot) end
    function self:stomps(slot) return self.history:stomps(slot) end
    function self:multiplier(slot, jelly)
        jelly = jelly or { x = 1, y = 1, z = 1 }
        return { x = jelly.x, y = jelly.y * self:height(slot), z = jelly.z }
    end
    function self:update(round, frame, replay, players)
        if self.history:advance(round, frame, replay) then
            self.active, self.status = {}, "Round/position changed; waiting for a successful Zangief grab."
            self.stomp:clear()
        end
        local emitted = {}
        for attacker = 1, 2 do
            local family, victim = rules.match(players, attacker)
            local a = players[attacker]
            local run = self.active[attacker]
            if family then
                if not run or run.family ~= family then
                    run = { family = family, attacker = attacker, victim = victim, started_at = frame }
                    if rules.impact_frames[family] and type(a.action_frame) == "number" then
                        -- Stable identity even if a replay is resumed halfway through the cinematic.
                        run.started_at = frame - a.action_frame
                    end
                    self.active[attacker] = run
                end
                run.last_pair_frame = frame
                if not run.committed then
                    self.status = family .. (rules.impact_frames[family]
                        and ": captured; waiting for impact." or ": captured; waiting for lying-down pose.")
                end
            end
            run = self.active[attacker]
            if run then
                local b = players[run.victim]
                local impact = family and rules.impact(run.family, run.last_action_frame, a)
                if run.committed then
                    -- The grab relation continues after impact. Keep the run consumed
                    -- until it ends, so release/get-up cannot add another two throws.
                    if not family then self.active[attacker] = nil end
                elseif frame - run.last_pair_frame > 120 then
                    self.status = run.family .. ": release window lost; skipped."
                    self.active[attacker] = nil
                elseif impact or rules.lying(b) then
                    local added, event = self.history:commit(attacker, run.victim, run.family, run.started_at)
                    if added then
                        event.trigger = impact and "super impact" or "lying down"
                        event.action_frame = a and a.action_frame
                        table.insert(emitted, event)
                        if #self.events < 128 then table.insert(self.events, event) end
                    end
                    self.status = string.format("P%d height %.0f%% after %s", run.victim,
                        self:height(run.victim) * 100, run.family)
                    if impact then run.committed = true else self.active[attacker] = nil end
                elseif not family then
                    -- The paired throw may release into a short falling state before lying.
                    -- Stop tracking once the victim is getting up/controllable, or the
                    -- attacker starts a different attack. Never shrink a standing victim.
                    local action_rule = a and rules.actions[a.action]
                    if not b or b.act_st == 35 or b.act_st == 0 or b.act_st == 1
                        or action_rule and action_rule.family ~= run.family then
                        self.status = run.family .. ": lying-down window not observed; skipped."
                        self.active[attacker] = nil
                    end
                end
                run.last_action_frame = a and a.action_frame
            end
        end
        for _, hit in ipairs(self.stomp:update(frame, players)) do
            local added, event = self.history:commit(hit.attacker, hit.victim, hit.family, hit.started_at)
            if added then
                event.action = hit.action
                table.insert(emitted, event)
                if #self.events < 128 then table.insert(self.events, event) end
                self.status = string.format("P%d height %.0f%% after Power Stomp", hit.victim, self:height(hit.victim) * 100)
            end
        end
        return emitted
    end
    return self
end
return M
