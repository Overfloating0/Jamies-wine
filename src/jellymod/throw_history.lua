-- SPDX-License-Identifier: AGPL-3.0-only
-- Plain-data height history. Throws commit at the lying-down frame; stomp hits
-- commit on confirmed contact. Replay seeks reconstruct the known height by frame.
local M = {}
local percentages = { [0] = 100, 85, 70, 50, 30 }
function M.height(count, stomps)
    return math.max(30, percentages[math.min(4, count)] - (stomps or 0)) / 100
end
function M.weight(family) return (family == "SA3" or family == "CA") and 2 or 1 end

local function accumulate(state, event)
    if M.height(state.count, state.stomps) <= 0.30 then return false end
    if event.family == "Power Stomp" then
        if M.height(state.count, state.stomps) > 0.50 then return false end
        state.stomps = state.stomps + 1
    else state.count = math.min(4, state.count + M.weight(event.family)) end
    return true
end

function M.new()
    local self = { rounds = {}, round = nil, frame = nil, replay = nil }
    function self:clear()
        self.rounds, self.round, self.frame, self.replay = {}, nil, nil, nil
    end
    function self:advance(round, frame, replay)
        assert(type(round) == "number" and round >= 0 and round % 1 == 0, "Invalid round")
        assert(type(frame) == "number" and frame >= 0 and frame % 1 == 0, "Invalid frame")
        local changed = self.round ~= nil and (round ~= self.round or frame < self.frame or self.replay ~= replay)
        -- Training restart creates a fresh attempt; replay rewinds revisit recorded events.
        if not replay and changed or self.replay ~= nil and self.replay ~= replay then self:clear() end
        self.round, self.frame, self.replay = round, frame, replay
        self.rounds[round] = self.rounds[round] or {}
        return changed
    end
    function self:progress(slot)
        local state = { count = 0, stomps = 0 }
        for _, event in ipairs(self.rounds[self.round] or {}) do
            if event.victim == slot and event.frame <= self.frame then accumulate(state, event) end
        end
        return state
    end
    function self:count(slot) return self:progress(slot).count end
    function self:stomps(slot) return self:progress(slot).stomps end
    function self:height(slot)
        local state = self:progress(slot)
        return M.height(state.count, state.stomps)
    end
    function self:commit(attacker, victim, family, started_at)
        assert(self.round ~= nil, "Clock not initialized")
        local events = self.rounds[self.round]
        for _, event in ipairs(events) do
            -- Re-entering a replay halfway through a grab changes the observed start,
            -- but the actual release frame identifies the same completed throw.
            if event.attacker == attacker and event.victim == victim and event.family == family
                and (event.frame == self.frame or event.started_at == started_at) then
                return false, event
            end
        end
        if not accumulate(self:progress(victim), { family = family }) then return false end
        local event = { attacker = attacker, victim = victim, family = family,
            started_at = started_at, frame = self.frame, round = self.round,
            throw_units = family == "Power Stomp" and 0 or M.weight(family) }
        table.insert(events, event)
        table.sort(events, function(a, b) return a.frame < b.frame end)
        -- Rewinds can reveal earlier events. Keep only reductions before the floor:
        -- at most four throw events plus twenty stomp hits for either victim.
        local states = { { count = 0, stomps = 0 }, { count = 0, stomps = 0 } }
        local kept = {}
        for _, item in ipairs(events) do
            if accumulate(states[item.victim], item) then table.insert(kept, item) end
        end
        self.rounds[self.round] = kept
        return true, event
    end
    return self
end
return M
