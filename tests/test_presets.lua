--[[--
Unit and Integration Tests for Preset Management in ReorderingMenus
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"), "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()

local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

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
print("=== Preset Management Test Suite                            ===")
print("===============================================================")

-- 1. Test Built-in Presets
print("\n--- Test 1: Built-in Presets ---")
local reader_builtins = MenuOrderManager:getBuiltinPresets("reader")
assert_true(#reader_builtins >= 4, "Reader has 4+ built-in presets")
assert_eq(reader_builtins[1].id, "builtin_default", "Default preset present")
assert_eq(reader_builtins[2].id, "builtin_reading_focused", "Reading Focused preset present")
assert_eq(reader_builtins[3].id, "builtin_minimalist", "Minimalist Reader preset present")
assert_eq(reader_builtins[4].id, "builtin_power_user", "Power User preset present")

local fm_builtins = MenuOrderManager:getBuiltinPresets("filemanager")
assert_true(#fm_builtins >= 3, "FileManager has 3+ built-in presets")

-- 2. Test Saving User Preset
print("\n--- Test 2: Saving User Preset ---")
local test_preset_name = "Unit_Test_Preset_Alpha"
-- Clean up previous run if any
MenuOrderManager:deletePreset("reader", test_preset_name)

local ok, path = MenuOrderManager:savePreset("reader", test_preset_name)
assert_true(ok, "Preset saved successfully to: " .. tostring(path))
assert_true(lfs.attributes(path) ~= nil, "Preset file exists on filesystem")

-- 3. Test Listing Presets
print("\n--- Test 3: Listing Presets ---")
local user_presets = MenuOrderManager:listUserPresets("reader")
local found = false
for __, p in ipairs(user_presets) do
    if p.name == test_preset_name then
        found = true
        break
    end
end
assert_true(found, "User preset found in listUserPresets")

local all_presets = MenuOrderManager:getAllPresets("reader")
assert_true(#all_presets >= #reader_builtins + 1, "getAllPresets returns built-ins + user presets")

-- 4. Test Loading Built-in Minimalist Preset
print("\n--- Test 4: Loading Built-in Minimalist Preset ---")
local load_ok, err = MenuOrderManager:loadPreset("reader", "builtin_minimalist")
assert_true(load_ok, "Minimalist preset loaded successfully")
local tabs = MenuOrderManager:getTabs("reader")
assert_eq(#tabs, 2, "Minimalist preset has exactly 2 tabs (navi, typeset)")
assert_eq(tabs[1], "navi", "First tab is navi")
assert_eq(tabs[2], "typeset", "Second tab is typeset")

-- 5. Test Loading Built-in Reading Focused Preset
print("\n--- Test 5: Loading Built-in Reading Focused Preset ---")
load_ok, err = MenuOrderManager:loadPreset("reader", "builtin_reading_focused")
assert_true(load_ok, "Reading focused preset loaded successfully")
tabs = MenuOrderManager:getTabs("reader")
assert_eq(#tabs, 4, "Reading focused preset has 4 tabs")
assert_eq(tabs[1], "typeset", "First tab is typeset")
assert_eq(tabs[2], "navi", "Second tab is navi")

-- 6. Test Loading User Preset
print("\n--- Test 6: Loading User Preset ---")
load_ok, err = MenuOrderManager:loadPreset("reader", test_preset_name)
assert_true(load_ok, "User preset loaded successfully")

-- 7. Test Deleting User Preset
print("\n--- Test 7: Deleting User Preset ---")
local del_ok = MenuOrderManager:deletePreset("reader", test_preset_name)
assert_true(del_ok, "User preset deleted successfully")
user_presets = MenuOrderManager:listUserPresets("reader")
found = false
for __, p in ipairs(user_presets) do
    if p.name == test_preset_name then
        found = true
        break
    end
end
assert_eq(found, false, "User preset no longer in list")

-- 8. Test Submenu Presets
print("\n--- Test 8: Submenu Presets ---")
local direct_preset_name = "Unit_Test_Navigation_Direct"
local nested_preset_name = "Unit_Test_Navigation_Nested"
MenuOrderManager:deleteSubmenuPreset("reader", "navi", direct_preset_name)
MenuOrderManager:deleteSubmenuPreset("reader", "navi", nested_preset_name)
MenuOrderManager:resetOrder("reader")

local default_order = MenuOrderManager:getDefaultOrder("reader")
local desired_navi = util.tableDeepCopy(default_order.navi)
local desired_navi_settings = util.tableDeepCopy(default_order.navi_settings)
desired_navi[1], desired_navi[2] = desired_navi[2], desired_navi[1]
desired_navi_settings[1], desired_navi_settings[2] = desired_navi_settings[2], desired_navi_settings[1]

local working_order = MenuOrderManager:loadOrder("reader")
working_order.navi = util.tableDeepCopy(desired_navi)
working_order.navi_settings = util.tableDeepCopy(desired_navi_settings)

ok, path = MenuOrderManager:saveSubmenuPreset(
    "reader", "navi", "Navigation", direct_preset_name, false
)
assert_true(ok and lfs.attributes(path) ~= nil, "Direct submenu preset saved")
ok, path = MenuOrderManager:saveSubmenuPreset(
    "reader", "navi", "Navigation", nested_preset_name, true
)
assert_true(ok and lfs.attributes(path) ~= nil, "Nested submenu preset saved")

local submenu_presets = MenuOrderManager:listSubmenuPresets("reader", "navi")
local direct_preset
local nested_preset
for _, preset in ipairs(submenu_presets) do
    if preset.name == direct_preset_name then direct_preset = preset end
    if preset.name == nested_preset_name then nested_preset = preset end
end
assert_true(direct_preset ~= nil and not direct_preset.include_submenus, "Direct preset is scoped to one menu")
assert_true(nested_preset ~= nil and nested_preset.include_submenus, "Nested preset records recursive scope")
assert_true(nested_preset and nested_preset.menu_count >= 2, "Nested preset captures child submenu order")

working_order.navi = util.tableDeepCopy(default_order.navi)
table.insert(working_order.navi, "new_plugin_navigation_item")
working_order.navi_settings = util.tableDeepCopy(default_order.navi_settings)
load_ok, err = MenuOrderManager:loadSubmenuPreset("reader", "navi", direct_preset)
assert_true(load_ok, "Direct submenu preset loaded")
assert_eq(working_order.navi[1], desired_navi[1], "Direct preset restores root submenu order")
assert_eq(working_order.navi_settings[1], default_order.navi_settings[1], "Direct preset leaves nested submenu unchanged")
assert_eq(working_order.navi[#working_order.navi], "new_plugin_navigation_item", "Direct preset preserves new plugin items")

working_order.navi = util.tableDeepCopy(default_order.navi)
table.insert(working_order.navi, "new_plugin_navigation_item")
working_order.navi_settings = util.tableDeepCopy(default_order.navi_settings)
load_ok, err = MenuOrderManager:loadSubmenuPreset("reader", "navi", nested_preset)
assert_true(load_ok, "Nested submenu preset loaded")
assert_eq(working_order.navi[1], desired_navi[1], "Nested preset restores root submenu order")
assert_eq(working_order.navi_settings[1], desired_navi_settings[1], "Nested preset restores child submenu order")
assert_eq(working_order.navi[#working_order.navi], "new_plugin_navigation_item", "Nested preset preserves new plugin items")

assert_true(MenuOrderManager:deleteSubmenuPreset("reader", "navi", direct_preset), "Direct submenu preset deleted")
assert_true(MenuOrderManager:deleteSubmenuPreset("reader", "navi", nested_preset), "Nested submenu preset deleted")

-- 9. Test Presets UI Screens
print("\n--- Test 9: Presets UI Screens Simulation ---")
local mock_ui = {
    document = { file = "test.epub" },
    doc_settings = { isTrue = function() return false end, makeFalse = function() end, makeTrue = function() end },
    saveSettings = function() end,
    registerTouchZones = function() end,
    onClose = function() end,
    showFileManager = function() end,
    registerModule = function(self, name, mod) self[name] = mod end,
    menu = { registerToMainMenu = function() end },
}
local plugin = ReorderingMenus:new{ ui = mock_ui }

local ui_ok, ui_err = pcall(function()
    UIScreens:showPresetsMenu(plugin, "reader")
    local top_entry = UIManager._window_stack[#UIManager._window_stack]
    local menu = (top_entry and top_entry.widget) or top_entry
    assert_true(menu ~= nil, "Presets menu opened")
    UIManager:close(menu)
end)
assert_true(ui_ok, "showPresetsMenu opened and closed cleanly: " .. tostring(ui_err))

ui_ok, ui_err = pcall(function()
    UIScreens:showLoadPresetMenu(plugin, "reader")
    local top_entry = UIManager._window_stack[#UIManager._window_stack]
    local menu = (top_entry and top_entry.widget) or top_entry
    assert_true(menu ~= nil, "Load Preset menu opened")
    UIManager:close(menu)
end)
assert_true(ui_ok, "showLoadPresetMenu opened and closed cleanly: " .. tostring(ui_err))

ui_ok, ui_err = pcall(function()
    UIScreens:showSubmenuPresetsMenu(plugin, "reader", "tools", "Tools")
    local top_entry = UIManager._window_stack[#UIManager._window_stack]
    local menu = (top_entry and top_entry.widget) or top_entry
    assert_true(menu ~= nil and menu.title == "Presets for Tools", "Submenu preset manager opened for its menu name")
    assert_eq(menu.item_table[1].text, "Save this menu order…", "Direct-only save is the default option")
    assert_eq(menu.item_table[2].text, "Save with nested submenu orders…", "Nested submenu capture is offered separately")
    UIManager:close(menu)
end)
assert_true(ui_ok, "showSubmenuPresetsMenu opened and closed cleanly: " .. tostring(ui_err))

ui_ok, ui_err = pcall(function()
    MenuOrderManager:saveSubmenuPreset("reader", "tools", "Tools", direct_preset_name, false)
    MenuOrderManager:saveSubmenuPreset("reader", "tools", "Tools", nested_preset_name, true)
    UIScreens:showDeleteSubmenuPresetMenu(plugin, "reader", "tools", "Tools")
    local top_entry = UIManager._window_stack[#UIManager._window_stack]
    local menu = (top_entry and top_entry.widget) or top_entry
    local labels = {}
    for _, item in ipairs(menu.item_table or {}) do labels[item.text] = true end
    assert_true(labels["[Direct] " .. direct_preset_name], "Delete list labels direct presets")
    assert_true(labels["[Nested] " .. nested_preset_name], "Delete list labels nested presets")
    UIManager:close(menu)
    MenuOrderManager:deleteSubmenuPreset("reader", "tools", direct_preset_name)
    MenuOrderManager:deleteSubmenuPreset("reader", "tools", nested_preset_name)
end)
assert_true(ui_ok, "Delete submenu preset labels rendered cleanly: " .. tostring(ui_err))

-- Reset to clean defaults
MenuOrderManager:resetOrder("reader")
MenuOrderManager:resetOrder("filemanager")

print(string.format("\n==============================================================="))
print(string.format("=== PRESET TESTS COMPLETED: %d PASSED, %d FAILED             ===", passed, failed))
print("===============================================================")

if failed > 0 then
    os.exit(1)
end
