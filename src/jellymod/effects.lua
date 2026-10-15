-- SPDX-License-Identifier: AGPL-3.0-only
-- Waveform ported from Endfield-Poser v0.4.5; see THIRD_PARTY_NOTICES.md.
local M = { DEFAULT_PERIOD = 0.65, MIN_PERIOD = 0.2, MAX_PERIOD = 3.0 }

function M.finite(v)
    return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

function M.period(mode, bpm, beats)
    if mode == "original" then return M.DEFAULT_PERIOD end
    if mode ~= "bpm" or not M.finite(bpm) or bpm <= 0 then return nil, "BPM must be positive and finite." end
    if beats ~= 0.5 and beats ~= 1 and beats ~= 2 and beats ~= 4 then return nil, "Choose 0.5, 1, 2 or 4 beats." end
    local t = 60 / bpm * beats
    if t < M.MIN_PERIOD or t > M.MAX_PERIOD then
        return nil, "Period must be 0.2-3 seconds. Adjust BPM or beats per cycle."
    end
    return t
end

-- Maximum of sin(4*pi*u)*exp(-2*u)*(1-u)^2 in the first positive lobe.
-- Its location is independent of positive amplitude and period.
local lo, hi = 0, 0.125
for _ = 1, 60 do
    local u = (lo + hi) / 2
    local derivative = 4 * math.pi * math.cos(4 * math.pi * u)
        - (2 + 2 / (1 - u)) * math.sin(4 * math.pi * u)
    if derivative > 0 then lo = u else hi = u end
end
M.PEAK_PHASE = (lo + hi) / 2

function M.phase(now, anchor, period, offset_ms)
    if not M.finite(now) or now < 0 or not M.finite(period)
        or period < M.MIN_PERIOD or period > M.MAX_PERIOD or not M.finite(offset_ms) then
        return nil, "Invalid clock, period or offset."
    end
    anchor = anchor or { seconds = 0, peak = false }
    if not M.finite(anchor.seconds) or anchor.seconds < 0 then return nil, "Invalid beat anchor." end
    local seconds = now - anchor.seconds - offset_ms / 1000
    -- Positive modulo deliberately supports positions BEFORE the anchor and negative offsets.
    return ((seconds / period + (anchor.peak and M.PEAK_PHASE or 0)) % 1)
end

function M.sample(phase, amplitude)
    if not M.finite(phase) or not M.finite(amplitude) or amplitude < 0 or amplitude > 1 then
        return nil, "Strength must be between 0 and 1."
    end
    local u = phase % 1
    local y = 1 - amplitude * math.sin(4 * math.pi * u) * math.exp(-2 * u) * (1 - u)^2
    local side = 1 / math.sqrt(y)
    return { x = side, y = y, z = side }
end

function M.drink_strength(base, enabled, players)
    if not enabled then return base end
    local total = 0
    for slot = 1, 2 do
        local p = players and players[slot]
        if not p or not p.ready then return base, "Drink level unavailable" end
        if p.character == 21 then
            if not M.finite(p.level) or p.level % 1 ~= 0 or p.level < 0 or p.level > 4 then
                return base, "Drink level outside 0-4"
            end
            total = total + p.level
        end
    end
    return math.min(1, base + 0.03 * total)
end

-- This multiplier is applied once by the existing target manager, after game animation.
function M.body_multiplier(body, shrink, jelly)
    jelly = jelly or { x = 1, y = 1, z = 1 }
    local height, width = 1, 1
    if body.enabled then height, width = body.height, body.width end
    assert(M.finite(height) and height >= 0.5 and height <= 1.5, "Invalid custom height")
    assert(M.finite(width) and width >= 0.5 and width <= 1.5, "Invalid custom width")
    assert(M.finite(shrink) and shrink >= 0.3 and shrink <= 1, "Invalid throw height")
    local result = { x = width * jelly.x, y = height * shrink * jelly.y, z = width * jelly.z }
    for _, value in pairs(result) do
        -- Includes 50% body * 30% throw height * strength-1 jelly's minimum (~0.0554).
        assert(M.finite(value) and value >= 0.05 and value <= 3, "Combined scale outside 0.05-3")
    end
    return result
end

function M.at_time(now, anchor, settings, amplitude)
    local t, err = M.period(settings.mode, settings.bpm, settings.beats)
    if not t then return nil, err end
    local u
    u, err = M.phase(now, anchor, t, settings.offset_ms)
    if not u then return nil, err end
    local scale
    scale, err = M.sample(u, amplitude or settings.amplitude)
    if not scale then return nil, err end
    return scale, u, t
end

return M
