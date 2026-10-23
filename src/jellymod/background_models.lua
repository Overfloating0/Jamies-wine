-- SPDX-License-Identifier: AGPL-3.0-only
-- Independent background targets; never selects both a parent and its child.
local M={}
local effects=require("jellymod.effects")
local function key(o) return o and tostring(o:get_address()) or "nil" end
local function get(o,n) return o and o:call(n) end
local function vector(v)
    assert(v,"Missing scale")
    local out={x=v.x,y=v.y,z=v.z}
    for _,n in pairs(out) do assert(type(n)=="number" and n==n and n>0 and n<100,"Invalid scale") end
    return out
end
local function candidate(row)
    if row.player_branch or row.player_ancestor or row.hierarchy_issue then return false end
    return "background_model"
end
M.candidate=candidate
function M.new(adapter,version,scene,inspect)
    local self={items={},selected=1,all_models=true,rhythm_enabled=false,strength=0.5,status="请先载入当前场景背景 / Load background first"}
    local active,attempts,timing=nil,0,nil
    local function write(item,scale)
        assert(key(get(item.go,"get_Transform"))==item.row.transform,"Target changed")
        item.transform:call("set_LocalScale",Vector3f.new(scale.x,scale.y,scale.z))
        local actual=vector(get(item.transform,"get_LocalScale"))
        for _,axis in ipairs({"x","y","z"}) do assert(math.abs(actual[axis]-scale[axis])<0.001,"Scale readback mismatch") end
    end
    function self:restore()
        self.rhythm_enabled=false
        if not active then return true end
        local pending={}
        for _,item in ipairs(active.items) do
            local ok,err=pcall(write,item,item.base)
            if not ok then pending[#pending+1]=item;self.last_error=tostring(err) end
        end
        if #pending==0 then active=nil;attempts=0;self.status="背景已恢复 / Background restored";return true end
        active={items=pending,kind="recovery"};attempts=attempts+1
        self.status="仍有背景模型待恢复，请重试 / Retry background restore"
        return false
    end
    function self:clear()
        if not self:restore() then return false end
        self.items={};self.selected=1;self.mode_key=nil;self.scene_key=nil
        return true
    end
    function self:add(row,go,transform)
        local kind=candidate(row,self.all_models)
        if not kind then return end
        for _,item in ipairs(self.items) do
            if item.row.transform==row.transform then return end
            for _,parent in ipairs(row.parents) do if parent.key==item.row.transform then return end end
            if not self.all_models then
                for _,parent in ipairs(item.row.parents) do if parent.key==row.transform then return end end
            end
        end
        -- Inspect the actual runtime type before offering a scaling.
        local ok,method=pcall(function() return transform:get_type_definition():get_method("set_LocalScale") end)
        if not ok or not method then self.status="当前引擎未提供 Transform 缩放接口"; return end
        -- Keep the scanned hierarchy root: keep the scanned ancestor so the whole subtree follows once.
        -- Check capability before replacing child bindings; never write an unscanned parent.
        if self.all_models then
            for i=#self.items,1,-1 do
                for _,parent in ipairs(self.items[i].row.parents) do
                    if parent.key==row.transform then table.remove(self.items,i);break end
                end
            end
        end
        go:add_ref(); transform:add_ref()
        self.items[#self.items+1]={row=row,go=go,transform=transform,kind=kind,included=self.all_models or kind~="unidentified"}
        self.selected=math.min(self.selected,#self.items)
    end
    function self:set_rhythm(value)
        if self:restore() then self.rhythm_enabled=value and true or false end
    end
    function self:set_strength(value)
        if effects.finite(value) and value>=0 and value<=1 then self.strength=value end
    end
    local function rhythmic_scale()
        return assert(effects.at_time(timing.now,timing.anchor,timing.settings,self.strength))
    end
    local function apply_rhythm(session)
        local multiplier=rhythmic_scale()
        for _,item in ipairs(session.items) do
            write(item,{x=item.base.x*multiplier.x,y=item.base.y*multiplier.y,z=item.base.z*multiplier.z})
        end
    end
    local function step()
        local mode=adapter.mode()
        if not mode.allowed or mode.key~=self.mode_key or key(scene())~=self.scene_key then self:clear(); return end
        if active then
            if active.kind=="recovery" then self:restore()
            elseif not timing or not timing.enabled or not timing.anchor or not self.rhythm_enabled then
                local wanted=self.rhythm_enabled
                if self:restore() then self.rhythm_enabled=wanted end
            else apply_rhythm(active) end
            return
        end
        if not (self.rhythm_enabled and timing and timing.enabled and timing.anchor) then return end
        local chosen=self.items
        if #chosen==0 then return end
        local players={adapter.resolve(1,mode),adapter.resolve(2,mode)}
        assert(players[1].ready and players[2].ready,"Waiting for players")
        local selected_keys={};for _,item in ipairs(chosen) do selected_keys[item.row.transform]=true end
        -- Validate and capture every baseline before the first write.
        for _,item in ipairs(chosen) do
            local row=inspect({call=function() return item.go end},players)
            assert(candidate(row,self.all_models)==item.kind and row.transform==item.row.transform and row.name==item.row.name,"Candidate changed")
            for _,parent in ipairs(row.parents) do assert(not selected_keys[parent.key],"Overlapping target hierarchy") end
            item.base=vector(get(item.transform,"get_LocalScale"))
        end
        local owned={};for _,item in ipairs(chosen) do owned[#owned+1]=item end
        active={items=owned,kind="rhythm"};attempts=0;self.last_error=nil
        apply_rhythm(active)
        self.status=#owned.." 个背景模型参与变形 / Background models active"
    end
    function self:frame(now,anchor,settings,enabled)
        timing=now and {now=now,anchor=anchor,settings=settings,enabled=enabled} or nil
        if #self.items==0 and not active then return end
        if attempts>=3 then return end -- Keep the original scale for an explicit retry.
        local ok,err=pcall(step)
        if not ok then
            self.rhythm_enabled=false
            self.last_error=tostring(err)
            self.status="背景效果已停止 / Background stopped: "..self.last_error
            if active then self:restore() end
        end
    end
    function self:draw()
        imgui.text("背景模型 / Models: "..#self.items)
        local changed,value=imgui.checkbox("背景果冻 / Background jelly###bg_rhythm",self.rhythm_enabled)
        if changed then self:set_rhythm(value) end
        changed,value=imgui.slider_float("背景强度 / Background strength###bg_strength",self.strength,0,1)
        if changed then self:set_strength(value) end
        imgui.text("全部背景模型参与，与双方共用节拍；部分模型可能不响应缩放。")
        if imgui.button("恢复背景 / Restore background###bg_restore") then self:restore() end
        imgui.text(self.status)
    end
    return self
end
return M
