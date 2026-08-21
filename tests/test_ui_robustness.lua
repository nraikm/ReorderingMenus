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

-- 2. Test live-menu filtering and newly registered plugin discovery
print("\n--- Test 2: Live Menu Discovery & Filtering ---")
local ok, err = pcall(function()
    local fake_plugin = {
        ui = {
            menu = {
                tab_item_table = {
                    {
                        id = "fixture_menu",
                        { id = "known_item", text = "Known item" },
                        { id = "new_plugin_item", text = "New plugin item" },
                    },
                },
            },
        },
    }
    local live_ids, live_by_id, has_live = UIScreens:_getLiveMenuItems(fake_plugin, "fixture_menu")
    assert_true(has_live, "Direct-table live menu is discovered")
    assert_eq(#live_ids, 2, "All direct live menu children are collected")
    assert_eq(live_ids[2], "new_plugin_item", "New plugin item is collected in live order")
    assert_eq(live_by_id.new_plugin_item.text, "New plugin item", "Live plugin title remains available")
    live_by_id.new_plugin_item.sub_item_table = {
        { text = "Plugin-owned setting" },
    }
    assert_eq(MenuOrderManager:isSubmenu("reader", "new_plugin_item"), false,
        "Plugin-owned internal menu is not treated as an editable ordered submenu")

    local saved_stack_size = #UIManager._window_stack
    table.insert(UIManager._window_stack, {
        widget = {
            menu = {
                tab_item_table = fake_plugin.ui.menu.tab_item_table,
            },
        },
    })
    local stale_plugin = { ui = { menu = {} } }
    local fallback_ids, _, fallback_live = UIScreens:_getLiveMenuItems(stale_plugin, "fixture_menu")
    table.remove(UIManager._window_stack)
    assert_eq(#UIManager._window_stack, saved_stack_size, "Live-menu fallback leaves the window stack unchanged")
    assert_true(fallback_live, "Active KOReader window supplies live menu after a stale plugin reference")
    assert_eq(fallback_ids[2], "new_plugin_item", "Active-window fallback still discovers new plugins")

    local rebuilt_plugin = {
        ui = {
            menu = {
                setUpdateItemTable = function(self)
                    self.tab_item_table = fake_plugin.ui.menu.tab_item_table
                end,
            },
        },
    }
    local rebuilt_ids, _, rebuilt_live = UIScreens:_getLiveMenuItems(rebuilt_plugin, "fixture_menu")
    assert_true(rebuilt_live, "Missing live menu tree is rebuilt through KOReader's menu updater")
    assert_eq(rebuilt_ids[2], "new_plugin_item", "Rebuilt live tree includes new plugin items")

    local merged, unavailable = UIScreens:_mergeConfiguredAndLiveItems(
        { "stale_item", "known_item", MenuOrderManager.SEPARATOR_ID },
        {}, live_ids, has_live
    )
    assert_eq(merged[1], "known_item", "Registered configured item keeps its position")
    assert_eq(merged[2], MenuOrderManager.SEPARATOR_ID, "Configured separator is retained")
    assert_eq(merged[3], "new_plugin_item", "New live plugin item is appended for reordering")
    assert_eq(unavailable[1], "stale_item", "Unavailable legacy item is filtered from the editor")

    local merged_hidden = UIScreens:_mergeConfiguredAndLiveItems(
        { "known_item", "hidden_item" }, { "hidden_item" }, live_ids, has_live
    )
    assert_eq(#merged_hidden, 2, "Visible items and new plugins remain after hidden filtering")
    assert_eq(merged_hidden[1], "known_item", "Hidden item is not presented as visible")
end)
assert_true(ok, "Live menu discovery and filtering completed cleanly: " .. tostring(err))

-- 3. Test Top Tabs Reordering with SortWidget Simulation
print("\n--- Test 3: Top Tabs Reordering via SortWidget Simulation ---")
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

-- 4. Test Item Customizer & Item SortWidget Simulation
print("\n--- Test 4: Submenu Item SortWidget Simulation ---")
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

-- 5. Test destination chooser safety for complete submenus
print("\n--- Test 5: Safe Submenu Destinations ---")
local ok, err = pcall(function()
    UIScreens:showDestinationMenuChooser(plugin, "reader", "more_tools", "tools")
    local chooser
    for i = #UIManager._window_stack, 1, -1 do
        local entry = UIManager._window_stack[i]
        local candidate = (entry and entry.widget) or entry
        if candidate and candidate.item_table and candidate.title
                and candidate.title:find("Move", 1, true) then
            chooser = candidate
            break
        end
    end
    assert_true(chooser and chooser.item_table, "Destination chooser opened")
    local settings_found = false
    local self_found = false
    local source_found = false
    for _, choice in ipairs(chooser.item_table or {}) do
        if choice.text == "[Tab] Settings" then settings_found = true end
        if choice.text == "[Menu] More tools" then self_found = true end
        if choice.text == "[Tab] Tools" then source_found = true end
    end
    assert_true(settings_found, "Valid destination remains available")
    assert_eq(self_found, false, "Submenu itself is excluded as a destination")
    assert_eq(source_found, false, "Current parent is excluded as a destination")
    UIManager:close(chooser)
end)
assert_true(ok, "Safe submenu destination chooser completed cleanly: " .. tostring(err))

-- 6. Test Cross-Menu Movement Simulation
print("\n--- Test 6: Cross-Menu Item Movement Simulation ---")
local ok, err = pcall(function()
    MenuOrderManager:moveItemToMenu("reader", "read_timer", "tools", "navi", 1)
    UIScreens:saveAndApply(plugin, "reader")
    local navi_items = MenuOrderManager:getMenuItems("reader", "navi")
    assert_eq(navi_items[1], "read_timer", "read_timer moved to navi index 1")
end)
assert_true(ok, "Cross-menu movement applied cleanly: " .. tostring(err))

-- 7. Test Hidden Items Manager Simulation
print("\n--- Test 7: Hidden Items Manager Simulation ---")
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

-- 8. Test Search Results Simulation
print("\n--- Test 8: Search Dialog & Results Simulation ---")
local ok, err = pcall(function()
    UIScreens:showSearchResults(plugin, "reader", "timer")
    local entry = UIManager._window_stack[#UIManager._window_stack]
    local search_menu = (entry and entry.widget) or entry
    assert_true(search_menu ~= nil, "Search menu displayed")
    UIManager:close(search_menu)
end)
assert_true(ok, "Search results opened and closed cleanly: " .. tostring(err))

-- 9. Reset to clean defaults
print("\n--- Test 9: Reset to Clean Defaults ---")
MenuOrderManager:resetOrder("reader")
MenuOrderManager:resetOrder("filemanager")
assert_eq(MenuOrderManager:isCustomized("reader"), false, "Reader order cleanly reset")

print(string.format("\n==============================================================="))
print(string.format("=== ROBUSTNESS TESTS COMPLETED: %d PASSED, %d FAILED         ===", passed, failed))
print("===============================================================")

if failed > 0 then
    os.exit(1)
end
