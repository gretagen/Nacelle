-- Pretty much the same thing as the system nacelle, but for your files
-- Install prefix, overridable so a working tree can be tested without a
-- repack (NACELLE_LIB=/home/gretagen/nacelle ./nacelle spin house).
local LIB = os.getenv("NACELLE_LIB")
if not LIB or LIB == "" then LIB = "/usr/lib/nacelle" end

package.path = LIB .. "/house-handlers/house_generators/?.lua;"
  .. LIB .. "/house-handlers/?.lua;" .. package.path

local config = require("config")

local house_sync = {}

-- repower mode: --repower exports NACELLE_REPOWER=1 and every "already
-- satisfied" gate is bypassed, so the house reapplies every edit even when
-- the file on disk already matches the declaration.
house_sync.repower = os.getenv("NACELLE_REPOWER") ~= nil

-- Set by the shell helpers when a command ends because the user pressed
-- Ctrl+C. os.execute runs through system(), which per POSIX ignores
-- SIGINT/SIGQUIT in *this* process while waiting for the child: the child
-- dies (same foreground process group) and this process never sees the
-- signal. The child's signal-death is therefore the only evidence of an
-- interrupt, and it is what lets the apply loop tell "user cancelled" from
-- "command failed". A Ctrl+C landing between commands still reaches us with
-- the default disposition and kills the process outright; that is correct
-- and needs no flag.
house_sync.interrupted = false

-- single gate helper used by every generator equality check
function house_sync.differs(current, desired)
  if house_sync.repower then return true end
  return current ~= desired
end

-- verbose diagnostics: silent unless the CLI passed --verbose (which exports
-- NACELLE_VERBOSE=1). Errors never travel through vprint: generator load
-- failures and planner crashes are written straight to stderr so a normal
-- run still shows them.
local VERBOSE = os.getenv("NACELLE_VERBOSE") ~= nil

-- Colors for the apply loop and every error line: only when stderr is a
-- terminal and NO_COLOR is unset, so a pipe or a log file stays plain.
-- All colored output goes to stderr; the preview on stdout is never
-- colored. With colors off the constants are empty strings, so every
-- format string below reads the same in both modes.
local COLOR = false
if not os.getenv("NO_COLOR") then
  local ok = os.execute("test -t 2")
  COLOR = (ok == true or ok == 0)
end
local GREEN = COLOR and "\27[32m" or "" -- done
local RED   = COLOR and "\27[31m" or "" -- failed / error:
local GREY  = COLOR and "\27[90m" or "" -- applied / skipped: secondary text
local RESET = COLOR and "\27[0m"  or ""

function house_sync.vprint(...)
  if not VERBOSE then return end
  io.stderr:write(string.format(...))
  io.stderr:write("\n")
end

function house_sync.eprint(fmt, ...)
  io.stderr:write(RED .. "error: " .. RESET)
  io.stderr:write(string.format(fmt, ...))
  io.stderr:write("\n")
end

-- file I/O helpers
function house_sync.read_file(path)
  house_sync.vprint("read_file %s", path)
  local f, err = io.open(path, "r")
  if not f then
    house_sync.vprint("  not found")
    return nil
  end
  local c = f:read("*a")
  f:close()
  house_sync.vprint("  %d bytes", #c)
  return c
end

function house_sync.file_exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

function house_sync.ensure_dir(dir)
  local f = io.open(dir, "r")
  if f then f:close(); return true end
  io.stderr:write("creating directory: " .. dir .. "\n")
  return house_sync.shell("mkdir -p '" .. dir .. "'")
end

function house_sync.write_file(path, content)
  house_sync.vprint("write_file %s (%d bytes)", path, #content)
  local dir = path:match("^(.*/)")
  if dir then
    local ok = house_sync.ensure_dir(dir)
    if not ok then return false, "failed to create " .. dir end
  end
  local f, err = io.open(path, "w")
  if not f then return false, err end
  f:write(content)
  f:close()
  return true
end

-- shell helpers
--
-- Every command the house runs goes through one of these, so they share
-- the interrupt check: the child ended by SIGINT/SIGQUIT (signal 2/3) or a
-- shell propagated that death as exit 130/131. Either way the run is
-- cancelled, not failed.
local function child_interrupted(how, code)
  return (how == "signal" and (code == 2 or code == 3)) or
    (how == "exit" and (code == 130 or code == 131))
end

function house_sync.shell(cmd)
  house_sync.vprint("shell: %s", cmd)
  local ok, how, code = os.execute(cmd .. " 2>/dev/null")
  if child_interrupted(how, code) then
    house_sync.vprint("  interrupted (how=%s code=%s)", tostring(how), tostring(code))
    house_sync.interrupted = true
    return false
  end
  -- false, never nil: generators return this straight out of their
  -- apply_fn, and house_sync.apply tells a failure from success by
  -- `result == false`; nil would be read as success.
  return ok or false
end

function house_sync.shell_output(cmd)
  local f = io.popen(cmd .. " 2>/dev/null")
  if not f then return "" end
  local out = f:read("*a")
  f:close()
  return out:gsub("%s+$", "")
end

-- quote one argument for embedding inside /bin/bash -c "..."
function house_sync.shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- run a user command under /bin/bash with output visible
function house_sync.shell_live(cmd)
  house_sync.vprint("bash: %s", cmd)
  local ok, how, code = os.execute("/bin/bash -c " .. house_sync.shell_quote(cmd))
  if child_interrupted(how, code) then
    house_sync.vprint("  interrupted (how=%s code=%s)", tostring(how), tostring(code))
    house_sync.interrupted = true
    return false
  end
  return ok or false
end

-- silent probe under /bin/bash: true only when the command exits 0
function house_sync.shell_ok(cmd)
  local ok, how, code = os.execute("/bin/bash -c " .. house_sync.shell_quote(cmd .. " 2>/dev/null"))
  if child_interrupted(how, code) then
    house_sync.interrupted = true
  end
  return ok == true
end

-- true when the current user can write path (or, for a missing path, its
-- nearest existing ancestor directory, since write_file/mkdir -p build
-- everything from there down). Root is assumed able to write anywhere, so
-- only unprivileged runs pay the probe cost.
function house_sync.writable_path(path)
  if not house_sync.unprivileged then return true end
  if house_sync.file_exists(path) then
    return house_sync.shell_ok("test -w " .. house_sync.shell_quote(path))
  end
  return house_sync.shell_ok(
    "d=" .. house_sync.shell_quote(path) ..
    "; while [ ! -e \"$d\" ]; do d=$(dirname -- \"$d\"); done" ..
    "; [ -d \"$d\" ] && [ -w \"$d\" ] && [ -x \"$d\" ]")
end

-- true when the current user owns path: chmod (script generator) needs
-- ownership even when the file itself is writable.
function house_sync.owns(path)
  if not house_sync.unprivileged then return true end
  return house_sync.shell_ok("test -O " .. house_sync.shell_quote(path))
end

-- change builder
function house_sync.change(type_, generator, target, detail, apply_fn)
  return {
    type = type_ or "~",
    section = generator,
    generator = generator,
    target = target,
    detail = detail,
    apply_fn = apply_fn,
  }
end

-- load house generators
--
-- Which ones run is decided by /etc/nacelle/houses/enabled_house_generators.lua
-- (variable: enabled_house_generators), read by plugins.lua, the same module
-- the system category asks, so house_sync owns no list of its own. loadfile
-- rather than require: package.path here has no $LIB/?.lua, and
-- require("config") above must keep resolving to this directory's house
-- config loader (the collision registry.lua avoids the same way). The CLI
-- block inside plugins.lua does not fire: arg[0] is house_sync.lua, not
-- plugins.lua.
local plugins = assert(loadfile(LIB .. "/plugins.lua"))()
local enabled_generators = plugins.enabled_generators("house")

local generators = {}

house_sync.vprint("loading house generators...")
for _, name in ipairs(enabled_generators) do
  local ok, gen = pcall(require, name)
  if ok and type(gen) == "table" then
    table.insert(generators, gen)
    house_sync.vprint("  generator '%s' loaded", name)
  else
    -- always visible: a silently dropped generator would make the run
    -- report success while planning with a smaller set than the house asks
    house_sync.eprint("house generator '%s' failed to load: %s", name, tostring(gen))
  end
end
house_sync.vprint("%d generators loaded", #generators)

-- collect all changes
function house_sync.collect(cfg)
  local changes = {}
  local seq = 0
  for _, gen in ipairs(generators) do
    local name = gen.name or "?"
    house_sync.vprint("planner '%s' running...", name)
    local ok, plans = pcall(gen.plan, cfg, house_sync)
    if ok and plans then
      house_sync.vprint("  %d changes", #plans)
      for _, c in ipairs(plans) do
        c.seq = seq
        seq = seq + 1
        table.insert(changes, c)
      end
    else
      -- always visible, same reason as a failed load: the plan is incomplete
      house_sync.eprint("house planner '%s' crashed: %s", name, tostring(plans))
    end
  end
  -- stable sort: order by change type, keep declaration order within a type
  table.sort(changes, function(a, b)
    local order = { ["+"] = 1, ["~"] = 2, ["-"] = 3 }
    local oa, ob = order[a.type] or 0, order[b.type] or 0
    if oa ~= ob then return oa < ob end
    return (a.seq or 0) < (b.seq or 0)
  end)
  house_sync.vprint("total changes: %d", #changes)
  return changes
end

-- print summary
function house_sync.summary(changes)
  if #changes == 0 then
    print("House nacelle seems to be already synchronized, no need to change anything.")
    return
  end
  -- No banner: the [sections] below are the content, and the only context
  -- worth stating is which mode the run is in (if any).
  local modes = {}
  if house_sync.repower then
    modes[#modes + 1] = "You are currently repowering the house nacelle, This reapplies every change."
  end
  if house_sync.unprivileged then
    modes[#modes + 1] = "You are synchronizing the house nacelle unprivileged"
  end
  if #modes > 0 then
    print()
    for _, line in ipairs(modes) do
      print(line)
    end
  end
  print()
  print(string.format("  %d changes (+ create  ~ update  - remove)", #changes))
  -- Sections in first-appearance order over the sorted change list:
  -- deterministic (pairs() over a hash is not) and it matches the order
  -- apply walks the same list.
  local order, groups = {}, {}
  for _, c in ipairs(changes) do
    local s = c.section or "misc"
    if not groups[s] then
      groups[s] = {}
      order[#order + 1] = s
    end
    groups[s][#groups[s] + 1] = c
  end
  print()
  for _, s in ipairs(order) do
    local entries = groups[s]
    print(string.format("  [%s] %d", s, #entries))
    for _, c in ipairs(entries) do
      local sym = c.type == "+" and "+" or c.type == "-" and "-" or "~"
      local line = "     " .. sym .. " " .. c.target
      if c.requires_root then
        line = line .. "  (needs superuser, will be skipped)"
      end
      print(line)
      if c.detail then
        print("       " .. c.detail)
      end
    end
    print()
  end
end

-- apply all changes
--
-- Returns true, failures, skipped, interrupted. An interrupt (Ctrl+C
-- during a command) stops the loop right there: the current command is
-- already dead and the remaining changes must not run.
--
-- One line per change, printed after it resolves: "  ~ section target
-- status", status word colored (done green, failed red, skipped grey).
-- The closing tally always runs, so a clean run says "no failures"
-- instead of the old silence that only ever reported failures.
function house_sync.apply(changes)
  local failures = 0
  local applied = 0
  local skipped = 0
  -- dynamic columns: the section column is as wide as the widest section
  -- name in this run, the target is padded to 50; a longer target just
  -- pushes its status right, nothing is ever truncated
  local swidth = 0
  for _, c in ipairs(changes) do
    local n = #(c.section or "?")
    if n > swidth then swidth = n end
  end
  local fmt = "  %s %-" .. swidth .. "s %-50s %s\n"
  for i, c in ipairs(changes) do
    local sym = c.type == "+" and "+" or c.type == "-" and "-" or "~"
    local status
    local extra
    if c.requires_root then
      status = GREY .. "skipped (requires superuser)" .. RESET
      skipped = skipped + 1
    else
      if c.apply_fn then
        local ok, result = pcall(c.apply_fn, c, house_sync)
        if not ok then
          -- first line of the Lua error inline, the rest verbatim below so
          -- a multi-line traceback is not thrown away
          local msg = tostring(result)
          local first = msg:match("^[^\n]*") or msg
          extra = msg:match("\n(.*)")
          status = RED .. "failed" .. RESET .. ": " .. first
          failures = failures + 1
        elseif result == false then
          -- an interrupt shows up as a failed command too (the shell
          -- helpers return false): the loop breaks on the flag, so no
          -- further change is attempted and this failure is just the
          -- interrupted one
          status = RED .. "failed" .. RESET
          failures = failures + 1
        else
          status = GREEN .. "done" .. RESET
          applied = applied + 1
        end
      else
        status = GREEN .. "done" .. RESET
        applied = applied + 1
      end
    end
    io.stderr:write(string.format(fmt, sym, c.section or "?", c.target, status))
    if extra and extra ~= "" then
      if extra:sub(-1) ~= "\n" then extra = extra .. "\n" end
      io.stderr:write(extra)
    end
    if house_sync.interrupted then
      io.stderr:write(string.format(
        "house synchronization aborted: %d of %d change(s) %sapplied%s, %d remaining\n",
        i - 1, #changes, GREY, RESET, #changes - i + 1))
      return true, failures, skipped, true
    end
  end
  local tally
  if failures > 0 then
    tally = string.format("  %d changes %sapplied%s, %s%d failed%s",
      applied, GREY, RESET, RED, failures, RESET)
  else
    tally = string.format("  %d changes %sapplied%s, %sno failures%s",
      applied, GREY, RESET, GREY, RESET)
  end
  if skipped > 0 then
    tally = tally .. string.format(", %s%d skipped (requires superuser)%s", GREY, skipped, RESET)
  end
  io.stderr:write(tally .. ".\n")
  return true, failures, skipped, false
end

-- CLI entry point
if arg and arg[0] and arg[0]:match("house_sync%.lua$") then
  local uid = tonumber((house_sync.shell_output("id -u")))
  house_sync.unprivileged = (uid ~= 0)
  if house_sync.unprivileged then
    io.stderr:write("You are running nacelle without privileges: changes to system paths will be skipped, and no generation will be created.\n")
  end

  local cfg_path = arg[1] or "/etc/nacelle/houses/house.lua"
  house_sync.vprint("loading house config from %s", cfg_path)
  local cfg, err = config.load(cfg_path)
  if not cfg then
    io.stderr:write(RED .. "error: " .. RESET .. err .. "\n")
    os.exit(1)
  end

  local changes = house_sync.collect(cfg)
  house_sync.summary(changes)

  if #changes == 0 then os.exit(0) end

  -- unprivileged run where nothing can actually be applied: say so and stop
  -- before asking a pointless y/N question.
  if house_sync.unprivileged then
    local applicable = 0
    for _, c in ipairs(changes) do
      if not c.requires_root then applicable = applicable + 1 end
    end
    if applicable == 0 then
      print(#changes .. " requires su, so re-run with superuser privileges.")
      os.exit(0)
    end
  end

  io.write("Synchronize the house nacelle? [y/N]: ")
  io.flush()
  local answer = io.read()
  local ok = answer and (answer:lower() == "y" or answer:lower() == "yes")
  if not ok then
    print("Cancelled.")
    os.exit(0)
  end

  print("Synchronizing...")
  local _, failures, skipped, interrupted = house_sync.apply(changes)
  if interrupted then
    -- Ctrl+C during a command: the counts are on the aborted line above.
    -- Exit 130 (128 + SIGINT) so the shell sees a conventional interrupt
    -- status, and create no generation: the run is partial.
    print("House synchronization aborted.")
    io.stderr:write("Run the nacelle again to apply the remaining changes.\n")
    os.exit(130)
  elseif failures and failures > 0 then
    print("House synchronization finished with " .. failures .. " failure(s).")
    io.stderr:write("Due to those, the nacelle did not create a generation.")
    io.stderr:write("I recommend you to fix them as soon as possible, just so you can have something recent to rollback to.")
  elseif house_sync.unprivileged then
    print("House nacelle synchronization process completed.")
    if skipped and skipped > 0 then
      print(skipped .. " change(s) were skipped.")
      print("Re-run the nacelle synchronization process with privileges if you want those applied.")
    end
  else
    -- NACELLE_NO_GENERATION comes from the CLI's --no-generation: apply
    -- everything, but leave the boot entries alone.
    if os.getenv("NACELLE_NO_GENERATION") then
      print("Skipping generation creation, this is probably a bad idea.")
      print("Are you sure you know what you're doing?")
    else
      print(house_sync.repower and "Creating post-repower house generation..."
        or "Creating post-sync house generation...")
      local label = house_sync.repower and "post-repower of house nacelle" or "post-synchronization of house nacelle"
      if not house_sync.shell("chronos create '" .. label .. "'") then
        io.stderr:write("The nacelle synchronized the house, but couldn't create a generation.\n")
        io.stderr:write("You can add one by hand if you want?\n")
      end
    end
    print("Synchronization of house nacelle complete.")
  end
end

return house_sync
