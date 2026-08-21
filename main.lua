--[[--
Reordering Menus KOReader Plugin
Allows reordering, customizing, and hiding menus and menu items in both
Book view (Reader) and Normal view (File manager).
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

-- Register the plugin's menu item into KOReader's default menu order
pcall(function()
    require("ui/plugin/insert_menu").add("reordering_menus")
end)

local UIScreens = require("ui_screens")

local ReorderingMenus = WidgetContainer:extend{
    name = "reorderingmenus",
}

function ReorderingMenus:init()
    UIScreens:initView(self.ui)
    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function ReorderingMenus:onReaderReady()
    UIScreens.current_view = "reader"
end

function ReorderingMenus:onShowFileManager()
    UIScreens.current_view = "filemanager"
end

function ReorderingMenus:addToMainMenu(menu_items)
    menu_items.reordering_menus = {
        text = _("Reorder menus"),
        sorting_hint = "more_tools",
        callback = function()
            UIScreens:showTabReorderDialog(self, UIScreens:getCurrentView(self))
        end,
    }
end

return ReorderingMenus
