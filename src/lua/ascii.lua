-- Glyph definitions are embedded from the pinned OpenTUI ASCIIFont assets.
-- OpenTUI sources these fonts from https://github.com/dominikwilkowski/cfonts.
return function(definitions)
  local parsed = {}
  local api = {}

  local function characters(value)
    local result = {}
    for _, code in utf8.codes(value) do result[#result + 1] = utf8.char(code) end
    return result
  end

  local function font(name)
    if parsed[name] then return parsed[name] end
    local source = assert(definitions[name], "unknown ASCII font: " .. tostring(name))
    local result = { height = source.lines, spacing = source.letterspace_size, chars = {} }
    for character, lines in pairs(source.chars) do
      local glyph = { lines = {} }
      for index, line in ipairs(lines) do
        -- The initial Lua surface accepts one foreground color for every segment.
        glyph.lines[index] = characters((line:gsub("</?c%d+>", "")))
      end
      glyph.width = #glyph.lines[1]
      result.chars[character] = glyph
    end
    parsed[name] = result
    return result
  end

  local function layout(options)
    assert(type(options) == "table" and type(options.text) == "string", "ASCII font expects text")
    local definition = font(options.font or "tiny")
    local letters = characters(options.text:upper())
    local width, glyphs = 0, {}
    for index, letter in ipairs(letters) do
      local glyph = definition.chars[letter]
      glyphs[index] = { glyph = glyph, x = width + 1 }
      width = width + (glyph and glyph.width or definition.chars[" "].width)
      if glyph and index < #letters then width = width + definition.spacing end
    end
    return definition, glyphs, width
  end

  function api.measure(options)
    local definition, _, width = layout(options)
    return { width = width, height = definition.height }
  end

  function api.render(options)
    local definition, glyphs, width = layout(options)
    local rows = {}
    for row = 1, definition.height do
      local cells = {}
      for column = 1, width do cells[column] = " " end
      for _, positioned in ipairs(glyphs) do
        if positioned.glyph then
          for index, character in ipairs(positioned.glyph.lines[row] or {}) do
            local column = positioned.x + index - 1
            if column <= width and character ~= " " then cells[column] = character end
          end
        end
      end
      rows[row] = table.concat(cells)
    end
    return { content = table.concat(rows, "\n"), width = width, height = definition.height }
  end

  return api
end
