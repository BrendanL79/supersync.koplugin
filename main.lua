--[[--
Super Sync Plugin for KOReader

A comprehensive metadata synchronization plugin that backs up your complete
reading data (.sdr directories) to cloud storage.
--]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local CloudProvider = require("cloudprovider")
local SyncEngine = require("syncengine")

local SuperSync = WidgetContainer:extend{
    name = "supersync",
    is_doc_only = false,
}

function SuperSync:init()
    self.ui.menu:registerToMainMenu(self)
    self.settings = G_reader_settings:readSetting("supersync") or {}
    self.last_sync_time = G_reader_settings:readSetting("supersync_last_sync")

    -- Ensure defaults
    if self.settings.enabled == nil then
        self.settings.enabled = false
    end
    if self.settings.sync_on_close == nil then
        self.settings.sync_on_close = false
    end
    if self.settings.sync_folder == nil then
        self.settings.sync_folder = "/KOReader-SuperSync"
    end

    -- Register dispatcher actions
    self:onDispatcherRegisterActions()
end

function SuperSync:onDispatcherRegisterActions()
    Dispatcher:registerAction("supersync_sync_now", {
        category = "none",
        event = "SuperSyncNow",
        title = _("Super Sync: Sync Now"),
        general = true,
    })
end

function SuperSync:onSuperSyncNow()
    self:performSync()
    return true
end

function SuperSync:saveSettings()
    G_reader_settings:saveSetting("supersync", self.settings)
end

function SuperSync:isConfigured()
    return self.settings.cloud_storage and
           self.settings.sync_folder and
           self.settings.sync_folder ~= ""
end

function SuperSync:addToMainMenu(menu_items)
    menu_items.supersync = {
        text = _("Super Sync"),
        sorting_hint = "tools",
        sub_item_table = self:getSubMenuItems(),
    }
end

function SuperSync:getSubMenuItems()
    return {
        {
            text = _("Sync now"),
            enabled_func = function()
                return self.settings.enabled and self:isConfigured()
            end,
            callback = function()
                self:performSync()
            end,
            keep_menu_open = false,
        },
        {
            text = _("Status"),
            callback = function()
                self:showStatus()
            end,
            keep_menu_open = true,
        },
        {
            text = _("Settings"),
            sub_item_table = self:getSettingsSubMenu(),
        },
    }
end

function SuperSync:getSettingsSubMenu()
    return {
        {
            text_func = function()
                return self.settings.enabled and _("Enabled") or _("Disabled")
            end,
            checked_func = function()
                return self.settings.enabled
            end,
            callback = function()
                self.settings.enabled = not self.settings.enabled
                self:saveSettings()
            end,
        },
        {
            text = _("Cloud storage"),
            sub_item_table_func = function()
                return self:getCloudStorageSubMenu()
            end,
        },
        {
            text_func = function()
                local folder = self.settings.sync_folder or _("Not set")
                return T(_("Sync folder: %1"), folder)
            end,
            callback = function()
                self:showSyncFolderDialog()
            end,
            keep_menu_open = true,
        },
        {
            text = _("Auto-sync options"),
            sub_item_table = self:getAutoSyncSubMenu(),
        },
        {
            text = _("Configure cloud storage"),
            callback = function()
                self:showCloudStorageConfig()
            end,
            keep_menu_open = false,
            separator = true,
        },
    }
end

function SuperSync:getCloudStorageSubMenu()
    local servers = CloudProvider.getServerList()
    local sub_items = {}

    if #servers == 0 then
        table.insert(sub_items, {
            text = _("No cloud storage configured"),
            enabled = false,
        })
        table.insert(sub_items, {
            text = _("Configure cloud storage"),
            callback = function()
                self:showCloudStorageConfig()
            end,
        })
    else
        for _, server in ipairs(servers) do
            table.insert(sub_items, {
                text = server.display,
                checked_func = function()
                    return self.settings.cloud_storage == server.name
                end,
                callback = function()
                    self.settings.cloud_storage = server.name
                    self:saveSettings()
                    UIManager:show(InfoMessage:new{
                        text = T(_("Cloud storage set to: %1"), server.name),
                        timeout = 2,
                    })
                end,
            })
        end
    end

    return sub_items
end

function SuperSync:getAutoSyncSubMenu()
    return {
        {
            text = _("Sync on document close"),
            checked_func = function()
                return self.settings.sync_on_close
            end,
            callback = function()
                self.settings.sync_on_close = not self.settings.sync_on_close
                self:saveSettings()
            end,
        },
        {
            text = _("Sync on suspend"),
            checked_func = function()
                return self.settings.sync_on_suspend
            end,
            callback = function()
                self.settings.sync_on_suspend = not self.settings.sync_on_suspend
                self:saveSettings()
            end,
        },
    }
end

function SuperSync:showSyncFolderDialog()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Sync folder path"),
        input = self.settings.sync_folder or "/KOReader-SuperSync",
        input_hint = _("Path in cloud storage (e.g., /KOReader-SuperSync)"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local new_path = input_dialog:getInputText()
                        if new_path and new_path ~= "" then
                            -- Ensure path starts with /
                            if not new_path:match("^/") then
                                new_path = "/" .. new_path
                            end
                            self.settings.sync_folder = new_path
                            self:saveSettings()
                            UIManager:close(input_dialog)
                            UIManager:show(InfoMessage:new{
                                text = T(_("Sync folder set to: %1"), new_path),
                                timeout = 2,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function SuperSync:showCloudStorageConfig()
    local CloudStorage = require("apps/cloudstorage/cloudstorage")
    local cloud_storage = CloudStorage:new{}
    UIManager:show(cloud_storage)
end

function SuperSync:showStatus()
    local status_lines = {}

    table.insert(status_lines, _("Super Sync Status"))
    table.insert(status_lines, "")

    if not self.settings.enabled then
        table.insert(status_lines, _("Status: Disabled"))
    elseif not self:isConfigured() then
        table.insert(status_lines, _("Status: Not configured"))
        if not self.settings.cloud_storage then
            table.insert(status_lines, _("  - No cloud storage selected"))
        end
        if not self.settings.sync_folder then
            table.insert(status_lines, _("  - No sync folder set"))
        end
    else
        table.insert(status_lines, _("Status: Ready"))
        table.insert(status_lines, "")
        table.insert(status_lines, T(_("Cloud storage: %1"), self.settings.cloud_storage))
        table.insert(status_lines, T(_("Sync folder: %1"), self.settings.sync_folder))
        table.insert(status_lines, T(_("Sync on close: %1"), self.settings.sync_on_close and _("Yes") or _("No")))
        table.insert(status_lines, T(_("Sync on suspend: %1"), self.settings.sync_on_suspend and _("Yes") or _("No")))
    end

    table.insert(status_lines, "")
    if self.last_sync_time then
        table.insert(status_lines, T(_("Last sync: %1"), os.date("%Y-%m-%d %H:%M", self.last_sync_time)))
    else
        table.insert(status_lines, _("Last sync: Never"))
    end

    UIManager:show(InfoMessage:new{
        text = table.concat(status_lines, "\n"),
    })
end

function SuperSync:performSync()
    if not self.settings.enabled then
        UIManager:show(InfoMessage:new{
            text = _("Super Sync is disabled. Enable it in settings."),
        })
        return
    end

    if not self:isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("Super Sync is not configured. Please select cloud storage and set a sync folder."),
        })
        return
    end

    -- Check network connectivity
    if not NetworkMgr:isOnline() then
        NetworkMgr:promptWifiOn(function()
            self:doSync()
        end)
        return
    end

    self:doSync()
end

function SuperSync:doSync()
    logger.info("SuperSync: Starting sync operation")

    -- Show initial message
    local info = InfoMessage:new{
        text = _("Super Sync: Initializing..."),
        timeout = 1,
    }
    UIManager:show(info)

    -- Schedule the actual sync to run after UI updates
    UIManager:nextTick(function()
        self:executeSyncOperation()
    end)
end

function SuperSync:executeSyncOperation()
    local sync_engine = SyncEngine:new(self.settings.cloud_storage, self.settings.sync_folder)

    if not sync_engine:isInitialized() then
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to initialize sync: %1"), sync_engine:getInitError() or _("Unknown error")),
        })
        return
    end

    -- Track progress
    local last_status = ""

    local success, result = sync_engine:performFullSync(function(completed, total, status_text)
        if status_text and status_text ~= last_status then
            last_status = status_text
            logger.dbg("SuperSync progress:", status_text)
        end
    end)

    if success then
        self.last_sync_time = os.time()
        G_reader_settings:saveSetting("supersync_last_sync", self.last_sync_time)

        local msg
        if result and result > 0 then
            msg = T(_("Super Sync completed!\n%1 files uploaded."), result)
        else
            msg = _("Super Sync completed!\nNo files needed uploading.")
        end

        UIManager:show(InfoMessage:new{
            text = msg,
            timeout = 3,
        })
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Super Sync failed: %1"), result or _("Unknown error")),
        })
    end
end

-- Event handlers for auto-sync
function SuperSync:onCloseDocument()
    if self.settings.enabled and self.settings.sync_on_close and self:isConfigured() then
        if NetworkMgr:isOnline() then
            -- Run sync in background
            UIManager:nextTick(function()
                self:executeSyncOperation()
            end)
        end
    end
end

function SuperSync:onSuspend()
    if self.settings.enabled and self.settings.sync_on_suspend and self:isConfigured() then
        if NetworkMgr:isOnline() then
            -- Quick sync before suspend
            local sync_engine = SyncEngine:new(self.settings.cloud_storage, self.settings.sync_folder)
            if sync_engine:isInitialized() then
                sync_engine:performFullSync()
                self.last_sync_time = os.time()
                G_reader_settings:saveSetting("supersync_last_sync", self.last_sync_time)
            end
        end
    end
end

return SuperSync
