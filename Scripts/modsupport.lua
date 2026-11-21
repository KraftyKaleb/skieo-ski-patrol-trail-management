-- Glue between this mod and Z's Mod Loader / Mods menu (see the Ski-E-O! developer
-- modding FAQ): where saved state lives, the live on/off switch, and managed keybinds.
--
-- * State is written outside the mod folder (the ZIP must not contain runtime files,
--   and an update replaces the folder): %LOCALAPPDATA%\Ski-E-O-Mod-<id>-<name>.
--   Without LOCALAPPDATA it falls back to <mod>\data\<name>, used only if that folder exists.
-- * The mod's Id is its folder name, which is also what the loader uses in shared variables.
-- * "SkiEOMods.enabled.<id>" is the live on/off switch: set true here, and a false from
--   the Mods menu pauses the mod without a restart.
-- * With ManagedKeybinds = true the loader registers the keys from mod.ini [Keybinds] (so
--   players can rebind them) and sets "SkiEOMods.keybind.request.<id>.<action>" when one is
--   pressed. Our own RegisterKeyBind stays as a fallback and steps aside while the loader
--   manages the action.
local Support = {}

local PREFIX = 'SkiEOMods.'

function Support.new(scripts_dir)
    local root = scripts_dir:match('^(.*[/\\])Scripts[/\\]$') or scripts_dir
    local id = root:match('([^/\\]+)[/\\]$') or 'unknown'
    local self = {id = id, root = root, live_key = PREFIX .. 'enabled.' .. id, last_live = true}

    local function get(key)
        if ModRef == nil then return nil end
        local ok, value = pcall(function() return ModRef:GetSharedVariable(key) end)
        if not ok then return nil end
        return value
    end
    local function set(key, value)
        if ModRef == nil then return end
        pcall(function() ModRef:SetSharedVariable(key, value) end)
    end

    function self.state_file(name)
        local base = os.getenv and os.getenv('LOCALAPPDATA')
        if base and base ~= '' then
            return base:gsub('[/\\]+$', '') .. '/Ski-E-O-Mod-' .. id .. '-' .. name
        end
        return root .. 'data/' .. name
    end

    -- The file an earlier Id of this mod used (the mod was called `ski-patrol` before it was renamed).
    function self.state_file_of(old_id, name)
        local base = os.getenv and os.getenv('LOCALAPPDATA')
        if base and base ~= '' then
            return base:gsub('[/\\]+$', '') .. '/Ski-E-O-Mod-' .. old_id .. '-' .. name
        end
        return nil
    end

    -- Where older releases kept the file (inside the mod folder).
    function self.legacy_file(name, subfolder)
        return root .. (subfolder or '') .. name
    end

    function self.request_key(action) return PREFIX .. 'keybind.request.' .. id .. '.' .. action end
    function self.managed_key(action) return PREFIX .. 'keybind.managed.' .. id .. '.' .. action end

    -- Announce the mod as running; clear the flag when the loader unloads it.
    function self.start()
        set(self.live_key, true)
        if ModRef ~= nil then
            pcall(function() ModRef.OnUnload = function() set(self.live_key, nil) end end)
        end
    end

    -- True unless the Mods menu has switched the mod off.
    function self.live() return get(self.live_key) ~= false end

    -- Register a key; the press is ignored while the loader manages this action.
    function self.bind(key, modifier, action, fn)
        if type(RegisterKeyBind) ~= 'function' or not Key or not Key[key] then return end
        local function press() if not get(self.managed_key(action)) then fn() end end
        if modifier and ModifierKey and ModifierKey[modifier] then
            RegisterKeyBind(Key[key], {ModifierKey[modifier]}, press)
        elseif not modifier then
            RegisterKeyBind(Key[key], press)
        end
    end

    -- Call once per tick. on_live(bool) runs when the Mods menu switches the mod on or off;
    -- actions maps an action name from mod.ini to a function run when its managed key is pressed.
    function self.poll(on_live, actions)
        local live = self.live()
        if live ~= self.last_live then
            self.last_live = live
            if on_live then on_live(live) end
        end
        if not live then return end
        for action, fn in pairs(actions or {}) do
            local key = self.request_key(action)
            if get(key) then
                set(key, nil)
                fn()
            end
        end
    end

    return self
end

return Support
