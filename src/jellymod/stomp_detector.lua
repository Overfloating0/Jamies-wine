-- SPDX-License-Identifier: AGPL-3.0-only
-- Runtime capture v0.0.15: Power Stomp actions 678/679/680 each hit once.
-- hit_atk also occurs on block; exclude defensive flags and require the victim's
-- damage state plus reciprocal hit/source slots. No HP or combo-count dependency.
local M = {}
local actions = { [678] = true, [679] = true, [680] = true }
local function flag(value, bit)
    return type(value) == "number" and math.floor(value / bit) % 2 == 1
end
local function contact(player) return flag(player.hit_st, 2147483648) end -- HIT_ST.hit_atk
local function damaging(a, b, attacker, victim)
    -- HIT_ST.GUARD_MASK=8257536: armor/guard/atemi/reflect/parry/just flags.
    return contact(a) and math.floor(a.hit_st / 131072) % 64 == 0
        and b and b.act_st == 32 and flag(b.hit_st, 32768)
        and a.hit_player == victim and b.damage_player == attacker
end
function M.new()
    local self = { runs = {} }
    function self:clear() self.runs = {} end
    function self:update(frame, players)
        local emitted = {}
        for attacker = 1, 2 do
            local a, victim = players[attacker], 3 - attacker
            local run = self.runs[attacker]
            if not a or a.character ~= 6 or not actions[a.action] or type(a.action_frame) ~= "number" then
                self.runs[attacker] = nil
            else
                if not run or run.action ~= a.action or a.action_frame < run.last_action_frame then
                    -- Enabling/seeking into an already connected hit must not count it retroactively.
                    run = { action = a.action, started_at = frame, resolved = contact(a) }
                    self.runs[attacker] = run
                elseif not run.resolved and contact(a) then
                    run.resolved = true -- one contact per kick, including a blocked kick
                    if damaging(a, players[victim], attacker, victim) then
                        table.insert(emitted, { attacker = attacker, victim = victim,
                            family = "Power Stomp", started_at = run.started_at, action = a.action, frame = frame })
                    end
                end
                run.last_action_frame = a.action_frame
            end
        end
        return emitted
    end
    return self
end
return M
