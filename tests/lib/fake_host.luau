--!nonstrict
-- In-memory stand-in for the `noctalia` host API, for tests running under the Luau CLI.
-- It mirrors the method names of `noctalia.*` so modules that receive a host can be
-- driven deterministically: a controllable clock, synchronous shared state, an
-- in-memory filesystem, declared settings, and captured logs/notifications.
--
--   local FakeHost = require("./lib/fake_host.luau")
--   local host = FakeHost.new({ nowMs = 1791529020000, config = { weekly_hours = 35 } })
--   host.clock.advance(60 * 1000)

local FakeHost = {}

function FakeHost.new(options)
  options = options or {}
  local now = options.nowMs or 0
  local config = options.config or {}
  local translations = options.translations or {}
  local dataDir = options.dataDir or "/data"

  local host = {
    logs = {},
    notifications = {},
    files = {},
  }

  -- Clock -------------------------------------------------------------------

  host.clock = {
    set = function(ms)
      now = ms
    end,
    advance = function(ms)
      now += ms
    end,
  }

  function host.nowMs()
    return now
  end

  -- Shared state (delivered synchronously, every set fires, like the host) -----

  local values, watchers = {}, {}
  host.state = {
    set = function(key, value)
      values[key] = value
      for _, fn in watchers[key] or {} do
        fn(value)
      end
    end,
    get = function(key)
      return values[key]
    end,
    watch = function(key, fn)
      watchers[key] = watchers[key] or {}
      table.insert(watchers[key], fn)
    end,
  }

  -- Settings ----------------------------------------------------------------

  function host.getConfig(key)
    return config[key]
  end

  function host.setConfig(key, value)
    config[key] = value
  end

  -- Filesystem (flat map path -> contents; directories are implicit) ----------

  function host.pluginDataDir()
    return dataDir
  end

  function host.readFile(path)
    local contents = host.files[path]
    if contents == nil then
      return nil, "no such file: " .. path
    end
    return contents
  end

  function host.writeFile(path, contents)
    host.files[path] = contents
    return true
  end

  function host.renameFile(from, to)
    if host.files[from] == nil then
      return false, "no such file: " .. from
    end
    host.files[to] = host.files[from]
    host.files[from] = nil
    return true
  end

  function host.removeFile(path)
    if host.files[path] == nil then
      return false, "no such file: " .. path
    end
    host.files[path] = nil
    return true
  end

  function host.fileExists(path)
    if host.files[path] ~= nil then
      return true
    end
    local prefix = path .. "/"
    for existing in host.files do
      if string.sub(existing, 1, #prefix) == prefix then
        return true
      end
    end
    return false
  end

  function host.mkdirAll(_path)
    return true
  end

  function host.listDir(path)
    local prefix = path .. "/"
    local names, seen = {}, {}
    for existing in host.files do
      if string.sub(existing, 1, #prefix) == prefix then
        local name = string.match(string.sub(existing, #prefix + 1), "^[^/]+")
        if name and not seen[name] then
          seen[name] = true
          table.insert(names, name)
        end
      end
    end
    table.sort(names)
    return names
  end

  -- Logs, notifications, translations -------------------------------------------

  function host.log(message)
    table.insert(host.logs, message)
  end

  function host.notify(title, body)
    table.insert(host.notifications, { kind = "info", title = title, body = body })
  end

  function host.notifyError(title, body)
    table.insert(host.notifications, { kind = "error", title = title, body = body })
  end

  function host.tr(key, subst)
    local text = translations[key] or key
    if subst then
      text = string.gsub(text, "{(%w+)}", function(name)
        local value = subst[name]
        return value ~= nil and tostring(value) or "{" .. name .. "}"
      end)
    end
    return text
  end

  return host
end

return FakeHost
