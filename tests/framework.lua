package.path = "src/lua/?.lua;" .. package.path
local h = require("haunt")
local runtime = require("runtime")
local now = 0
local rt = runtime.new(function() return now end)

local source = [[
local h = require('haunt')
return h.widget {
  options = { label = h.field.string('default') },
  setup = function(ctx)
    local state = ctx:retain('counter', { ticks = 0 })
    ctx:every(1000, function() state.ticks = state.ticks + 1; ctx:update() end)
    ctx:on_cleanup(function() _G.cleaned = true end)
    return function() return h.ui.text { ctx.options.label .. ':' .. state.ticks } end
  end,
}
]]
assert(rt.load_source('a', 'a.lua', source, { label = 'A' }, 20, 5))
assert(rt.load_source('b', 'b.lua', source, { label = 'B' }, 20, 5))
assert(rt.frame('a', 20, 5).props.content == 'A:0')
assert(rt.frame('b', 20, 5).props.content == 'B:0')
assert(rt.poll())
assert(not rt.poll(), 'idle widgets should not request rendering')
now = 1000
assert(rt.poll())
assert(rt.frame('a', 20, 5).props.content == 'A:1')
local old = rt.inspect('a')
assert(rt.load_source('a', 'a.lua', source, { label = 'new' }, 20, 5))
assert(not old.alive and #old.timers == 0, 'old resource scope must be disposed')
assert(rt.frame('a', 20, 5).props.content == 'new:1', 'retained data survives reload')

local working = rt.inspect('a')
local bad = source:gsub("return h.ui.text", "error('broken render'); return h.ui.text")
assert(not rt.load_source('a', 'a.lua', bad, {}, 20, 5))
assert(rt.inspect('a') == working and working.alive, 'broken candidates must not replace the running widget')
assert(not rt.load_source('a', 'a.lua', source, { unexpected = true }, 20, 5))
now = 2000
rt.poll()
assert(rt.frame('a', 20, 5).props.content == 'new:2', 'only the active timer should fire')
assert(rt.frame('b', 20, 5).props.content == 'B:2', 'instances must be independent')

local nodes = h.ui.box { h.ui.text {'first'}, false, { h.ui.text {'second'} }, [6] = h.ui.text {'third'} }
assert(#nodes.children == 3 and nodes.children[3].props.content == 'third')
local shared = h.ui.text { 'reusable' }
assert(h.validate_scene(h.ui.box { shared, shared }))
assert(not pcall(h.ui.box, { alignItems = 'typo' }))
assert(not pcall(h.ui.box, { backgroundColour = '#fff' }))
assert(not pcall(h.ui.box, { h.ui.text {key='x','a'}, h.ui.text {key='x','b'} }))
assert(not pcall(h.ui.text, { width = -1 }))
assert(not pcall(h.ui.text, { attributes = 256 }))
assert(not pcall(h.ui.box, { padding = 'auto' }))

-- No implicit state observation: changing a closure variable alone keeps the cached frame.
assert(rt.load_source('explicit', 'explicit.lua', [[
  local h = require('haunt')
  print('module initialization is captured')
  return h.widget { setup = function(ctx)
    local n = 0
    ctx:every(1, function() n = n + 1 end)
    return function() return h.ui.text { n } end
  end }
]], {}, 20, 5))
rt.poll()
now = now + 1
assert(not rt.poll())
assert(rt.frame('explicit', 20, 5).props.content == '0')
rt.inspect('explicit').ctx:update()
assert(rt.poll())
assert(rt.frame('explicit', 20, 5).props.content == '1')
assert(rt.inspect('explicit').log == 'module initialization is captured')

local before = working.retained.counter.ticks
assert(not rt.load_source('a', 'bad.lua', [[
  local h = require('haunt')
  return h.widget { setup = function(ctx)
    ctx:retain('counter', {}).ticks = 999
    return function() return {kind='box',props={padding=-1},children={}} end
  end }
]], {}, 20, 5))
assert(working.retained.counter.ticks == before, 'candidate state must be transactional')
local stale_called = false
rt.dispatch('a', function() stale_called = true end, {}, working.version - 1)
assert(not stale_called, 'native handlers from an old scene must not run after reload')
rt.dispatch('a', function() stale_called = true end, {}, working.version)
assert(stale_called)

local measured = h.ascii.measure {text='12', font='tiny'}
assert(measured.width == 5 and measured.height == 2)
local lettering = h.ui.ascii_font {text='12', font='tiny', color='#c4a7e7'}
assert(lettering.props.content == '▄█ ▀█\n █ █▄', 'glyphs must match the embedded OpenTUI tiny font')
assert(lettering.props.width == 5 and lettering.props.height == 2 and lettering.props.fg == '#c4a7e7')
assert(h.validate_scene(lettering))
assert(h.ascii.measure {text='12:34', font='block'}.height == 6)
assert(not pcall(h.ui.ascii_font, {text='12', font='missing'}))

-- The actual clock defaults to a time-only twelve-hour display using ASCII digits.
local clock_file = assert(io.open('widgets/clock.lua', 'rb'))
local clock_source = clock_file:read('a')
clock_file:close()
local real_date = os.date
os.date = function(format)
  assert(format == '%I:%M %p', 'the default clock should not request a date or 24-hour time')
  return '04:07 PM'
end
local clock_ok, clock_error = rt.load_source('clock', 'widgets/clock.lua', clock_source, {font='tiny'}, 30, 4)
os.date = real_date
assert(clock_ok, clock_error)
local clock_scene = rt.frame('clock', 30, 4)
assert(#clock_scene.children == 1, 'clock should have only its time row')
local clock_row = clock_scene.children[1]
assert(clock_row.children[1].props.content == h.ascii.render {text='4:07', font='tiny'}.content)
assert(clock_row.children[2].props.content == 'PM')

rt.remove('b')
assert(rt.load_source('b', 'b.lua', source, {label='B'}, 20, 5))
now = now + 1000
rt.poll()
assert(rt.frame('b', 20, 5).props.content == 'B:1', 're-adding an ID must not duplicate timer dispatch')
rt.close()
assert(not working.alive and #working.timers == 0)
-- Keep stdout clear: this suite also runs inside Zig's IPC-based test runner.
