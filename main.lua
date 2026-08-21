--[[--
Reordering Menus KOReader Plugin
Allows reordering, customizing, and hiding menus and menu items in both
Book view (Reader) and Normal view (File manager).
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
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
    local view = UIScreens:getCurrentView(self)
    -- The initial File Manager launch does not consistently emit
    -- ShowFileManager. Reconcile once now to repair existing order files, then
    -- once on the next UI tick after the remaining plugins have registered.
    UIScreens:reconcileRegisteredItems(self, view, true)
    UIManager:nextTick(function()
        if self.ui and self.ui.menu then
            UIScreens:reconcileRegisteredItems(self, UIScreens:getCurrentView(self), true)
        end
    end)
end

function ReorderingMenus:onReaderReady()
    UIScreens.current_view = "reader"
    UIScreens:reconcileRegisteredItems(self, "reader", true)
end

function ReorderingMenus:onShowFileManager()
    UIScreens.current_view = "filemanager"
    UIScreens:reconcileRegisteredItems(self, "filemanager", true)
end

function ReorderingMenus:showReorderScreen()
    UIScreens:showTabReorderDialog(self, UIScreens:getCurrentView(self))
end

function ReorderingMenus:addToMainMenu(menu_items)
    menu_items.reordering_menus = {
        text = _("Reorder menus"),
        sorting_hint = "more_tools",
        callback = function()
            self:showReorderScreen()
        end,
    }
end

return ReorderingMenus
