-- what makes nacelle sync possible
-- for tests, there's an install prefix, overridable so a working tree can be tested without a
-- repack (NACELLE_LIB=/home/gretagen/nacelle ./nacelle spin system). 

local LIB = os.getenv("NACELLE_LIB")
if not LIB or LIB == "" then LIB = "/usr/lib/nacelle" end

package.path = LIB .. "/?.lua;" .. LIB .. "/generators/?.lua;" .. package.path

-- Which generators run is decided by /etc/nacelle/enabled_system_generators.lua
-- (the system category's enable list; see plugins.lua, which owns it: the
-- house category has its own file). sync.lua does not own a list of its own.
local enabled_generators = require("plugins").enabled_generators("system")

local config = require("config")

local sync = {}

-- repower mode: --repower exports NACELLE_REPOWER=1 and every "already
-- satisfied" gate is bypassed, so the run reapplies and rebuilds everything
-- even on a converged system (nixos-rebuild switch style). Detection reads
-- stay untouched: generators still parse what is on disk, they just never
-- short-circuit to "no change".
sync.repower = os.getenv("NACELLE_REPOWER") ~= nil

-- Set by sync.shell when a command ends because the user pressed Ctrl+C.
-- os.execute runs through system(), which per POSIX ignores SIGINT/SIGQUIT
-- in *this* process while waiting for the child: the child dies (it is in
-- the same foreground process group) and the nacelle process never sees the
-- signal. The child's signal-death is therefore the only evidence of an
-- interrupt, and it is what lets the apply loop tell "user cancelled" from
-- "command failed". A Ctrl+C landing between commands still reaches us with
-- the default disposition and kills the process outright; that is correct
-- and needs no flag.
sync.interrupted = false

-- single gate helper used by every generator equality check
function sync.differs(current, desired)
  if sync.repower then return true end
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

function sync.vprint(...)
  if not VERBOSE then return end
  io.stderr:write(string.format(...))
  io.stderr:write("\n")
end

function sync.eprint(fmt, ...)
  io.stderr:write(RED .. "error: " .. RESET)
  io.stderr:write(string.format(fmt, ...))
  io.stderr:write("\n")
end

-- file I/O helpers
function sync.read_file(path)
  sync.vprint("read_file %s", path)
  local f, err = io.open(path, "r")
  if not f then
    sync.vprint("  not found")
    return nil
  end
  local c = f:read("*a")
  f:close()
  sync.vprint("  %d bytes", #c)
  return c
end

function sync.ensure_dir(dir)
  local f = io.open(dir, "r")
  if f then f:close(); return true end
  io.stderr:write("creating directory: " .. dir .. "\n")
  return sync.shell("mkdir -p '" .. dir .. "'")
end

function sync.write_file(path, content)
  sync.vprint("write_file %s (%d bytes)", path, #content)
  local dir = path:match("^(.*/)")
  if dir then
    local ok = sync.ensure_dir(dir)
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
-- Every command the sync runs goes through here, so this is where an
-- interrupted command is recognised: the child ended by SIGINT/SIGQUIT
-- (signal 2/3) or a shell propagated that death as exit 130/131. Either
-- way the run is cancelled, not failed.
function sync.shell(cmd)
  sync.vprint("shell: %s", cmd)
  local ok, how, code = os.execute(cmd)
  if (how == "signal" and (code == 2 or code == 3)) or
     (how == "exit" and (code == 130 or code == 131)) then
    sync.vprint("  interrupted (how=%s code=%s)", tostring(how), tostring(code))
    sync.interrupted = true
    return false
  end
  sync.vprint("  %s", tostring(ok))
  return ok or false
end

function sync.shell_output(cmd)
  sync.vprint("shell_output: %s", cmd)
  local f = io.popen(cmd .. " 2>/dev/null", "r")
  if not f then
    sync.vprint("  (popen failed)")
    return ""
  end
  local out = f:read("*a")
  f:close()
  local result = (out or ""):gsub("%s+$", "")
  sync.vprint("  [%s]", result)
  return result
end

-- diff entry constructor
function sync.change(typ, section, target, detail, apply)
  return { type = typ, section = section, target = target, detail = detail, apply_fn = apply }
end

-- load generators
--
-- Order matters within a change type: subspaces must come before
-- subspaces_packages and merged_packages, because those two install into or
-- merge from a subspace that has to exist first. The sort in sync.collect is
-- stable (it breaks ties on collection order), so this list is respected.
local generators = {}


sync.vprint("loading generators...")
for _, name in ipairs(enabled_generators) do
  local ok, gen = pcall(require, name)
  if ok and type(gen) == "table" then
    table.insert(generators, gen)
    sync.vprint("  generator '%s' loaded", name)
  else
    -- always visible: a silently dropped generator would make the sync
    -- report success while planning with a smaller set than the config asks
    sync.eprint("generator '%s' failed to load: %s", name, tostring(gen))
  end
end
sync.vprint("%d generators loaded", #generators)

-- collect all changes
function sync.collect(cfg)
  local changes = {}
  local seq = 0
  for _, gen in ipairs(generators) do
    local name = gen.name or "?"
    sync.vprint("planner '%s' running...", name)
    local ok, plans = pcall(gen.plan, cfg, sync)
    if ok and plans then
      sync.vprint("  %d changes", #plans)
      for _, c in ipairs(plans) do
        seq = seq + 1
        c.seq = seq
        table.insert(changes, c)
      end
    else
      -- always visible, same reason as a failed load: the plan is incomplete
      sync.eprint("planner '%s' crashed: %s", name, tostring(plans))
    end
  end
  -- Group by type (+ before ~ before -) so a package swap installs the
  -- replacement before removing the original. Ties break on collection order:
  -- table.sort is not stable, so without an explicit tiebreaker the order
  -- within a group would be arbitrary and a subspace could be used before the
  -- change that creates it is applied.
  table.sort(changes, function(a, b)
    local order = { ["+"] = 1, ["~"] = 2, ["-"] = 3 }
    local oa, ob = order[a.type] or 0, order[b.type] or 0
    if oa ~= ob then
      return oa < ob
    end
    return a.seq < b.seq
  end)
  sync.vprint("total changes: %d", #changes)
  return changes
end

-- print summary
function sync.summary(changes)
  if #changes == 0 then
    print("System nacelle seems to be already synchronized, no need to change anything.")
    return
  end
  -- No banner: the [sections] below are the content, and the only context
  -- worth stating is which mode the run is in (if any).
  local modes = {}
  if sync.repower then
    modes[#modes + 1] = "You are currently repowering the system nacelle, This reapplies and rebuilds everything."
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
      print("     " .. sym .. " " .. c.target)
      if c.detail then
        print("       " .. c.detail)
      end
    end
    print()
  end
end

-- apply all changes
--
-- Returns true, failures, interrupted. An interrupt (Ctrl+C during a
-- command) stops the loop right there: the current command is already
-- dead, the remaining changes must not run, and the caller must skip the
-- generation creation: a partial run must not be recorded as a
-- generation.
--
-- One line per change, printed after it resolves: "  ~ section target
-- status", status word colored (done green, failed red). The closing
-- tally always runs, so a clean run says "no failures" instead of the old
-- silence that only ever reported failures.
function sync.apply(changes)
  local failures = 0
  local applied = 0
  local merged_applied = false
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
    if c.apply_fn then
      local ok, result = pcall(c.apply_fn, c, sync)
      if not ok then
        -- first line of the Lua error inline, the rest verbatim below so
        -- a multi-line traceback is not thrown away
        local msg = tostring(result)
        local first = msg:match("^[^\n]*") or msg
        extra = msg:match("\n(.*)")
        status = RED .. "failed" .. RESET .. ": " .. first
        failures = failures + 1
      elseif result == false then
        -- an interrupt shows up as a failed command too (sync.shell returns
        -- false): the loop below breaks on the flag, so no further change
        -- is attempted and this failure is just the interrupted one
        status = RED .. "failed" .. RESET
        failures = failures + 1
      else
        status = GREEN .. "done" .. RESET
        applied = applied + 1
        if (c.section or ""):match("^merged%-packages") then
          merged_applied = true
        end
      end
    else
      status = GREEN .. "done" .. RESET
      applied = applied + 1
    end
    io.stderr:write(string.format(fmt, sym, c.section or "?", c.target, status))
    if extra and extra ~= "" then
      if extra:sub(-1) ~= "\n" then extra = extra .. "\n" end
      io.stderr:write(extra)
    end
    if sync.interrupted then
      io.stderr:write(string.format(
        "synchronization aborted: %d of %d change(s) %sapplied%s, %d remaining\n",
        i - 1, #changes, GREY, RESET, #changes - i + 1))
      return true, failures, true
    end
  end
  -- Post-merge hooks (desktop/icon/font caches, ldconfig, wayland pruning)
  -- live on the merged_packages generator: run them once, after every merge
  -- change landed, so a rebuild leaves the host caches consistent.
  if merged_applied then
    for _, gen in ipairs(generators) do
      if type(gen.post_merge) == "function" then
        local ok, err = pcall(gen.post_merge, sync)
        if not ok then
          io.stderr:write(RED .. "error: " .. RESET .. "post_merge: " .. tostring(err) .. "\n")
        end
        -- a hook that ends on Ctrl+C stops the remaining hooks: the caches
        -- are refreshed by the next run
        if sync.interrupted then return true, failures, true end
      end
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
  io.stderr:write(tally .. ".\n")
  return true, failures, false
end

-- CLI entry point
if arg and arg[0] and arg[0]:match("sync%.lua$") then
  local uid = tonumber((sync.shell_output("id -u")))
  if uid ~= 0 then
    io.stderr:write("The nacelle can't synchronize without superuser privileges.\n")
    os.exit(1)
  end

  local cfg_path = arg[1] or "/etc/nacelle/definition.lua"
  sync.vprint("loading config from %s", cfg_path)
  local cfg, err = config.load(cfg_path)
  if not cfg then
    io.stderr:write(RED .. "error: " .. RESET .. err .. "\n")
    os.exit(1)
  end
  sync.vprint("config loaded: hostname=%s, timezone=%s, packages=%d/%d, services=%d/%d/%d",
    cfg.hostname, cfg.timezone,
    #(cfg["packages-haliade"] or {}), #(cfg["packages-isolated"] or {}),
    #(cfg["rc-services"] or {}), #(cfg["runit-services"] or {}), #(cfg["dinit-services"] or {}))

  local changes = sync.collect(cfg)
  sync.summary(changes)

  if #changes == 0 then os.exit(0) end

  io.write("Synchronize the system nacelle? [y/N]: ")
  io.flush()
  local answer = io.read()
  local ok = answer and (answer:lower() == "y" or answer:lower() == "yes")
  if not ok then
    print("Cancelled.")
    os.exit(0)
  end

  print("Synchronizing the system nacelle...")
  local _, failures, interrupted = sync.apply(changes)
  if interrupted then
    -- Ctrl+C during a command: the counts are on the aborted line above.
    -- Exit 130 (128 + SIGINT) so the shell sees a conventional
    -- interrupt status, and create no generation: the run is partial.
    print("Synchronization aborted.")
    io.stderr:write("Run the nacelle again to apply the remaining changes.\n")
    os.exit(130)
  elseif failures and failures > 0 then
    print("Synchronization finished with " .. failures .. " failure(s).")
    io.stderr:write("Due to those, the nacelle did not create a generation.")
    io.stderr:write("I recommend you to fix them as soon as possible, just so you can have something recent to rollback to.")
  else
    -- NACELLE_NO_GENERATION comes from the CLI's --no-generation: apply
    -- everything, but leave the boot entries alone.
    if os.getenv("NACELLE_NO_GENERATION") then
      print("Skipping generation creation, this is probably a bad idea.")
      print("Are you sure you know what you're doing?")
    else
      print("Creating post-sync generation...")
      local label = sync.repower and "post-repowering of system nacelle" or "post-synchronization of system nacelle"
      if not sync.shell("chronos create '" .. label .. "'") then
        io.stderr:write("The nacelle synchronized the system, but couldn't create a generation.\n")
        io.stderr:write("You can create one by hand if you want?\n")
      end
    end
    print("Synchronization of system nacelle complete.")
  end
end



return sync
