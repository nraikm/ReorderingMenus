--[[--
Core data manager for reading, modifying, serializing, and applying
KOReader menu orders for Book View (Reader) and Normal View (File Manager).
--]]

local DataStorage = require("datastorage")
local dump = require("dump")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local SEPARATOR_ID = "----------------------------"

local MenuOrderManager = {
    SEPARATOR_ID = SEPARATOR_ID,
    orders = {
        reader = nil,
        filemanager = nil,
    },
    default_orders = {
        reader = nil,
        filemanager = nil,
    },
    backups = {
        reader = nil,
        filemanager = nil,
    },
}

local function getSettingsPath(view)
    return string.format("%s/%s_menu_order.lua", DataStorage:getSettingsDir(), view)
end

function MenuOrderManager:getDefaultOrder(view)
    if self.default_orders[view] then
        return util.tableDeepCopy(self.default_orders[view])
    end

    local default_file = string.format("frontend/ui/elements/%s_menu_order.lua", view)
    local loaded
    local ok, res = pcall(dofile, default_file)
    if ok and type(res) == "table" then
        loaded = res
    else
        -- Fallback require
        local req_name = string.format("ui/elements/%s_menu_order", view)
        loaded = require(req_name)
    end

    self.default_orders[view] = util.tableDeepCopy(loaded)
    return util.tableDeepCopy(loaded)
end

function MenuOrderManager:loadOrder(view, force_reload)
    if self.orders[view] and not force_reload then
        return self.orders[view]
    end

    local file_path = getSettingsPath(view)
    local working_order

    if lfs.attributes(file_path) then
        local ok, res = pcall(dofile, file_path)
        if ok and type(res) == "table" then
            working_order = util.tableDeepCopy(res)
            logger.info("ReorderingMenus: loaded user configuration from", file_path)
        else
            logger.warn("ReorderingMenus: failed to load user order, falling back to default:", res)
        end
    end

    if not working_order then
        working_order = self:getDefaultOrder(view)
    end

    -- Ensure standard tables exist
    if not working_order["KOMenu:menu_buttons"] then
        local default_order = self:getDefaultOrder(view)
        working_order["KOMenu:menu_buttons"] = util.tableDeepCopy(default_order["KOMenu:menu_buttons"])
    end
    if not working_order["KOMenu:disabled"] then
        working_order["KOMenu:disabled"] = {}
    end

    self.orders[view] = working_order
    return working_order
end

function MenuOrderManager:isCustomized(view)
    local file_path = getSettingsPath(view)
    return lfs.attributes(file_path, "mode") == "file"
end

function MenuOrderManager:saveOrder(view)
    local order = self:loadOrder(view)
    local file_path = getSettingsPath(view)

    -- Clean up disabled list (ensure no duplicates and no separators)
    if order["KOMenu:disabled"] then
        local unique_disabled = {}
        local seen = {}
        for __, id in ipairs(order["KOMenu:disabled"]) do
            if id ~= SEPARATOR_ID and not seen[id] then
                seen[id] = true
                table.insert(unique_disabled, id)
            end
        end
        order["KOMenu:disabled"] = unique_disabled
    end

    local serialized = dump(order, nil, true)
    local ok, err = util.writeToFile(serialized, file_path, true, true)
    if not ok then
        logger.err("ReorderingMenus: Failed to write menu order file:", err)
        return false, err
    end

    logger.info("ReorderingMenus: Successfully saved menu order to", file_path)
    return true, file_path
end

function MenuOrderManager:resetOrder(view)
    local file_path = getSettingsPath(view)
    if lfs.attributes(file_path) then
        os.remove(file_path)
    end
    self.orders[view] = nil
    self.backups[view] = nil
    -- Invalidate module cache
    package.loaded["ui/elements/reader_menu_order"] = nil
    package.loaded["ui/elements/filemanager_menu_order"] = nil
    return true
end

function MenuOrderManager:resetTabsOnly(view)
    local order = self:loadOrder(view)
    local default_order = self:getDefaultOrder(view)
    order["KOMenu:menu_buttons"] = util.tableDeepCopy(default_order["KOMenu:menu_buttons"])
    -- Clear disabled for tabs that are now visible (only keep non-tab disabled)
    local default_tabs_set = {}
    for _, t in ipairs(default_order["KOMenu:menu_buttons"] or {}) do default_tabs_set[t] = true end
    local new_disabled = {}
    for _, id in ipairs(order["KOMenu:disabled"] or {}) do
        if not default_tabs_set[id] then
            table.insert(new_disabled, id)
        end
    end
    order["KOMenu:disabled"] = new_disabled
    return true
end

function MenuOrderManager:resetSubmenu(view, menu_id)
    local order = self:loadOrder(view)
    local default_order = self:getDefaultOrder(view)
    if not default_order[menu_id] then return false end
    order[menu_id] = util.tableDeepCopy(default_order[menu_id])
    -- Clear disabled for items that belong to this submenu's default
    local default_items_set = {}
    for _, id in ipairs(default_order[menu_id] or {}) do
        if id ~= SEPARATOR_ID then default_items_set[id] = true end
    end
    local new_disabled = {}
    for _, id in ipairs(order["KOMenu:disabled"] or {}) do
        if not default_items_set[id] then
            table.insert(new_disabled, id)
        end
    end
    order["KOMenu:disabled"] = new_disabled
    return true
end

function MenuOrderManager:backupOrder(view)
    local order = self:loadOrder(view)
    self.backups[view] = util.tableDeepCopy(order)
    return true
end

function MenuOrderManager:restoreOrder(view)
    if self.backups[view] then
        self.orders[view] = util.tableDeepCopy(self.backups[view])
        return true
    end
    return false
end

function MenuOrderManager:hasBackup(view)
    return self.backups[view] ~= nil
end

function MenuOrderManager:getTabs(view)
    local order = self:loadOrder(view)
    local tabs = order["KOMenu:menu_buttons"]
    if tabs and type(tabs) == "table" then
        return util.tableDeepCopy(tabs)
    end
    local default_order = self:getDefaultOrder(view)
    return util.tableDeepCopy(default_order["KOMenu:menu_buttons"] or {})
end

function MenuOrderManager:getAllKnownTabs(view)
    local default_order = self:getDefaultOrder(view)
    local user_order = self:loadOrder(view)
    local tabs = {}
    local seen = {}

    for __, t in ipairs(user_order["KOMenu:menu_buttons"] or {}) do
        if not seen[t] then
            seen[t] = true
            table.insert(tabs, t)
        end
    end

    for __, t in ipairs(default_order["KOMenu:menu_buttons"] or {}) do
        if not seen[t] then
            seen[t] = true
            table.insert(tabs, t)
        end
    end

    return tabs
end

function MenuOrderManager:getMenuItems(view, menu_id)
    local order = self:loadOrder(view)
    if order[menu_id] and type(order[menu_id]) == "table" then
        return util.tableDeepCopy(order[menu_id])
    end
    return {}
end

function MenuOrderManager:isSubmenu(view, id)
    local order = self:loadOrder(view)
    return order[id] ~= nil and id ~= "KOMenu:menu_buttons" and id ~= "KOMenu:disabled"
end

function MenuOrderManager:getAllSubmenuIds(view)
    local order = self:loadOrder(view)
    local submenus = {}
    for k, v in pairs(order) do
        if k ~= "KOMenu:menu_buttons" and k ~= "KOMenu:disabled" and type(v) == "table" then
            -- Verify if it is not a top level tab
            local is_tab = false
            for __, tab in ipairs(order["KOMenu:menu_buttons"] or {}) do
                if tab == k then
                    is_tab = true
                    break
                end
            end
            if not is_tab then
                table.insert(submenus, k)
            end
        end
    end
    table.sort(submenus)
    return submenus
end

function MenuOrderManager:getAllMenusAndSubmenus(view)
    local order = self:loadOrder(view)
    local list = {}
    local seen = {}

    -- Add top level tabs first
    for __, tab in ipairs(order["KOMenu:menu_buttons"] or {}) do
        if not seen[tab] then
            seen[tab] = true
            table.insert(list, { id = tab, is_tab = true })
        end
    end

    -- Add all other submenus
    for k, v in pairs(order) do
        if k ~= "KOMenu:menu_buttons" and k ~= "KOMenu:disabled" and type(v) == "table" and not seen[k] then
            seen[k] = true
            table.insert(list, { id = k, is_tab = false })
        end
    end

    return list
end

function MenuOrderManager:getParentMenu(view, item_id)
    local order = self:loadOrder(view)
    for menu_id, items in pairs(order) do
        if menu_id ~= "KOMenu:disabled" and type(items) == "table" then
            for idx, it in ipairs(items) do
                if it == item_id then
                    return menu_id, idx
                end
            end
        end
    end
    return nil, nil
end

function MenuOrderManager:isItemHidden(view, item_id)
    local order = self:loadOrder(view)
    local disabled = order["KOMenu:disabled"] or {}
    for __, id in ipairs(disabled) do
        if id == item_id then
            return true
        end
    end
    return false
end

function MenuOrderManager:getDisabledItems(view)
    local order = self:loadOrder(view)
    return order["KOMenu:disabled"] or {}
end

function MenuOrderManager:setItemHidden(view, item_id, is_hidden, current_menu_id)
    local order = self:loadOrder(view)
    order["KOMenu:disabled"] = order["KOMenu:disabled"] or {}

    if is_hidden then
        -- Add to disabled list if not present
        local found = false
        for __, id in ipairs(order["KOMenu:disabled"]) do
            if id == item_id then
                found = true
                break
            end
        end
        if not found then
            table.insert(order["KOMenu:disabled"], item_id)
        end

        -- Remove from current menu
        if current_menu_id and order[current_menu_id] then
            for i = #order[current_menu_id], 1, -1 do
                if order[current_menu_id][i] == item_id then
                    table.remove(order[current_menu_id], i)
                end
            end
        else
            -- Search across all menus
            for menu_id, items in pairs(order) do
                if menu_id ~= "KOMenu:disabled" and type(items) == "table" then
                    for i = #items, 1, -1 do
                        if items[i] == item_id then
                            table.remove(items, i)
                        end
                    end
                end
            end
        end
    else
        -- Unhide: remove from disabled list
        for i = #order["KOMenu:disabled"], 1, -1 do
            if order["KOMenu:disabled"][i] == item_id then
                table.remove(order["KOMenu:disabled"], i)
            end
        end

        -- Re-add to target menu if not present anywhere
        local target_menu = current_menu_id
        if not target_menu or not order[target_menu] then
            -- Fallback to default location
            local default_order = self:getDefaultOrder(view)
            for menu_id, items in pairs(default_order) do
                if menu_id ~= "KOMenu:disabled" and type(items) == "table" then
                    for __, it in ipairs(items) do
                        if it == item_id then
                            target_menu = menu_id
                            break
                        end
                    end
                end
                if target_menu then break end
            end
        end

        if target_menu and order[target_menu] then
            -- Check if already present
            local exists = false
            for __, it in ipairs(order[target_menu]) do
                if it == item_id then
                    exists = true
                    break
                end
            end
            if not exists then
                table.insert(order[target_menu], item_id)
            end
        end
    end
end

function MenuOrderManager:moveItem(view, menu_id, from_idx, to_idx)
    local order = self:loadOrder(view)
    local items = order[menu_id]
    if not items then return false end

    if from_idx < 1 or from_idx > #items or to_idx < 1 or to_idx > #items then
        return false
    end

    local item = table.remove(items, from_idx)
    table.insert(items, to_idx, item)
    return true
end

function MenuOrderManager:isMenuDescendant(view, ancestor_menu_id, candidate_menu_id)
    local order = self:loadOrder(view)
    if not order[ancestor_menu_id] or ancestor_menu_id == candidate_menu_id then
        return false
    end

    local visited = {}
    local function containsDescendant(menu_id)
        if visited[menu_id] then return false end
        visited[menu_id] = true
        for _, child_id in ipairs(order[menu_id] or {}) do
            if child_id == candidate_menu_id then return true end
            if type(order[child_id]) == "table" and containsDescendant(child_id) then
                return true
            end
        end
        return false
    end
    return containsDescendant(ancestor_menu_id)
end

function MenuOrderManager:canMoveItemToMenu(view, item_id, from_menu_id, to_menu_id)
    local order = self:loadOrder(view)
    if item_id == SEPARATOR_ID then
        return false, _("Separators cannot be moved between menus.")
    end
    if not from_menu_id or type(order[from_menu_id]) ~= "table" then
        return false, _("The source menu is unavailable.")
    end
    if not to_menu_id or type(order[to_menu_id]) ~= "table" then
        return false, _("The destination menu is unavailable.")
    end
    if from_menu_id == to_menu_id then
        return false, _("The item is already in this menu.")
    end

    local found_in_source = false
    for _, id in ipairs(order[from_menu_id]) do
        if id == item_id then
            found_in_source = true
            break
        end
    end
    if not found_in_source then
        -- Newly registered plugin items can be visible in KOReader before they
        -- have an entry in the persisted order. Allow those orphans to acquire
        -- their first configured parent, but reject a stale/wrong source when
        -- the item is already configured elsewhere.
        local configured_parent = self:getParentMenu(view, item_id)
        if configured_parent then
            return false, _("The item is no longer in the source menu.")
        end
    end

    for _, id in ipairs(order[to_menu_id]) do
        if id == item_id then
            return false, _("The destination menu already contains this item.")
        end
    end

    if type(order[item_id]) == "table" then
        if to_menu_id == item_id then
            return false, _("A submenu cannot be moved into itself.")
        end
        if self:isMenuDescendant(view, item_id, to_menu_id) then
            return false, _("A submenu cannot be moved into one of its own submenus.")
        end
    end
    return true
end

function MenuOrderManager:moveItemToMenu(view, item_id, from_menu_id, to_menu_id, target_idx)
    local order = self:loadOrder(view)
    local can_move, err = self:canMoveItemToMenu(view, item_id, from_menu_id, to_menu_id)
    if not can_move then return false, err end

    -- Remove from from_menu
    for i = #order[from_menu_id], 1, -1 do
        if order[from_menu_id][i] == item_id then
            table.remove(order[from_menu_id], i)
        end
    end

    -- Insert into to_menu
    if target_idx and target_idx >= 1 and target_idx <= #order[to_menu_id] + 1 then
        table.insert(order[to_menu_id], target_idx, item_id)
    else
        table.insert(order[to_menu_id], item_id)
    end

    -- Ensure item is not disabled
    self:setItemHidden(view, item_id, false, to_menu_id)
    return true
end

function MenuOrderManager:insertSeparator(view, menu_id, idx)
    local order = self:loadOrder(view)
    if not order[menu_id] then return false end
    if idx < 1 then idx = 1 end
    if idx > #order[menu_id] + 1 then idx = #order[menu_id] + 1 end

    table.insert(order[menu_id], idx, SEPARATOR_ID)
    return true
end

function MenuOrderManager:removeSeparator(view, menu_id, idx)
    local order = self:loadOrder(view)
    if not order[menu_id] or not order[menu_id][idx] then return false end
    if order[menu_id][idx] == SEPARATOR_ID then
        table.remove(order[menu_id], idx)
        return true
    end
    return false
end

function MenuOrderManager:reorderTabs(view, new_tab_list)
    local order = self:loadOrder(view)
    order["KOMenu:menu_buttons"] = util.tableDeepCopy(new_tab_list)
    return true
end

function MenuOrderManager:setTabHidden(view, tab_id, is_hidden)
    local order = self:loadOrder(view)
    local tabs = order["KOMenu:menu_buttons"] or {}
    order["KOMenu:disabled"] = order["KOMenu:disabled"] or {}

    if is_hidden then
        for i = #tabs, 1, -1 do
            if tabs[i] == tab_id then
                table.remove(tabs, i)
            end
        end
        local found = false
        for __, id in ipairs(order["KOMenu:disabled"]) do
            if id == tab_id then found = true; break end
        end
        if not found then
            table.insert(order["KOMenu:disabled"], tab_id)
        end
    else
        for i = #order["KOMenu:disabled"], 1, -1 do
            if order["KOMenu:disabled"][i] == tab_id then
                table.remove(order["KOMenu:disabled"], i)
            end
        end
        local exists = false
        for __, id in ipairs(tabs) do
            if id == tab_id then exists = true; break end
        end
        if not exists then
            table.insert(tabs, tab_id)
        end
    end
end

function MenuOrderManager:copyLayout(from_view, to_view)
    local src_order = self:loadOrder(from_view)
    local dst_order = self:loadOrder(to_view)

    -- Common submenus to sync between views
    local sync_keys = {
        "setting", "tools", "search", "main",
        "network", "screen", "taps_and_gestures", "navigation", "document", "device",
        "more_tools", "search_settings", "help", "exit_menu",
    }

    for __, key in ipairs(sync_keys) do
        if src_order[key] then
            dst_order[key] = util.tableDeepCopy(src_order[key])
        end
    end

    if src_order["KOMenu:disabled"] then
        dst_order["KOMenu:disabled"] = util.tableDeepCopy(src_order["KOMenu:disabled"])
    end

    self.orders[to_view] = dst_order
    return true
end

function MenuOrderManager:applyLiveReload(ui, view)
    -- Invalidate menu order module cache in package.loaded
    package.loaded["ui/elements/reader_menu_order"] = nil
    package.loaded["ui/elements/filemanager_menu_order"] = nil

    if not ui then return end

    pcall(function()
        if ui.menu then
            -- Close open menu popup safely if visible
            if ui.menu.menu_container then
                pcall(function()
                    if ui.menu.onCloseReaderMenu then
                        ui.menu:onCloseReaderMenu()
                    elseif ui.menu.onCloseFileManagerMenu then
                        ui.menu:onCloseFileManagerMenu()
                    elseif ui.menu.onTapCloseMenu then
                        ui.menu:onTapCloseMenu()
                    end
                end)
            end

            local is_reader = ui.document ~= nil
            local old_menu = ui.menu
            local old_widgets = (old_menu and old_menu.registered_widgets) or {}

            local new_menu
            if is_reader then
                local ReaderMenu = require("apps/reader/modules/readermenu")
                new_menu = ReaderMenu:new{ ui = ui, view = ui.view }
            else
                local FileManagerMenu = require("apps/filemanager/filemanagermenu")
                new_menu = FileManagerMenu:new{ ui = ui }
            end

            new_menu.registered_widgets = {}
            for __, w in pairs(old_widgets) do
                table.insert(new_menu.registered_widgets, w)
            end

            if ui.registerModule then
                ui:registerModule("menu", new_menu)
            else
                ui.menu = new_menu
            end

            new_menu:setUpdateItemTable()
        end
    end)
end

-- =========================================================================
-- Preset Management
-- =========================================================================

function MenuOrderManager:getPresetsDir(view)
    local base_dir = string.format("%s/menu_order_presets", DataStorage:getSettingsDir())
    if not lfs.attributes(base_dir) then
        util.makePath(base_dir)
    end
    local view_dir = string.format("%s/%s", base_dir, view)
    if not lfs.attributes(view_dir) then
        util.makePath(view_dir)
    end
    return view_dir
end

local function cleanPresetName(preset_name)
    if not preset_name or preset_name:match("^%s*$") then
        return nil, _("Preset name cannot be empty.")
    end
    local clean_name = preset_name:gsub("[^%w_%- %.]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if clean_name == "" then
        return nil, _("Invalid preset name.")
    end
    return clean_name
end

local function cleanPathComponent(value)
    local clean_value = tostring(value or ""):gsub("[^%w_%-]", "_")
    return clean_value ~= "" and clean_value or "submenu"
end

function MenuOrderManager:getSubmenuPresetsDir(view, menu_id)
    local root_dir = string.format("%s/submenus", self:getPresetsDir(view))
    if not lfs.attributes(root_dir) then
        util.makePath(root_dir)
    end
    local menu_dir = string.format("%s/%s", root_dir, cleanPathComponent(menu_id))
    if not lfs.attributes(menu_dir) then
        util.makePath(menu_dir)
    end
    return menu_dir
end

local function collectSubmenuOrders(order, default_order, menu_id, include_nested, menus, visited)
    if visited[menu_id] or type(order[menu_id]) ~= "table" then return end
    visited[menu_id] = true
    menus[menu_id] = util.tableDeepCopy(order[menu_id])
    if not include_nested then return end

    local children = {}
    for _, item_id in ipairs(order[menu_id]) do
        if type(order[item_id]) == "table" then
            children[item_id] = true
        end
    end

    -- A hidden submenu is removed from its parent list. Include it when it is
    -- disabled, but do not pull in a submenu that was deliberately moved.
    local disabled = {}
    for _, item_id in ipairs(order["KOMenu:disabled"] or {}) do
        disabled[item_id] = true
    end
    for _, item_id in ipairs(default_order[menu_id] or {}) do
        if disabled[item_id] and type(order[item_id]) == "table" then
            children[item_id] = true
        end
    end

    for child_id in pairs(children) do
        collectSubmenuOrders(order, default_order, child_id, true, menus, visited)
    end
end

function MenuOrderManager:saveSubmenuPreset(view, menu_id, menu_title, preset_name, include_nested, current_menu_items)
    local clean_name, name_err = cleanPresetName(preset_name)
    if not clean_name then return false, name_err end

    local order = self:loadOrder(view)
    if type(order[menu_id]) ~= "table" then
        return false, _("Submenu not found.")
    end

    local menus = {}
    collectSubmenuOrders(order, self:getDefaultOrder(view), menu_id, include_nested == true, menus, {})
    if type(current_menu_items) == "table" then
        menus[menu_id] = util.tableDeepCopy(current_menu_items)
    end
    local preset_data = {
        format = "reorderingmenus_submenu_preset",
        version = 1,
        name = clean_name,
        menu_id = menu_id,
        menu_title = menu_title or menu_id,
        include_submenus = include_nested == true,
        menus = menus,
    }
    local file_path = string.format("%s/%s.lua", self:getSubmenuPresetsDir(view, menu_id), clean_name)
    local ok, err = util.writeToFile(dump(preset_data, nil, true), file_path, true, true)
    if not ok then return false, err end
    return true, file_path
end

function MenuOrderManager:listSubmenuPresets(view, menu_id)
    local dir = self:getSubmenuPresetsDir(view, menu_id)
    local presets = {}
    for file in lfs.dir(dir) do
        if file:sub(-4) == ".lua" and file:sub(1, 1) ~= "." then
            local path = string.format("%s/%s", dir, file)
            local ok, data = pcall(dofile, path)
            if ok and type(data) == "table"
                    and data.format == "reorderingmenus_submenu_preset"
                    and data.menu_id == menu_id and type(data.menus) == "table" then
                local menu_count = 0
                for _ in pairs(data.menus) do menu_count = menu_count + 1 end
                table.insert(presets, {
                    id = "submenu_" .. file:sub(1, -5),
                    name = data.name or file:sub(1, -5),
                    description = data.include_submenus
                        and string.format(_("Order for this menu and %d nested menu(s)"), math.max(0, menu_count - 1))
                        or _("Order for this menu only"),
                    include_submenus = data.include_submenus == true,
                    menu_count = menu_count,
                    path = path,
                })
            end
        end
    end
    table.sort(presets, function(a, b) return a.name:lower() < b.name:lower() end)
    return presets
end

local function mergeCapturedOrder(captured, current)
    local current_items = {}
    for _, item_id in ipairs(current) do
        if item_id ~= SEPARATOR_ID then current_items[item_id] = true end
    end

    local merged = {}
    local used = {}
    for _, item_id in ipairs(captured) do
        if item_id == SEPARATOR_ID then
            table.insert(merged, item_id)
        elseif current_items[item_id] and not used[item_id] then
            used[item_id] = true
            table.insert(merged, item_id)
        end
    end
    -- Preserve entries introduced after the preset was saved (for example by
    -- newly installed plugins) and place them after the captured ordering.
    for _, item_id in ipairs(current) do
        if item_id ~= SEPARATOR_ID and not used[item_id] then
            used[item_id] = true
            table.insert(merged, item_id)
        end
    end
    return merged
end

function MenuOrderManager:loadSubmenuPreset(view, menu_id, preset, current_menu_items)
    local data
    if type(preset) == "table" and preset.menus then
        data = preset
    elseif type(preset) == "table" and preset.path then
        local ok, result = pcall(dofile, preset.path)
        if ok then data = result end
    elseif type(preset) == "string" then
        local path = string.format("%s/%s.lua", self:getSubmenuPresetsDir(view, menu_id), preset)
        local ok, result = pcall(dofile, path)
        if ok then data = result end
    end

    if type(data) ~= "table" or data.format ~= "reorderingmenus_submenu_preset"
            or data.menu_id ~= menu_id or type(data.menus) ~= "table"
            or type(data.menus[menu_id]) ~= "table" then
        return false, _("Submenu preset not found or does not match this menu.")
    end

    local order = self:loadOrder(view)
    if type(order[menu_id]) ~= "table" then
        return false, _("Submenu not found.")
    end
    local previous_order = util.tableDeepCopy(order)
    for captured_menu_id, captured_items in pairs(data.menus) do
        if type(captured_items) == "table" and type(order[captured_menu_id]) == "table" then
            local current_items = order[captured_menu_id]
            if captured_menu_id == menu_id and type(current_menu_items) == "table" then
                current_items = current_menu_items
            end
            order[captured_menu_id] = mergeCapturedOrder(captured_items, current_items)
        end
    end

    local ok, result = self:saveOrder(view)
    if not ok then
        self.orders[view] = previous_order
        return false, result
    end
    return true, result
end

function MenuOrderManager:deleteSubmenuPreset(view, menu_id, preset)
    local path
    if type(preset) == "table" then
        path = preset.path
    elseif type(preset) == "string" then
        local clean_name, name_err = cleanPresetName(preset:gsub("^submenu_", ""))
        if not clean_name then return false, name_err end
        path = string.format("%s/%s.lua", self:getSubmenuPresetsDir(view, menu_id), clean_name)
    end
    if path and lfs.attributes(path, "mode") == "file" then
        local ok, data = pcall(dofile, path)
        if ok and type(data) == "table" and data.menu_id == menu_id then
            os.remove(path)
            return true
        end
    end
    return false, _("Submenu preset file not found.")
end

function MenuOrderManager:getHiddenBuiltinPath(view)
    return string.format("%s/.hidden_builtins.lua", self:getPresetsDir(view))
end

function MenuOrderManager:getHiddenBuiltinIds(view)
    local path = self:getHiddenBuiltinPath(view)
    if lfs.attributes(path) then
        local ok, res = pcall(dofile, path)
        if ok and type(res) == "table" then
            return res
        end
    end
    return {}
end

function MenuOrderManager:isBuiltinHidden(view, preset_id)
    if preset_id == "builtin_default" then return false end
    local hidden = self:getHiddenBuiltinIds(view)
    for __, hid in ipairs(hidden) do
        if hid == preset_id then return true end
    end
    return false
end

function MenuOrderManager:hideBuiltinPreset(view, preset_id)
    if preset_id == "builtin_default" then
        return false, _("Cannot delete the default preset.")
    end
    local hidden = self:getHiddenBuiltinIds(view)
    for __, hid in ipairs(hidden) do
        if hid == preset_id then return true end
    end
    table.insert(hidden, preset_id)
    local path = self:getHiddenBuiltinPath(view)
    local serialized = dump(hidden, nil, true)
    local ok, err = util.writeToFile(serialized, path, true, true)
    if not ok then return false, err end
    return true
end

function MenuOrderManager:unhideBuiltinPreset(view, preset_id)
    local hidden = self:getHiddenBuiltinIds(view)
    local new_hidden = {}
    local found = false
    for __, hid in ipairs(hidden) do
        if hid ~= preset_id then
            table.insert(new_hidden, hid)
        else
            found = true
        end
    end
    if not found then return false end
    local path = self:getHiddenBuiltinPath(view)
    if #new_hidden == 0 then
        os.remove(path)
    else
        local serialized = dump(new_hidden, nil, true)
        util.writeToFile(serialized, path, true, true)
    end
    return true
end

local function buildBuiltinPresets(view, default_order)
    local presets = {}

    table.insert(presets, {
        id = "builtin_default",
        name = _("Default (Stock KOReader)"),
        description = _("Standard factory menu layout. Selecting this empties the config file to restore stock."),
        is_builtin = true,
        order = default_order,
    })

    if view == "reader" then
        local reading_focused = util.tableDeepCopy(default_order)
        reading_focused["KOMenu:menu_buttons"] = { "typeset", "navi", "setting", "tools" }
        reading_focused["KOMenu:disabled"] = { "filemanager", "main", "search" }
        table.insert(presets, {
            id = "builtin_reading_focused",
            name = _("Reading Focused"),
            description = _("Puts Typeset and Navigation first; hides Search, Main, and Filemanager."),
            is_builtin = true,
            order = reading_focused,
        })

        local minimalist = util.tableDeepCopy(default_order)
        minimalist["KOMenu:menu_buttons"] = { "navi", "typeset" }
        minimalist["KOMenu:disabled"] = { "setting", "tools", "search", "filemanager", "main" }
        table.insert(presets, {
            id = "builtin_minimalist",
            name = _("Minimalist Reader"),
            description = _("Keeps only Navigation and Typeset tabs for a distraction-free experience."),
            is_builtin = true,
            order = minimalist,
        })

        local power_user = util.tableDeepCopy(default_order)
        power_user["KOMenu:menu_buttons"] = { "search", "navi", "typeset", "setting", "tools", "filemanager", "main" }
        power_user["KOMenu:disabled"] = {}
        table.insert(presets, {
            id = "builtin_power_user",
            name = _("Full Power User"),
            description = _("All tabs and submenus exposed with Search in the first position."),
            is_builtin = true,
            order = power_user,
        })
    else
        local clean_fm = util.tableDeepCopy(default_order)
        clean_fm["KOMenu:menu_buttons"] = { "filemanager_settings", "setting", "tools" }
        clean_fm["KOMenu:disabled"] = { "search", "filemanager", "main" }
        table.insert(presets, {
            id = "builtin_clean_fm",
            name = _("Clean File Manager"),
            description = _("Essential browsing and device tools without clutter."),
            is_builtin = true,
            order = clean_fm,
        })

        local power_user = util.tableDeepCopy(default_order)
        power_user["KOMenu:menu_buttons"] = { "filemanager_settings", "search", "setting", "tools", "filemanager", "main" }
        power_user["KOMenu:disabled"] = {}
        table.insert(presets, {
            id = "builtin_power_user",
            name = _("Full Power User"),
            description = _("All tabs and submenus visible."),
            is_builtin = true,
            order = power_user,
        })
    end

    return presets
end

function MenuOrderManager:getBuiltinPresets(view)
    local hidden = {}
    for _, id in ipairs(self:getHiddenBuiltinIds(view)) do
        hidden[id] = true
    end

    local visible = {}
    for _, preset in ipairs(buildBuiltinPresets(view, self:getDefaultOrder(view))) do
        if not hidden[preset.id] then
            table.insert(visible, preset)
        end
    end
    return visible
end

function MenuOrderManager:listUserPresets(view)
    local dir = self:getPresetsDir(view)
    local list = {}
    if lfs.attributes(dir) then
        for file in lfs.dir(dir) do
            if file:sub(-4) == ".lua" and file:sub(1,1) ~= "." then
                local name = file:sub(1, -5)
                -- Skip hidden file
                if name ~= ".hidden_builtins" then
                    local full_path = string.format("%s/%s", dir, file)
                    table.insert(list, {
                        id = "user_" .. name,
                        name = name,
                        description = _("Custom user preset"),
                        path = full_path,
                        is_builtin = false,
                    })
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
end

function MenuOrderManager:getAllPresets(view)
    local builtins = self:getBuiltinPresets(view)
    local user_presets = self:listUserPresets(view)
    local combined = {}
    for __, p in ipairs(builtins) do
        table.insert(combined, p)
    end
    for __, p in ipairs(user_presets) do
        table.insert(combined, p)
    end
    return combined
end

function MenuOrderManager:listDeletablePresets(view)
    local deletable = {}
    for _, p in ipairs(self:getAllPresets(view)) do
        if p.id ~= "builtin_default" then
            table.insert(deletable, p)
        end
    end
    return deletable
end

function MenuOrderManager:savePreset(view, preset_name)
    local clean_name, name_err = cleanPresetName(preset_name)
    if not clean_name then return false, name_err end

    local order = self:loadOrder(view)
    local dir = self:getPresetsDir(view)
    local file_path = string.format("%s/%s.lua", dir, clean_name)

    local serialized = dump(order, nil, true)
    local ok, err = util.writeToFile(serialized, file_path, true, true)
    if not ok then
        return false, err
    end
    return true, file_path
end

function MenuOrderManager:loadPreset(view, preset)
    local preset_id
    local order
    if type(preset) == "table" and preset.order then
        order = util.tableDeepCopy(preset.order)
        preset_id = preset.id
    elseif type(preset) == "table" and preset.path then
        local ok, res = pcall(dofile, preset.path)
        if ok and type(res) == "table" then
            order = util.tableDeepCopy(res)
        else
            return false, _("Failed to load preset file.")
        end
        preset_id = preset.id
    elseif type(preset) == "string" then
        local dir = self:getPresetsDir(view)
        local file_path = string.format("%s/%s.lua", dir, preset)
        if lfs.attributes(file_path) then
            local ok, res = pcall(dofile, file_path)
            if ok and type(res) == "table" then
                order = util.tableDeepCopy(res)
            end
        end
        if not order then
            for _, b in ipairs(buildBuiltinPresets(view, self:getDefaultOrder(view))) do
                if b.name == preset or b.id == preset then
                    order = util.tableDeepCopy(b.order)
                    preset_id = b.id
                    break
                end
            end
        else
            preset_id = preset
        end
    else
        preset_id = preset and preset.id or nil
    end

    if not order then
        return false, _("Preset not found.")
    end

    -- Default preset should empty the config file (stock)
    if preset_id == "builtin_default" then
        self:resetOrder(view)
        -- Also clear the in-memory order to default
        self.orders[view] = util.tableDeepCopy(order)
        logger.info("ReorderingMenus: applied Default preset - reset to stock (emptied config)")
        return true
    end

    self.orders[view] = order
    local ok, res = self:saveOrder(view)
    return ok, res
end

function MenuOrderManager:deletePreset(view, preset_name)
    for _, b in ipairs(buildBuiltinPresets(view, self:getDefaultOrder(view))) do
        if b.id == preset_name or b.name == preset_name then
            if b.id == "builtin_default" then
                return false, _("Cannot delete the default preset.")
            end
            return self:hideBuiltinPreset(view, b.id)
        end
    end

    local dir = self:getPresetsDir(view)
    local file_path = string.format("%s/%s.lua", dir, preset_name)
    if lfs.attributes(file_path) then
        os.remove(file_path)
        return true
    end
    local clean_name = preset_name:gsub("^user_", "")
    file_path = string.format("%s/%s.lua", dir, clean_name)
    if lfs.attributes(file_path) then
        os.remove(file_path)
        return true
    end
    return false, _("Preset file not found.")
end

return MenuOrderManager
