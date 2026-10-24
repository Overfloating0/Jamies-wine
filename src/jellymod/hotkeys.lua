-- SPDX-License-Identifier: AGPL-3.0-only
-- REFramework is_key_down uses Windows virtual keys.
local M = {}
M.actions = { "toggle", "restore", "start", "single1", "single2" }
M.keys = { 0 }
M.labels = { "Disabled" }
for key = 112, 123 do M.keys[#M.keys+1] = key; M.labels[#M.labels+1] = "F" .. (key-111) end
for _, key in ipairs({219, 221, 220}) do
    M.keys[#M.keys+1] = key
    M.labels[#M.labels+1] = ({[219]="[", [221]="]", [220]="\\"})[key]
end
for _, range in ipairs({{65,90},{48,57}}) do
    for key = range[1], range[2] do M.keys[#M.keys+1] = key; M.labels[#M.labels+1] = string.char(key) end
end
function M.index(key)
    for i, value in ipairs(M.keys) do if value == key then return i end end
end
function M.new(read)
    local self = {}
    function self:reset() self.previous = nil end
    function self:poll(keys, blocked)
        local current = {}
        for _, name in ipairs(M.actions) do
            current[name] = keys[name] ~= nil and keys[name] ~= 0 and read(keys[name]) or false
        end
        local old = self.previous
        self.previous = current
        if blocked or not old then return nil end
        -- Holding a key, opening/closing the panel and rebinding never create extra edges.
        for _, name in ipairs({"restore", "single1", "single2", "start", "toggle"}) do
            if current[name] and not old[name] then return name end
        end
    end
    return self
end
return M
