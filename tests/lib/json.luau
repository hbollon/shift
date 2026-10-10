--!nonstrict
-- Minimal JSON codec for tests, standing in for `noctalia.json` under the Luau CLI.
-- It matches the host on what the plugin relies on: integers are written without a
-- fraction, an empty table encodes as `{}`, `null` decodes to nil, and decode returns
-- (nil, err) on malformed input. Object keys are sorted so encoded output is stable.

local Json = {}

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function isArray(value)
  local count = 0
  for key in value do
    if type(key) ~= "number" then
      return false
    end
    count += 1
  end
  return count > 0 and count == #value
end

local function encodeValue(value, pretty, indent, out)
  local kind = type(value)
  if value == nil then
    table.insert(out, "null")
  elseif kind == "boolean" then
    table.insert(out, tostring(value))
  elseif kind == "number" then
    if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
      table.insert(out, string.format("%d", value))
    else
      table.insert(out, string.format("%.17g", value))
    end
  elseif kind == "string" then
    local escaped = string.gsub(value, '[%c"\\]', function(char)
      return ESCAPES[char] or string.format("\\u%04x", string.byte(char))
    end)
    table.insert(out, '"' .. escaped .. '"')
  elseif kind == "table" then
    local inner = pretty and indent .. "  " or ""
    local newline = pretty and "\n" or ""
    if isArray(value) then
      table.insert(out, "[" .. newline)
      for i, item in ipairs(value) do
        table.insert(out, inner)
        encodeValue(item, pretty, inner, out)
        table.insert(out, (i < #value and "," or "") .. newline)
      end
      table.insert(out, (pretty and indent or "") .. "]")
    else
      local keys = {}
      for key in value do
        table.insert(keys, tostring(key))
      end
      table.sort(keys)
      if #keys == 0 then
        table.insert(out, "{}")
        return
      end
      table.insert(out, "{" .. newline)
      for i, key in ipairs(keys) do
        table.insert(out, inner)
        encodeValue(key, false, "", out)
        table.insert(out, pretty and ": " or ":")
        encodeValue(value[key] == nil and value[tonumber(key)] or value[key], pretty, inner, out)
        table.insert(out, (i < #keys and "," or "") .. newline)
      end
      table.insert(out, (pretty and indent or "") .. "}")
    end
  else
    error("cannot encode a " .. kind)
  end
end

function Json.encode(value, pretty)
  local out = {}
  local ok, err = pcall(encodeValue, value, pretty, "", out)
  if not ok then
    return nil, tostring(err)
  end
  return table.concat(out)
end

-- Decoding -------------------------------------------------------------------

local UNESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function decoder(text)
  local pos = 1

  local function fail(message)
    error(string.format("parse error at %d: %s", pos, message), 0)
  end

  local function skip()
    pos = string.find(text, "[^ \t\r\n]", pos) or #text + 1
  end

  local parseValue

  local function parseString()
    pos += 1
    local parts = {}
    while true do
      local char = string.sub(text, pos, pos)
      if char == "" then
        fail("unterminated string")
      elseif char == '"' then
        pos += 1
        return table.concat(parts)
      elseif char == "\\" then
        local esc = string.sub(text, pos + 1, pos + 1)
        if esc == "u" then
          local hex = string.sub(text, pos + 2, pos + 5)
          table.insert(parts, utf8.char(tonumber(hex, 16) or fail("bad \\u escape")))
          pos += 6
        else
          table.insert(parts, UNESCAPES[esc] or fail("bad escape"))
          pos += 2
        end
      else
        table.insert(parts, char)
        pos += 1
      end
    end
  end

  local function parseNumber()
    local literal = string.match(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    local number = literal and tonumber(literal)
    if number == nil then
      fail("invalid literal")
    end
    pos += #literal
    return number
  end

  local function parseContainer(close, readEntry)
    pos += 1
    local result = {}
    skip()
    if string.sub(text, pos, pos) == close then
      pos += 1
      return result
    end
    while true do
      readEntry(result)
      skip()
      local char = string.sub(text, pos, pos)
      pos += 1
      if char == close then
        return result
      elseif char ~= "," then
        fail("expected ',' or '" .. close .. "'")
      end
      skip()
    end
  end

  function parseValue()
    skip()
    local char = string.sub(text, pos, pos)
    if char == "{" then
      return parseContainer("}", function(result)
        if string.sub(text, pos, pos) ~= '"' then
          fail("expected string key")
        end
        local key = parseString()
        skip()
        if string.sub(text, pos, pos) ~= ":" then
          fail("expected ':'")
        end
        pos += 1
        result[key] = parseValue()
      end)
    elseif char == "[" then
      return parseContainer("]", function(result)
        table.insert(result, (parseValue()))
      end)
    elseif char == '"' then
      return parseString()
    end
    for literal, value in { ["true"] = true, ["false"] = false, null = "null" } do
      if string.sub(text, pos, pos + #literal - 1) == literal then
        pos += #literal
        if value == "null" then
          return nil
        end
        return value
      end
    end
    return parseNumber()
  end

  return function()
    local value = parseValue()
    skip()
    if pos <= #text then
      fail("trailing characters")
    end
    return value
  end
end

function Json.decode(text)
  local ok, result = pcall(decoder(text))
  if not ok then
    return nil, tostring(result)
  end
  return result
end

return Json
