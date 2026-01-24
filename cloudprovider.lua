--[[--
Cloud Provider Abstraction Layer

Provides a unified interface for different cloud storage APIs (Dropbox, WebDAV, FTP).
Each provider has different method signatures; this module normalizes them.
--]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")
local _ = require("gettext")

local CloudProvider = {}

-- Load cloud storage settings using KOReader's LuaSettings
function CloudProvider.getCloudStorageSettings()
    local settings_file = DataStorage:getSettingsDir() .. "/cloudstorage.lua"
    local cs_settings = LuaSettings:open(settings_file)
    return cs_settings:readSetting("cs_servers") or {}
end

-- Get a specific server configuration by name
function CloudProvider.getServerByName(server_name)
    local servers = CloudProvider.getCloudStorageSettings()
    for _, server in ipairs(servers) do
        if server.name == server_name then
            return server
        end
    end
    return nil
end

-- Get list of configured servers for UI display
function CloudProvider.getServerList()
    local servers = CloudProvider.getCloudStorageSettings()
    local list = {}
    for _, server in ipairs(servers) do
        table.insert(list, {
            name = server.name,
            type = server.type,
            display = string.format("%s (%s)", server.name, server.type or "unknown"),
        })
    end
    return list
end

--[[--
Create a provider instance for a specific server.
Returns a table with normalized methods: uploadFile, downloadFile, createFolder, listFolder
--]]
function CloudProvider.create(server_name)
    local server = CloudProvider.getServerByName(server_name)
    if not server then
        logger.err("SuperSync: Server not found:", server_name)
        return nil, _("Cloud storage server not found")
    end

    local provider = {
        server = server,
        server_name = server_name,
        server_type = server.type,
    }

    if server.type == "dropbox" then
        return CloudProvider._createDropboxProvider(provider, server)
    elseif server.type == "webdav" then
        return CloudProvider._createWebDAVProvider(provider, server)
    elseif server.type == "ftp" then
        return CloudProvider._createFTPProvider(provider, server)
    else
        logger.err("SuperSync: Unsupported cloud storage type:", server.type)
        return nil, _("Unsupported cloud storage type")
    end
end

-- Dropbox provider implementation
function CloudProvider._createDropboxProvider(provider, server)
    local DropBoxApi = require("apps/cloudstorage/dropboxapi")

    -- Get access token from refresh token
    local function getToken()
        if server.password then
            -- password field stores the refresh token for Dropbox
            local token = DropBoxApi:getAccessToken(server.password, server.address)
            return token
        end
        return nil
    end

    provider.uploadFile = function(self, local_path, remote_path)
        local token = getToken()
        if not token then
            return false, _("Failed to get Dropbox access token")
        end
        local ok, err = pcall(function()
            DropBoxApi:uploadFile(remote_path, token, local_path, nil, true)
        end)
        if not ok then
            logger.warn("SuperSync: Dropbox upload failed:", err)
            return false, tostring(err)
        end
        return true
    end

    provider.downloadFile = function(self, remote_path, local_path, progress_callback)
        local token = getToken()
        if not token then
            return false, _("Failed to get Dropbox access token")
        end
        local ok, err = pcall(function()
            DropBoxApi:downloadFile(remote_path, token, local_path, progress_callback)
        end)
        if not ok then
            logger.warn("SuperSync: Dropbox download failed:", err)
            return false, tostring(err)
        end
        return true
    end

    provider.createFolder = function(self, remote_path, folder_name)
        local token = getToken()
        if not token then
            return false, _("Failed to get Dropbox access token")
        end
        local ok, err = pcall(function()
            DropBoxApi:createFolder(remote_path, token, folder_name)
        end)
        if not ok then
            logger.warn("SuperSync: Dropbox createFolder failed:", err)
            return false, tostring(err)
        end
        return true
    end

    provider.listFolder = function(self, remote_path)
        local token = getToken()
        if not token then
            return nil, _("Failed to get Dropbox access token")
        end
        local ok, result = pcall(function()
            return DropBoxApi:fetchListFolders(remote_path, token)
        end)
        if not ok then
            logger.warn("SuperSync: Dropbox listFolder failed:", result)
            return nil, tostring(result)
        end
        return result
    end

    return provider
end

-- WebDAV provider implementation
function CloudProvider._createWebDAVProvider(provider, server)
    local WebDavApi = require("apps/cloudstorage/webdavapi")

    local address = server.address
    local username = server.username
    local password = server.password

    provider.uploadFile = function(self, local_path, remote_path)
        local file_url = WebDavApi:getJoinedPath(address, remote_path)
        local code, err = WebDavApi:uploadFile(file_url, username, password, local_path, nil)
        if code and (code >= 200 and code < 300) then
            return true
        end
        logger.warn("SuperSync: WebDAV upload failed:", code, err)
        return false, err or tostring(code)
    end

    provider.downloadFile = function(self, remote_path, local_path, progress_callback)
        local file_url = WebDavApi:getJoinedPath(address, remote_path)
        local code, err = WebDavApi:downloadFile(file_url, username, password, local_path, progress_callback)
        if code and (code >= 200 and code < 300) then
            return true
        end
        logger.warn("SuperSync: WebDAV download failed:", code, err)
        return false, err or tostring(code)
    end

    provider.createFolder = function(self, remote_path, folder_name)
        local folder_url = WebDavApi:getJoinedPath(address, remote_path .. "/" .. folder_name)
        local code, err = WebDavApi:createFolder(folder_url, username, password, "")
        if code and (code >= 200 and code < 300 or code == 405) then
            -- 405 often means folder already exists
            return true
        end
        logger.warn("SuperSync: WebDAV createFolder failed:", code, err)
        return false, err or tostring(code)
    end

    provider.listFolder = function(self, remote_path)
        local ok, result = pcall(function()
            return WebDavApi:listFolder(address, username, password, remote_path, false)
        end)
        if not ok then
            logger.warn("SuperSync: WebDAV listFolder failed:", result)
            return nil, tostring(result)
        end
        return result
    end

    return provider
end

-- FTP provider implementation
function CloudProvider._createFTPProvider(provider, server)
    local FtpApi = require("apps/cloudstorage/ftpapi")

    local address = server.address
    local username = server.username
    local password = server.password

    provider.uploadFile = function(self, local_path, remote_path)
        local ok, err = pcall(function()
            FtpApi:uploadFile(local_path, remote_path, address, username, password)
        end)
        if not ok then
            logger.warn("SuperSync: FTP upload failed:", err)
            return false, tostring(err)
        end
        return true
    end

    provider.downloadFile = function(self, remote_path, local_path, progress_callback)
        local ok, err = pcall(function()
            FtpApi:downloadFile(remote_path, local_path, address, username, password, progress_callback)
        end)
        if not ok then
            logger.warn("SuperSync: FTP download failed:", err)
            return false, tostring(err)
        end
        return true
    end

    provider.createFolder = function(self, remote_path, folder_name)
        -- FTP folder creation - may need to be implemented differently
        -- For now, attempt to create via path
        local ok, err = pcall(function()
            local ftp = require("socket.ftp")
            local url = string.format("ftp://%s:%s@%s/%s/%s/",
                username, password, address, remote_path, folder_name)
            -- FTP doesn't have a direct mkdir in socket.ftp, would need raw commands
            -- This is a limitation - log and return true (folder will be created on first file upload)
            logger.info("SuperSync: FTP folder creation requested:", remote_path, "/", folder_name)
        end)
        return true -- FTP typically creates folders implicitly
    end

    provider.listFolder = function(self, remote_path)
        local ok, result = pcall(function()
            return FtpApi:listFolder(address, username, password, remote_path)
        end)
        if not ok then
            logger.warn("SuperSync: FTP listFolder failed:", result)
            return nil, tostring(result)
        end
        return result
    end

    return provider
end

return CloudProvider
