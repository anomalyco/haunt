local h = { ui = {}, field = {}, ascii = _haunt_ascii, attributes = { bold = 1, dim = 2, italic = 4, underline = 8 } }

local enums = {
  flexDirection = { "column", "row", "column-reverse", "row-reverse" },
  justifyContent = { "flex-start", "center", "flex-end", "space-between", "space-around", "space-evenly" },
  alignItems = { "stretch", "flex-start", "center", "flex-end", "baseline" },
  alignSelf = { "auto", "stretch", "flex-start", "center", "flex-end", "baseline" },
  flexWrap = { "no-wrap", "wrap", "wrap-reverse" },
  position = { "relative", "absolute" },
  overflow = { "visible", "hidden" },
  wrapMode = { "none", "word", "char" },
  borderStyle = { "single", "rounded", "double" },
}
local dimensions = {}
for _, key in ipairs({ "width", "height", "minWidth", "minHeight", "maxWidth", "maxHeight",
  "padding", "paddingX", "paddingY", "paddingTop", "paddingRight", "paddingBottom", "paddingLeft",
  "margin", "marginX", "marginY", "marginTop", "marginRight", "marginBottom", "marginLeft",
  "top", "right", "bottom", "left", "gap", "rowGap", "columnGap", "flexBasis" }) do
  dimensions[key] = true
end
local colors = { fg = true, bg = true, backgroundColor = true, borderColor = true }
local handlers = { onMouseDown = true, onMouseUp = true, onMouseMove = true, onKeyDown = true }

local function contains(values, value)
  for _, candidate in ipairs(values) do if candidate == value then return true end end
  return false
end

local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function validate(key, value)
  if enums[key] then
    assert(contains(enums[key], value), "invalid " .. key .. ": " .. tostring(value))
  elseif dimensions[key] then
    local percentage = type(value) == "string" and value:match("^(%d+%.?%d*)%%$")
    assert((finite(value) and math.abs(value) <= 100000) or value == "auto" or
      (percentage and tonumber(percentage) <= 100), "invalid dimension " .. key)
    if key ~= "top" and key ~= "left" and key ~= "right" and key ~= "bottom" then
      assert(type(value) ~= "number" or value >= 0, key .. " must not be negative")
    end
    if key:match("^padding") or key == "gap" or key == "rowGap" or key == "columnGap" then
      assert(value ~= "auto", key .. " does not accept auto")
    end
  elseif colors[key] then
    assert(type(value) == "string" and value:match("^#%x+$") and
      (#value == 4 or #value == 7 or #value == 9), key .. " must be a hex color")
  elseif handlers[key] then
    assert(type(value) == "function", key .. " must be a function")
  elseif key == "flexGrow" or key == "flexShrink" then
    assert(finite(value) and value >= 0 and value <= 100000, "invalid " .. key)
  elseif key == "attributes" then
    assert(math.type(value) == "integer" and value >= 0 and value <= 255, "attributes must be a text-style bitmask")
  elseif key == "border" then
    assert(type(value) == "boolean", "border must be a boolean")
  elseif key == "key" then
    assert(type(value) == "string" or finite(value), "key must be a string or number")
    assert(value ~= "", "key must not be empty")
  elseif key == "content" then
    assert(type(value) == "string" or finite(value), "content must be text")
  else
    error("unsupported UI property: " .. tostring(key))
  end
end

local construct
local function append(children, value, depth)
  if value == nil or value == false then return end
  assert(depth < 64, "UI nesting is too deep")
  if type(value) == "string" or type(value) == "number" then
    children[#children + 1] = construct("text", { content = tostring(value) })
  elseif type(value) == "table" and value.kind then
    children[#children + 1] = value
  elseif type(value) == "table" then
    local max = 0
    for index in pairs(value) do
      assert(math.type(index) == "integer" and index > 0 and index <= 4096, "children must be an ordered array")
      max = math.max(max, index)
    end
    for index = 1, max do append(children, value[index], depth + 1) end
  else
    error("invalid child: " .. type(value))
  end
  assert(#children <= 4096, "too many UI children")
end

construct = function(kind, values)
  if type(values) == "string" then values = { values } end
  assert(type(values) == "table", kind .. " expects a table")
  local props, children, max = {}, {}, 0
  for key, value in pairs(values) do
    if type(key) == "number" then
      assert(math.type(key) == "integer" and key > 0 and key <= 4096, "invalid child index")
      max = math.max(max, key)
    else
      validate(key, value)
      props[key] = value
    end
  end
  if kind == "text" then
    local parts = {}
    if props.content ~= nil then parts[1] = tostring(props.content) end
    for index = 1, max do
      local value = values[index]
      if value ~= nil and value ~= false then
        assert(type(value) == "string" or type(value) == "number", "text children must be strings or numbers")
        parts[#parts + 1] = tostring(value)
      end
    end
    props.content = table.concat(parts)
  else
    assert(props.content == nil, "content belongs on a text node")
    for index = 1, max do append(children, values[index], 0) end
    local keys = {}
    for _, child in ipairs(children) do
      local key = child.props.key
      if key ~= nil then
        key = tostring(key)
        assert(not keys[key], "duplicate sibling key: " .. key)
        keys[key] = true
      end
    end
  end
  return { kind = kind, props = props, children = children }
end

function h.ui.box(values) return construct("box", values) end
function h.ui.text(values) return construct("text", values) end

function h.ui.ascii_font(values)
  assert(type(values) == "table", "ascii_font expects a table")
  assert(values.width == nil and values.height == nil, "ASCII fonts have intrinsic dimensions")
  local rendered = h.ascii.render(values)
  local props = {}
  for key, value in pairs(values) do
    if key ~= "text" and key ~= "font" and key ~= "color" then props[key] = value end
  end
  props.content, props.width, props.height = rendered.content, rendered.width, rendered.height
  props.fg = values.color or values.fg or "#ffffff"
  props.wrapMode, props.flexShrink = "none", 0
  return construct("text", props)
end

function h.validate_scene(root)
  local count, seen = 0, {}
  local function visit(node, depth)
    count = count + 1
    assert(count <= 8192 and depth <= 64, "widget tree is too large")
    assert(type(node) == "table" and (node.kind == "box" or node.kind == "text"), "render must return box/text nodes")
    assert(not seen[node], "UI tree cannot contain cycles")
    seen[node] = true
    assert(type(node.props) == "table" and type(node.children) == "table", "invalid UI node")
    for key, value in pairs(node.props) do validate(key, value) end
    if node.kind == "text" then
      assert(type(node.props.content) == "string" and next(node.children) == nil, "invalid text node")
    end
    local keys, max = {}, 0
    for index in pairs(node.children) do
      assert(math.type(index) == "integer" and index > 0 and index <= 4096, "invalid normalized children")
      max = math.max(max, index)
    end
    for index = 1, max do
      local child = node.children[index]
      visit(child, depth + 1)
      local key = child.props.key
      if key ~= nil then
        key = tostring(key)
        assert(not keys[key], "duplicate sibling key: " .. key)
        keys[key] = true
      end
    end
    seen[node] = nil
  end
  visit(root, 0)
  return root
end
function h.field.string(default, description) return { type = "string", default = default, description = description } end
function h.field.number(default, description) return { type = "number", default = default, description = description } end
function h.field.boolean(default, description) return { type = "boolean", default = default, description = description } end
function h.field.enum(values, default, description)
  return { type = "enum", values = values, default = default, description = description }
end

function h.widget(definition)
  assert(type(definition) == "table" and type(definition.setup) == "function", "widget must supply setup(ctx)")
  assert(definition.title == nil or type(definition.title) == "string", "widget title must be a string")
  return definition
end

function h.validate_options(schema, options)
  assert(type(options) == "table", "widget options must be an object")
  local result = {}
  for key in pairs(options) do assert(schema[key], "unknown widget option: " .. tostring(key)) end
  for key, field in pairs(schema) do
    local value = options[key]
    if value == nil then value = field.default end
    assert(value ~= nil, "missing widget option: " .. key)
    if field.type == "enum" then
      assert(contains(field.values, value), "invalid widget option: " .. key)
    else
      assert(type(value) == field.type, "widget option " .. key .. " must be " .. field.type)
      if field.type == "number" then assert(finite(value), "invalid widget option: " .. key) end
    end
    result[key] = value
  end
  return result
end

return h
