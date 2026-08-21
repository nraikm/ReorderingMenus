--[[--
Comprehensive UI Interaction and Live Reload Stress Test
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"), "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")

G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()

local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local ReaderMenu = require("apps/reader/modules/readermenu")
local MenuTitles = require("menu_titles")
local MenuOrderManager = require("menuorder_manager")
local UIScreens = require("ui_screens")
local ReorderingMenus = require("main")
local UIManager = require("ui/uimanager")

local passed = 0
local failed = 0

local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or "assertion"))
    else
        failed = failed + 1
        print("  [FAIL] " .. (msg or "assertion") .. " -> Expected: " .. tostring(expected) .. ", Got: " .. tostring(actual))
    end
end

local function assert_true(cond, msg)
    assert_eq(not not cond, true, msg)
end

print("===============================================================")
print("=== UI Interaction & Reload Robustness Test                 ===")
print("===============================================================")

local mock_ui_reader = {
    document = {
        file = "/Users/Shared/minimal.epub",
        configurable = {},
    },
    doc_settings = {
        isTrue = function() return false end,
        makeFalse = function() end,
        makeTrue = function() end,
    },
    saveSettings = function() end,
    registerTouchZones = function() end,
    onClose = function() end,
    showFileManager = function() end,
    registerModule = function(self, name, mod) self[name] = mod end,
}

local reader_menu = ReaderMenu:new{ ui = mock_ui_reader }
mock_ui_reader.menu = reader_menu

local plugin = ReorderingMenus:new{ ui = mock_ui_reader }
reader_menu:registerToMainMenu(plugin)
reader_menu:setUpdateItemTable()

-- 1. Test Multiple Consecutive Saves and Live Reloads
print("\n--- Test 1: Consecutive Live Reload Stress Test (10 cycles) ---")
for i = 1, 10 do
    local ok, err = pcall(function()
        MenuOrderManager:moveItem("reader", "navi", 1, 2)
        UIScreens:saveAndApply(plugin, "reader")
    end)
    assert_true(ok, string.format("Cycle %d completed without crash", i))
    assert_true(mock_ui_reader.menu ~= nil, string.format("Cycle %d menu instance valid", i))
    assert_true(#mock_ui_reader.menu.tab_item_table >= 6, string.format("Cycle %d tabs rebuilt correctly", i))
end

local function getTopSortWidget()
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
        if w and w.item_table then
            return w
        end
    end
    return nil
end

-- 2. Test Top Tabs Reordering with SortWidget Simulation
print("\n--- Test 2: Top Tabs Reordering via SortWidget Simulation ---")
local ok, err = pcall(function()
    UIScreens:showTabReorderDialog(plugin, "reader")
    local sort_widget = getTopSortWidget()
    assert_true(sort_widget ~= nil, "SortWidget window on stack")

    sort_widget.marked = 1
    local selected_menu_title = MenuTitles:getTitle(sort_widget.item_table[1].tab_id)
    sort_widget:onShowWidgetMenu()
    local widget_menu
    for i = #UIManager._window_stack, 1, -1 do
        local candidate = UIManager._window_stack[i].widget or UIManager._window_stack[i]
        if candidate.buttontable then
            widget_menu = candidate
            break
        end
    end
    assert_true(widget_menu ~= nil, "Hamburger menu dialog opened")
    local presets_callback
    local named_reset_found = false
    local selected_reset_found = false
    for _, row in ipairs(widget_menu.buttontable.buttons) do
        for _, button in ipairs(row) do
            if button.text == "Presets…" then
                presets_callback = button.callback
            elseif button.text == "Reset Book menu" then
                named_reset_found = true
            elseif button.text == "Reset " .. selected_menu_title .. " menu" then
                selected_reset_found = true
            end
        end
    end
    assert_true(presets_callback ~= nil, "Hamburger menu exposes preset management")
    assert_true(named_reset_found, "Top-level reset names the current view")
    assert_true(selected_reset_found, "Marked top-level submenu gets its own reset action")
    presets_callback()

    local presets_menu
    for i = #UIManager._window_stack, 1, -1 do
        local candidate = UIManager._window_stack[i].widget or UIManager._window_stack[i]
        if candidate.title and candidate.title:find("Presets", 1, true) then
            presets_menu = candidate
            break
        end
    end
    assert_true(presets_menu ~= nil, "Preset management opens from hamburger menu")
    UIManager:close(presets_menu)
    sort_widget.marked = 0

    -- Simulate dragging first item down
    local item = table.remove(sort_widget.item_table, 1)
    table.insert(sort_widget.item_table, 2, item)
    -- Trigger OK callback
    sort_widget:onReturn()
end)
assert_true(ok, "Top tabs reordering completed cleanly: " .. tostring(err))

-- 3. Test Item Customizer & Item SortWidget Simulation
print("\n--- Test 3: Submenu Item SortWidget Simulation ---")
local ok, err = pcall(function()
    UIScreens:showItemSortWidget(plugin, "reader", "tools")
    local sort_widget = getTopSortWidget()
    assert_true(sort_widget ~= nil, "Tools SortWidget window on stack")

    local selected_submenu_title
    for i, item in ipairs(sort_widget.item_table) do
        if item.is_submenu then
            sort_widget.marked = i
            selected_submenu_title = MenuTitles:getTitle(item.item_id)
            break
        end
    end
    assert_true(selected_submenu_title ~= nil, "Tools contains a selectable submenu")

    -- Test onShowWidgetMenu with separator insertion
    sort_widget:onShowWidgetMenu()
    local btn_widget
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget or UIManager._window_stack[i]
        if w.buttontable then
            btn_widget = w
            break
        end
    end
    assert_true(btn_widget ~= nil, "SortWidget menu dialog opened")

    local submenu_reset_found = false
    local selected_submenu_reset_found = false
    local submenu_presets_callback
    local sort_a_index
    local sort_z_index
    local button_index = 0
    for _, row in ipairs(btn_widget.buttontable.buttons) do
        for _, button in ipairs(row) do
            button_index = button_index + 1
            if button.text == "Reset Tools menu" then
                submenu_reset_found = true
            elseif button.text == "Presets for Tools…" then
                submenu_presets_callback = button.callback
            elseif selected_submenu_title and button.text == "Reset " .. selected_submenu_title .. " menu" then
                selected_submenu_reset_found = true
            elseif button.text == "Sort A to Z" then
                sort_a_index = button_index
            elseif button.text == "Sort Z to A" then
                sort_z_index = button_index
            end
        end
    end
    assert_true(submenu_reset_found, "Submenu reset names the current menu")
    assert_true(selected_submenu_reset_found, "Marked nested submenu gets its own reset action")
    assert_true(submenu_presets_callback ~= nil, "Submenu hamburger exposes presets for the current menu")
    assert_eq(sort_z_index, sort_a_index + 1, "Sort actions remain next to each other")

    -- Simulate tapping "Add separator at bottom" (button 1)
    local initial_count = #sort_widget.item_table
    local cb
    if btn_widget and btn_widget.buttontable and btn_widget.buttontable.buttons then
        cb = btn_widget.buttontable.buttons[1][1].callback
    end
    assert_true(cb ~= nil, "Button callback found")
    if cb then cb() end
    assert_eq(#sort_widget.item_table, initial_count + 1, "Separator added inside SortWidget")
    assert_eq(sort_widget.item_table[#sort_widget.item_table].item_id, MenuOrderManager.SEPARATOR_ID, "New item is separator")

    -- Test deleting separator via hold_callback
    local sep_item = sort_widget.item_table[#sort_widget.item_table]
    assert_true(sep_item.hold_callback ~= nil, "Separator has hold_callback")

    -- Simulate toggling checkbox (hiding item)
    if sort_widget.item_table[1] and sort_widget.item_table[1].callback then
        sort_widget.item_table[1]:callback()
    end
    -- Trigger OK callback
    sort_widget:onReturn()
end)
assert_true(ok, "Submenu Item SortWidget completed cleanly: " .. tostring(err))

-- 4. Test Cross-Menu Movement Simulation
print("\n--- Test 4: Cross-Menu Item Movement Simulation ---")
local ok, err = pcall(function()
    MenuOrderManager:moveItemToMenu("reader", "read_timer", "tools", "navi", 1)
    UIScreens:saveAndApply(plugin, "reader")
    local navi_items = MenuOrderManager:getMenuItems("reader", "navi")
    assert_eq(navi_items[1], "read_timer", "read_timer moved to navi index 1")
end)
assert_true(ok, "Cross-menu movement applied cleanly: " .. tostring(err))

-- 5. Test Hidden Items Manager Simulation
print("\n--- Test 5: Hidden Items Manager Simulation ---")
local ok, err = pcall(function()
    MenuOrderManager:setItemHidden("reader", "read_timer", true)
    UIScreens:saveAndApply(plugin, "reader")
    assert_true(MenuOrderManager:isItemHidden("reader", "read_timer"), "read_timer is hidden")
    UIScreens:showHiddenItemsManager(plugin, "reader")
    local entry = UIManager._window_stack[#UIManager._window_stack]
    local hid_menu = (entry and entry.widget) or entry
    assert_true(hid_menu ~= nil, "Hidden items menu displayed")
    UIManager:close(hid_menu)
end)
assert_true(ok, "Hidden items manager opened and closed cleanly: " .. tostring(err))

-- 6. Test Search Results Simulation
print("\n--- Test 6: Search Dialog & Results Simulation ---")
local ok, err = pcall(function()
    UIScreens:showSearchResults(plugin, "reader", "timer")
    local entry = UIManager._window_stack[#UIManager._window_stack]
    local search_menu = (entry and entry.widget) or entry
    assert_true(search_menu ~= nil, "Search menu displayed")
    UIManager:close(search_menu)
end)
assert_true(ok, "Search results opened and closed cleanly: " .. tostring(err))

-- 7. Reset to clean defaults
print("\n--- Test 7: Reset to Clean Defaults ---")
MenuOrderManager:resetOrder("reader")
MenuOrderManager:resetOrder("filemanager")
assert_eq(MenuOrderManager:isCustomized("reader"), false, "Reader order cleanly reset")

print(string.format("\n==============================================================="))
print(string.format("=== ROBUSTNESS TESTS COMPLETED: %d PASSED, %d FAILED         ===", passed, failed))
print("===============================================================")

if failed > 0 then
    os.exit(1)
end
