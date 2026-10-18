--!nonstrict
-- In-memory stand-in for the `noctalia` host API, for tests running under the Luau CLI.
-- It mirrors the method names of `noctalia.*` so modules that receive a host can be
-- driven deterministically: a controllable clock, synchronous shared state, an
-- in-memory filesystem, declared settings, JSON, and captured logs/notifications.
--
--   local FakeHost = require("./lib/fake_host.luau")
--   local host = FakeHost.new({ nowMs = 1791529020000, config = { weekly_hours = 35 } })
--   host.clock.advance(60 * 1000)

local Json = require("./json.luau")
local Types = require("../../shift/lib/types.luau")

local FakeHost = {}

function FakeHost.new(options)
  options = options or {}
  local now = options.nowMs or 0
  local config = options.config or {}
  local translations = options.translations or {}
  local dataDir = options.dataDir or "/data"
  local timeFormat = options.timeFormat or "{:%H:%M}"
  local palette = options.palette or {}
  local commands = options.commands or {}
  local env = options.env or {}

  local host = {
    logs = {},
    notifications = {},
    files = {},
  }

  host.json = Json
  host.updateIntervalMs = nil
  host.toggledPanels = {}

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

  -- Local time comes from the process timezone (the test runner pins TZ).
  function host.formatTime(pattern, unixSeconds)
    local strftime = string.match(pattern, "^{:(.*)}$") or pattern
    return os.date(strftime, unixSeconds or now // 1000)
  end

  function host.timeFormat()
    return timeFormat
  end

  function host.dateFormat()
    return "%A, %x"
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

  -- Entry runtime ---------------------------------------------------------------

  function host.setUpdateInterval(ms)
    host.updateIntervalMs = ms
  end

  function host.togglePanel(panelId)
    table.insert(host.toggledPanels, panelId)
  end

  host.settingsOpened = 0
  function host.openSettings()
    host.settingsOpened += 1
  end

  -- Palette roles resolve to `options.palette[role]`, or a stable fake color.
  function host.getColor(role)
    return palette[role] or "#" .. string.format("%06x", #role * 0x10101)
  end

  -- Processes: streams and commands are recorded; tests feed lines and results --

  -- Each started stream: { cmd, onLine }. `host.streamLine(i, line)` delivers a line.
  host.streams = {}
  -- Each runAsync call: { argv, onResult, timeoutMs }. `host.finish(i, result)` answers it.
  host.commands = {}

  function host.runStream(cmd, onLine)
    table.insert(host.streams, { cmd = cmd, onLine = onLine })
    return options.streamsFail ~= true
  end

  function host.streamLine(index, line)
    host.streams[index].onLine(line)
  end

  function host.runAsync(argv, onResult, timeoutMs)
    table.insert(host.commands, { argv = argv, onResult = onResult, timeoutMs = timeoutMs })
    return true
  end

  function host.finish(index, result)
    local entry = host.commands[index]
    entry.onResult({
      exitCode = result.exitCode or 0,
      stdout = result.stdout or "",
      stderr = result.stderr or "",
      timedOut = false,
    })
  end

  -- Each http call: { url, onResponse }. `host.respond(i, response)` answers it.
  host.requests = {}

  function host.http(req, onResponse)
    table.insert(host.requests, { url = req.url, onResponse = onResponse })
    return true
  end

  function host.respond(index, response)
    host.requests[index].onResponse({ ok = response.ok ~= false, status = response.status or 200, body = response.body or "" })
  end

  function host.commandExists(name)
    return commands[name] == true
  end

  function host.getenv(name)
    return env[name]
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

  -- Plurals: `<key>.one` or `<key>.other`, with `{count}`.
  function host.trp(key, count, subst)
    local values = table.clone(subst or {})
    values.count = count
    return host.tr(key .. (count == 1 and ".one" or ".other"), values)
  end

  -- Compile-time check (make analyze) that the fake keeps up with the real adapter.
  local _: Types.Host = host
  return host
end

return FakeHost
