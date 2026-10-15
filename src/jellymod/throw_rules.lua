-- SPDX-License-Identifier: AGPL-3.0-only
-- Action pairs from MMDK's fixed Zangief moves_dict (see notices). The recorded
-- normal SPD / Express / Air SPD / SA1 / SA2 neutral slam / SA3 / CA paths match
-- the current game. OD/strength/directional variants still need live coverage.
-- Successful captures require reciprocal runtime catch links; whiff/start actions
-- and SA2's non-slam spinning actions are deliberately absent.
local M = { actions = {} }
-- Earlier cinematic cues in the fixed move data: victim SYSTEM notification
-- at SA3 frame 371 / CA frame 486 (release is much later: 520 / 650).
-- These are visual-impact candidates; confirm alignment in the current game.
M.impact_frames = { SA3 = 371, CA = 486 }
function M.impact(family, previous_frame, player)
    local target = M.impact_frames[family]
    local current = player and player.action_frame
    return target and type(previous_frame) == "number" and type(current) == "number"
        and previous_frame < target and current >= target
end
local function add(family, pairs)
    for _, pair in ipairs(pairs) do
        M.actions[pair[1]] = { family = family, victim_action = pair[2] }
    end
end
add("SPD", { {931,932}, {933,932}, {936,937}, {938,937}, {941,942}, {943,942}, {946,947}, {948,947} })
-- 1011/1017 is the current-game heavy-kick variant captured on this machine;
-- it is absent from the older MMDK reference table.
add("Russian Suplex", { {1011,1017}, {1016,1017}, {1018,1017}, {1021,1022}, {1023,1022} })
add("Siberian Express", { {919,920}, {921,920}, {926,927}, {928,927} })
add("Air SPD", { {955,956}, {957,958}, {959,956}, {960,958}, {964,965}, {966,967}, {968,965}, {969,967} })
add("SA1", { {1196,1202}, {1197,1204}, {1201,1202}, {1203,1204} })
add("SA2 slam", { {1211,1212}, {1213,1214}, {1215,1216} })
add("SA3", { {1219,1220} })
add("CA", { {1223,1224} })

function M.match(players, attacker)
    local victim = 3 - attacker
    local a, b = players[attacker], players[victim]
    if not a or not b or a.character ~= 6 then return nil end
    local rule = M.actions[a.action]
    if rule and b.action == rule.victim_action and a.catch_player == victim and b.catch_player == attacker then
        return rule.family, victim
    end
end

-- Current runtime ACT_ID metadata: LIE_DOWN_FU=336, LIE_DOWN_FD=337.
-- These include the KO pose; all height reductions stop at the 30% floor.
-- Get-up (340-345), airborne damage and sliding/falling states are not accepted.
function M.lying(player) return player and (player.action == 336 or player.action == 337) end
return M
