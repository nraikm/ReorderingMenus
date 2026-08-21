--[[--
UI screens and interactive dialogs for KOReader Reordering Menus plugin.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local dump = require("dump")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local SortWidget = require("ui/widget/sortwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local util = require("util")
local _ = require("gettext")

local MenuOrderManager = require("menuorder_manager")
local MenuTitles = require("menu_titles")

-- Patch SortWidget's private row widget so a second tap on the selected row
-- opens a submenu. Long-press remains available if KOReader changes the
-- private upvalue and this patch can no longer be applied.
do
    pcall(function()
        local info = debug.getinfo(SortWidget._populateItems, "u")
        for i = 1, info.nups do
            local name, SortItemWidget = debug.getupvalue(SortWidget._populateItems, i)
            if name == "SortItemWidget" and SortItemWidget and SortItemWidget.onTap then
                SortItemWidget.onTap = function(self, _, ges)
                    if self.item.checked_func and (self.show_parent.sort_disabled or ges.pos:intersectWith(self.checkmark_widget.dimen)) then
                        if self.item.callback then self.item:callback() end
                    elseif self.show_parent.sort_disabled then
                        if self.item.callback then self.item:callback() else return true end
                    elseif self.show_parent.marked == self.index then
                        if self.item.is_submenu and self.item.onSubmenuTap then
                            self.item.onSubmenuTap()
                            self.show_parent:_populateItems()
                            return true
                        end
                        self.show_parent.marked = 0
                    else
                        self.show_parent.marked = self.index
                    end
                    self.show_parent:_populateItems()
                    return true
                end
                break
            end
        end
    end)
end

local UIScreens = {
    current_view = "reader", -- "reader" or "filemanager"
    needs_restart = false,
}

function UIScreens:initView(ui)
    if ui and ui.document then
        self.current_view = "reader"
    else
        self.current_view = "filemanager"
    end
end

function UIScreens:getCurrentView(plugin)
    local active_plugin = plugin or self.plugin
    local ui = active_plugin and active_plugin.ui
    if ui and ui.document then
        return "reader"
    end
    return self.current_view or "filemanager"
end

function UIScreens:_collectRegisteredMenuItems(plugin)
    local active_plugin = plugin or self.plugin
    local menu = active_plugin and active_plugin.ui and active_plugin.ui.menu
    local menu_items = {}
    for _, widget in pairs(menu and menu.registered_widgets or {}) do
        if widget and type(widget.addToMainMenu) == "function" then
            pcall(widget.addToMainMenu, widget, menu_items)
        end
    end
    return menu_items
end

function UIScreens:reconcileRegisteredItems(plugin, view, persist)
    if plugin then self.plugin = plugin end
    local changed = MenuOrderManager:reconcileRegisteredItems(
        view, self:_collectRegisteredMenuItems(plugin)
    )
    if changed and persist then MenuOrderManager:saveOrder(view) end
    return changed
end

function UIScreens:reconcileLiveMenuItems(plugin, view, menu_id)
    local live_ids = self:_getLiveMenuItems(plugin, menu_id)
    return MenuOrderManager:reconcileMenuItems(view, menu_id, live_ids)
end

function UIScreens:promptRestart(msg)
    local message_text = msg or _("Menu order changes have been saved. Would you like to restart KOReader now for all changes to take full effect?")
    UIManager:show(ConfirmBox:new{
        text = message_text,
        ok_text = _("Restart now"),
        ok_callback = function()
            UIManager:broadcastEvent(Event:new("Restart"))
        end,
        cancel_text = _("Restart later"),
    })
end

function UIScreens:checkPromptRestartOnExit()
    if not self.needs_restart then return end
    self.needs_restart = false
    UIManager:nextTick(function()
        self:promptRestart()
    end)
end

function UIScreens:_getHiddenForMenu(view, menu_id)
    local disabled = MenuOrderManager:getDisabledItems(view)
    if #disabled == 0 then return {} end
    local default_order = MenuOrderManager:getDefaultOrder(view)
    local hidden_for_menu = {}
    local default_list = default_order[menu_id] or {}
    for _, item_id in ipairs(disabled) do
        if MenuOrderManager:getHiddenItemParent(view, item_id) == menu_id then
            table.insert(hidden_for_menu, item_id)
        else
            for _, default_id in ipairs(default_list) do
                if default_id == item_id then
                    table.insert(hidden_for_menu, item_id)
                    break
                end
            end
        end
    end
    return hidden_for_menu
end

-- Return the direct children of a menu as KOReader currently renders them.
-- Depending on where a menu lives, KOReader may represent its contents either
-- in sub_item_table or directly in the menu table itself.
function UIScreens:_getLiveMenuItems(plugin, menu_id)
    local menu = plugin and plugin.ui and plugin.ui.menu
    local function getTabItemTable(active_menu)
        if not active_menu then return nil end
        if type(active_menu.tab_item_table) ~= "table"
                and type(active_menu.setUpdateItemTable) == "function" then
            pcall(active_menu.setUpdateItemTable, active_menu)
        end
        if type(active_menu.tab_item_table) == "table" then
            return active_menu.tab_item_table
        end
    end

    local tab_item_table = getTabItemTable(menu)
    if type(tab_item_table) ~= "table" then
        -- A plugin instance can retain an older UI/menu reference after
        -- KOReader rebuilds the Reader or FileManager menu. The active base
        -- window still owns the authoritative live menu tree.
        for i = #(UIManager._window_stack or {}), 1, -1 do
            local entry = UIManager._window_stack[i]
            local widget = entry and (entry.widget or entry)
            local candidates = {
                widget or false,
                widget and widget.ui or false,
                widget and widget.show_parent or false,
            }
            for _, candidate in ipairs(candidates) do
                local active_menu = candidate and candidate.menu
                tab_item_table = getTabItemTable(active_menu)
                if type(tab_item_table) == "table" then break end
            end
            if type(tab_item_table) == "table" then break end
        end
    end
    if type(tab_item_table) ~= "table" then
        return {}, {}, false
    end

    local live_menu
    local ok_sorter, MenuSorter = pcall(require, "ui/menusorter")
    if ok_sorter and MenuSorter and MenuSorter.findById then
        live_menu = MenuSorter:findById(tab_item_table, menu_id)
    end

    if not live_menu then
        return {}, {}, false
    end

    local children = type(live_menu.sub_item_table) == "table"
        and live_menu.sub_item_table or live_menu
    local ids = {}
    local items_by_id = {}
    for _, item in ipairs(children) do
        if type(item) == "table" and item.id
                and item.id ~= MenuOrderManager.SEPARATOR_ID then
            table.insert(ids, item.id)
            items_by_id[item.id] = item
        end
    end
    return ids, items_by_id, true
end

-- Keep configured ordering for items that are actually registered, then add
-- newly registered plugin items in their live KOReader order. Missing entries
-- are returned separately so saving another change does not destroy data for a
-- feature that may only be temporarily unavailable on this device/document.
function UIScreens:_mergeConfiguredAndLiveItems(
        configured_items, hidden_items, live_ids, has_live_menu, recent_moves, menu_id)
    local hidden = {}
    for _, id in ipairs(hidden_items or {}) do hidden[id] = true end

    local live = {}
    for _, id in ipairs(live_ids or {}) do
        local moved_to = recent_moves and recent_moves[id]
        -- Ignore a stale live copy left in the old menu after a move.
        if not moved_to or moved_to == menu_id then
            live[id] = true
        end
    end

    local merged = {}
    local seen = {}
    local unavailable = {}
    for _, id in ipairs(configured_items or {}) do
        if id == MenuOrderManager.SEPARATOR_ID then
            table.insert(merged, id)
        elseif hidden[id] then
            -- Hidden entries are appended by the caller with their hidden state.
        elseif not has_live_menu or live[id]
                or (recent_moves and recent_moves[id] == menu_id) then
            if not seen[id] then
                table.insert(merged, id)
                seen[id] = true
            end
        else
            table.insert(unavailable, id)
        end
    end

    if has_live_menu then
        for _, id in ipairs(live_ids or {}) do
            local moved_to = recent_moves and recent_moves[id]
            if (not moved_to or moved_to == menu_id)
                    and not hidden[id] and not seen[id] then
                table.insert(merged, id)
                seen[id] = true
            end
        end
    end
    return merged, unavailable
end

function UIScreens:saveAndApply(plugin, view, silent)
    local active_plugin = plugin or self.plugin
    local ui = active_plugin and active_plugin.ui
    self:reconcileRegisteredItems(active_plugin, view, false)
    local ok, path = MenuOrderManager:saveOrder(view)
    if ok then
        self.needs_restart = true
        if ui then
            MenuOrderManager:applyLiveReload(ui, view)
        end
        local view_name = view == "reader" and _("Book view") or _("Normal view")
        if not silent then
            UIManager:show(Notification:new{
                text = string.format(_("%s menu order saved."), view_name),
            })
        end
    else
        UIManager:show(InfoMessage:new{
            text = string.format(_("Error saving configuration:\n%s"), tostring(path)),
        })
    end
end

function UIScreens:confirmResetSubmenu(plugin, view, menu_id, menu_title, on_success)
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Reset %s menu to default?"), menu_title),
        ok_text = _("Reset"),
        ok_callback = function()
            if not MenuOrderManager:resetSubmenu(view, menu_id) then
                UIManager:show(InfoMessage:new{
                    text = string.format(_("No default layout is available for %s."), menu_title),
                })
                return
            end

            self:reconcileRegisteredItems(plugin, view, false)
            local ok, err = MenuOrderManager:saveOrder(view)
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Error saving configuration:\n%s"), tostring(err)),
                })
                return
            end
            if plugin and plugin.ui then
                MenuOrderManager:applyLiveReload(plugin.ui, view)
            end
            if on_success then on_success() end
        end,
    })
end

-- =========================================================================
-- Top Tabs Reorder & Visibility Screen (SortWidget) - unified
-- =========================================================================

function UIScreens:showTabReorderDialog(plugin, view, on_close_callback)
    if plugin then self.plugin = plugin end
    view = view or self:getCurrentView(plugin)
    local sort_widget
    local function makeTabItem(tid)
        local tab_title = MenuTitles:getTitle(tid)
        local icon = MenuTitles:getIcon(tid)
        local display_text = icon and string.format("[%s] %s", tab_title, tid) or tab_title
        return {
            text = display_text,
            tab_id = tid,
            item_id = tid,
            is_submenu = true,
            onSubmenuTap = function()
                self:showItemSortWidget(plugin, view, tid, function()
                    if sort_widget then sort_widget:_populateItems() end
                end)
            end,
            checked_func = function()
                return not MenuOrderManager:isItemHidden(view, tid)
            end,
            callback = function()
                local is_hidden = MenuOrderManager:isItemHidden(view, tid)
                if not is_hidden then
                    self:reconcileLiveMenuItems(plugin, view, tid)
                    self:reconcileRegisteredItems(plugin, view, false)
                end
                MenuOrderManager:setTabHidden(view, tid, not is_hidden)
            end,
            hold_callback = function(self_item, refresh_func)
                local dialog
                dialog = ButtonDialog:new{
                    title = string.format(_("“%s”"), MenuTitles:getTitle(tid)),
                    title_align = "center",
                    buttons = {
                        {{
                            text = _("Edit submenu contents →"),
                            callback = function()
                                UIManager:close(dialog)
                                self:showItemSortWidget(plugin, view, tid, function()
                                    if refresh_func then refresh_func() end
                                end)
                            end,
                        }},
                        {{
                            text = _("Hide this tab"),
                            callback = function()
                                UIManager:close(dialog)
                                self:reconcileLiveMenuItems(plugin, view, tid)
                                self:reconcileRegisteredItems(plugin, view, false)
                                MenuOrderManager:setTabHidden(view, tid, true)
                                if refresh_func then refresh_func() end
                            end,
                        }},
                    },
                }
                UIManager:show(dialog)
            end,
        }
    end

    local function buildSortItems()
        local items = {}
        local seen = {}
        for _, tab_id in ipairs(MenuOrderManager:getTabs(view)) do
            seen[tab_id] = true
            table.insert(items, makeTabItem(tab_id))
        end
        for _, tab_id in ipairs(MenuOrderManager:getAllKnownTabs(view)) do
            if not seen[tab_id] then
                table.insert(items, makeTabItem(tab_id))
            end
        end
        return items
    end

    local sort_items = buildSortItems()
    local function refreshSortItems()
        if not sort_widget then return end
        sort_widget.item_table = buildSortItems()
        sort_widget.orig_item_table = nil
        sort_widget.marked = 0
        sort_widget.show_page = 1
        sort_widget.pages = math.max(1, math.ceil(#sort_widget.item_table / sort_widget.items_per_page))
        sort_widget:_populateItems()
    end

    local title_view = view == "reader" and _("Book view") or _("Normal view")
    local reset_menu_name = view == "reader" and _("Book") or _("Normal")
    sort_widget = SortWidget:new{
        title = string.format("%s (%s)", _("Reorder menus"), title_view),
        item_table = sort_items,
        callback = function()
            local source_items = (sort_widget and sort_widget.item_table) or sort_items
            local new_tabs = {}
            for __, sort_item in ipairs(source_items) do
                local tid = sort_item.tab_id
                if not MenuOrderManager:isItemHidden(view, tid) then
                    table.insert(new_tabs, tid)
                end
            end
            MenuOrderManager:reorderTabs(view, new_tabs)
            self:saveAndApply(plugin, view)
            if sort_widget then
                sort_widget.marked = 0
                sort_widget.orig_item_table = nil
            end
        end,
    }
    local orig_on_close = sort_widget.onClose
    sort_widget.onClose = function(this)
        local ret = orig_on_close(this)
        if on_close_callback then
            on_close_callback()
        else
            self:checkPromptRestartOnExit()
        end
        return ret
    end
    -- Top-level: add Edit submenu in hamburger, same as when continuing moving in submenu
    local outer_self_tab = self
    function sort_widget:onShowWidgetMenu()
        local this = self
        local dialog
        local buttons = {
            {{
                text = _("Sort A to Z"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    this:sortItems("natural")
                end,
            }},
            {{
                text = _("Sort Z to A"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    this:sortItems("natural", true)
                end,
            }},
        }
        local selected_submenu_id
        local selected_submenu_title
        if this.marked > 0 then
            local sel = this.item_table[this.marked]
            if sel and sel.tab_id then
                selected_submenu_id = sel.tab_id
                selected_submenu_title = MenuTitles:getTitle(sel.tab_id)
                table.insert(buttons, 1, {{
                    text = string.format(_("Edit submenu “%s” →"), selected_submenu_title),
                    align = "left",
                    callback = function()
                        UIManager:close(dialog)
                        outer_self_tab:showItemSortWidget(plugin, view, sel.tab_id, function()
                            this:_populateItems()
                        end)
                    end,
                }})
            end
        end
        table.insert(buttons, {{
            text = _("Presets…"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                outer_self_tab:showPresetsMenu(plugin, view, function(preset_applied)
                    if preset_applied then
                        refreshSortItems()
                    end
                end)
            end,
        }})
        table.insert(buttons, {{
            text = string.format(_("Reset %s menu"), reset_menu_name),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Reset %s menu to default?"), reset_menu_name),
                    ok_text = _("Reset"),
                    ok_callback = function()
                        MenuOrderManager:resetOrder(view)
                        if plugin and plugin.ui then MenuOrderManager:applyLiveReload(plugin.ui, view) end
                        UIManager:nextTick(function()
                            outer_self_tab:showTabReorderDialog(plugin, view)
                        end)
                        this:onClose()
                    end,
                })
            end,
        }})
        if selected_submenu_id then
            table.insert(buttons, {{
                text = string.format(_("Reset %s menu"), selected_submenu_title),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    outer_self_tab:confirmResetSubmenu(plugin, view, selected_submenu_id, selected_submenu_title, refreshSortItems)
                end,
            }})
        end
        table.insert(buttons, {{
            text = _("Reset all menus"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = _("Reset all menus for both views to default?"),
                    ok_text = _("Reset all"),
                    ok_callback = function()
                        MenuOrderManager:resetOrder("reader")
                        MenuOrderManager:resetOrder("filemanager")
                        if plugin and plugin.ui then
                            MenuOrderManager:applyLiveReload(plugin.ui, "reader")
                            MenuOrderManager:applyLiveReload(plugin.ui, "filemanager")
                        end
                        UIManager:nextTick(function()
                            outer_self_tab:showTabReorderDialog(plugin, view)
                        end)
                        this:onClose()
                    end,
                })
            end,
        }})
        dialog = ButtonDialog:new{
            shrink_unneeded_width = true,
            buttons = buttons,
            anchor = function()
                return this.title_bar.left_button.image.dimen
            end,
        }
        UIManager:show(dialog)
        return true
    end
    UIManager:show(sort_widget)
end

-- =========================================================================
-- Menu & Submenu Browser Screen - DIRECT to SortWidget (cleaned)
-- =========================================================================

function UIScreens:showMenuBrowser(plugin, view, on_close_callback)
    -- Selection interface removed per request: just open unified reordering interface
    -- Previously showed Menu with top tabs; now directly drills via SortWidget double-tap
    return self:showTabReorderDialog(plugin, view, on_close_callback)
end

-- =========================================================================
-- Menu Item Customizer Screen - DEPRECATED wrapper (kept for compatibility)
-- Now simply forwards to the standard SortWidget interface.
-- =========================================================================

function UIScreens:showMenuItemCustomizer(plugin, view, menu_id, on_close_callback)
    -- Compatibility shim: directly open unified SortWidget.
    -- Previously this showed an intermediate menu with duplicate separator / per-item list.
    -- Now all actions are inside SortWidget (drag, checkbox hide, hold to move, widget menu for separators).
    return self:showItemSortWidget(plugin, view, menu_id, on_close_callback)
end

-- =========================================================================
-- Item Sort Widget Screen - UNIFIED reordering interface
-- Handles reorder, hide/show (checkbox), separators, move between menus via long-press
-- =========================================================================

function UIScreens:showItemSortWidget(plugin, view, menu_id, on_close_callback)
    if plugin then self.plugin = plugin end
    local menu_title = MenuTitles:getTitle(menu_id)
    local configured_items = MenuOrderManager:getMenuItems(view, menu_id)

    local hidden_for_menu = self:_getHiddenForMenu(view, menu_id)
    local hidden_set = {}
    for _, id in ipairs(hidden_for_menu) do hidden_set[id] = true end
    -- Also retain malformed/older configurations that left a disabled item in
    -- its menu list instead of removing it.
    for _, id in ipairs(configured_items) do
        if id ~= MenuOrderManager.SEPARATOR_ID
                and MenuOrderManager:isItemHidden(view, id) and not hidden_set[id] then
            table.insert(hidden_for_menu, id)
            hidden_set[id] = true
        end
    end

    local live_ids, live_items_by_id, has_live_menu = self:_getLiveMenuItems(plugin, menu_id)
    local items, unavailable_items = self:_mergeConfiguredAndLiveItems(
        configured_items, hidden_for_menu, live_ids, has_live_menu,
        MenuOrderManager:getRecentMoves(view), menu_id
    )

    local sort_widget
    local getCurrentEditorOrder
    local refreshEditorAfterMove

    local function create_sep_item()
        local this_entry
        this_entry = {
            text = _("--- Separator ---"),
            item_id = MenuOrderManager.SEPARATOR_ID,
            checked_func = function() return true end,
            hold_callback = function(self_item, refresh_func)
                UIManager:show(ConfirmBox:new{
                    text = _("Delete this separator?"),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        if sort_widget and sort_widget.item_table then
                            for i, sit in ipairs(sort_widget.item_table) do
                                if sit == this_entry then
                                    table.remove(sort_widget.item_table, i)
                                    sort_widget.pages = math.ceil(#sort_widget.item_table / sort_widget.items_per_page)
                                    if sort_widget.show_page > sort_widget.pages then
                                        sort_widget.show_page = math.max(1, sort_widget.pages)
                                    end
                                    sort_widget.marked = 0
                                    if refresh_func then refresh_func() end
                                    UIManager:show(Notification:new{ text = _("Separator deleted.") })
                                    break
                                end
                            end
                        end
                    end,
                })
            end,
        }
        return this_entry
    end

    -- Build ordered list: visible items + hidden items for this menu at bottom (unchecked)
    local sort_items = {}
    local seen_hidden = {}

    local function makeSortItem(id, submenu_flag, disp_text)
        local this_id = id
        local is_sub = submenu_flag
        local text_for_closure = disp_text
        local submenu_cb = nil
        if is_sub then
            submenu_cb = function()
                self:showItemSortWidget(plugin, view, this_id, function()
                    if sort_widget then sort_widget:_populateItems() end
                end)
            end
        end
        return {
            text = text_for_closure,
            item_id = this_id,
            is_submenu = is_sub,
            onSubmenuTap = submenu_cb,
            checked_func = function()
                return not MenuOrderManager:isItemHidden(view, this_id)
            end,
            callback = function()
                local is_hidden = MenuOrderManager:isItemHidden(view, this_id)
                MenuOrderManager:setItemHidden(view, this_id, not is_hidden, menu_id)
            end,
            hold_callback = function(self_item, refresh_func)
                local dialog
                local buttons = {
                    {
                        {
                            text = _("Move to another menu…"),
                            callback = function()
                                UIManager:close(dialog)
                                self:showDestinationMenuChooser(
                                    plugin, view, this_id, menu_id,
                                    function(moved_item_id)
                                        if refreshEditorAfterMove then
                                            refreshEditorAfterMove(moved_item_id)
                                        elseif refresh_func then
                                            refresh_func()
                                        end
                                    end,
                                    getCurrentEditorOrder and getCurrentEditorOrder() or nil
                                )
                            end,
                        }
                    },
                    {
                        {
                            text = _("Hide this item"),
                            callback = function()
                                UIManager:close(dialog)
                                MenuOrderManager:setItemHidden(view, this_id, true, menu_id)
                                if refresh_func then refresh_func() end
                            end,
                        }
                    },
                }
                if is_sub then
                    table.insert(buttons, {
                        {
                            text = _("Edit submenu contents →"),
                            callback = function()
                                UIManager:close(dialog)
                                self:showItemSortWidget(plugin, view, this_id, function()
                                    if refresh_func then refresh_func() end
                                end)
                            end,
                        }
                    })
                end
                dialog = ButtonDialog:new{
                    title = string.format(_("“%s”"), MenuTitles:getTitle(this_id, live_items_by_id)),
                    title_align = "center",
                    buttons = buttons,
                }
                UIManager:show(dialog)
            end,
        }
    end

    for idx, item_id in ipairs(items) do
        local is_sep = (item_id == MenuOrderManager.SEPARATOR_ID)
        if is_sep then
            table.insert(sort_items, create_sep_item())
        else
            local item_title = MenuTitles:getTitle(item_id, live_items_by_id)
            -- Only KOReader order-table submenus are editable here. A plugin may
            -- expose its own sub_item_table (for example HTTP Inspector), but
            -- its internal arrangement is owned by that plugin and cannot be
            -- safely persisted through KOReader's menu order.
            local is_submenu = MenuOrderManager:isSubmenu(view, item_id)
            local display_text = string.format("%s%s", is_submenu and "[+] " or "", item_title)
            table.insert(sort_items, makeSortItem(item_id, is_submenu, display_text))
        end
    end

    for __, hid in ipairs(hidden_for_menu) do
        -- Only add if not already visible (shouldn't be)
        local already = false
        for __, it in ipairs(items) do
            if it == hid then already = true; break end
        end
        if not already and not seen_hidden[hid] then
            seen_hidden[hid] = true
            local item_title = MenuTitles:getTitle(hid, live_items_by_id)
            local is_submenu = MenuOrderManager:isSubmenu(view, hid)
            local display_text = string.format("%s%s (%s)", is_submenu and "[+] " or "", item_title, _("hidden"))
            local this_id = hid
            table.insert(sort_items, {
                text = display_text,
                item_id = this_id,
                dim = true,
                checked_func = function()
                    return false -- hidden => unchecked
                end,
                callback = function()
                    -- Tapping checkbox restores
                    MenuOrderManager:setItemHidden(view, this_id, false, menu_id)
                end,
                hold_callback = function(self_item, refresh_func)
                    UIManager:show(ConfirmBox:new{
                        text = string.format(_("Restore “%s” to this menu?"), MenuTitles:getTitle(this_id, live_items_by_id)),
                        ok_text = _("Restore"),
                        ok_callback = function()
                            MenuOrderManager:setItemHidden(view, this_id, false, menu_id)
                            if refresh_func then refresh_func() end
                        end,
                    })
                end,
            })
        end
    end

    -- If no items and no hidden, add hint
    if #sort_items == 0 then
        table.insert(sort_items, {
            text = _("(No items in this menu)"),
            item_id = "__empty_hint__",
            checked_func = function() return true end,
            callback = function() end,
        })
    end

    local function buildOrderFromSortItems(source_items)
        local new_list = {}
        for _, sort_item in ipairs(source_items or {}) do
            local iid = sort_item.item_id
            if iid == "__empty_hint__" then
                -- skip hint
            elseif iid == MenuOrderManager.SEPARATOR_ID or not MenuOrderManager:isItemHidden(view, iid) then
                table.insert(new_list, iid)
            end
        end
        return new_list
    end

    local function buildPersistentOrder(source_items)
        local new_list = buildOrderFromSortItems(source_items)
        local present = {}
        for _, id in ipairs(new_list) do
            if id ~= MenuOrderManager.SEPARATOR_ID then present[id] = true end
        end
        for _, id in ipairs(unavailable_items) do
            if not present[id] and not MenuOrderManager:isItemHidden(view, id) then
                table.insert(new_list, id)
                present[id] = true
            end
        end
        return new_list
    end

    -- A cross-menu move is saved immediately. Include any pending drag, sort,
    -- separator, or visibility changes from this editor in that same save so
    -- opening the destination chooser cannot silently discard them.
    getCurrentEditorOrder = function()
        local source_items = (sort_widget and sort_widget.item_table) or sort_items
        return buildPersistentOrder(source_items)
    end

    -- The SortWidget owns a separate UI model from MenuOrderManager. Merely
    -- repainting it after a move leaves the old row and parent/index captured
    -- in its callbacks; the next separator/sort/OK action can then put the item
    -- back in its source menu. Remove it from the editor model and reset all
    -- selection/paging state to the newly saved source menu instead.
    refreshEditorAfterMove = function(moved_item_id)
        if not sort_widget or not sort_widget.item_table then return end
        for i = #sort_widget.item_table, 1, -1 do
            if sort_widget.item_table[i].item_id == moved_item_id then
                table.remove(sort_widget.item_table, i)
            end
        end
        if #sort_widget.item_table == 0 then
            table.insert(sort_widget.item_table, {
                text = _("(No items in this menu)"),
                item_id = "__empty_hint__",
                checked_func = function() return true end,
                callback = function() end,
            })
        end
        sort_widget.orig_item_table = nil
        sort_widget.marked = 0
        sort_widget.pages = math.max(1, math.ceil(#sort_widget.item_table / sort_widget.items_per_page))
        sort_widget.show_page = math.min(math.max(1, sort_widget.show_page), sort_widget.pages)
        sort_widget:_populateItems()
    end

    sort_widget = SortWidget:new{
        title = string.format("%s - %s", _("Reorder"), menu_title),
        item_table = sort_items,
        callback = function()
            local source_items = (sort_widget and sort_widget.item_table) or sort_items
            local order = MenuOrderManager:loadOrder(view)
            order[menu_id] = buildPersistentOrder(source_items)
            self:saveAndApply(plugin, view)
            -- Ensure check always goes up a level
            if sort_widget then
                sort_widget.marked = 0
                sort_widget.orig_item_table = nil
            end
        end,
    }

    local orig_on_close = sort_widget.onClose
    sort_widget.onClose = function(this)
        local ret = orig_on_close(this)
        if on_close_callback then
            on_close_callback()
        else
            self:checkPromptRestartOnExit()
        end
        return ret
    end

    local outer_self_item = self
    function sort_widget:onShowWidgetMenu()
        local this = self
        local dialog
        local sep_text = this.marked > 0 and _("Insert separator after selection") or _("Add separator at bottom")
        local sep_msg = this.marked > 0 and _("Separator inserted after.") or _("Separator added at bottom.")
        local buttons = {
            {{
                text = sep_text,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    local insert_pos
                    if this.marked > 0 then
                        insert_pos = this.marked + 1
                    else
                        insert_pos = #this.item_table + 1
                    end
                    local new_sep = create_sep_item()
                    for i = #this.item_table, 1, -1 do
                        if this.item_table[i].item_id == "__empty_hint__" then
                            table.remove(this.item_table, i)
                            if insert_pos > #this.item_table + 1 then insert_pos = #this.item_table + 1 end
                        end
                    end
                    table.insert(this.item_table, insert_pos, new_sep)
                    this.pages = math.ceil(#this.item_table / this.items_per_page)
                    this.show_page = math.ceil(insert_pos / this.items_per_page)
                    this.marked = insert_pos
                    this:_populateItems()
                    UIManager:show(Notification:new{ text = sep_msg })
                end,
            }},
            {{
                text = _("Move item to another menu…"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    if this.marked > 0 and this.item_table[this.marked] then
                        local iid = this.item_table[this.marked].item_id
                        if iid and iid ~= MenuOrderManager.SEPARATOR_ID and iid ~= "__empty_hint__" then
                            outer_self_item:showDestinationMenuChooser(
                                plugin, view, iid, menu_id,
                                function(moved_item_id)
                                    refreshEditorAfterMove(moved_item_id)
                                end,
                                getCurrentEditorOrder()
                            )
                        else
                            UIManager:show(InfoMessage:new{ text = _("Select a regular item first (tap to mark).") })
                        end
                    else
                        UIManager:show(InfoMessage:new{ text = _("Mark an item first (tap its row), then use this to move it.") })
                    end
                end,
            }},
            {{
                text = _("Sort A to Z"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    this:sortItems("natural")
                end,
            }},
            {{
                text = _("Sort Z to A"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    this:sortItems("natural", true)
                end,
            }},
        }
        local selected_submenu_id
        local selected_submenu_title
        if this.marked > 0 then
            local sel = this.item_table[this.marked]
            if sel and sel.item_id and sel.is_submenu then
                selected_submenu_id = sel.item_id
                selected_submenu_title = MenuTitles:getTitle(sel.item_id, live_items_by_id)
                table.insert(buttons, 5, {{
                    text = string.format(_("Edit submenu “%s” →"), selected_submenu_title),
                    align = "left",
                    callback = function()
                        UIManager:close(dialog)
                        outer_self_item:showItemSortWidget(plugin, view, sel.item_id, function()
                            this:_populateItems()
                        end)
                    end,
                }})
            end
        end
        table.insert(buttons, {{
            text = string.format(_("Presets for %s…"), menu_title),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                local current_menu_items = buildOrderFromSortItems(this.item_table)
                outer_self_item:showSubmenuPresetsMenu(plugin, view, menu_id, menu_title, function(preset_applied)
                    if preset_applied then
                        UIManager:nextTick(function()
                            outer_self_item:showItemSortWidget(plugin, view, menu_id, on_close_callback)
                        end)
                        this:onClose()
                    end
                end, current_menu_items)
            end,
        }})
        table.insert(buttons, {{
            text = string.format(_("Reset %s menu"), menu_title),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                outer_self_item:confirmResetSubmenu(plugin, view, menu_id, menu_title, function()
                    UIManager:nextTick(function()
                        outer_self_item:showItemSortWidget(plugin, view, menu_id, on_close_callback)
                    end)
                    this:onClose()
                end)
            end,
        }})
        if selected_submenu_id then
            table.insert(buttons, {{
                text = string.format(_("Reset %s menu"), selected_submenu_title),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    outer_self_item:confirmResetSubmenu(plugin, view, selected_submenu_id, selected_submenu_title, function()
                        this:_populateItems()
                    end)
                end,
            }})
        end
        table.insert(buttons, {{
            text = _("Reset all menus"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = _("Reset all menus for both views to default?"),
                    ok_text = _("Reset all"),
                    ok_callback = function()
                        MenuOrderManager:resetOrder("reader")
                        MenuOrderManager:resetOrder("filemanager")
                        if plugin and plugin.ui then
                            MenuOrderManager:applyLiveReload(plugin.ui, "reader")
                            MenuOrderManager:applyLiveReload(plugin.ui, "filemanager")
                        end
                        UIManager:nextTick(function()
                            outer_self_item:showTabReorderDialog(plugin, view)
                        end)
                        this:onClose()
                    end,
                })
            end,
        }})
        dialog = ButtonDialog:new{
            shrink_unneeded_width = true,
            buttons = buttons,
            anchor = function()
                return this.title_bar.left_button.image.dimen
            end,
        }
        UIManager:show(dialog)
        return true
    end

    UIManager:show(sort_widget)
end

-- =========================================================================
-- Detailed Item Action Dialog (kept for search & compatibility)
-- Now streamlined: only used via search results or hold callback
-- =========================================================================

function UIScreens:showItemActionDialog(plugin, view, menu_id, item_id, idx, on_update_callback)
    if plugin then self.plugin = plugin end
    local is_sep = (item_id == MenuOrderManager.SEPARATOR_ID)
    local item_title = is_sep and _("Separator") or MenuTitles:getTitle(item_id)
    local items = MenuOrderManager:getMenuItems(view, menu_id)
    local total_items = #items

    local actions = {}

    if not is_sep then
        if idx > 1 then
            table.insert(actions, {
                text = _("Move up"),
                callback = function()
                    MenuOrderManager:moveItem(view, menu_id, idx, idx - 1)
                    self:saveAndApply(plugin, view)
                    on_update_callback()
                end,
            })
        end
        if idx < total_items then
            table.insert(actions, {
                text = _("Move down"),
                callback = function()
                    MenuOrderManager:moveItem(view, menu_id, idx, idx + 1)
                    self:saveAndApply(plugin, view)
                    on_update_callback()
                end,
            })
        end
        if idx > 1 then
            table.insert(actions, {
                text = _("Move to top"),
                callback = function()
                    MenuOrderManager:moveItem(view, menu_id, idx, 1)
                    self:saveAndApply(plugin, view)
                    on_update_callback()
                end,
            })
        end
        if idx < total_items then
            table.insert(actions, {
                text = _("Move to bottom"),
                callback = function()
                    MenuOrderManager:moveItem(view, menu_id, idx, total_items)
                    self:saveAndApply(plugin, view)
                    on_update_callback()
                end,
            })
        end
        table.insert(actions, {
            text = _("Move to another menu…"),
            separator = true,
            callback = function()
                self:showDestinationMenuChooser(plugin, view, item_id, menu_id, on_update_callback)
            end,
        })
        table.insert(actions, {
            text = _("Hide / disable this item"),
            callback = function()
                MenuOrderManager:setItemHidden(view, item_id, true, menu_id)
                self:saveAndApply(plugin, view)
                on_update_callback()
            end,
        })
        if MenuOrderManager:isSubmenu(view, item_id) then
            table.insert(actions, {
                text = _("Open and reorder this submenu"),
                separator = true,
                callback = function()
                    self:showItemSortWidget(plugin, view, item_id, on_update_callback)
                end,
            })
        end
    else
        if idx > 1 then
            table.insert(actions, {
                text = _("Move separator up"),
                callback = function()
                    MenuOrderManager:moveItem(view, menu_id, idx, idx - 1)
                    self:saveAndApply(plugin, view)
                    on_update_callback()
                end,
            })
        end
        if idx < total_items then
            table.insert(actions, {
                text = _("Move separator down"),
                callback = function()
                    MenuOrderManager:moveItem(view, menu_id, idx, idx + 1)
                    self:saveAndApply(plugin, view)
                    on_update_callback()
                end,
            })
        end
        table.insert(actions, {
            text = _("Delete separator"),
            callback = function()
                MenuOrderManager:removeSeparator(view, menu_id, idx)
                self:saveAndApply(plugin, view)
                on_update_callback()
            end,
        })
    end

    local action_dialog
    action_dialog = Menu:new{
        title = string.format("%s: %s", _("Action for"), item_title),
        item_table = actions,
    }
    UIManager:show(action_dialog)
end

-- =========================================================================
-- Destination Menu Chooser (Move item to another tab or submenu)
-- =========================================================================

function UIScreens:showDestinationMenuChooser(
        plugin, view, item_id, from_menu_id, on_moved_callback, pending_source_order)
    if plugin then self.plugin = plugin end
    local all_menus = MenuOrderManager:getAllMenusAndSubmenus(view)
    local choices = {}

    for __, entry in ipairs(all_menus) do
        local target_mid = entry.id
        local can_move = MenuOrderManager:canMoveItemToMenu(view, item_id, from_menu_id, target_mid)
        if can_move then
            local is_tab = entry.is_tab
            local title = MenuTitles:getTitle(target_mid)
            local prefix = is_tab and "[Tab] " or "[Menu] "

            table.insert(choices, {
                text = string.format("%s%s", prefix, title),
                callback = function()
                    -- The open source editor may contain unsaved reordering or
                    -- separators. Stage that exact model only when a destination
                    -- is selected (not when the chooser is merely opened).
                    local order = MenuOrderManager:loadOrder(view)
                    local previous_source_order
                    if pending_source_order then
                        previous_source_order = util.tableDeepCopy(order[from_menu_id])
                        order[from_menu_id] = util.tableDeepCopy(pending_source_order)
                    end
                    local moved, err = MenuOrderManager:moveItemToMenu(view, item_id, from_menu_id, target_mid)
                    if not moved then
                        if previous_source_order then
                            order[from_menu_id] = previous_source_order
                        end
                        UIManager:show(InfoMessage:new{
                            text = err or _("This item cannot be moved to that menu."),
                        })
                        return
                    end
                    self:saveAndApply(plugin, view)
                    UIManager:show(Notification:new{
                        text = string.format(_("Moved to %s."), title),
                    })
                    if on_moved_callback then
                        on_moved_callback(item_id, from_menu_id, target_mid)
                    end
                end,
            })
        end
    end

    local chooser_dialog
    chooser_dialog = Menu:new{
        title = string.format(_("Move “%s” to:"), MenuTitles:getTitle(item_id)),
        item_table = choices,
    }
    UIManager:show(chooser_dialog)
end

-- =========================================================================
-- Hidden Items Manager Screen
-- =========================================================================

function UIScreens:showHiddenItemsManager(plugin, view, on_close_callback)
    if plugin then self.plugin = plugin end
    local disabled = MenuOrderManager:getDisabledItems(view)
    local function refresh()
        self:showHiddenItemsManager(plugin, view, on_close_callback)
    end

    if #disabled == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No items are currently hidden in this view."),
        })
        return
    end

    local items = {
        {
            text = _("Unhide all items"),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Unhide and restore all hidden items to their default locations?"),
                    ok_text = _("Unhide all"),
                    ok_callback = function()
                        for __, id in ipairs(util.tableDeepCopy(disabled)) do
                            MenuOrderManager:setItemHidden(view, id, false)
                        end
                        self:saveAndApply(plugin, view)
                        if on_close_callback then on_close_callback() end
                    end,
                })
            end,
            separator = true,
        },
    }

    for __, item_id in ipairs(disabled) do
        local title = MenuTitles:getTitle(item_id)
        local desc = MenuTitles:getDescription(item_id)
        local label = desc and string.format("%s (%s)", title, desc) or title

        table.insert(items, {
            text = label,
            help_text = _("Tap to unhide and restore this item."),
            callback = function()
                MenuOrderManager:setItemHidden(view, item_id, false)
                self:saveAndApply(plugin, view)
                UIManager:show(Notification:new{
                    text = string.format(_("Restored “%s”."), title),
                })
                refresh()
            end,
        })
    end

    local dialog
    dialog = Menu:new{
        title = string.format("%s (%d)", _("Hidden items"), #disabled),
        item_table = items,
        on_close = function()
            if on_close_callback then
                on_close_callback()
            else
                self:checkPromptRestartOnExit()
            end
        end,
    }
    UIManager:show(dialog)
end

-- =========================================================================
-- Search Dialog & Search Results
-- =========================================================================

function UIScreens:showSearchDialog(plugin, view, on_close_callback)
    if plugin then self.plugin = plugin end
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Search menu items"),
        input_hint = _("e.g. font, wifi, timer, toc, gesture"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                        if on_close_callback then
                            on_close_callback()
                        else
                            self:checkPromptRestartOnExit()
                        end
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if query and query:match("%S") then
                            self:showSearchResults(plugin, view, query, on_close_callback)
                        else
                            if on_close_callback then
                                on_close_callback()
                            else
                                self:checkPromptRestartOnExit()
                            end
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function UIScreens:showSearchResults(plugin, view, query, on_close_callback)
    if plugin then self.plugin = plugin end
    local clean_query = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local all_menus = MenuOrderManager:getAllMenusAndSubmenus(view)
    local disabled = MenuOrderManager:getDisabledItems(view)

    local matches = {}
    local seen = {}

    for __, menu_entry in ipairs(all_menus) do
        local mid = menu_entry.id
        local items = MenuOrderManager:getMenuItems(view, mid)
        for idx, item_id in ipairs(items) do
            if item_id ~= MenuOrderManager.SEPARATOR_ID and not seen[item_id] then
                local title = MenuTitles:getTitle(item_id):lower()
                if item_id:lower():find(clean_query, 1, true) or title:find(clean_query, 1, true) then
                    seen[item_id] = true
                    table.insert(matches, {
                        item_id = item_id,
                        menu_id = mid,
                        idx = idx,
                        is_hidden = false,
                    })
                end
            end
        end
    end

    for __, item_id in ipairs(disabled) do
        if not seen[item_id] then
            local title = MenuTitles:getTitle(item_id):lower()
            if item_id:lower():find(clean_query, 1, true) or title:find(clean_query, 1, true) then
                seen[item_id] = true
                table.insert(matches, {
                    item_id = item_id,
                    menu_id = nil,
                    idx = nil,
                    is_hidden = true,
                })
            end
        end
    end

    if #matches == 0 then
        UIManager:show(InfoMessage:new{
            text = string.format(_("No menu items matching “%s” were found."), query),
        })
        return
    end

    local result_items = {}
    for __, match in ipairs(matches) do
        local item_id = match.item_id
        local title = MenuTitles:getTitle(item_id)
        local location = match.is_hidden and _("Hidden") or MenuTitles:getTitle(match.menu_id)
        local status_prefix = match.is_hidden and "[Hidden] " or ""
        local row_text = string.format("%s%s [%s: %s]", status_prefix, title, _("in"), location)

        table.insert(result_items, {
            text = row_text,
            callback = function()
                if match.is_hidden then
                    MenuOrderManager:setItemHidden(view, item_id, false)
                    self:saveAndApply(plugin, view)
                    UIManager:show(Notification:new{
                        text = string.format(_("Unhid “%s”."), title),
                    })
                    self:showSearchResults(plugin, view, query, on_close_callback)
                else
                    self:showItemActionDialog(plugin, view, match.menu_id, item_id, match.idx, function()
                        self:showSearchResults(plugin, view, query, on_close_callback)
                    end)
                end
            end,
        })
    end

    local results_dialog
    results_dialog = Menu:new{
        title = string.format(_("Search: “%s” (%d found)"), query, #matches),
        item_table = result_items,
        on_close = function()
            if on_close_callback then
                on_close_callback()
            else
                self:checkPromptRestartOnExit()
            end
        end,
    }
    UIManager:show(results_dialog)
end

-- =========================================================================
-- Raw Configuration Viewer (TextViewer)
-- =========================================================================

function UIScreens:showRawConfigViewer(_, view)
    local order = MenuOrderManager:loadOrder(view)
    local serialized = "-- Configuration for " .. (view == "reader" and "Book view" or "Normal view") .. "\nreturn " .. dump(order, nil, true)
    local viewer = TextViewer:new{
        title = string.format("%s (%s)", _("Menu configuration"), view == "reader" and _("Book view") or _("Normal view")),
        text = serialized,
        alignment = "left",
        auto_para_direction = false,
    }
    UIManager:show(viewer)
end

-- =========================================================================
-- Preset Management UI
-- =========================================================================

local function submenuPresetPrefix(preset)
    return preset.include_submenus and "[Nested] " or "[Direct] "
end

function UIScreens:showSaveSubmenuPresetDialog(plugin, view, menu_id, menu_title, include_submenus, on_close_callback, current_menu_items)
    if plugin then self.plugin = plugin end
    local input_dialog
    input_dialog = InputDialog:new{
        title = include_submenus
            and string.format(_("Save %s and nested menus"), menu_title)
            or string.format(_("Save %s menu order"), menu_title),
        input_hint = _("e.g. My preferred order"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                        if on_close_callback then on_close_callback() end
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local name = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if name and name:match("%S") then
                            local ok, result = MenuOrderManager:saveSubmenuPreset(
                                view, menu_id, menu_title, name, include_submenus, current_menu_items
                            )
                            if ok then
                                UIManager:show(Notification:new{
                                    text = string.format(_("Saved preset “%s” for %s."), name, menu_title),
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = string.format(_("Error saving submenu preset:\n%s"), tostring(result)),
                                })
                            end
                        end
                        if on_close_callback then on_close_callback() end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function UIScreens:showDeleteSubmenuPresetMenu(plugin, view, menu_id, menu_title, on_close_callback)
    if plugin then self.plugin = plugin end
    local presets = MenuOrderManager:listSubmenuPresets(view, menu_id)
    if #presets == 0 then
        UIManager:show(InfoMessage:new{ text = _("No submenu presets to delete.") })
        if on_close_callback then on_close_callback() end
        return
    end

    local items = {}
    local dialog
    for _, preset in ipairs(presets) do
        local current_preset = preset
        table.insert(items, {
            text = submenuPresetPrefix(current_preset) .. current_preset.name,
            help_text = current_preset.description,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Delete preset “%s” for %s?"), current_preset.name, menu_title),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        local ok, err = MenuOrderManager:deleteSubmenuPreset(view, menu_id, current_preset)
                        if ok then
                            UIManager:show(Notification:new{
                                text = string.format(_("Deleted preset “%s”."), current_preset.name),
                            })
                            dialog.on_close = nil
                            UIManager:close(dialog)
                            if on_close_callback then on_close_callback() end
                        else
                            UIManager:show(InfoMessage:new{ text = tostring(err or _("Failed to delete.")) })
                        end
                    end,
                })
            end,
        })
    end

    dialog = Menu:new{
        title = string.format(_("Delete presets for %s"), menu_title),
        item_table = items,
        on_close = on_close_callback,
    }
    UIManager:show(dialog)
end

function UIScreens:showSubmenuPresetsMenu(plugin, view, menu_id, menu_title, on_close_callback, current_menu_items)
    if plugin then self.plugin = plugin end
    local presets = MenuOrderManager:listSubmenuPresets(view, menu_id)
    local preset_applied = false
    local items = {}
    local menu_dialog

    local function closeForNavigation()
        menu_dialog.on_close = nil
        UIManager:close(menu_dialog)
    end

    table.insert(items, {
        text = _("Save this menu order…"),
        help_text = _("Capture only the direct item order of this menu. Visibility is unchanged."),
        callback = function()
            closeForNavigation()
            self:showSaveSubmenuPresetDialog(plugin, view, menu_id, menu_title, false, function()
                self:showSubmenuPresetsMenu(plugin, view, menu_id, menu_title, on_close_callback, current_menu_items)
            end, current_menu_items)
        end,
    })
    table.insert(items, {
        text = _("Save with nested submenu orders…"),
        help_text = _("Capture this menu order and the order of every submenu below it."),
        callback = function()
            closeForNavigation()
            self:showSaveSubmenuPresetDialog(plugin, view, menu_id, menu_title, true, function()
                self:showSubmenuPresetsMenu(plugin, view, menu_id, menu_title, on_close_callback, current_menu_items)
            end, current_menu_items)
        end,
        separator = true,
    })

    for _, preset in ipairs(presets) do
        local current_preset = preset
        table.insert(items, {
            text = submenuPresetPrefix(current_preset) .. current_preset.name,
            help_text = current_preset.description,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Apply preset “%s” to %s?"), current_preset.name, menu_title),
                    ok_text = _("Apply"),
                    ok_callback = function()
                        local ok, err = MenuOrderManager:loadSubmenuPreset(view, menu_id, current_preset, current_menu_items)
                        if ok then
                            preset_applied = true
                            self.needs_restart = true
                            if plugin and plugin.ui then
                                MenuOrderManager:applyLiveReload(plugin.ui, view)
                            end
                            UIManager:show(Notification:new{
                                text = string.format(_("Loaded preset “%s” for %s."), current_preset.name, menu_title),
                            })
                            UIManager:close(menu_dialog)
                        else
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("Failed to load submenu preset:\n%s"), tostring(err)),
                            })
                        end
                    end,
                })
            end,
        })
    end

    if #presets > 0 then
        table.insert(items, {
            text = _("Delete preset…"),
            help_text = string.format(_("Delete a saved preset for %s."), menu_title),
            callback = function()
                closeForNavigation()
                self:showDeleteSubmenuPresetMenu(plugin, view, menu_id, menu_title, function()
                    self:showSubmenuPresetsMenu(plugin, view, menu_id, menu_title, on_close_callback, current_menu_items)
                end)
            end,
            separator = true,
        })
    end

    menu_dialog = Menu:new{
        title = string.format(_("Presets for %s"), menu_title),
        item_table = items,
        on_close = function()
            if on_close_callback then on_close_callback(preset_applied) end
        end,
    }
    UIManager:show(menu_dialog)
end

function UIScreens:showPresetsMenu(plugin, view, on_close_callback)
    if plugin then self.plugin = plugin end
    local view_label = (view == "reader") and _("Book view") or _("Normal view")
    local presets = MenuOrderManager:getAllPresets(view)
    local preset_applied = false

    local items = {}
    local menu_dialog

    -- Save action at top (normal menu entry) - close current before opening save dialog to avoid stacking
    table.insert(items, {
        text = _("Save current as preset…"),
        help_text = _("Save the current menu layout with a custom name."),
        callback = function()
            UIManager:close(menu_dialog)
            self:showSavePresetDialog(plugin, view, function()
                self:showPresetsMenu(plugin, view, on_close_callback)
            end)
        end,
        separator = true,
    })

    -- Direct list of all presets in the same normal Menu (no additional interface)
    for __, preset in ipairs(presets) do
        local prefix = preset.is_builtin and "[Built-in] " or "[Custom] "
        -- capture preset for closure
        local cur_preset = preset
        table.insert(items, {
            text = prefix .. cur_preset.name,
            help_text = cur_preset.description,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Apply preset “%s”?"), cur_preset.name),
                    ok_text = _("Apply"),
                    ok_callback = function()
                        local ok, err = MenuOrderManager:loadPreset(view, cur_preset)
                        if ok then
                            self:reconcileRegisteredItems(plugin, view, true)
                            preset_applied = true
                            self.needs_restart = true
                            if plugin and plugin.ui then
                                MenuOrderManager:applyLiveReload(plugin.ui, view)
                            end
                            UIManager:close(menu_dialog)
                            UIManager:show(Notification:new{
                                text = string.format(_("Loaded preset “%s”."), cur_preset.name),
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("Failed to load preset:\n%s"), tostring(err)),
                            })
                        end
                    end,
                })
            end,
        })
    end

    -- Delete action at bottom if any deletable presets exist (custom + built-ins except default)
    local deletable = MenuOrderManager:listDeletablePresets(view)
    if #deletable > 0 then
        table.insert(items, {
            text = _("Delete preset…"),
            help_text = _("Remove a custom or built-in preset (default cannot be deleted)."),
            callback = function()
                UIManager:close(menu_dialog)
                self:showDeletePresetMenu(plugin, view, function()
                    self:showPresetsMenu(plugin, view, on_close_callback)
                end)
            end,
            separator = true,
        })
    end

    menu_dialog = Menu:new{
        title = string.format("%s - %s", _("Presets"), view_label),
        item_table = items,
        on_close = function()
            if on_close_callback then
                on_close_callback(preset_applied)
            else
                self:checkPromptRestartOnExit()
            end
        end,
    }
    UIManager:show(menu_dialog)
end

function UIScreens:showLoadPresetMenu(plugin, view, on_close_callback)
    if plugin then self.plugin = plugin end
    local presets = MenuOrderManager:getAllPresets(view)
    local items = {}

    for _, preset in ipairs(presets) do
        local cur_preset = preset
        local prefix = cur_preset.is_builtin and "[Built-in] " or "[Custom] "
        table.insert(items, {
            text = prefix .. cur_preset.name,
            help_text = cur_preset.description,
            callback = function()
                local ok, err = MenuOrderManager:loadPreset(view, cur_preset)
                if ok then
                    self:reconcileRegisteredItems(plugin, view, true)
                    self.needs_restart = true
                    if plugin and plugin.ui then
                        MenuOrderManager:applyLiveReload(plugin.ui, view)
                    end
                    UIManager:show(Notification:new{
                        text = string.format(_("Loaded preset “%s”."), cur_preset.name),
                    })
                    if on_close_callback then on_close_callback() end
                else
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Failed to load preset:\n%s"), tostring(err)),
                    })
                end
            end,
        })
    end

    local dialog
    dialog = Menu:new{
        title = _("Select preset to load"),
        item_table = items,
        on_close = on_close_callback,
    }
    UIManager:show(dialog)
end

function UIScreens:showSavePresetDialog(plugin, view, on_close_callback)
    if plugin then self.plugin = plugin end
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Save layout as preset"),
        input_hint = _("e.g. My Reading Layout"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                        if on_close_callback then on_close_callback() end
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local name = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if name and name:match("%S") then
                            local ok, res = MenuOrderManager:savePreset(view, name)
                            if ok then
                                UIManager:show(Notification:new{
                                    text = string.format(_("Saved preset “%s”."), name),
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = string.format(_("Error saving preset:\n%s"), tostring(res)),
                                })
                            end
                        end
                        if on_close_callback then on_close_callback() end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function UIScreens:showDeletePresetMenu(plugin, view, on_close_callback)
    if plugin then self.plugin = plugin end
    local deletable = MenuOrderManager:listDeletablePresets(view)

    if #deletable == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No presets to delete (default cannot be deleted)."),
        })
        if on_close_callback then on_close_callback() end
        return
    end

    local items = {}
    local dialog
    for __, preset in ipairs(deletable) do
        local cur_preset = preset
        local is_builtin = cur_preset.is_builtin
        local label = (is_builtin and "[Built-in] " or "[Custom] ") .. cur_preset.name
        local help = is_builtin and _("Delete built-in preset (can be restored by resetting hidden file).") or _("Delete custom preset file.")
        if cur_preset.id == "builtin_default" then
            help = _("Default cannot be deleted.")
        end
        table.insert(items, {
            text = label,
            help_text = help,
            callback = function()
                local confirm_text
                if is_builtin then
                    confirm_text = string.format(_("Delete built-in preset “%s”?"), cur_preset.name)
                else
                    confirm_text = string.format(_("Delete custom preset “%s”?"), cur_preset.name)
                end
                UIManager:show(ConfirmBox:new{
                    text = confirm_text,
                    ok_text = _("Delete"),
                    ok_callback = function()
                        local ok, err = MenuOrderManager:deletePreset(view, cur_preset.id)
                        if not ok then
                            -- Fallback try name
                            ok, err = MenuOrderManager:deletePreset(view, cur_preset.name)
                        end
                        if ok then
                            UIManager:show(Notification:new{
                                text = string.format(_("Deleted preset “%s”."), cur_preset.name),
                            })
                            -- Close this delete menu before going back to parent to avoid stacking
                            if dialog then
                                -- Prevent on_close from re-triggering parent twice
                                local cb = dialog.on_close
                                dialog.on_close = nil
                                UIManager:close(dialog)
                                if cb then cb() end
                                -- Also call the passed on_close_callback to refresh parent
                                if on_close_callback and cb ~= on_close_callback then
                                    on_close_callback()
                                end
                            else
                                if on_close_callback then on_close_callback() end
                            end
                        else
                            UIManager:show(InfoMessage:new{
                                text = tostring(err or _("Failed to delete.")),
                            })
                        end
                    end,
                })
            end,
        })
    end

    dialog = Menu:new{
        title = _("Select preset to delete"),
        item_table = items,
        on_close = on_close_callback,
    }
    UIManager:show(dialog)
end

return UIScreens
