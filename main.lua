local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local CloudStorage = require("apps/cloudstorage/cloudstorage")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local DropBox = require("apps/cloudstorage/dropbox")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local PathChooser = require("ui/widget/pathchooser")
local ProgressWidget = require("ui/widget/progresswidget")
local UIManager = require("ui/uimanager")
local WebDav = require("apps/cloudstorage/webdav")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

-- Import our sync engine
local SyncEngine = require("plugins/supersync.koplugin/syncengine")

local SuperSync = WidgetContainer:extend{
    name = "supersync",
    is_doc_only = false,
}

function SuperSync:init()
    self.ui.menu:registerToMainMenu(self)
    self.settings = G_reader_settings:readSetting("supersync") or {}
    self.last_sync_time = G_reader_settings:readSetting("supersync_last_sync")
    
    -- Ensure we have a settings structure
    if not self.settings.enabled then
        self.settings.enabled = false
    end
    if not self.settings.auto_sync then
        self.settings.auto_sync = false
    end
    if not self.settings.sync_on_close then
        self.settings.sync_on_close = true
    end
    
    -- Register for document close events if auto-sync is enabled
    if self.settings.enabled and self.settings.sync_on_close then
        self.ui:handleEvent(Event:new("AddUpdateNotification", self.onCloseDocument, self))
    end
end

function SuperSync:addToMainMenu(menu_items)
    menu_items.supersync = {
        text = _("Super Sync"),
        sub_item_table = {
            {
                text = _("Settings"),
                callback = function()
                    self:showSettings()
                end,
            },
            {
                text = _("Manual Sync"),
                enabled_func = function()
                    return self.settings.enabled and self:isConfigured()
                end,
                callback = function()
                    self:performSync()
                end,
            },
            {
                text = _("Status"),
                callback = function()
                    self:showStatus()
                end,
            },
        },
    }
end

function SuperSync:showSettings()
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    
    local function getCloudStorageOptions()
        local cs_settings = self:readCloudStorageSettings()
        local options = {}
        
        for server_name, server_config in pairs(cs_settings) do
            local display_name = server_config.name or server_name
            local server_type = server_config.type and 
                (server_config.type == "dropbox" and "Dropbox" or 
                 server_config.type == "webdav" and "WebDAV" or 
                 server_config.type == "ftp" and "FTP" or 
                 server_config.type) or "Unknown"
            table.insert(options, {
                text = string.format("%s (%s)", display_name, server_type),
                value = server_name,
            })
        end
        
        if #options == 0 then
            table.insert(options, {
                text = _("No cloud storage configured"),
                value = nil,
            })
        end
        
        return options
    end
    
    local cloud_options = getCloudStorageOptions()
    local selected_storage = self.settings.cloud_storage or (cloud_options[1] and cloud_options[1].value)
    
    local settings_dialog
    settings_dialog = MultiInputDialog:new{
        title = _("Super Sync Settings"),
        fields = {
            {
                text = _("Enable Super Sync"),
                input_type = "check",
                checked = self.settings.enabled,
            },
            {
                text = _("Cloud Storage"),
                input_type = "option",
                options = cloud_options,
                option_selected = selected_storage,
            },
            {
                text = _("Sync Folder Path"),
                input_type = "string",
                text_widget = self.settings.sync_folder or "/KOReader-SuperSync",
                hint = _("Path in cloud storage for sync data"),
            },
            {
                text = _("Auto-sync on document close"),
                input_type = "check", 
                checked = self.settings.sync_on_close,
            },
            {
                text = _("Auto-sync interval (hours)"),
                input_type = "number",
                text_widget = tostring(self.settings.auto_sync_hours or 0),
                hint = _("0 = disabled"),
            },
        },
        buttons = {
            {
                {
                    text = _("Configure Cloud Storage"),
                    callback = function()
                        settings_dialog:onClose()
                        self:showCloudStorageConfig()
                    end,
                },
                {
                    text = _("Cancel"),
                    callback = function()
                        settings_dialog:onClose()
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local new_settings = {}
                        new_settings.enabled = settings_dialog:getInputValue(1)
                        new_settings.cloud_storage = settings_dialog:getInputValue(2)
                        new_settings.sync_folder = settings_dialog:getInputValue(3)
                        new_settings.sync_on_close = settings_dialog:getInputValue(4)
                        new_settings.auto_sync_hours = tonumber(settings_dialog:getInputValue(5)) or 0
                        
                        -- Validate settings
                        if new_settings.enabled and not new_settings.cloud_storage then
                            UIManager:show(InfoMessage:new{
                                text = _("Please select a cloud storage provider or configure one first."),
                            })
                            return
                        end
                        
                        if new_settings.enabled and (not new_settings.sync_folder or new_settings.sync_folder:match("^%s*$")) then
                            UIManager:show(InfoMessage:new{
                                text = _("Please specify a sync folder path."),
                            })
                            return
                        end
                        
                        self.settings = new_settings
                        G_reader_settings:saveSetting("supersync", self.settings)
                        
                        settings_dialog:onClose()
                        
                        UIManager:show(InfoMessage:new{
                            text = _("Super Sync settings saved."),
                        })
                        
                        -- Set up auto-sync if enabled
                        self:setupAutoSync()
                    end,
                },
            },
        },
    }
    
    UIManager:show(settings_dialog)
end

function SuperSync:showCloudStorageConfig()
    local cloudstorage = CloudStorage:new{}
    UIManager:show(cloudstorage)
end

function SuperSync:readCloudStorageSettings()
    local cs_settings_file = DataStorage:getSettingsDir() .. "/cloudstorage.lua"
    local cs_settings = {}
    
    if lfs.attributes(cs_settings_file, "mode") == "file" then
        local ok, stored_settings = pcall(dofile, cs_settings_file)
        if ok and type(stored_settings) == "table" then
            cs_settings = stored_settings
        end
    end
    
    return cs_settings
end

function SuperSync:isConfigured()
    return self.settings.cloud_storage and self.settings.sync_folder
end

function SuperSync:showStatus()
    local status_text = _("Super Sync Status:\n\n")
    
    if not self.settings.enabled then
        status_text = status_text .. _("❌ Super Sync is disabled")
    elseif not self:isConfigured() then
        status_text = status_text .. _("⚠️ Super Sync is enabled but not configured")
    else
        status_text = status_text .. _("✅ Super Sync is enabled and configured\n\n")
        status_text = status_text .. T(_("Cloud Storage: %1\n"), self.settings.cloud_storage)
        status_text = status_text .. T(_("Sync Folder: %1\n"), self.settings.sync_folder)
        status_text = status_text .. T(_("Auto-sync on close: %1\n"), self.settings.sync_on_close and _("Yes") or _("No"))
        if self.settings.auto_sync_hours and self.settings.auto_sync_hours > 0 then
            status_text = status_text .. T(_("Auto-sync interval: %1 hours\n"), self.settings.auto_sync_hours)
        end
        
        if self.last_sync_time then
            status_text = status_text .. T(_("Last sync: %1"), os.date("%c", self.last_sync_time))
        else
            status_text = status_text .. _("Never synced")
        end
    end
    
    UIManager:show(InfoMessage:new{
        text = status_text,
    })
end

function SuperSync:performSync()
    if not self.settings.enabled or not self:isConfigured() then
        UIManager:show(InfoMessage:new{
            text = _("Super Sync is not properly configured."),
        })
        return
    end
    
    if not NetworkMgr:willRerunWhenOnline(function() self:performSync() end) then
        return
    end
    
    logger.info("SuperSync: Starting sync operation")
    
    -- Create progress dialog
    local progress_widget = ProgressWidget:new{
        title = _("Super Sync"),
        text = _("Initializing sync..."),
        percentage = 0,
        width = math.floor(0.8 * require("device").screen:getWidth()),
        height = math.floor(0.2 * require("device").screen:getHeight()),
    }
    UIManager:show(progress_widget)
    
    -- Initialize sync engine
    local sync_engine = SyncEngine:new(self.settings.cloud_storage, self.settings.sync_folder)
    
    -- Perform sync in a coroutine to allow UI updates
    local sync_coroutine = coroutine.create(function()
        local success = sync_engine:performFullSync(function(completed, total, status_text)
            local percentage = math.floor((completed / total) * 100)
            progress_widget:setPercentage(percentage)
            progress_widget:setText(status_text or _("Syncing..."))
            coroutine.yield()
        end)
        
        UIManager:close(progress_widget)
        
        if success then
            self.last_sync_time = os.time()
            G_reader_settings:saveSetting("supersync_last_sync", self.last_sync_time)
            
            UIManager:show(InfoMessage:new{
                text = _("Super Sync completed successfully!"),
                timeout = 3,
            })
        else
            UIManager:show(InfoMessage:new{
                text = _("Super Sync failed. Check logs for details."),
                timeout = 3,
            })
        end
    end)
    
    -- Start the sync coroutine
    local function resumeSync()
        local status, err = coroutine.resume(sync_coroutine)
        if not status then
            logger.err("SuperSync: Sync coroutine error:", err)
            UIManager:close(progress_widget)
            UIManager:show(InfoMessage:new{
                text = _("Super Sync failed with error: ") .. tostring(err),
                timeout = 5,
            })
        elseif coroutine.status(sync_coroutine) ~= "dead" then
            -- Schedule next resume
            UIManager:scheduleIn(0.1, resumeSync)
        end
    end
    
    resumeSync()
end

function SuperSync:setupAutoSync()
    -- TODO: Implement periodic sync scheduling
    -- This would use KOReader's task scheduling system
end

function SuperSync:onCloseDocument()
    if self.settings.enabled and self.settings.sync_on_close and self:isConfigured() then
        self:performSync()
    end
end

function SuperSync:onSuspend()
    -- Optional: sync before device suspend
    if self.settings.enabled and self.settings.sync_on_suspend and self:isConfigured() then
        self:performSync()
    end
end

return SuperSync