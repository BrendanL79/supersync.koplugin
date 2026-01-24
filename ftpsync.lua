--[[--
FTP Bidirectional Sync Module

Implements timestamp-based bidirectional synchronization for FTP servers.
Uses MDTM command for modification times and maintains a local sync cache
to enable three-way comparison and conflict resolution.
--]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local FtpHelper = require("ftphelper")
local SyncCache = require("synccache")

local FtpSync = {}

-- Sync action constants
FtpSync.ACTION_SKIP = "skip"
FtpSync.ACTION_UPLOAD = "upload"
FtpSync.ACTION_DOWNLOAD = "download"
FtpSync.ACTION_CONFLICT = "conflict"
FtpSync.ACTION_DELETE_LOCAL = "delete_local"
FtpSync.ACTION_DELETE_REMOTE = "delete_remote"

function FtpSync:new(server, sync_folder_path)
    local o = {
        server = server,
        sync_folder_path = sync_folder_path,
        ftp = FtpHelper:new(server),
        cache = SyncCache:new(server.name),
        mdtm_available = nil,
    }
    setmetatable(o, self)
    self.__index = self

    -- Load cache
    o.cache:load()

    return o
end

-- Check if MDTM is available (enables full bidirectional sync)
function FtpSync:checkMdtmSupport()
    if self.mdtm_available ~= nil then
        return self.mdtm_available
    end

    self.mdtm_available = self.ftp:isMdtmSupported()

    if not self.mdtm_available then
        logger.warn("SuperSync: FTP server does not support MDTM - falling back to upload-only")
    end

    return self.mdtm_available
end

-- Determine what action to take for a file
-- Parameters are file info tables with: name, mtime, size (or nil if doesn't exist)
function FtpSync:determineAction(local_info, remote_info, cached_info)
    local local_exists = local_info ~= nil
    local remote_exists = remote_info ~= nil
    local was_synced = cached_info ~= nil

    -- First time seeing this file (not in cache)
    if not was_synced then
        if local_exists and remote_exists then
            -- Both exist but never synced - treat as conflict
            return self.ACTION_CONFLICT
        elseif local_exists then
            return self.ACTION_UPLOAD
        elseif remote_exists then
            return self.ACTION_DOWNLOAD
        else
            return self.ACTION_SKIP
        end
    end

    -- We have sync history
    local local_mtime = local_info and local_info.mtime
    local remote_mtime = remote_info and remote_info.mtime
    local cached_local_mtime = cached_info.local_mtime
    local cached_remote_mtime = cached_info.remote_mtime

    -- Determine what changed using deltas (handles clock skew)
    local local_changed = local_exists and local_mtime and cached_local_mtime and
                          (local_mtime > cached_local_mtime)
    local remote_changed = remote_exists and remote_mtime and cached_remote_mtime and
                           (remote_mtime > cached_remote_mtime)

    local local_deleted = not local_exists and was_synced
    local remote_deleted = not remote_exists and was_synced

    -- Decision matrix
    if local_deleted and remote_deleted then
        return self.ACTION_SKIP -- Both deleted, nothing to do
    elseif local_deleted and remote_changed then
        return self.ACTION_DOWNLOAD -- Restore from remote (remote has updates)
    elseif local_deleted then
        return self.ACTION_DELETE_REMOTE -- Propagate delete
    elseif remote_deleted and local_changed then
        return self.ACTION_UPLOAD -- Re-upload (local has updates)
    elseif remote_deleted then
        return self.ACTION_DELETE_LOCAL -- Propagate delete
    elseif local_changed and remote_changed then
        return self.ACTION_CONFLICT -- Both changed
    elseif local_changed then
        return self.ACTION_UPLOAD
    elseif remote_changed then
        return self.ACTION_DOWNLOAD
    else
        return self.ACTION_SKIP -- Nothing changed
    end
end

-- Read a Lua data file
function FtpSync:readLuaFile(path)
    if not path or lfs.attributes(path, "mode") ~= "file" then
        return nil
    end

    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then
        return data
    end

    return nil
end

-- Write a Lua data file
function FtpSync:writeLuaFile(path, data)
    local file = io.open(path, "w")
    if not file then
        return false
    end

    -- Simple serialization
    local function serialize(t, indent)
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
                val_str = serialize(v, next_indent)
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

    file:write("return " .. serialize(data))
    file:close()
    return true
end

-- Deep merge two tables (source values override target)
function FtpSync:deepMerge(target, source)
    local result = {}

    if target then
        for k, v in pairs(target) do
            if type(v) == "table" then
                result[k] = self:deepMerge({}, v)
            else
                result[k] = v
            end
        end
    end

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

-- Compare two values for equality
function FtpSync:valuesEqual(a, b)
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

-- Three-way merge for Lua tables
function FtpSync:threeWayMerge(local_data, cached_data, remote_data)
    if not cached_data then
        return self:deepMerge(remote_data, local_data)
    end

    local merged = {}
    local all_keys = {}

    for k in pairs(local_data or {}) do all_keys[k] = true end
    for k in pairs(cached_data or {}) do all_keys[k] = true end
    for k in pairs(remote_data or {}) do all_keys[k] = true end

    for key in pairs(all_keys) do
        local local_val = local_data and local_data[key]
        local cached_val = cached_data and cached_data[key]
        local remote_val = remote_data and remote_data[key]

        local local_changed = not self:valuesEqual(local_val, cached_val)
        local remote_changed = not self:valuesEqual(remote_val, cached_val)

        if local_changed and remote_changed then
            -- Conflict - prefer local
            if local_val ~= nil then
                merged[key] = local_val
            end
        elseif local_changed then
            if local_val ~= nil then
                merged[key] = local_val
            end
        elseif remote_changed then
            if remote_val ~= nil then
                merged[key] = remote_val
            end
        else
            merged[key] = local_val or remote_val or cached_val
        end
    end

    return merged
end

-- Resolve a conflict by three-way merge
function FtpSync:resolveConflict(local_path, remote_path)
    -- Download remote to temp file
    local temp_path = local_path .. ".remote_tmp"
    local ok, err = self.ftp:downloadFile(remote_path, temp_path)
    if not ok then
        logger.warn("SuperSync: Failed to download for merge:", err)
        -- Fall back to uploading local
        return self.ACTION_UPLOAD
    end

    -- Read all three versions
    local local_data = self:readLuaFile(local_path)
    local remote_data = self:readLuaFile(temp_path)
    local cached_data = self.cache:getCachedContent(remote_path)

    -- Clean up temp file
    os.remove(temp_path)

    -- If not Lua tables, fall back to local wins
    if not local_data or not remote_data then
        logger.info("SuperSync: Non-Lua conflict, local wins:", local_path)
        return self.ACTION_UPLOAD
    end

    -- Perform three-way merge
    local merged = self:threeWayMerge(local_data, cached_data, remote_data)

    -- Write merged result
    self:writeLuaFile(local_path, merged)

    -- Update cache with merged content
    self.cache:saveCachedContent(remote_path, merged)

    logger.info("SuperSync: Merged conflict:", local_path)

    -- Now upload the merged result
    return self.ACTION_UPLOAD
end

-- Get local files in an .sdr directory
function FtpSync:getLocalFiles(sdr_path)
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
                files[file] = {
                    name = file,
                    path = file_path,
                    mtime = attr.modification,
                    size = attr.size,
                }
            end
        end
    end

    return files
end

-- Get remote files in an .sdr directory
function FtpSync:getRemoteFiles(remote_sdr_path)
    local files = {}

    local listing, err = self.ftp:listDirectory(remote_sdr_path)
    if not listing then
        logger.dbg("SuperSync: Cannot list remote directory:", remote_sdr_path, err)
        return files
    end

    for _, entry in ipairs(listing) do
        if not entry.is_dir then
            files[entry.name] = {
                name = entry.name,
                path = remote_sdr_path .. "/" .. entry.name,
                mtime = entry.mtime,
                size = entry.size,
            }
        end
    end

    return files
end

-- Sync a single .sdr directory
function FtpSync:syncDirectory(local_sdr_path, sdr_name, progress_callback)
    local remote_sdr_path = self.sync_folder_path .. "/" .. sdr_name

    -- Ensure remote directory exists
    self.ftp:createDirectoryPath(remote_sdr_path)

    -- Get file lists
    local local_files = self:getLocalFiles(local_sdr_path)
    local remote_files = self:getRemoteFiles(remote_sdr_path)
    local cached_files = self.cache:getFilesInDirectory(remote_sdr_path)

    -- Build unified file list
    local all_files = {}
    for name in pairs(local_files) do all_files[name] = true end
    for name in pairs(remote_files) do all_files[name] = true end
    for path in pairs(cached_files) do
        local name = path:match("([^/]+)$")
        if name then all_files[name] = true end
    end

    local stats = {
        uploaded = 0,
        downloaded = 0,
        conflicts = 0,
        deleted = 0,
        skipped = 0,
        errors = 0,
    }

    local file_list = {}
    for name in pairs(all_files) do
        table.insert(file_list, name)
    end
    table.sort(file_list)

    local total_files = #file_list

    for i, filename in ipairs(file_list) do
        local local_info = local_files[filename]
        local remote_info = remote_files[filename]
        local remote_path = remote_sdr_path .. "/" .. filename
        local cached_info = self.cache:getFileState(remote_path)

        local action = self:determineAction(local_info, remote_info, cached_info)

        if progress_callback then
            progress_callback(i, total_files, filename .. " (" .. action .. ")")
        end

        local success = true
        local err

        if action == self.ACTION_UPLOAD then
            success, err = self.ftp:uploadFile(local_info.path, remote_path)
            if success then
                local remote_mtime = self.ftp:getModificationTime(remote_path) or os.time()
                self.cache:setFileState(remote_path, local_info.mtime, remote_mtime, os.time())
                -- Cache content for future merges
                local content = self:readLuaFile(local_info.path)
                if content then
                    self.cache:saveCachedContent(remote_path, content)
                end
                stats.uploaded = stats.uploaded + 1
            end

        elseif action == self.ACTION_DOWNLOAD then
            local local_path = local_sdr_path .. "/" .. filename
            success, err = self.ftp:downloadFile(remote_path, local_path)
            if success then
                -- Set local mtime to match remote for consistency
                if remote_info.mtime then
                    lfs.touch(local_path, remote_info.mtime)
                end
                local local_mtime = lfs.attributes(local_path, "modification") or os.time()
                self.cache:setFileState(remote_path, local_mtime, remote_info.mtime or local_mtime, os.time())
                -- Cache content for future merges
                local content = self:readLuaFile(local_path)
                if content then
                    self.cache:saveCachedContent(remote_path, content)
                end
                stats.downloaded = stats.downloaded + 1
            end

        elseif action == self.ACTION_CONFLICT then
            stats.conflicts = stats.conflicts + 1
            local local_path = local_sdr_path .. "/" .. filename
            local resolved_action = self:resolveConflict(local_path, remote_path)

            if resolved_action == self.ACTION_UPLOAD then
                success, err = self.ftp:uploadFile(local_path, remote_path)
                if success then
                    local local_mtime = lfs.attributes(local_path, "modification") or os.time()
                    local remote_mtime = self.ftp:getModificationTime(remote_path) or os.time()
                    self.cache:setFileState(remote_path, local_mtime, remote_mtime, os.time())
                    stats.uploaded = stats.uploaded + 1
                end
            end

        elseif action == self.ACTION_DELETE_REMOTE then
            success, err = self.ftp:deleteFile(remote_path)
            if success then
                self.cache:removeFile(remote_path)
                stats.deleted = stats.deleted + 1
            end

        elseif action == self.ACTION_DELETE_LOCAL then
            local local_path = local_sdr_path .. "/" .. filename
            os.remove(local_path)
            self.cache:removeFile(remote_path)
            stats.deleted = stats.deleted + 1

        else -- SKIP
            stats.skipped = stats.skipped + 1
        end

        if not success and action ~= self.ACTION_SKIP then
            logger.warn("SuperSync: Failed to", action, filename, ":", err)
            stats.errors = stats.errors + 1
        end
    end

    return stats
end

-- Perform full sync (all .sdr directories)
function FtpSync:performFullSync(sdr_directories, progress_callback)
    -- Check MDTM support first
    local has_mdtm = self:checkMdtmSupport()

    if not has_mdtm then
        -- Fall back to upload-only mode
        return self:performUploadOnlySync(sdr_directories, progress_callback)
    end

    logger.info("SuperSync: Starting FTP bidirectional sync")

    -- Ensure base sync folder exists
    self.ftp:createDirectoryPath(self.sync_folder_path)

    local total_stats = {
        uploaded = 0,
        downloaded = 0,
        conflicts = 0,
        deleted = 0,
        skipped = 0,
        errors = 0,
    }

    local total_dirs = #sdr_directories
    for i, sdr_info in ipairs(sdr_directories) do
        if progress_callback then
            progress_callback(i - 1, total_dirs, string.format(_("Syncing %s..."), sdr_info.name))
        end

        local stats = self:syncDirectory(sdr_info.path, sdr_info.name, function(current, total, status)
            if progress_callback then
                local overall = (i - 1) + (current / total)
                progress_callback(overall, total_dirs, sdr_info.name .. ": " .. status)
            end
        end)

        -- Accumulate stats
        for k, v in pairs(stats) do
            total_stats[k] = (total_stats[k] or 0) + v
        end
    end

    -- Save cache
    self.cache:setLastSyncTime(os.time())
    self.cache:save()

    if progress_callback then
        progress_callback(total_dirs, total_dirs, _("Sync complete"))
    end

    local total_synced = total_stats.uploaded + total_stats.downloaded
    logger.info("SuperSync: FTP sync completed.",
        "Uploaded:", total_stats.uploaded,
        "Downloaded:", total_stats.downloaded,
        "Conflicts:", total_stats.conflicts,
        "Deleted:", total_stats.deleted,
        "Errors:", total_stats.errors)

    return true, total_synced, total_stats
end

-- Fallback: upload-only sync when MDTM is not available
function FtpSync:performUploadOnlySync(sdr_directories, progress_callback)
    logger.info("SuperSync: Starting FTP upload-only sync (MDTM not available)")

    self.ftp:createDirectoryPath(self.sync_folder_path)

    local total_uploaded = 0
    local total_dirs = #sdr_directories

    for i, sdr_info in ipairs(sdr_directories) do
        if progress_callback then
            progress_callback(i - 1, total_dirs, string.format(_("Uploading %s..."), sdr_info.name))
        end

        local remote_sdr_path = self.sync_folder_path .. "/" .. sdr_info.name
        self.ftp:createDirectoryPath(remote_sdr_path)

        local local_files = self:getLocalFiles(sdr_info.path)
        local file_list = {}
        for name in pairs(local_files) do
            table.insert(file_list, name)
        end

        local total_files = #file_list
        for j, filename in ipairs(file_list) do
            local local_info = local_files[filename]
            local remote_path = remote_sdr_path .. "/" .. filename

            if progress_callback then
                local overall = (i - 1) + (j / total_files)
                progress_callback(overall, total_dirs, sdr_info.name .. ": " .. filename)
            end

            local ok, err = self.ftp:uploadFile(local_info.path, remote_path)
            if ok then
                total_uploaded = total_uploaded + 1
            else
                logger.warn("SuperSync: Upload failed:", filename, err)
            end
        end
    end

    if progress_callback then
        progress_callback(total_dirs, total_dirs, _("Upload complete"))
    end

    logger.info("SuperSync: FTP upload-only completed.", total_uploaded, "files uploaded")
    return true, total_uploaded
end

return FtpSync
