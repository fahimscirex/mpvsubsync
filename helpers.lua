local utils = require('mp.utils')
local self = {}

function self.is_empty(var)
    return var == nil or var == '' or (type(var) == 'table' and next(var) == nil)
end

function self.file_exists(filepath)
    if not self.is_empty(filepath) then
        local info = utils.file_info(filepath)
        if info and info.is_file then
            return true
        end
    end
    return false
end

function self.alt_dirs()
    local dirs = {
        '/opt/homebrew/bin',
        '/usr/local/bin',
    }
    
    local home = os.getenv("USERPROFILE") or os.getenv("HOME") or "~"
    table.insert(dirs, utils.join_path(home, '.local/bin'))
    table.insert(dirs, utils.join_path(home, '.cargo/bin'))
    
    local path_env = os.getenv("PATH")
    if path_env then
        local sep = (os.getenv("HOME") == nil) and ";" or ":"
        for path in string.gmatch(path_env, "[^" .. sep .. "]+") do
            table.insert(dirs, path)
        end
    end
    
    return dirs
end

function self.find_executable(name)
    local is_windows = os.getenv("HOME") == nil
    local names = { name }
    if is_windows then
        table.insert(names, name .. ".exe")
    end

    local exec_path
    for _, n in ipairs(names) do
        for _, path in pairs(self.alt_dirs()) do
            exec_path = utils.join_path(path, n)
            if self.file_exists(exec_path) then
                return exec_path
            end
        end
    end
    return name
end

function self.is_path(str)
    return not not string.match(str, '[/\\]')
end

return self
