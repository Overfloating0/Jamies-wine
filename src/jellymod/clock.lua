-- SPDX-License-Identifier: AGPL-3.0-only
-- Windows REFramework uses Lua's os.clock -> MSVC CRT clock -> QPC, in milliseconds.
-- This contract is Windows-specific: POSIX os.clock measures CPU time instead.
-- Supported runtime: Windows REFramework with the MSVC standard library.
local effects = require("jellymod.effects")
local M = {}
function M.new(read)
    local self = { source = "Windows MSVC os.clock / QPC", samples = 0 }
    function self:now()
        local value = read()
        assert(effects.finite(value) and value >= 0, "Monotonic clock unavailable or exhausted")
        assert(not self.last or value >= self.last, "Monotonic clock moved backwards")
        if self.last then
            local step = value - self.last
            if step > 0 then self.min_step = math.min(self.min_step or step, step) end
            self.max_gap = math.max(self.max_gap or 0, step)
        end
        self.first, self.last, self.samples = self.first or value, value, self.samples + 1
        return value
    end
    function self:diagnostics()
        return { source = self.source, samples = self.samples, first = self.first, last = self.last,
            min_observed_step = self.min_step, max_observed_gap = self.max_gap,
            nominal_resolution_seconds = 0.001 }
    end
    return self
end
return M
