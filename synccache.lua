--[[--
Sync Cache Module

Persists sync state between sessions to enable three-way comparison for
bidirectional sync. Tracks local and remote modification times for each
file at the time of last successful sync.
--]]

local DataStorage = require("datastorage")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local SyncCache = {}

local CACHE_VERSION = 1

function SyncCache:new(server_name)
    local o = {
        server_name = server_name,
        cache_file = DataStorage:getSettingsDir() .. "/supersync_cache.json",
        data = nil,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Load cache from disk
function SyncCache:load()
    if self.data then
        return true -- Already loaded
    end

    local file = io.open(self.cache_file, "r")
    if not file then
        -- No cache file yet, initialize empty
        self.data = {
            version = CACHE_VERSION,
            servers = {},
        }
        return true
    end

    local content = file:read("*all")
    file:close()

    local ok, parsed = pcall(json.decode, content)
    if not ok or type(parsed) ~= "table" then
        logger.warn("SuperSync: Cache file corrupted, reinitializing")
        self.data = {
            version = CACHE_VERSION,
            servers = {},
        }
        return true
    end

    -- Handle version upgrades if needed
    if parsed.version ~= CACHE_VERSION then
        logger.info("SuperSync: Upgrading cache from version", parsed.version, "to", CACHE_VERSION)
        -- For now, just reset on version mismatch
        self.data = {
            version = CACHE_VERSION,
            servers = {},
        }
        return true
    end

    self.data = parsed
    return true
end

-- Save cache to disk
function SyncCache:save()
    if not self.data then
        return false
    end

    -- Write to temp file first, then rename for atomicity
    local temp_file = self.cache_file .. ".tmp"
    local file = io.open(temp_file, "w")
    if not file then
        logger.err("SuperSync: Cannot write cache file:", temp_file)
        return false
    end

    local ok, encoded = pcall(json.encode, self.data)
    if not ok then
        logger.err("SuperSync: Cannot encode cache:", encoded)
        file:close()
        os.remove(temp_file)
        return false
    end

    file:write(encoded)
    file:close()

    -- Atomic rename
    os.remove(self.cache_file)
    os.rename(temp_file, self.cache_file)

    return true
end

-- Get server-specific data, creating if needed
function SyncCache:getServerData()
    self:load()

    if not self.data.servers[self.server_name] then
        self.data.servers[self.server_name] = {
            last_sync_time = nil,
            files = {},
            cached_content = {},
        }
    end

    return self.data.servers[self.server_name]
end

-- Get state for a specific file
function SyncCache:getFileState(remote_path)
    local server_data = self:getServerData()
    return server_data.files[remote_path]
end

-- Set state for a specific file
function SyncCache:setFileState(remote_path, local_mtime, remote_mtime, synced_at)
    local server_data = self:getServerData()
    server_data.files[remote_path] = {
        local_mtime = local_mtime,
        remote_mtime = remote_mtime,
        synced_at = synced_at or os.time(),
    }
end

-- Remove a file from cache (when deleted)
function SyncCache:removeFile(remote_path)
    local server_data = self:getServerData()
    server_data.files[remote_path] = nil
    server_data.cached_content[remote_path] = nil
end

-- Get all cached file states for this server
function SyncCache:getAllFiles()
    local server_data = self:getServerData()
    return server_data.files or {}
end

-- Get files within a specific remote directory
function SyncCache:getFilesInDirectory(remote_dir)
    local server_data = self:getServerData()
    local result = {}

    -- Ensure directory path ends with /
    if not remote_dir:match("/$") then
        remote_dir = remote_dir .. "/"
    end

    for path, state in pairs(server_data.files or {}) do
        -- Check if file is directly in this directory (not subdirectory)
        if path:sub(1, #remote_dir) == remote_dir then
            local relative = path:sub(#remote_dir + 1)
            if not relative:match("/") then
                result[path] = state
            end
        end
    end

    return result
end

-- Get last sync time for this server
function SyncCache:getLastSyncTime()
    local server_data = self:getServerData()
    return server_data.last_sync_time
end

-- Set last sync time
function SyncCache:setLastSyncTime(timestamp)
    local server_data = self:getServerData()
    server_data.last_sync_time = timestamp or os.time()
end

-- Save cached content for three-way merge (stores serialized Lua table)
function SyncCache:saveCachedContent(remote_path, content)
    local server_data = self:getServerData()

    -- Serialize if it's a table
    if type(content) == "table" then
        local ok, encoded = pcall(json.encode, content)
        if ok then
            server_data.cached_content[remote_path] = encoded
        else
            logger.warn("SuperSync: Cannot serialize content for cache:", remote_path)
        end
    else
        server_data.cached_content[remote_path] = content
    end
end

-- Get cached content for three-way merge
function SyncCache:getCachedContent(remote_path)
    local server_data = self:getServerData()
    local cached = server_data.cached_content[remote_path]

    if not cached then
        return nil
    end

    -- Try to decode as JSON (it's a serialized table)
    local ok, decoded = pcall(json.decode, cached)
    if ok then
        return decoded
    end

    return cached
end

-- Clear all cached content (to save space)
function SyncCache:clearCachedContent()
    local server_data = self:getServerData()
    server_data.cached_content = {}
end

-- Get cache statistics
function SyncCache:getStats()
    local server_data = self:getServerData()
    local file_count = 0
    local content_count = 0

    for _ in pairs(server_data.files or {}) do
        file_count = file_count + 1
    end

    for _ in pairs(server_data.cached_content or {}) do
        content_count = content_count + 1
    end

    return {
        file_count = file_count,
        content_count = content_count,
        last_sync = server_data.last_sync_time,
    }
end

return SyncCache
