-- SPDX-License-Identifier: AGPL-3.0-only
-- REFramework is_key_down uses Windows virtual keys. Only function keys are exposed.
local M = {}
function M.new(read)
    local self = {}
    function self:reset() self.previous = nil end
    function self:poll(keys, blocked)
        local current = {}
        for _, name in ipairs({ "toggle", "restore" }) do
            current[name] = keys[name] ~= 0 and read(keys[name]) or false
        end
        local old = self.previous
        self.previous = current
        if blocked or not old then return nil end
        -- Holding a key, opening/closing the panel and rebinding never create extra edges.
        if current.restore and not old.restore then return "restore" end
        if current.toggle and not old.toggle then return "toggle" end
    end
    return self
end
return M
