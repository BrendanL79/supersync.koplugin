--[[--
Super Sync Engine

Core synchronization functionality for backing up .sdr metadata directories
to cloud storage. Uses the CloudProvider abstraction for multi-provider support.
--]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local CloudProvider = require("cloudprovider")

local SyncEngine = {}

function SyncEngine:new(cloud_storage_name, sync_folder_path)
    local o = {
        cloud_storage_name = cloud_storage_name,
        sync_folder_path = sync_folder_path,
        provider = nil,
    }
    setmetatable(o, self)
    self.__index = self

    -- Initialize cloud provider
    local provider, err = CloudProvider.create(cloud_storage_name)
    if not provider then
        logger.err("SuperSync: Failed to create cloud provider:", err)
        o.init_error = err
    else
        o.provider = provider
        logger.info("SuperSync: Initialized", provider.server_type, "provider for", cloud_storage_name)
    end

    return o
end

function SyncEngine:isInitialized()
    return self.provider ~= nil
end

function SyncEngine:getInitError()
    return self.init_error
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
                    -- This is an .sdr directory
                    table.insert(sdr_dirs, {
                        path = item_path,
                        name = item,
                        location_type = location_type,
                        last_modified = attr.modification,
                    })
                elseif location_type == "hash" then
                    -- In hash directories, we need to scan subdirectories too (e.g., ab/, cd/)
                    self:scanDirectoryForSdr(item_path, sdr_dirs, location_type)
                end
            end
        end
    end
end

-- Ensure remote directory exists
function SyncEngine:ensureRemoteDirectory(remote_path)
    if not self.provider then
        return false, _("Cloud provider not initialized")
    end

    -- Split path and create each level
    local parts = {}
    for part in remote_path:gmatch("[^/]+") do
        table.insert(parts, part)
    end

    local current_path = ""
    for i, part in ipairs(parts) do
        local parent_path = current_path
        current_path = current_path .. "/" .. part

        -- Try to create the folder (will fail silently if exists)
        local success, err = self.provider:createFolder(parent_path, part)
        if not success then
            -- Log but continue - folder might already exist
            logger.dbg("SuperSync: createFolder returned:", err, "for", current_path)
        end
    end

    return true
end

-- Upload a single file
function SyncEngine:uploadFile(local_path, remote_path)
    if not self.provider then
        return false, _("Cloud provider not initialized")
    end

    return self.provider:uploadFile(local_path, remote_path)
end

-- Download a single file
function SyncEngine:downloadFile(remote_path, local_path, progress_callback)
    if not self.provider then
        return false, _("Cloud provider not initialized")
    end

    return self.provider:downloadFile(remote_path, local_path, progress_callback)
end

-- Count files in a directory
function SyncEngine:countFilesInDirectory(directory)
    local count = 0
    local ok, iter, dir_obj = pcall(lfs.dir, directory)
    if not ok then
        return 0
    end

    for file in iter, dir_obj do
        if file ~= "." and file ~= ".." then
            local file_path = directory .. "/" .. file
            if lfs.attributes(file_path, "mode") == "file" then
                count = count + 1
            end
        end
    end
    return count
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

-- Upload an .sdr directory to cloud storage
function SyncEngine:uploadSdrDirectory(sdr_info, progress_callback)
    if not self.provider then
        return false, _("Cloud provider not initialized")
    end

    local remote_base = self.sync_folder_path .. "/" .. sdr_info.name

    -- Ensure remote directory exists
    local success, err = self:ensureRemoteDirectory(remote_base)
    if not success then
        logger.warn("SuperSync: Could not ensure remote directory:", err)
        -- Continue anyway - upload might still work
    end

    -- Get files to upload
    local files = self:getFilesInSdr(sdr_info.path)
    local total_files = #files
    local uploaded_count = 0
    local failed_count = 0

    for i, file_info in ipairs(files) do
        local remote_file_path = remote_base .. "/" .. file_info.name

        local upload_success, upload_err = self:uploadFile(file_info.path, remote_file_path)
        if upload_success then
            uploaded_count = uploaded_count + 1
        else
            failed_count = failed_count + 1
            logger.warn("SuperSync: Failed to upload", file_info.name, ":", upload_err)
        end

        if progress_callback then
            progress_callback(i, total_files, file_info.name)
        end
    end

    if failed_count > 0 then
        logger.warn("SuperSync: Uploaded", uploaded_count, "files,", failed_count, "failed for", sdr_info.name)
    end

    return true, uploaded_count
end

-- Perform a full sync operation (upload all .sdr directories)
function SyncEngine:performFullSync(progress_callback)
    if not self.provider then
        logger.err("SuperSync: Cannot sync - provider not initialized:", self.init_error)
        return false, self.init_error
    end

    logger.info("SuperSync: Starting full sync operation")

    -- Ensure base sync folder exists
    local success, err = self:ensureRemoteDirectory(self.sync_folder_path)
    if not success then
        logger.warn("SuperSync: Could not ensure base sync folder:", err)
    end

    local sdr_directories = self:getSdrDirectories()
    logger.info("SuperSync: Found", #sdr_directories, ".sdr directories to sync")

    if #sdr_directories == 0 then
        logger.info("SuperSync: No .sdr directories found to sync")
        if progress_callback then
            progress_callback(1, 1, _("No metadata directories found"))
        end
        return true, 0
    end

    local total_operations = #sdr_directories
    local completed_operations = 0
    local total_files_uploaded = 0

    for _, sdr_info in ipairs(sdr_directories) do
        if progress_callback then
            progress_callback(completed_operations, total_operations,
                string.format(_("Syncing %s..."), sdr_info.name))
        end

        local success, result = self:uploadSdrDirectory(sdr_info, function(current, total, filename)
            if progress_callback then
                local overall_progress = completed_operations + (current / total)
                progress_callback(overall_progress, total_operations,
                    string.format("%s: %s (%d/%d)", sdr_info.name, filename, current, total))
            end
        end)

        completed_operations = completed_operations + 1

        if success then
            total_files_uploaded = total_files_uploaded + (result or 0)
            logger.info("SuperSync: Successfully synced", sdr_info.name)
        else
            logger.err("SuperSync: Failed to sync", sdr_info.name, ":", result)
        end
    end

    if progress_callback then
        progress_callback(total_operations, total_operations, _("Sync complete"))
    end

    logger.info("SuperSync: Full sync completed.", total_files_uploaded, "files uploaded from", completed_operations, "directories")
    return true, total_files_uploaded
end

return SyncEngine
