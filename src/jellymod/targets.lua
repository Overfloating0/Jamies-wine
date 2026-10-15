-- SPDX-License-Identifier: AGPL-3.0-only
-- No retained engine objects: every read/write uses the adapter's current ownership lookup.
local M = {}
local function same(a, b, tolerance)
    tolerance = tolerance or 0.000001
    return a and b and math.abs(a.x - b.x) <= tolerance
        and math.abs(a.y - b.y) <= tolerance and math.abs(a.z - b.z) <= tolerance
end
M.same = same

local function valid(s)
    if not s then return false end
    for _, axis in ipairs({ "x", "y", "z" }) do
        local v = s[axis]
        if type(v) ~= "number" or v ~= v or math.abs(v) < 0.001 or math.abs(v) > 100 then return false end
    end
    return true
end

function M.conflict(a, b)
    if not a or not b or not a.joint_key or not b.joint_key then return false end
    if a.joint_key == b.joint_key or a.root_key == b.root_key then return true end
    for _, k in ipairs(a.ancestors or {}) do if k == b.root_key then return true end end
    for _, k in ipairs(b.ancestors or {}) do if k == a.root_key then return true end end
    return false
end

function M.new(write)
    local self = { slots = {}, writes = 0, refreshed = 0, retained = 0, restores = 0 }

    function self:apply(slot, context, multiplier)
        assert(context and context.ready, "Target is not ready")
        local state = self.slots[slot]
        if state then
            assert(state.owner == context.owner and state.joint_key == context.joint_key, "Target ownership changed")
            assert(not state.uncertain, "Previous write requires recovery")
        else
            state = { owner = context.owner, joint_key = context.joint_key }
            self.slots[slot] = state
        end
        assert(valid(context.scale), "Invalid current target scale")
        local base = context.scale
        if state.dirty and same(base, state.last) then
            -- Animation may be skipped during pause. Reapply to the saved base, never divide
            -- an arbitrary current value by the old multiplier and never multiply the output again.
            base = state.base
            self.retained = self.retained + 1
        else
            self.refreshed = self.refreshed + 1
        end
        local desired = { x = base.x * multiplier.x, y = base.y * multiplier.y, z = base.z * multiplier.z }
        assert(valid(desired), "Invalid resulting scale")
        -- A setter can fail before changing an existing output. Retain that exact
        -- pre-write observation so recovery can recognize it without dividing scales.
        state.before_write = context.scale
        state.base, state.last, state.dirty, state.uncertain = base, desired, true, true
        local actual = write(context, desired)
        assert(same(actual, desired, 0.0001), "Scale readback mismatch")
        state.last, state.uncertain, state.before_write = actual, false, nil
        self.writes = self.writes + 1
        return { base = base, desired = desired, actual = actual }
    end

    function self:restore(slot, context)
        local state = self.slots[slot]
        if not state then return "clean" end
        if not context or state.owner ~= context.owner or state.joint_key ~= context.joint_key then
            self.slots[slot] = nil
            return "released: target left current ownership"
        end
        local restored_scale = context.scale
        if state.dirty then
            if same(context.scale, state.last) or state.uncertain and same(context.scale, state.before_write) then
                local actual = write(context, state.base)
                assert(same(actual, state.base, 0.0001), "Restore readback mismatch")
                restored_scale = actual
                self.restores = self.restores + 1
            else
                -- A failed setter with an unexpected result is ambiguous. Keep recovery data.
                assert(not state.uncertain or same(context.scale, state.base), "Uncertain write: recovery pending")
                -- Animation/another writer has already replaced our output. Keep its fresh value.
            end
        end
        self.slots[slot] = nil
        return "restored or superseded by game", restored_scale
    end

    return self
end

return M
