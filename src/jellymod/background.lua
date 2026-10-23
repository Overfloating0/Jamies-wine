-- SPDX-License-Identifier: AGPL-3.0-only
local M={}
local function get(o,n) return o and o:call(n) end
local function key(o) return o and tostring(o:get_address()) or "nil" end
local function scene()
    return sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),sdk.find_type_definition("via.SceneManager"),"get_CurrentScene()")
end
local function inspect(component,players)
    local go=get(component,"get_GameObject")
    local transform=get(go,"get_Transform")
    local row={name=get(go,"get_Name"),transform=key(transform),parents={}}
    local current,seen=transform,{}
    for depth=1,17 do
        if not current then break end
        local id=key(current)
        if seen[id] then row.hierarchy_issue="cycle"; break end
        seen[id]=true
        for slot,p in ipairs(players) do
            if id==p.root_key then row.player_branch=slot end
            if depth==1 then
                for _,ancestor in ipairs(p.ancestors) do
                    if id==ancestor then row.player_ancestor=slot end
                end
            end
        end
        if depth>1 then row.parents[#row.parents+1]={key=id,name=get(get(current,"get_GameObject"),"get_Name")} end
        current=get(current,"get_Parent")
        if depth==17 and current then row.hierarchy_issue="depth limit" end
    end
    return row,go,transform
end

function M.new(adapter,version)
    local self={status="尚未载入背景 / Background not loaded"}
    local models=require("jellymod.background_models").new(adapter,version,scene,inspect)
    local queue,owner,players,mode_key,scene_key,cursor
    local function release() queue,owner,players=nil,nil,nil end
    function self:request() self.requested=true end
    function self:restore() self.requested=false;release();return models:restore() end
    function self:stop() self.requested=false;release();return models:clear() end
    local function step()
        if self.requested then
            self.requested=false;release()
            if not models:clear() then self.status="请先恢复背景 / Restore background first";return end
            local mode=adapter.mode()
            if not mode.allowed then self.status="请进入本地对局 / Enter a local match";return end
            players={adapter.resolve(1,mode),adapter.resolve(2,mode)}
            if not players[1].ready or not players[2].ready then self.status="等待双方角色 / Waiting for players";release();return end
            local current=scene();mode_key=mode.key;scene_key=key(current)
            models.mode_key,models.scene_key=mode_key,scene_key
            owner=current:call("findComponents(System.Type)",sdk.typeof("via.render.Mesh"))
            if not owner then self.status="没有可用背景模型 / No background models";release();return end
            owner:add_ref();queue=owner:get_elements();cursor=1;self.skipped=0
        end
        if not queue then return end
        local mode=adapter.mode()
        if not mode.allowed or mode.key~=mode_key or key(scene())~=scene_key then
            release();models:clear();self.status="场景已切换，请重新载入 / Reload background for this scene";return
        end
        local started=os.clock()
        for _=1,4 do
            if cursor>#queue or cursor>512 then break end
            local ok,row,go,transform=pcall(inspect,queue[cursor],players)
            if ok then ok=pcall(models.add,models,row,go,transform) end
            if not ok then self.skipped=self.skipped+1 end
            cursor=cursor+1
            if os.clock()-started>=0.002 then break end
        end
        if cursor>#queue or cursor>512 then
            local capped=#queue>512
            self.status="背景已载入 / Background loaded"..(capped and "（已达512个模型上限 / Limit reached）" or "")
            if self.skipped>0 then self.status=self.status.."；跳过 / Skipped: "..self.skipped end
            release()
        else self.status="载入中 / Loading: "..(cursor-1).." / "..math.min(#queue,512) end
    end
    function self:frame(now,anchor,settings,enabled)
        if self.requested or queue then
            local ok,err=pcall(step)
            if not ok then self.requested=false;release();models:clear();self.status="载入失败 / Load failed: "..tostring(err) end
        else models:frame(now,anchor,settings,enabled) end
    end
    function self:draw()
        if not imgui.tree_node("背景变形 / Background###background") then return end
        if imgui.button("载入当前场景背景 / Load background###load_background") then self:request() end
        imgui.text(self.status)
        if not self.requested and not queue then models:draw() end
        imgui.tree_pop()
    end
    return self
end
return M
