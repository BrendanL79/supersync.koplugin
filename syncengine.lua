--[[--
Super Sync Engine

Core synchronization functionality for backing up .sdr metadata directories
to cloud storage. Uses KOReader's SyncService for bidirectional sync with
conflict resolution (Dropbox/WebDAV), and FtpSync for FTP bidirectional sync.
--]]

local DataStorage = require("datastorage")
local SyncService = require("apps/cloudstorage/syncservice")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local CloudProvider = require("cloudprovider")
local FtpSync = require("ftpsync")

local SyncEngine = {}

function SyncEngine:new(cloud_storage_name, sync_folder_path)
    local o = {
        cloud_storage_name = cloud_storage_name,
        sync_folder_path = sync_folder_path,
        server = nil,
        provider = nil, -- For FTP fallback and directory creation
    }
    setmetatable(o, self)
    self.__index = self

    -- Get server configuration
    local server = CloudProvider.getServerByName(cloud_storage_name)
    if not server then
        logger.err("SuperSync: Server not found:", cloud_storage_name)
        o.init_error = _("Cloud storage server not found")
        return o
    end

    o.server = server
    logger.info("SuperSync: Initialized for", server.type, "server:", cloud_storage_name)

    -- Create provider for directory creation and FTP fallback
    local provider, err = CloudProvider.create(cloud_storage_name)
    if provider then
        o.provider = provider
    else
        logger.warn("SuperSync: Could not create provider:", err)
    end

    return o
end

function SyncEngine:isInitialized()
    return self.server ~= nil
end

function SyncEngine:getInitError()
    return self.init_error
end

function SyncEngine:supportsBidirectionalSync()
    -- All providers now support bidirectional sync:
    -- - Dropbox/WebDAV: via SyncService with ETag-based conflict detection
    -- - FTP: via FtpSync with timestamp-based conflict detection
    return self.server and (self.server.type == "dropbox" or
                            self.server.type == "webdav" or
                            self.server.type == "ftp")
end

function SyncEngine:usesFtpSync()
    return self.server and self.server.type == "ftp"
end

-- Get list of all .sdr directories that need syncing
function SyncEngine:getSdrDirectories()
    local sdr_dirs = {}
    local docsettings_dir = DataStorage:getDocSettingsDir()
    local hash_docsettings_dir = DataStorage:getDocSettingsHashDir()

    -- Scan the main docsettings directory
    if docsettings_dir and lfs.attributes(docsettings_dir, "mode") == "directory" then
        self:scanDirectoryForSdr(docsettings_dir, sdr_dirs, "dir")
    end

    -- Scan the hash-based docsettings directory
    if hash_docsettings_dir and lfs.attributes(hash_docsettings_dir, "mode") == "directory" then
        self:scanDirectoryForSdr(hash_docsettings_dir, sdr_dirs, "hash")
    end

    return sdr_dirs
end

function SyncEngine:scanDirectoryForSdr(directory, sdr_dirs, location_type)
    local ok, iter, dir_obj = pcall(lfs.dir, directory)
    if not ok then
        logger.warn("SuperSync: Cannot scan directory:", directory)
        return
    end

    for item in iter, dir_obj do
        if item ~= "." and item ~= ".." then
            local item_path = directory .. "/" .. item
            local attr = lfs.attributes(item_path)

            if attr and attr.mode == "directory" then
                if item:match("%.sdr$") then
                    table.insert(sdr_dirs, {
                        path = item_path,
                        name = item,
                        location_type = location_type,
                        last_modified = attr.modification,
                    })
                elseif location_type == "hash" then
                    -- In hash directories, scan subdirectories too (e.g., ab/, cd/)
                    self:scanDirectoryForSdr(item_path, sdr_dirs, location_type)
                end
            end
        end
    end
end

-- Get all files in an .sdr directory
function SyncEngine:getFilesInSdr(sdr_path)
    local files = {}
    local ok, iter, dir_obj = pcall(lfs.dir, sdr_path)
    if not ok then
        return files
    end

    for file in iter, dir_obj do
        if file ~= "." and file ~= ".." then
            local file_path = sdr_path .. "/" .. file
            local attr = lfs.attributes(file_path)
            if attr and attr.mode == "file" then
                table.insert(files, {
                    name = file,
                    path = file_path,
                    size = attr.size,
                    modified = attr.modification,
                })
            end
        end
    end
    return files
end

--[[--
Merge callback for SyncService.sync()

Merges local, cached, and incoming (remote) Lua table files.
Strategy: Deep merge with local changes taking precedence on conflicts.
--]]
function SyncEngine:createMergeCallback()
    return function(local_path, cached_path, income_path)
        logger.dbg("SuperSync: Merging files:", local_path)

        -- Read all three versions
        local local_data = self:readLuaFile(local_path)
        local cached_data = self:readLuaFile(cached_path)
        local income_data = self:readLuaFile(income_path)

        -- If no income (remote) data, nothing to merge - just use local
        if not income_data then
            logger.dbg("SuperSync: No remote data, keeping local")
            return true
        end

        -- If no local data, use income data
        if not local_data then
            logger.dbg("SuperSync: No local data, using remote")
            self:writeLuaFile(local_path, income_data)
            return true
        end

        -- Perform three-way merge
        local merged = self:threeWayMerge(local_data, cached_data, income_data)

        -- Write merged result back to local file
        self:writeLuaFile(local_path, merged)

        logger.dbg("SuperSync: Merge completed for", local_path)
        return true
    end
end

--[[--
Three-way merge for Lua tables.

Uses cached version to determine what changed locally vs remotely.
Local changes take precedence on direct conflicts.
--]]
function SyncEngine:threeWayMerge(local_data, cached_data, income_data)
    -- If no cached data, this is first sync - prefer local but add remote-only keys
    if not cached_data then
        return self:deepMerge(income_data, local_data)
    end

    local merged = {}

    -- Get all keys from all three versions
    local all_keys = {}
    for k in pairs(local_data or {}) do all_keys[k] = true end
    for k in pairs(cached_data or {}) do all_keys[k] = true end
    for k in pairs(income_data or {}) do all_keys[k] = true end

    for key in pairs(all_keys) do
        local local_val = local_data and local_data[key]
        local cached_val = cached_data and cached_data[key]
        local income_val = income_data and income_data[key]

        -- Determine what changed
        local local_changed = not self:valuesEqual(local_val, cached_val)
        local remote_changed = not self:valuesEqual(income_val, cached_val)

        if local_changed and remote_changed then
            -- Both changed - conflict, prefer local
            if local_val ~= nil then
                merged[key] = local_val
            end
            logger.dbg("SuperSync: Conflict on key", key, "- using local value")
        elseif local_changed then
            -- Only local changed
            if local_val ~= nil then
                merged[key] = local_val
            end
        elseif remote_changed then
            -- Only remote changed
            if income_val ~= nil then
                merged[key] = income_val
            end
        else
            -- Neither changed, use any non-nil value
            merged[key] = local_val or income_val or cached_val
        end
    end

    return merged
end

-- Deep merge two tables (source values override target)
function SyncEngine:deepMerge(target, source)
    local result = {}

    -- Copy target first
    if target then
        for k, v in pairs(target) do
            if type(v) == "table" then
                result[k] = self:deepMerge({}, v)
            else
                result[k] = v
            end
        end
    end

    -- Override with source
    if source then
        for k, v in pairs(source) do
            if type(v) == "table" and type(result[k]) == "table" then
                result[k] = self:deepMerge(result[k], v)
            else
                result[k] = v
            end
        end
    end

    return result
end

-- Compare two values for equality (handles tables)
function SyncEngine:valuesEqual(a, b)
    if type(a) ~= type(b) then
        return false
    end

    if type(a) == "table" then
        for k in pairs(a) do
            if not self:valuesEqual(a[k], b[k]) then
                return false
            end
        end
        for k in pairs(b) do
            if a[k] == nil then
                return false
            end
        end
        return true
    end

    return a == b
end

-- Read a Lua data file safely
function SyncEngine:readLuaFile(path)
    if not path or lfs.attributes(path, "mode") ~= "file" then
        return nil
    end

    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then
        return data
    end

    -- Try reading as raw Lua with return statement
    local file = io.open(path, "r")
    if file then
        local content = file:read("*all")
        file:close()
        if content then
            local func, err = loadstring("return " .. content)
            if func then
                local ok2, result = pcall(func)
                if ok2 and type(result) == "table" then
                    return result
                end
            end
        end
    end

    return nil
end

-- Write a Lua data file
function SyncEngine:writeLuaFile(path, data)
    local file = io.open(path, "w")
    if not file then
        logger.warn("SuperSync: Cannot write to", path)
        return false
    end

    -- Use util.serialize if available, otherwise simple dump
    local content
    if util.serialize then
        content = util.serialize(data)
    else
        content = "return " .. self:serializeTable(data)
    end

    file:write(content)
    file:close()
    return true
end

-- Simple table serialization fallback
function SyncEngine:serializeTable(t, indent)
    indent = indent or ""
    local result = "{\n"
    local next_indent = indent .. "    "

    for k, v in pairs(t) do
        local key_str
        if type(k) == "string" then
            if k:match("^[%a_][%w_]*$") then
                key_str = k
            else
                key_str = '["' .. k:gsub('"', '\\"') .. '"]'
            end
        else
            key_str = "[" .. tostring(k) .. "]"
        end

        local val_str
        if type(v) == "table" then
            val_str = self:serializeTable(v, next_indent)
        elseif type(v) == "string" then
            val_str = '"' .. v:gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
        elseif type(v) == "boolean" then
            val_str = v and "true" or "false"
        else
            val_str = tostring(v)
        end

        result = result .. next_indent .. key_str .. " = " .. val_str .. ",\n"
    end

    return result .. indent .. "}"
end

-- Ensure remote directory exists
function SyncEngine:ensureRemoteDirectory(remote_path)
    if not self.provider then
        return false, _("Provider not initialized")
    end

    -- Split path and create each level
    local parts = {}
    for part in remote_path:gmatch("[^/]+") do
        table.insert(parts, part)
    end

    local current_path = ""
    for _, part in ipairs(parts) do
        local parent_path = current_path
        current_path = current_path .. "/" .. part

        local success, err = self.provider:createFolder(parent_path, part)
        if not success then
            logger.dbg("SuperSync: createFolder returned:", err, "for", current_path)
        end
    end

    return true
end

--[[--
Sync a single file using SyncService (for Dropbox/WebDAV)
--]]
function SyncEngine:syncFileWithSyncService(file_info, remote_sdr_path)
    -- Create a modified server config with url pointing to the .sdr folder
    local sync_server = {}
    for k, v in pairs(self.server) do
        sync_server[k] = v
    end
    sync_server.url = remote_sdr_path

    -- Use SyncService.sync()
    local merge_cb = self:createMergeCallback()
    SyncService.sync(sync_server, file_info.path, merge_cb, true)

    return true
end

--[[--
Sync a single file using upload-only (for FTP)
--]]
function SyncEngine:syncFileUploadOnly(file_info, remote_file_path)
    if not self.provider then
        return false, _("Provider not initialized")
    end

    return self.provider:uploadFile(file_info.path, remote_file_path)
end

--[[--
Sync an .sdr directory
--]]
function SyncEngine:syncSdrDirectory(sdr_info, progress_callback)
    local remote_sdr_path = self.sync_folder_path .. "/" .. sdr_info.name

    -- Ensure remote directory exists
    self:ensureRemoteDirectory(remote_sdr_path)

    -- Get files to sync
    local files = self:getFilesInSdr(sdr_info.path)
    local total_files = #files
    local synced_count = 0

    local use_sync_service = self:supportsBidirectionalSync()

    for i, file_info in ipairs(files) do
        local success, err

        if use_sync_service then
            success, err = self:syncFileWithSyncService(file_info, remote_sdr_path)
        else
            local remote_file_path = remote_sdr_path .. "/" .. file_info.name
            success, err = self:syncFileUploadOnly(file_info, remote_file_path)
        end

        if success then
            synced_count = synced_count + 1
        else
            logger.warn("SuperSync: Failed to sync", file_info.name, ":", err)
        end

        if progress_callback then
            progress_callback(i, total_files, file_info.name)
        end
    end

    return true, synced_count
end

--[[--
Perform a full sync operation
--]]
function SyncEngine:performFullSync(progress_callback)
    if not self.server then
        logger.err("SuperSync: Cannot sync - not initialized:", self.init_error)
        return false, self.init_error
    end

    -- Use FtpSync for FTP servers
    if self:usesFtpSync() then
        return self:performFtpSync(progress_callback)
    end

    local sync_type = self:supportsBidirectionalSync() and "bidirectional" or "upload-only"
    logger.info("SuperSync: Starting", sync_type, "sync operation")

    -- Ensure base sync folder exists
    self:ensureRemoteDirectory(self.sync_folder_path)

    local sdr_directories = self:getSdrDirectories()
    logger.info("SuperSync: Found", #sdr_directories, ".sdr directories to sync")

    if #sdr_directories == 0 then
        if progress_callback then
            progress_callback(1, 1, _("No metadata directories found"))
        end
        return true, 0
    end

    local total_dirs = #sdr_directories
    local completed_dirs = 0
    local total_files_synced = 0

    for _, sdr_info in ipairs(sdr_directories) do
        if progress_callback then
            progress_callback(completed_dirs, total_dirs,
                string.format(_("Syncing %s..."), sdr_info.name))
        end

        local success, result = self:syncSdrDirectory(sdr_info, function(current, total, filename)
            if progress_callback then
                local overall = completed_dirs + (current / total)
                progress_callback(overall, total_dirs,
                    string.format("%s: %s (%d/%d)", sdr_info.name, filename, current, total))
            end
        end)

        completed_dirs = completed_dirs + 1

        if success then
            total_files_synced = total_files_synced + (result or 0)
            logger.info("SuperSync: Synced", sdr_info.name)
        else
            logger.err("SuperSync: Failed to sync", sdr_info.name, ":", result)
        end
    end

    if progress_callback then
        progress_callback(total_dirs, total_dirs, _("Sync complete"))
    end

    logger.info("SuperSync: Completed.", total_files_synced, "files synced from", completed_dirs, "directories")
    return true, total_files_synced
end

--[[--
Perform FTP sync using FtpSync module (timestamp-based bidirectional sync)
--]]
function SyncEngine:performFtpSync(progress_callback)
    logger.info("SuperSync: Using FtpSync for FTP bidirectional sync")

    local sdr_directories = self:getSdrDirectories()
    logger.info("SuperSync: Found", #sdr_directories, ".sdr directories to sync")

    if #sdr_directories == 0 then
        if progress_callback then
            progress_callback(1, 1, _("No metadata directories found"))
        end
        return true, 0
    end

    local ftp_sync = FtpSync:new(self.server, self.sync_folder_path)
    local success, total_synced, stats = ftp_sync:performFullSync(sdr_directories, progress_callback)

    if success then
        -- Return detailed stats if available
        if stats then
            return true, total_synced, stats
        end
        return true, total_synced
    else
        return false, total_synced
    end
end

return SyncEngine
