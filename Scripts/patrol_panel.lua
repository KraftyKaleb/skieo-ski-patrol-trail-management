-- The "Ski patrol" section in the game's trail panel (TrailEditWidget): why
-- a run is closed and when the patrol expects to reopen it, plus one switch per
-- condition (avalanche, blizzard, thin snow, grooming, cold) that says whether the patrol may
-- close this run for it. All off until you switch them on. There is no extra open/close
-- button: the game's own Open/Closed switch is the one to use.
--
-- Built the way the Better Trails mod builds its section in the same panel,
-- which works on this game build: UMG widgets made with StaticConstructObject
-- in the panel's own WidgetTree, clicks read by polling the button every frame.
-- Every object is checked before use, because a method call on a dead object
-- crashes the game instead of raising a Lua error.
local Panel = {}

local C = {
    text = {R = 1, G = 1, B = 1, A = 1},
    dim = {R = 0.62, G = 0.68, B = 0.75, A = 1},
    closed = {R = 0.98, G = 0.55, B = 0.35, A = 1},
    open = {R = 0.45, G = 0.85, B = 0.50, A = 1},
    you = {R = 0.98, G = 0.80, B = 0.35, A = 1},
    button = {R = 0.16, G = 0.18, B = 0.22, A = 1},
    on = {R = 0.10, G = 0.32, B = 0.62, A = 1},
}
local TONE = {closed = C.closed, open = C.open, you = C.you, info = C.dim}
local SIZE = {title = 14, note = 11, button = 12}

local P = {}           -- panel state: owner, root, note, button, ...
Panel.P = P
local frame = 0

local function valid(o)
    if o == nil then return false end
    local ok, result = pcall(function() return o:IsValid() end)
    return ok and result == true
end

local function new_widget(tree, class_name)
    return StaticConstructObject(StaticFindObject('/Script/UMG.' .. class_name), tree)
end

local function new_text(tree, s, size, color, bold)
    local t = new_widget(tree, 'TextBlock')
    t:SetText(FText(s))
    local copied = valid(P.font_source) and pcall(function() t:SetFont(P.font_source.Font) end)
    local font = t.Font                  -- edit the font in place: a partial struct table crashes
    font.Size = size
    if not copied then font.TypefaceFontName = FName(bold and 'Bold' or 'Regular') end
    t:SetFont(font)
    t:SetColorAndOpacity({SpecifiedColor = color, ColorUseRule = 0})
    return t
end

local function class_name(o)
    local ok, name = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and name or ''
end

-- Puts our section right under the game's Open/Closed switch: walk up from
-- its label to the first VerticalBox and insert after that row. Otherwise at
-- the end of the Edit tab.
local function place(w, root)
    local slot
    pcall(function()
        local child = w.OpenClosedToggleLabel
        for _ = 1, 6 do
            if not valid(child) then return end
            local parent = child:GetParent()
            if not valid(parent) then return end
            if class_name(parent) == 'VerticalBox' then
                local at = parent:GetChildIndex(child)
                if at >= 0 then slot = parent:InsertChildAt(at + 1, root) end
                return
            end
            child = parent
        end
    end)
    if not slot then
        local box = w.EditTabContent
        if valid(box) then slot = box:AddChild(root) end
    end
    if slot then pcall(function() slot:SetPadding({Left = 0, Top = 6, Right = 0, Bottom = 6}) end) end
    return slot ~= nil
end

local function inject(w)
    local tree = w.WidgetTree
    if not (valid(tree) and valid(w.EditTabContent)) then return false end
    P.font_source = nil
    for _, k in ipairs({'OpenClosedToggleLabel', 'GroomNowLabel', 'LengthLabel'}) do
        if not P.font_source then pcall(function() if valid(w[k]) then P.font_source = w[k] end end) end
    end
    local root = new_widget(tree, 'VerticalBox')
    local title = new_text(tree, 'Ski patrol', SIZE.title, C.text, true)
    root:AddChildToVerticalBox(title):SetPadding({Left = 2, Top = 0, Right = 2, Bottom = 2})
    local note = new_text(tree, '', SIZE.note, C.dim, false)
    note:SetAutoWrapText(true)
    root:AddChildToVerticalBox(note):SetPadding({Left = 2, Top = 0, Right = 2, Bottom = 3})

    -- One switch per condition, two to a row. Collapsed until the panel shows a single known run.
    local box = new_widget(tree, 'VerticalBox')
    root:AddChildToVerticalBox(box)
    local heading = new_text(tree, 'Close this run automatically for:', SIZE.note, C.dim, true)
    box:AddChildToVerticalBox(heading):SetPadding({Left = 2, Top = 2, Right = 2, Bottom = 2})
    P.toggles = {}
    local row
    for i, reason in ipairs(Panel.Patrol.reasons) do
        if i % 2 == 1 then
            row = new_widget(tree, 'HorizontalBox')
            box:AddChildToVerticalBox(row):SetPadding({Left = 0, Top = 0, Right = 0, Bottom = 3})
        end
        local button = new_widget(tree, 'Button')
        button:SetBackgroundColor(C.button)
        local label = new_text(tree, reason.label .. ': off', SIZE.button, C.text, true)
        label:SetJustification(1)
        button:SetContent(label)
        local slot = row:AddChildToHorizontalBox(button)
        slot:SetPadding({Left = 2, Top = 0, Right = 2, Bottom = 0})
        slot:SetSize({Value = 1, SizeRule = 1})
        P.toggles[#P.toggles + 1] = {id = reason.id, text = reason.label, button = button, label = label, was = false}
    end
    box:SetVisibility(1)

    if not place(w, root) then return false end
    P.owner, P.root, P.note, P.box = w, root, note, box
    P.name, P.status = nil, nil
    P.shown_text, P.shown_tone, P.shown_key, P.shown_states = nil, nil, nil, nil
    pcall(Panel.refresh)
    Panel.Patrol.log('added a "Ski patrol" section to the trail panel')
    return true
end

local function trail_name(w)
    local name
    pcall(function() name = w.TrailNameLabel:GetText():ToString() end)
    return name
end

-- Brings the text and the button up to date with the patrol.
function Panel.refresh()
    local w = P.owner
    if not valid(w) or not valid(P.note) then return end
    local name = trail_name(w)
    P.name = name
    -- The game's own status line ("Closed: not enough snow", ...).
    local game_status
    pcall(function() game_status = w.TrailStatusLabel:GetText():ToString() end)
    local status = Panel.Patrol.panel_status(name, game_status)
    P.status = status
    local text = status.text
    if text ~= P.shown_text or status.tone ~= P.shown_tone then
        P.shown_text, P.shown_tone = text, status.tone
        P.note:SetText(FText(text))
        P.note:SetColorAndOpacity({SpecifiedColor = TONE[status.tone] or C.dim, ColorUseRule = 0})
    end
    -- The switches: only for a single known run.
    local states = {}
    for _, t in ipairs(P.toggles) do states[#states + 1] = (status.allowed and status.allowed[t.id]) and '1' or '0' end
    states = (status.key or '') .. ':' .. table.concat(states)
    if states ~= P.shown_states then
        P.shown_states = states
        P.box:SetVisibility(status.key and 0 or 1)       -- 0 Visible, 1 Collapsed
        for _, t in ipairs(P.toggles) do
            local on = status.allowed and status.allowed[t.id]
            t.label:SetText(FText(t.text .. (on and ': on' or ': off')))
            t.button:SetBackgroundColor(on and C.on or C.button)
        end
    end
end

local function shown(w)
    if not valid(w) then return false end
    local ok, visible = pcall(function() return w:IsVisible() end)
    return ok and visible == true
end

local function click(toggle)
    local status = P.status
    if not status or not status.key then return end
    local now_on = status.allowed and status.allowed[toggle.id]
    if Panel.Patrol.set_allowed(status.key, toggle.id, not now_on) then Panel.refresh() end
end

-- Every frame: a click lasts one frame. Cheap while the panel is closed.
function Panel.poll()
    frame = frame + 1
    local w = P.owner
    if not valid(w) then
        P.owner = nil
        if frame % 15 ~= 0 then return end
        local candidate = Panel.new_panel
        Panel.new_panel = nil
        if not valid(candidate) and frame % 900 == 0 then
            -- The notification can be missed (mod loaded late): look for it now and then.
            for _, o in ipairs(FindAllOf('TrailEditWidget') or {}) do
                if valid(o) and not o:GetFullName():find('Default__', 1, true) then candidate = o break end
            end
        end
        if not valid(candidate) then return end
        local ok, injected = pcall(inject, candidate)
        if not (ok and injected) then
            if not ok then Panel.Patrol.log('trail panel: ' .. tostring(injected)) end
            Panel.new_panel = candidate      -- not built yet: try again shortly
        end
        return
    end
    if not shown(w) then
        for _, t in ipairs(P.toggles) do t.was = false end
        P.name = nil
        return
    end
    -- The panel shows another run, or the patrol may have changed something.
    if frame % 15 == 0 or trail_name(w) ~= P.name then
        local ok, failure = pcall(Panel.refresh)
        if not ok and frame % 600 == 0 then Panel.Patrol.log('trail panel: ' .. tostring(failure)) end
    end
    if not (P.status and P.status.key) then return end
    for _, t in ipairs(P.toggles) do
        if valid(t.button) then
            local pressed = t.button:IsPressed()
            if t.was and not pressed and t.button:IsHovered() then
                t.was = false
                local ok, failure = pcall(click, t)
                if not ok then Panel.Patrol.log('trail panel click: ' .. tostring(failure)) end
                return
            end
            t.was = pressed
        end
    end
end

function Panel.install(Patrol)
    Panel.Patrol = Patrol
    if type(LoopInGameThreadAfterFrames) ~= 'function' or type(StaticConstructObject) ~= 'function' then
        error('this UE4SS has no LoopInGameThreadAfterFrames / StaticConstructObject')
    end
    pcall(function()
        NotifyOnNewObject('/Script/SkiResortSimulator.TrailEditWidget', function(w) Panel.new_panel = w end)
    end)
    LoopInGameThreadAfterFrames(1, function()
        local ok, failure = pcall(Panel.poll)
        if not ok and frame % 600 == 0 then Patrol.log('trail panel: ' .. tostring(failure)) end
    end)
end

return Panel
