local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local DropBox = require("apps/cloudstorage/dropbox")
local WebDav = require("apps/cloudstorage/webdav")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local SyncEngine = {}

function SyncEngine:new(cloud_storage_name, sync_folder_path)
    local o = {
        cloud_storage_name = cloud_storage_name,
        sync_folder_path = sync_folder_path,
        cloud_storage = nil,
    }
    setmetatable(o, self)
    self.__index = self
    
    -- Initialize cloud storage connection
    o:initCloudStorage()
    
    return o
end

function SyncEngine:initCloudStorage()
    local cs_settings = self:readCloudStorageSettings()
    local storage_config = cs_settings[self.cloud_storage_name]
    
    if not storage_config then
        logger.err("SuperSync: Cloud storage configuration not found:", self.cloud_storage_name)
        return false
    end
    
    if storage_config.type == "dropbox" then
        self.cloud_storage = DropBox:new{
            server_setting = storage_config
        }
    elseif storage_config.type == "webdav" then
        self.cloud_storage = WebDav:new{
            server_setting = storage_config
        }
    else
        logger.err("SuperSync: Unsupported cloud storage type:", storage_config.type)
        return false
    end
    
    return true
end

function SyncEngine:readCloudStorageSettings()
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

-- Get list of all .sdr directories that need syncing
function SyncEngine:getSdrDirectories()
    local sdr_dirs = {}
    local docsettings_dir = DataStorage:getDocSettingsDir()
    local hash_docsettings_dir = DataStorage:getDocSettingsHashDir()
    
    -- Scan the main docsettings directory
    if lfs.attributes(docsettings_dir, "mode") == "directory" then
        self:scanDirectoryForSdr(docsettings_dir, sdr_dirs, "dir")
    end
    
    -- Scan the hash-based docsettings directory
    if lfs.attributes(hash_docsettings_dir, "mode") == "directory" then
        self:scanDirectoryForSdr(hash_docsettings_dir, sdr_dirs, "hash")
    end
    
    -- Also scan for document-adjacent .sdr directories
    -- This is more complex as we need to traverse the filesystem
    -- For now, we'll focus on the centralized directories
    
    return sdr_dirs
end

function SyncEngine:scanDirectoryForSdr(directory, sdr_dirs, location_type)
    for item in lfs.dir(directory) do
        if item ~= "." and item ~= ".." then
            local item_path = directory .. "/" .. item
            local attr = lfs.attributes(item_path)
            
            if attr.mode == "directory" then
                if item:match("%.sdr$") then
                    -- This is an .sdr directory
                    table.insert(sdr_dirs, {
                        path = item_path,
                        name = item,
                        location_type = location_type,
                        last_modified = attr.modification,
                    })
                elseif location_type == "hash" then
                    -- In hash directories, we need to scan subdirectories too
                    self:scanDirectoryForSdr(item_path, sdr_dirs, location_type)
                end
            end
        end
    end
end

-- Upload an .sdr directory to cloud storage
function SyncEngine:uploadSdrDirectory(sdr_info, progress_callback)
    if not self.cloud_storage then
        return false, _("Cloud storage not initialized")
    end
    
    local remote_path = self:getRemoteSdrPath(sdr_info)
    
    -- Create remote directory if it doesn't exist
    local success, err = self:ensureRemoteDirectory(remote_path)
    if not success then
        return false, err
    end
    
    -- Upload all files in the .sdr directory
    local uploaded_count = 0
    local total_files = self:countFilesInDirectory(sdr_info.path)
    
    for file in lfs.dir(sdr_info.path) do
        if file ~= "." and file ~= ".." then
            local local_file_path = sdr_info.path .. "/" .. file
            local remote_file_path = remote_path .. "/" .. file
            
            if lfs.attributes(local_file_path, "mode") == "file" then
                local upload_success, upload_err = self:uploadFile(local_file_path, remote_file_path)
                if upload_success then
                    uploaded_count = uploaded_count + 1
                    if progress_callback then
                        progress_callback(uploaded_count, total_files, file)
                    end
                else
                    logger.warn("SuperSync: Failed to upload file", local_file_path, ":", upload_err)
                end
            end
        end
    end
    
    return true, uploaded_count
end

-- Download an .sdr directory from cloud storage
function SyncEngine:downloadSdrDirectory(sdr_name, local_location_type, progress_callback)
    if not self.cloud_storage then
        return false, _("Cloud storage not initialized")
    end
    
    local remote_path = self.sync_folder_path .. "/" .. sdr_name
    local local_path = self:getLocalSdrPath(sdr_name, local_location_type)
    
    -- Ensure local directory exists
    if lfs.attributes(local_path, "mode") ~= "directory" then
        local success, err = lfs.mkdir(local_path)
        if not success then
            return false, "Failed to create local directory: " .. err
        end
    end
    
    -- List remote files
    local remote_files, list_err = self:listRemoteFiles(remote_path)
    if not remote_files then
        return false, list_err
    end
    
    -- Download each file
    local downloaded_count = 0
    local total_files = #remote_files
    
    for _, file_info in ipairs(remote_files) do
        local remote_file_path = remote_path .. "/" .. file_info.name
        local local_file_path = local_path .. "/" .. file_info.name
        
        local download_success, download_err = self:downloadFile(remote_file_path, local_file_path)
        if download_success then
            downloaded_count = downloaded_count + 1
            if progress_callback then
                progress_callback(downloaded_count, total_files, file_info.name)
            end
        else
            logger.warn("SuperSync: Failed to download file", remote_file_path, ":", download_err)
        end
    end
    
    return true, downloaded_count
end

function SyncEngine:getRemoteSdrPath(sdr_info)
    return self.sync_folder_path .. "/" .. sdr_info.name
end

function SyncEngine:getLocalSdrPath(sdr_name, location_type)
    if location_type == "dir" then
        return DataStorage:getDocSettingsDir() .. "/" .. sdr_name
    elseif location_type == "hash" then
        -- For hash-based storage, we need to extract the hash and create the proper path
        local hash = sdr_name:match("([^/]+)%.sdr$")
        if hash and #hash >= 2 then
            local subdir = hash:sub(1, 2)
            local hash_dir = DataStorage:getDocSettingsHashDir() .. "/" .. subdir
            if lfs.attributes(hash_dir, "mode") ~= "directory" then
                lfs.mkdir(hash_dir)
            end
            return hash_dir .. "/" .. sdr_name
        end
    end
    
    -- Fallback to dir location
    return DataStorage:getDocSettingsDir() .. "/" .. sdr_name
end

function SyncEngine:ensureRemoteDirectory(remote_path)
    -- Implementation depends on cloud storage type
    if self.cloud_storage.createFolder then
        return self.cloud_storage:createFolder(remote_path)
    end
    return true -- Assume directory exists or will be created on upload
end

function SyncEngine:uploadFile(local_path, remote_path)
    if self.cloud_storage.uploadFile then
        return self.cloud_storage:uploadFile(local_path, remote_path)
    end
    return false, "Upload not supported by cloud storage provider"
end

function SyncEngine:downloadFile(remote_path, local_path)
    if self.cloud_storage.downloadFile then 
        return self.cloud_storage:downloadFile(remote_path, local_path)
    end
    return false, "Download not supported by cloud storage provider"
end

function SyncEngine:listRemoteFiles(remote_path)
    if self.cloud_storage.listFiles then
        return self.cloud_storage:listFiles(remote_path)
    end
    return {}, nil -- Return empty list if listing not supported
end

function SyncEngine:countFilesInDirectory(directory)
    local count = 0
    for file in lfs.dir(directory) do
        if file ~= "." and file ~= ".." then
            if lfs.attributes(directory .. "/" .. file, "mode") == "file" then
                count = count + 1
            end
        end
    end
    return count
end

-- Perform a full sync operation
function SyncEngine:performFullSync(progress_callback)
    logger.info("SuperSync: Starting full sync operation")
    
    local sdr_directories = self:getSdrDirectories()
    logger.info("SuperSync: Found", #sdr_directories, ".sdr directories to sync")
    
    local total_operations = #sdr_directories
    local completed_operations = 0
    
    for _, sdr_info in ipairs(sdr_directories) do
        local success, result = self:uploadSdrDirectory(sdr_info, function(current, total, filename)
            if progress_callback then
                progress_callback(completed_operations, total_operations, 
                    string.format("Uploading %s: %s (%d/%d)", sdr_info.name, filename, current, total))
            end
        end)
        
        completed_operations = completed_operations + 1
        
        if success then
            logger.info("SuperSync: Successfully uploaded", sdr_info.name, "with", result, "files")
        else
            logger.err("SuperSync: Failed to upload", sdr_info.name, ":", result)
        end
        
        if progress_callback then
            progress_callback(completed_operations, total_operations, 
                string.format("Completed %s", sdr_info.name))
        end
    end
    
    logger.info("SuperSync: Full sync completed")
    return true
end

return SyncEngine