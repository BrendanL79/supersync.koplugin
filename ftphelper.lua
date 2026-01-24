--[[--
FTP Helper Module

Provides FTP protocol operations not available in KOReader's ftpapi.lua:
- MDTM command for file modification times
- LIST parsing for directory listings with metadata
- MKD command for creating directories
- DELE command for deleting files
- Raw FTP command execution

Uses LuaSocket's socket.ftp module directly.
--]]

local ftp = require("socket.ftp")
local ltn12 = require("ltn12")
local url = require("socket.url")
local logger = require("logger")

local FtpHelper = {}

-- Parse MDTM response (format: YYYYMMDDHHMMSS or YYYYMMDDHHMMSS.mmm)
-- Returns Unix timestamp or nil on error
local function parseMdtmResponse(response)
    if not response or type(response) ~= "string" then
        return nil
    end

    -- Extract timestamp from response (may have leading "213 " status code)
    local timestamp_str = response:match("(%d%d%d%d%d%d%d%d%d%d%d%d%d%d)")
    if not timestamp_str then
        return nil
    end

    local year = tonumber(timestamp_str:sub(1, 4))
    local month = tonumber(timestamp_str:sub(5, 6))
    local day = tonumber(timestamp_str:sub(7, 8))
    local hour = tonumber(timestamp_str:sub(9, 10))
    local min = tonumber(timestamp_str:sub(11, 12))
    local sec = tonumber(timestamp_str:sub(13, 14))

    if not (year and month and day and hour and min and sec) then
        return nil
    end

    -- Convert to Unix timestamp (UTC)
    local time_table = {
        year = year,
        month = month,
        day = day,
        hour = hour,
        min = min,
        sec = sec,
    }

    local ok, timestamp = pcall(os.time, time_table)
    if ok then
        return timestamp
    end

    return nil
end

-- Parse a single LIST line (Unix-style format)
-- Example: "-rw-r--r--    1 user     group        1234 Jan 15 10:30 filename.txt"
-- Returns: {name=string, size=number, mtime=timestamp, is_dir=boolean} or nil
local function parseListLine(line)
    if not line or line == "" then
        return nil
    end

    -- Unix-style listing pattern
    local permissions, links, user, group, size, month, day, time_or_year, name =
        line:match("^([%-%w]+)%s+(%d+)%s+(%S+)%s+(%S+)%s+(%d+)%s+(%a+)%s+(%d+)%s+([%d:]+)%s+(.+)$")

    if not permissions then
        -- Try simpler pattern (some servers)
        permissions, size, month, day, time_or_year, name =
            line:match("^([%-%w]+)%s+(%d+)%s+(%a+)%s+(%d+)%s+([%d:]+)%s+(.+)$")
    end

    if not name then
        -- Fallback: just extract filename (last non-space sequence)
        name = line:match("(%S+)%s*$")
        if not name then
            return nil
        end
        -- Return with minimal info
        return {
            name = name,
            size = 0,
            mtime = nil,
            is_dir = line:match("^d") ~= nil,
        }
    end

    -- Parse is_dir from permissions
    local is_dir = permissions:sub(1, 1) == "d"

    -- Parse size
    size = tonumber(size) or 0

    -- Parse date/time
    local mtime = nil
    local month_map = {
        Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
        Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12
    }

    local month_num = month_map[month]
    local day_num = tonumber(day)

    if month_num and day_num then
        local year, hour, min

        if time_or_year:match(":") then
            -- Format: HH:MM (current year assumed)
            hour, min = time_or_year:match("(%d+):(%d+)")
            year = os.date("*t").year
        else
            -- Format: YYYY (year, time assumed 00:00)
            year = tonumber(time_or_year)
            hour, min = 0, 0
        end

        if year and hour and min then
            local ok, ts = pcall(os.time, {
                year = year,
                month = month_num,
                day = day_num,
                hour = tonumber(hour),
                min = tonumber(min),
                sec = 0,
            })
            if ok then
                mtime = ts
            end
        end
    end

    return {
        name = name,
        size = size,
        mtime = mtime,
        is_dir = is_dir,
    }
end

-- Create a new FtpHelper instance
function FtpHelper:new(server)
    local o = {
        host = server.address:gsub("^ftp://", ""),
        user = server.username or "anonymous",
        pass = server.password or "",
        mdtm_supported = nil, -- Unknown until tested
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Build FTP URL for a path
function FtpHelper:buildUrl(path)
    local encoded_user = url.escape(self.user)
    local encoded_pass = url.escape(self.pass)

    if self.pass and self.pass ~= "" then
        return string.format("ftp://%s:%s@%s%s", encoded_user, encoded_pass, self.host, path)
    elseif self.user and self.user ~= "" then
        return string.format("ftp://%s@%s%s", encoded_user, self.host, path)
    else
        return string.format("ftp://%s%s", self.host, path)
    end
end

-- Execute a raw FTP command
-- Returns: response string, error message
function FtpHelper:command(cmd, argument)
    local p = {
        host = self.host,
        user = self.user,
        password = self.pass,
        command = cmd,
        argument = argument,
    }

    local result, err = ftp.command(p)
    return result, err
end

-- Get file modification time using MDTM command
-- Returns: Unix timestamp or nil, error message
function FtpHelper:getModificationTime(remote_path)
    -- If we know MDTM is not supported, return nil immediately
    if self.mdtm_supported == false then
        return nil, "MDTM not supported"
    end

    -- Remove leading slash for MDTM argument
    local path_arg = remote_path:gsub("^/", "")

    local result, err = self:command("mdtm", path_arg)

    if not result then
        -- Check if this is a "command not supported" error
        if err and (err:match("500") or err:match("502") or err:match("not.*support")) then
            self.mdtm_supported = false
            logger.info("SuperSync: FTP server does not support MDTM command")
        end
        return nil, err
    end

    -- Mark MDTM as supported
    self.mdtm_supported = true

    local timestamp = parseMdtmResponse(result)
    if not timestamp then
        return nil, "Could not parse MDTM response: " .. tostring(result)
    end

    return timestamp
end

-- Check if MDTM is supported (tests with a command if unknown)
function FtpHelper:isMdtmSupported()
    if self.mdtm_supported ~= nil then
        return self.mdtm_supported
    end

    -- Try to get mtime of root directory (will fail but tells us if command exists)
    local _, err = self:command("mdtm", ".")
    if err and (err:match("500") or err:match("502")) then
        self.mdtm_supported = false
    else
        self.mdtm_supported = true
    end

    return self.mdtm_supported
end

-- List directory with modification times
-- Returns: table of {name, size, mtime, is_dir} or nil, error
function FtpHelper:listDirectory(remote_path)
    local results = {}
    local listing = {}

    -- Use LIST command (not NLST) to get detailed info
    local sink = ltn12.sink.table(listing)

    local ftp_url = self:buildUrl(remote_path)
    local p = url.parse(ftp_url)
    p.user = self.user
    p.password = self.pass
    p.command = "list"
    p.sink = sink

    local ok, err = ftp.get(p)
    if not ok then
        return nil, err
    end

    -- Parse each line
    local content = table.concat(listing)
    for line in content:gmatch("[^\r\n]+") do
        local entry = parseListLine(line)
        if entry and entry.name ~= "." and entry.name ~= ".." then
            table.insert(results, entry)
        end
    end

    -- If LIST didn't give us mtimes and MDTM is supported, fetch them individually
    local need_mdtm = false
    for _, entry in ipairs(results) do
        if not entry.mtime and not entry.is_dir then
            need_mdtm = true
            break
        end
    end

    if need_mdtm and self:isMdtmSupported() then
        for _, entry in ipairs(results) do
            if not entry.mtime and not entry.is_dir then
                local file_path = remote_path
                if not file_path:match("/$") then
                    file_path = file_path .. "/"
                end
                file_path = file_path .. entry.name

                local mtime = self:getModificationTime(file_path)
                if mtime then
                    entry.mtime = mtime
                end
            end
        end
    end

    return results
end

-- Create a directory (single level)
-- Returns: true/false, error message
function FtpHelper:createDirectory(remote_path)
    local path_arg = remote_path:gsub("^/", "")

    local result, err = self:command("mkd", path_arg)

    if result then
        return true
    end

    -- 550 usually means directory already exists - treat as success
    if err and err:match("550") then
        return true
    end

    return false, err
end

-- Create directory path recursively
-- Returns: true/false, error message
function FtpHelper:createDirectoryPath(remote_path)
    local parts = {}
    for part in remote_path:gmatch("[^/]+") do
        table.insert(parts, part)
    end

    local current = ""
    for _, part in ipairs(parts) do
        current = current .. "/" .. part
        local ok, err = self:createDirectory(current)
        if not ok then
            -- Log but continue - might already exist
            logger.dbg("SuperSync: FTP mkdir", current, ":", err or "unknown error")
        end
    end

    return true
end

-- Delete a file
-- Returns: true/false, error message
function FtpHelper:deleteFile(remote_path)
    local path_arg = remote_path:gsub("^/", "")

    local result, err = self:command("dele", path_arg)

    if result then
        return true
    end

    return false, err
end

-- Download a file
-- Returns: true/false, error message
function FtpHelper:downloadFile(remote_path, local_path)
    local ftp_url = self:buildUrl(remote_path)

    -- Ensure local directory exists
    local local_dir = local_path:match("(.+)/[^/]+$")
    if local_dir then
        os.execute('mkdir -p "' .. local_dir .. '"')
    end

    local file, open_err = io.open(local_path, "wb")
    if not file then
        return false, "Cannot open local file: " .. tostring(open_err)
    end

    local sink = ltn12.sink.file(file)

    local p = url.parse(ftp_url)
    p.user = self.user
    p.password = self.pass
    p.type = "i" -- Binary mode
    p.sink = sink

    local ok, err = ftp.get(p)

    if not ok then
        os.remove(local_path) -- Clean up partial download
        return false, err
    end

    return true
end

-- Upload a file
-- Returns: true/false, error message
function FtpHelper:uploadFile(local_path, remote_path)
    local file, open_err = io.open(local_path, "rb")
    if not file then
        return false, "Cannot open local file: " .. tostring(open_err)
    end

    local source = ltn12.source.file(file)

    local ftp_url = self:buildUrl(remote_path)
    local p = url.parse(ftp_url)
    p.user = self.user
    p.password = self.pass
    p.type = "i" -- Binary mode
    p.source = source
    p.command = "stor"

    -- Ensure parent directory exists
    local parent_dir = remote_path:match("(.+)/[^/]+$")
    if parent_dir then
        self:createDirectoryPath(parent_dir)
    end

    local ok, err = ftp.put(p)

    if not ok then
        return false, err
    end

    return true
end

-- Check if a remote path exists
-- Returns: "file", "directory", or nil
function FtpHelper:exists(remote_path)
    -- Try to get modification time (works for files)
    local mtime = self:getModificationTime(remote_path)
    if mtime then
        return "file"
    end

    -- Try to list it (works for directories)
    local listing, err = self:listDirectory(remote_path)
    if listing then
        return "directory"
    end

    return nil
end

return FtpHelper
