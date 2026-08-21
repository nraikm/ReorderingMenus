--[[--
End-to-End Integration Test for ReorderingMenus Plugin with KOReader Menu System
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
local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local MenuOrderManager = require("menuorder_manager")
local ReorderingMenus = require("main")

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
print("=== KOReader Reordering Menus Plugin - Integration Test     ===")
print("===============================================================")

-- -------------------------------------------------------------
-- Test 1: Full ReaderMenu Integration
-- -------------------------------------------------------------
print("\n--- Test 1: ReaderMenu Integration ---")

local mock_ui_reader = {
    document = {
        file = "test.epub",
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
}

local reader_menu = ReaderMenu:new{
    ui = mock_ui_reader,
}
mock_ui_reader.menu = reader_menu

-- Instantiate and register plugin
local plugin_reader = ReorderingMenus:new{
    ui = mock_ui_reader,
}
reader_menu:registerToMainMenu(plugin_reader)
plugin_reader:addToMainMenu(reader_menu.menu_items)
assert_true(reader_menu.menu_items.reordering_menus ~= nil, "reordering_menus is registered in reader menu_items")

-- Build menu
reader_menu:setUpdateItemTable()

assert_true(reader_menu.tab_item_table ~= nil, "tab_item_table built for reader")
assert_true(#reader_menu.tab_item_table >= 6, "reader tab_item_table contains standard tabs")

local function scan_tab(tbl)
    for _, item in ipairs(tbl) do
        if item.id == "reordering_menus" or item.text == "Reorder menus" then
            return true
        end
        if item.sub_item_table and scan_tab(item.sub_item_table) then
            return true
        end
    end
    return false
end

local found_in_reader = false
for _, tab in ipairs(reader_menu.tab_item_table) do
    if scan_tab(tab) then
        found_in_reader = true
        break
    end
end
assert_true(found_in_reader, "reordering_menus is accessible inside Reader menu hierarchy")

-- -------------------------------------------------------------
-- Test 2: Full FileManagerMenu Integration
-- -------------------------------------------------------------
print("\n--- Test 2: FileManagerMenu Integration ---")

local mock_ui_fm = {
    file_chooser = {
        show_hidden = false,
        show_unsupported = false,
        items_per_page_default = 14,
        collates = {
            filename = { text = "Filename", menu_order = 1 },
        },
        getCollate = function() return nil, "filename" end,
        refreshPath = function() end,
        toggleShowFilesMode = function() end,
    },
    registerTouchZones = function() end,
    onSetSortBy = function() end,
}

local fm_menu = FileManagerMenu:new{
    ui = mock_ui_fm,
}
mock_ui_fm.menu = fm_menu

local plugin_fm = ReorderingMenus:new{
    ui = mock_ui_fm,
}
fm_menu:registerToMainMenu(plugin_fm)
plugin_fm:addToMainMenu(fm_menu.menu_items)
assert_true(fm_menu.menu_items.reordering_menus ~= nil, "reordering_menus is registered in filemanager menu_items")

fm_menu:setUpdateItemTable()

assert_true(fm_menu.tab_item_table ~= nil, "tab_item_table built for filemanager")
assert_true(#fm_menu.tab_item_table >= 5, "filemanager tab_item_table contains standard tabs")

local found_in_fm = false
for _, tab in ipairs(fm_menu.tab_item_table) do
    if scan_tab(tab) then
        found_in_fm = true
        break
    end
end
assert_true(found_in_fm, "reordering_menus is accessible inside FileManager menu hierarchy")

-- -------------------------------------------------------------
-- Test 3: Customization and Live Reload in Reader
-- -------------------------------------------------------------
print("\n--- Test 3: Custom Order Application & Live Reload ---")

-- Modify menu: Put bookmarks before table_of_contents in navi
MenuOrderManager:moveItem("reader", "navi", 1, 2)
-- Hide bookmarks_browsing_mode
MenuOrderManager:setItemHidden("reader", "bookmark_browsing_mode", true, "navi")

-- Save order to disk
local saved_ok = MenuOrderManager:saveOrder("reader")
assert_true(saved_ok, "Saved custom reader menu order to disk")

-- Re-generate ReaderMenu
package.loaded["ui/elements/reader_menu_order"] = nil
local updated_reader_menu = ReaderMenu:new{
    ui = mock_ui_reader,
}
mock_ui_reader.menu = updated_reader_menu
updated_reader_menu:registerToMainMenu(plugin_reader)
updated_reader_menu:setUpdateItemTable()

-- Find navi tab
local navi_tab = updated_reader_menu.tab_item_table[1]
assert_true(navi_tab ~= nil, "Navi tab exists in updated reader menu")

-- Verify bookmark_browsing_mode is hidden (not present in navi tab)
local browsing_mode_found = false
for _, item in ipairs(navi_tab) do
    if item.id == "bookmark_browsing_mode" then
        browsing_mode_found = true
        break
    end
end
assert_eq(browsing_mode_found, false, "Hidden item (bookmark_browsing_mode) is omitted from menu")

-- Cleanup / reset
MenuOrderManager:resetOrder("reader")
MenuOrderManager:resetOrder("filemanager")
assert_eq(MenuOrderManager:isCustomized("reader"), false, "Cleaned up test settings")

print(string.format("\n==============================================================="))
print(string.format("=== INTEGRATION TESTS COMPLETED: %d PASSED, %d FAILED       ===", passed, failed))
print("===============================================================")

if failed > 0 then
    os.exit(1)
end
