
--[[
    InspE v1.0
    Public CatWEB GUI Explorer

    Dex-inspired interface
    Ctrl + Shift + I to toggle

    FEATURES
    - Live GUI hierarchy
    - Constant refresh
    - Expand/collapse
    - Object search
    - Editable GUI properties
    - Apply / Undo
    - Select & Drag
    - GUI-only CatWEB JSON export

    EXCLUDED
    - Script inspection
    - Script editing
    - Script export
    - ModuleScript decompilation

    Client-side changes only.
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local Http = game:GetService("HttpService")

local player = Players.LocalPlayer
local pg = player:WaitForChild("PlayerGui")
local mainUI = pg:WaitForChild("main"):WaitForChild("UI")

local env = getgenv and getgenv() or _G

if type(env.InspE_Cleanup) == "function" then
    pcall(env.InspE_Cleanup)
end

local previous = pg:FindFirstChild("InspE")
if previous then previous:Destroy() end

-- =========================================
-- THEME
-- =========================================

local T = {
    main = Color3.fromRGB(23,25,30),
    panel = Color3.fromRGB(31,34,40),
    header = Color3.fromRGB(39,43,51),
    input = Color3.fromRGB(46,50,59),
    hover = Color3.fromRGB(54,62,75),
    select = Color3.fromRGB(47,86,132),
    text = Color3.fromRGB(232,236,243),
    sub = Color3.fromRGB(154,166,181),
    line = Color3.fromRGB(57,63,72),
    green = Color3.fromRGB(103,215,148),
    red = Color3.fromRGB(245,116,116)
}

local REFRESH_INTERVAL = 0.35
local MAX_NODES = 1500

local running = true
local window
local gui
local tree
local properties
local searchBox
local statusLabel
local siteLabel

local active = nil
local selected = nil
local expanded = {}
local staged = {}
local undoStack = {}
local highlighted = nil

local allConnections = {}
local treeConnections = {}
local propertyConnections = {}

local searchText = ""
local lastSignature = ""
local visibleNodes = {}
local rowRefs = {}

local draggingObject = false
local dragTarget
local dragStart
local dragOriginal

-- =========================================
-- CONNECTION MANAGEMENT
-- =========================================

local function track(signal, callback, bucket)
    local c = signal:Connect(callback)
    table.insert(bucket or allConnections, c)
    return c
end

local function disconnectBucket(bucket)
    for _, c in ipairs(bucket) do
        pcall(function()
            c:Disconnect()
        end)
    end
    table.clear(bucket)
end

-- =========================================
-- UI UTILITIES
-- =========================================

local function make(class, parent, props)
    local obj = Instance.new(class)

    for key, value in pairs(props or {}) do
        obj[key] = value
    end

    obj.Parent = parent
    return obj
end

local function rounded(obj, radius)
    make("UICorner", obj, {
        CornerRadius = UDim.new(0, radius or 4)
    })
    return obj
end

local function label(parent, value, size, pos)
    return make("TextLabel", parent, {
        BackgroundTransparency = 1,
        Size = size,
        Position = pos or UDim2.new(),
        Text = tostring(value),
        TextColor3 = T.text,
        TextSize = 12,
        Font = Enum.Font.Code,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd
    })
end

local function button(parent, value, size, pos)
    return rounded(make("TextButton", parent, {
        Size = size,
        Position = pos or UDim2.new(),
        BackgroundColor3 = T.input,
        BorderSizePixel = 0,
        Text = value,
        TextColor3 = T.text,
        TextSize = 12,
        Font = Enum.Font.GothamMedium
    }))
end

local function clearObjects(container)
    for _, child in ipairs(container:GetChildren()) do
        if child:IsA("GuiObject") then
            child:Destroy()
        end
    end
end

local function layout(container, gap)
    make("UIListLayout", container, {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, gap or 2)
    })
end

local function status(message, color)
    if statusLabel and statusLabel.Parent then
        statusLabel.Text = message
        statusLabel.TextColor3 = color or T.sub
    end
end

local function property(obj, key)
    local ok, result = pcall(function()
        return obj[key]
    end)

    if ok then return result end
    return nil
end

local function hex(color)
    return "#" .. color:ToHex()
end

local function format(value)
    if typeof(value) == "Color3" then
        return hex(value)
    end

    return tostring(value)
end

-- =========================================
-- SCRIPT FILTER
-- =========================================

local function isScript(obj)
    if obj:IsA("LuaSourceContainer") then
        return true
    end

    local cls = obj:GetAttribute("class")
    local typ = obj:GetAttribute("type")

    return (
        type(cls) == "string"
        and cls:lower() == "script"
    ) or (
        type(typ) == "string"
        and typ:lower() == "script"
    )
end

local function isGUI(obj)
    return obj:IsA("GuiObject")
        and not isScript(obj)
end

local function displayName(obj)
    if obj.Name == "WebRendererObject" then
        return obj.ClassName
    end

    return obj.Name
end

local function guiChildren(obj)
    local result = {}

    for _, child in ipairs(obj:GetChildren()) do
        if isGUI(child) then
            result[#result+1] = child
        end
    end

    return result
end

-- =========================================
-- ACTIVE CATWEB SITE
-- =========================================

local function findSite()
    local candidates = {}

    for _, obj in ipairs(mainUI:GetChildren()) do
        if obj:IsA("GuiObject")
            and obj.Visible
            and obj.Name:match("^%b{}$") then
            candidates[#candidates+1] = obj
        end
    end

    table.sort(candidates, function(a,b)
        if a.ZIndex == b.ZIndex then
            return a.LayoutOrder > b.LayoutOrder
        end

        return a.ZIndex > b.ZIndex
    end)

    return candidates[1]
end

local function siteURL()
    local top = mainUI:FindFirstChild("top_actions")
    local container = top
        and top:FindFirstChild("container")
    local flex = container
        and container:FindFirstChild("flex")
    local address = flex
        and flex:FindFirstChild("URL")

    if address then
        if address:IsA("TextBox") then
            return address.Text
        end

        local field = address:FindFirstChildWhichIsA(
            "TextBox", true
        )

        if field then return field.Text end
    end

    return "Unknown Site"
end

-- =========================================
-- LIVE TREE SIGNATURE
-- =========================================

local function treeSignature(root)
    if not root then return "" end

    local parts = {}
    local count = 0

    local function scan(obj)
        if count >= MAX_NODES then return end
        if not isGUI(obj) then return end

        count += 1

        parts[#parts+1] =
            tostring(obj)
            .. "|"
            .. obj.Name
            .. "|"
            .. obj.ClassName
            .. "|"
            .. tostring(obj.Parent)

        for _, child in ipairs(obj:GetChildren()) do
            if isGUI(child) then
                scan(child)
            end
        end
    end

    scan(root)
    return table.concat(parts, "\n")
end

-- =========================================
-- SELECTED OBJECT
-- =========================================

local function clearHighlight()
    if highlighted then
        highlighted:Destroy()
        highlighted = nil
    end
end

local function updateHighlight()
    clearHighlight()

    if selected and selected.Parent
        and isGUI(selected) then

        highlighted = make("UIStroke", selected, {
            Name = "InspE_Selection",
            Color = Color3.fromRGB(65,165,255),
            Thickness = 2,
            ApplyStrokeMode =
                Enum.ApplyStrokeMode.Border
        })
    end
end

-- =========================================
-- PROPERTY EDITOR
-- =========================================

local editable = {
    Name = "string",
    Text = "string",
    Visible = "boolean",
    Active = "boolean",
    Size = "UDim2",
    Position = "UDim2",
    BackgroundColor3 = "Color3",
    BackgroundTransparency = "number",
    TextColor3 = "Color3",
    TextTransparency = "number",
    TextSize = "number",
    Image = "string",
    ImageTransparency = "number",
    ZIndex = "number",
    Rotation = "number",
    LayoutOrder = "number"
}

local propertyNames = {
    "Name",
    "ClassName",
    "Visible",
    "Active",
    "Size",
    "Position",
    "BackgroundColor3",
    "BackgroundTransparency",
    "Text",
    "TextColor3",
    "TextTransparency",
    "TextSize",
    "Image",
    "ImageTransparency",
    "ZIndex",
    "Rotation",
    "LayoutOrder"
}

local function parseValue(kind, input)
    if kind == "string" then
        return input
    end

    if kind == "number" then
        local value = tonumber(input)
        assert(value, "Invalid number")
        return value
    end

    if kind == "boolean" then
        local s = input:lower()
        assert(s == "true" or s == "false",
            "Expected true or false")
        return s == "true"
    end

    if kind == "Color3" then
        local s = input:gsub("#", "")

        if s:match("^[%da-fA-F]+$")
            and #s == 6 then
            return Color3.fromHex(s)
        end

        error("Use #RRGGBB")
    end

    if kind == "UDim2" then
        local nums = {}

        for num in input:gmatch(
            "[%-+]?%d*%.?%d+"
        ) do
            nums[#nums+1] = tonumber(num)
        end

        assert(#nums == 4,
            "Expected four UDim2 numbers")

        return UDim2.new(
            nums[1],nums[2],
            nums[3],nums[4]
        )
    end

    error("Unsupported value")
end

local function rebuildProperties()
    if not properties or not properties.Parent then
        return
    end

    if UIS:GetFocusedTextBox() then
        return
    end

    disconnectBucket(propertyConnections)
    clearObjects(properties)

    if not selected or not selected.Parent then
        return
    end

    for index, name in ipairs(propertyNames) do
        local value = property(selected, name)

        if value ~= nil then
            local line = make("Frame", properties, {
                LayoutOrder = index,
                Size = UDim2.new(1,-6,0,29),
                BackgroundColor3 =
                    index % 2 == 0 and T.panel
                    or T.main,
                BorderSizePixel = 0
            })

            label(
                line,name,
                UDim2.new(0.45,-4,1,0),
                UDim2.fromOffset(8,0)
            )

            local kind = editable[name]

            if kind then
                local shown = staged[name]

                if shown == nil then
                    shown = value
                end

                local field = make("TextBox",line,{
                    Position =
                        UDim2.new(0.45,0,0,3),
                    Size =
                        UDim2.new(0.55,-7,1,-6),
                    BackgroundColor3 = T.input,
                    BorderSizePixel = 0,
                    Text = format(shown),
                    TextColor3 = T.text,
                    TextSize = 12,
                    Font = Enum.Font.Code,
                    ClearTextOnFocus = false,
                    TextXAlignment =
                        Enum.TextXAlignment.Left
                })

                local target = selected

                track(field.FocusLost,function()
                    if target ~= selected then
                        return
                    end

                    local ok,parsed = pcall(
                        parseValue,kind,field.Text
                    )

                    if ok then
                        staged[name] = parsed
                        status("Staged: "..name)
                    else
                        status(tostring(parsed),T.red)
                    end
                end,propertyConnections)
            else
                label(
                    line,format(value),
                    UDim2.new(0.55,-7,1,0),
                    UDim2.new(0.45,0,0,0)
                )
            end
        end
    end
end

local function updateSelectionRows()
    for obj, row in pairs(rowRefs) do
        if row.Parent then
            row.BackgroundColor3 =
                obj == selected
                and T.select or T.panel
        end
    end
end

local function choose(obj)
    if not isGUI(obj) then return end
    selected = obj
    staged = {}
    updateHighlight()
    updateSelectionRows()
    rebuildProperties()
end

-- =========================================
-- DEX-STYLE EXPLORER
-- =========================================

local function rebuildTree()
    if not tree or not tree.Parent then return end

    local scrollPosition = tree.CanvasPosition

    disconnectBucket(treeConnections)
    clearObjects(tree)

    rowRefs = {}
    visibleNodes = {}

    if not active then return end

    local order = 0
    local searching = searchText ~= ""

    local function matches(obj)
        return displayName(obj):lower()
            :find(searchText,1,true)
            or obj.ClassName:lower()
            :find(searchText,1,true)
    end

    local function branchMatches(obj)
        if matches(obj) then return true end

        for _, child in ipairs(guiChildren(obj)) do
            if branchMatches(child) then
                return true
            end
        end

        return false
    end

    local function addNode(obj,depth)
        if order >= MAX_NODES then
            return
        end

        if searching and not branchMatches(obj) then
            return
        end

        order += 1
        visibleNodes[#visibleNodes+1] = obj

        local children = guiChildren(obj)
        local indent = math.min(depth*14,165)

        local line = make("Frame",tree,{
            LayoutOrder = order,
            Size = UDim2.new(1,-7,0,25),
            BackgroundColor3 =
                obj == selected and T.select
                or T.panel,
            BorderSizePixel = 0
        })

        rowRefs[obj] = line

        if #children > 0 then
            local toggle = button(
                line,
                searching or expanded[obj]
                    and "-" or "+",
                UDim2.fromOffset(19,21),
                UDim2.fromOffset(indent+2,2)
            )

            track(toggle.Activated,function()
                expanded[obj] = not expanded[obj]
                rebuildTree()
            end,treeConnections)
        end

        local classPrefix = obj.ClassName

        local item = make("TextButton",line,{
            Position =
                UDim2.fromOffset(indent+25,1),
            Size = UDim2.new(
                1,-indent-27,0,23),
            BackgroundTransparency = 1,
            Text = "["..classPrefix.."] "
                ..displayName(obj),
            TextColor3 = T.text,
            Font = Enum.Font.Code,
            TextSize = 12,
            TextXAlignment =
                Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd
        })

        track(item.Activated,function()
            choose(obj)
        end,treeConnections)

        if searching or expanded[obj] then
            for _,child in ipairs(children) do
                addNode(child,depth+1)
            end
        end
    end

    addNode(active,0)

    tree.CanvasPosition = scrollPosition
end

-- =========================================
-- GUI-ONLY EXPORT
-- =========================================

local function exportGUI()
    local root = findSite()

    if not root then
        status("No active site found",T.red)
        return
    end

    local idCounter = 0
    local used = {}

    local function getID(obj)
        local id = obj:GetAttribute("globalid")
            or obj:GetAttribute("GlobalID")

        if id ~= nil then
            id = tostring(id)

            if not used[id] then
                used[id] = true
                return id
            end
        end

        repeat
            idCounter += 1
            id = "inspe_"..idCounter
        until not used[id]

        used[id] = true
        return id
    end

    local function serialize(obj)
        if not isGUI(obj) then return nil end

        local data = {
            class = obj.ClassName,
            globalid = getID(obj),
            size = tostring(obj.Size),
            background_color =
                hex(obj.BackgroundColor3),
            background_transparency =
                tostring(obj.BackgroundTransparency)
        }

        if obj.Name ~= "WebRendererObject"
            and obj.Name ~= obj.ClassName then
            data.alias = obj.Name
        end

        if obj.Position ~= UDim2.new() then
            data.position = tostring(obj.Position)
        end

        if obj:IsA("TextLabel")
            or obj:IsA("TextButton")
            or obj:IsA("TextBox") then

            data.text = obj.Text
            data.rich = tostring(obj.RichText)
            data.align_x = obj.TextXAlignment.Name
            data.align_y = obj.TextYAlignment.Name
            data.font_size =
                obj.TextScaled and "scaled"
                or tostring(obj.TextSize)
            data.font_color = hex(obj.TextColor3)
            data.font_transparency =
                tostring(obj.TextTransparency)
        end

        if obj:IsA("ImageLabel")
            or obj:IsA("ImageButton") then

            if obj.Image ~= "" then
                data.image = obj.Image
            end
        end

        local children = {}

        for _,child in ipairs(
            guiChildren(obj)
        ) do
            local entry = serialize(child)

            if entry then
                children[#children+1] = entry
            end
        end

        if #children > 0
            or obj:IsA("Frame")
            or obj:IsA("ScrollingFrame") then
            data.children = children
        end

        return data
    end

    -- Export the active site, not only the
    -- selected element.

    local content = {}

    for _,child in ipairs(guiChildren(root)) do
        local result = serialize(child)

        if result then
            content[#content+1] = result
        end
    end

    local output = {
        title = tostring(
            root:GetAttribute("title")
            or siteURL()
        ),
        background =
            hex(root.BackgroundColor3),
        webcontent = content
    }

    local favicon =
        root:GetAttribute("favicon")
        or root:GetAttribute("Favicon")

    if favicon then
        output.favicon = tostring(favicon)
    end

    local ok,json = pcall(function()
        return Http:JSONEncode(output)
    end)

    if not ok then
        status("JSON encoding failed",T.red)
        return
    end

    local name =
        "InspE_GUI_"..os.time()..".json"

    if type(writefile) == "function" then
        local saved = pcall(function()
            writefile(name,json)
        end)

        if saved then
            status("Exported: "..name,T.green)
            return
        end
    end

    if type(setclipboard) == "function" then
        local copied = pcall(function()
            setclipboard(json)
        end)

        if copied then
            status("GUI JSON copied",T.green)
            return
        end
    end

    status("No working export API",T.red)
end

-- =========================================
-- APPLY / UNDO
-- =========================================

local function apply()
    if not selected then return end

    local count = 0

    for name,value in pairs(staged) do
        local old = property(selected,name)

        if old ~= nil then
            local ok = pcall(function()
                selected[name] = value
            end)

            if ok then
                undoStack[#undoStack+1] = {
                    object = selected,
                    property = name,
                    previous = old
                }

                count += 1
            end
        end
    end

    staged = {}
    rebuildProperties()

    status("Applied "..count.." changes",T.green)
end

local function undo()
    local entry = table.remove(undoStack)

    if not entry then
        status("Nothing to undo")
        return
    end

    local ok = pcall(function()
        entry.object[entry.property] =
            entry.previous
    end)

    if ok then
        status("Undo successful",T.green)
    else
        status("Undo failed",T.red)
    end

    rebuildProperties()
end

-- =========================================
-- MAIN WINDOW
-- =========================================

gui = make("ScreenGui",pg,{
    Name = "InspE",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    DisplayOrder = 1000,
    Enabled = false
})

window = rounded(make("Frame",gui,{
    Name = "DexWindow",
    AnchorPoint = Vector2.new(0.5,0.5),
    Position = UDim2.fromScale(0.5,0.5),
    Size = UDim2.fromOffset(900,570),
    BackgroundColor3 = T.main,
    BorderSizePixel = 0,
    Active = true
}),6)

local header = make("Frame",window,{
    Size = UDim2.new(1,0,0,42),
    BackgroundColor3 = T.header,
    BorderSizePixel = 0,
    Active = true
})

label(
    header,"InspE | CatWEB Explorer",
    UDim2.new(1,-160,1,0),
    UDim2.fromOffset(14,0)
)

local close = button(
    header,"X",
    UDim2.fromOffset(33,26),
    UDim2.new(1,-40,0,8)
)

local refresh = button(
    header,"Refresh",
    UDim2.fromOffset(77,26),
    UDim2.new(1,-126,0,8)
)

local searchLabel = label(
    window,"Search",
    UDim2.fromOffset(65,24),
    UDim2.fromOffset(12,48)
)

searchBox = rounded(make("TextBox",window,{
    Position = UDim2.fromOffset(75,48),
    Size = UDim2.fromOffset(300,25),
    BackgroundColor3 = T.input,
    BorderSizePixel = 0,
    Text = "",
    PlaceholderText = "Filter objects...",
    PlaceholderColor3 = T.sub,
    TextColor3 = T.text,
    Font = Enum.Font.Code,
    TextSize = 12,
    ClearTextOnFocus = false
}))

local exportButton = button(
    window,"Export GUI",
    UDim2.fromOffset(125,26),
    UDim2.new(1,-138,0,47)
)

local dragButton = button(
    window,"Select & Drag: OFF",
    UDim2.fromOffset(155,26),
    UDim2.new(1,-303,0,47)
)

local leftPane = rounded(make(
    "Frame",window,{
        Position = UDim2.fromOffset(12,84),
        Size = UDim2.new(0.53,-18,1,-115),
        BackgroundColor3 = T.panel,
        BorderSizePixel = 0
    }
))

local rightPane = rounded(make(
    "Frame",window,{
        Position = UDim2.new(0.53,2,0,84),
        Size = UDim2.new(0.47,-14,1,-115),
        BackgroundColor3 = T.panel,
        BorderSizePixel = 0
    }
))

label(
    leftPane,"Explorer",
    UDim2.new(1,-15,0,28),
    UDim2.fromOffset(10,3)
)

label(
    rightPane,"Properties",
    UDim2.new(1,-15,0,28),
    UDim2.fromOffset(10,3)
)

tree = make("ScrollingFrame",leftPane,{
    Position = UDim2.fromOffset(7,34),
    Size = UDim2.new(1,-14,1,-41),
    BackgroundColor3 = T.main,
    BorderSizePixel = 0,
    ScrollBarThickness = 5,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y
})

properties = make("ScrollingFrame",rightPane,{
    Position = UDim2.fromOffset(7,34),
    Size = UDim2.new(1,-14,1,-82),
    BackgroundColor3 = T.main,
    BorderSizePixel = 0,
    ScrollBarThickness = 5,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y
})

layout(tree,2)
layout(properties,2)

local applyButton = button(
    rightPane,"Apply",
    UDim2.fromOffset(97,28),
    UDim2.new(0,9,1,-36)
)

local undoButton = button(
    rightPane,"Undo",
    UDim2.fromOffset(97,28),
    UDim2.new(0,114,1,-36)
)

siteLabel = label(
    window,"Site: Unknown",
    UDim2.new(0.6,0,0,18),
    UDim2.new(0,12,1,-28)
)

statusLabel = label(
    window,"Live monitor initialized",
    UDim2.new(0.4,-17,0,18),
    UDim2.new(0.6,0,1,-28)
)

-- =========================================
-- WINDOW DRAG
-- =========================================

local moving = false
local mouseOrigin,windowOrigin

track(header.InputBegan,function(input)
    if input.UserInputType ==
        Enum.UserInputType.MouseButton1 then

        moving = true
        mouseOrigin = input.Position
        windowOrigin = window.Position
    end
end)

track(UIS.InputChanged,function(input)
    if moving and input.UserInputType ==
        Enum.UserInputType.MouseMovement then

        local delta = input.Position-mouseOrigin

        window.Position = UDim2.new(
            windowOrigin.X.Scale,
            windowOrigin.X.Offset+delta.X,
            windowOrigin.Y.Scale,
            windowOrigin.Y.Offset+delta.Y
        )
    end
end)

track(UIS.InputEnded,function(input)
    if input.UserInputType ==
        Enum.UserInputType.MouseButton1 then
        moving = false
    end
end)

-- =========================================
-- EVENTS
-- =========================================

track(close.Activated,function()
    gui.Enabled = false
end)

track(refresh.Activated,function()
    active = findSite()
    selected = active
    expanded = {}

    if active then
        expanded[active] = true
    end

    lastSignature = ""
    rebuildTree()
    rebuildProperties()
end)

track(searchBox:GetPropertyChangedSignal("Text"),
function()
    searchText = searchBox.Text:lower()
    rebuildTree()
end)

track(exportButton.Activated,exportGUI)
track(applyButton.Activated,apply)
track(undoButton.Activated,undo)

track(dragButton.Activated,function()
    draggingObject = not draggingObject

    dragButton.Text =
        "Select & Drag: "
        ..(draggingObject and "ON" or "OFF")
end)

-- Select & Drag live GUI objects.

track(UIS.InputBegan,function(input)
    if not gui.Enabled
        or not draggingObject
        or not active then
        return
    end

    if input.UserInputType ~=
        Enum.UserInputType.MouseButton1 then
        return
    end

    local mouse = UIS:GetMouseLocation()
    local winP = window.AbsolutePosition
    local winS = window.AbsoluteSize

    if mouse.X >= winP.X
        and mouse.X <= winP.X+winS.X
        and mouse.Y >= winP.Y
        and mouse.Y <= winP.Y+winS.Y then
        return
    end

    for _, obj in ipairs(
        pg:GetGuiObjectsAtPosition(mouse.X,mouse.Y)
    ) do
        if isGUI(obj)
            and obj:IsDescendantOf(active) then

            choose(obj)
            dragTarget = obj
            dragStart = mouse
            dragOriginal = obj.Position
            break
        end
    end
end)

track(UIS.InputChanged,function(input)
    if not dragTarget or not dragStart then
        return
    end

    if input.UserInputType ~=
        Enum.UserInputType.MouseMovement then
        return
    end

    local delta =
        UIS:GetMouseLocation()-dragStart

    dragTarget.Position = UDim2.new(
        dragOriginal.X.Scale,
        dragOriginal.X.Offset+delta.X,
        dragOriginal.Y.Scale,
        dragOriginal.Y.Offset+delta.Y
    )
end)

track(UIS.InputEnded,function(input)
    if input.UserInputType ==
        Enum.UserInputType.MouseButton1
        and dragTarget then

        if dragTarget.Position ~= dragOriginal then
            undoStack[#undoStack+1] = {
                object = dragTarget,
                property = "Position",
                previous = dragOriginal
            }
        end

        dragTarget = nil
        dragStart = nil
        rebuildProperties()
    end
end)

-- =========================================
-- HOTKEY
-- =========================================

track(UIS.InputBegan,function(input,processed)
    if processed then return end
    if input.KeyCode ~= Enum.KeyCode.I then
        return
    end

    local ctrl =
        UIS:IsKeyDown(Enum.KeyCode.LeftControl)
        or UIS:IsKeyDown(Enum.KeyCode.RightControl)

    local shift =
        UIS:IsKeyDown(Enum.KeyCode.LeftShift)
        or UIS:IsKeyDown(Enum.KeyCode.RightShift)

    if ctrl and shift then
        gui.Enabled = not gui.Enabled

        if gui.Enabled then
            active = findSite()

            if active and not selected then
                selected = active
                expanded[active] = true
            end

            lastSignature = ""
            rebuildTree()
            rebuildProperties()
        else
            clearHighlight()
        end
    end
end)

-- =========================================
-- CONSTANT REFRESH
-- =========================================

task.spawn(function()
    while running do
        task.wait(REFRESH_INTERVAL)

        if not gui or not gui.Parent then
            break
        end

        if gui.Enabled then
            local current = findSite()

            if current ~= active then
                active = current
                selected = current
                expanded = {}
                staged = {}

                if current then
                    expanded[current] = true
                end

                clearHighlight()
                lastSignature = ""
            end

            if siteLabel then
                siteLabel.Text = "Site: "..siteURL()
            end

            if active then
                local signature = treeSignature(active)

                if signature ~= lastSignature then
                    lastSignature = signature
                    rebuildTree()
                end

                if selected and not selected.Parent then
                    selected = active
                    staged = {}
                    rebuildTree()
                end

                -- Keeps property values current, while
                -- avoiding interruption during editing.
                if not UIS:GetFocusedTextBox() then
                    rebuildProperties()
                end
            end
        end
    end
end)

-- =========================================
-- CLEANUP
-- =========================================

env.InspE_Cleanup = function()
    running = false

    clearHighlight()

    disconnectBucket(treeConnections)
    disconnectBucket(propertyConnections)
    disconnectBucket(allConnections)

    if gui then
        gui:Destroy()
        gui = nil
    end
end

print("[InspE] v1.0 loaded")
print("[InspE] Ctrl + Shift + I")
print("[InspE] Dex-style Explorer enabled")
print("[InspE] Live GUI refresh enabled")
print("[InspE] GUI-only export enabled")


-- =========================================
-- InspE AUTO-NAVIGATION
-- =========================================

task.defer(function()
    local targetURL = "cwe-exploit/inspe"

    local top = mainUI:WaitForChild("top_actions", 5)
    local container = top and top:FindFirstChild("container")
    local flex = container and container:FindFirstChild("flex")
    local address = flex and flex:FindFirstChild("URL")

    if address and not address:IsA("TextBox") then
        address = address:FindFirstChildWhichIsA("TextBox", true)
    end

    if not address then
        warn("[InspE] Address bar not found")
        return
    end

    address.Text = targetURL

    local VIM = game:GetService("VirtualInputManager")

    local ok, err = pcall(function()
        address:CaptureFocus()
        task.wait(0.15)

        VIM:SendKeyEvent(true, Enum.KeyCode.Return, false, game)
        VIM:SendKeyEvent(false, Enum.KeyCode.Return, false, game)

        address:ReleaseFocus(true)
    end)

    if ok then
        print("[InspE] Navigation requested:", targetURL)
    else
        warn("[InspE] Navigation failed:", err)
    end
end)
