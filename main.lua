--- @since 10.01.2026
local M = {}

-- If Yazi asks for a skip larger than this, jump straight to the last page.
local SKIP_JUMP_THRESHOLD = 999
local PEEK_JUMP_THRESHOLD = 99999999
-- Maximum time allowed for preview (in ms)
local TIME_OUT_PREVIEW = 3000

----------------------------------------------------------------------
-- Utils
----------------------------------------------------------------------

----------------------------------------------------------------------
-- Lazy OS-specific query builder (cached within the SAME Lua state)
-- NOTE: This may be recomputed if Yazi reloads Lua between calls,
-- but that's fine because it's cheap and doesn't affect correctness.
----------------------------------------------------------------------

local function get_queries()
  if M._queries ~= nil then
    return M._queries, M._queries_err
  end

  local function build_queries()
    local os = ya.target_os()

    if os == "linux" then
      return {
        -- GNU sed: insert $L as new first line (no backup)
        sed_prepend = function(file_q)
          -- $L is a shell variable
          return 'sed -i "1i$L" ' .. file_q
        end,
      }
    elseif os == "macos" then
      return {
        -- GNU sed: insert $L as new first line (no backup)
        sed_prepend = function(file_q)
				  -- $L is a shell variable
          return 'gsed -i "1i$L" -- ' .. file_q
        end,
      }
    else
      return nil, "unsupported-os: " .. tostring(os)
    end
  end

  local q, err = build_queries()
  M._queries = q
  M._queries_err = err
  return M._queries, M._queries_err
end

local function is_true(v)
  if v == nil then return true end  -- default true
  if v == true then return true end
  if type(v) == "number" then return v ~= 0 end
  if type(v) == "string" then
    v = v:lower()
    return v == "true" or v == "1" or v == "yes" or v == "on"
  end
  return true
end

----------------------------------------------------------------------
-- sanitize_url(u) -> Url
--
-- Yazi sometimes gives "virtual" URLs for items shown in special views,
-- e.g. search results:
--   search://dupli:1:1//Users/Username/foo.txt
--
-- External preview commands (bat, tar, glow, etc.) usually expect a real
-- filesystem path, not a virtual scheme. The key trick is that `Url.path`
-- is the "path portion" of the URL, i.e. it strips the scheme and yields
-- the real underlying path (e.g. "/Users/Username/foo.txt").
--
-- This helper normalizes such virtual URLs into a usable file Url by
-- converting `u.path` back into a plain Url.
-- Defensive fallback: if `u.path` is empty for any reason, parse the
-- `//...` suffix from the string form.
----------------------------------------------------------------------
local function sanitize_url(u)
  -- u is a Url
  local s = tostring(u)

  -- Fast path: non-search URLs
  if not s:match("^search://") then
    return u
  end

  -- Best: use Url.path (drops scheme like search://, archive://, etc.)
  local p = tostring(u.path or "")
  if p ~= "" then
    return Url(p)
  end

  -- Defensive fallback: parse "...//<path>"
  local rest = s:match("^search://.-//(.*)$")
  if rest and rest ~= "" then
    if rest:sub(1, 1) ~= "/" then
      rest = "/" .. rest
    end
    return Url(rest)
  end

  -- If everything fails, return original
  return u
end

-- Split text into "lines" (like read_line()).
-- Drops empty / whitespace-only lines to avoid blank entries.
local function split_lines(s)
  local t = {}
  if not s or s == "" then
    return t
  end

  -- Ensure the last line is captured even if s doesn't end with '\n'
  s = s .. "\n"

  for line in s:gmatch("(.-)\n") do
    -- Remove empty and whitespace-only lines:
    -- - empty: line == ""
    -- - whitespace-only: line:match("^%s*$")
    if not line:match("^%s*$") then
      t[#t + 1] = line .. "\n"
    end
  end

  return t
end

function M.format(job, lines)
	local format = job.args.format
	if format ~= "url" then
		local s = table.concat(lines, ""):gsub("\r", ""):gsub("\t", string.rep(" ", rt.preview.tab_size))
		return ui.Text.parse(s):area(job.area)
	end

	for i = 1, #lines do
		lines[i] = lines[i]:gsub("[\r\n]+$", "")

		local icon = File({
			url = Url(lines[i]),
			cha = Cha { mode = tonumber(lines[i]:sub(-1) == "/" and "40700" or "100644", 8) },
		}):icon()

		if icon then
			lines[i] = ui.Line { ui.Span(" " .. icon.text .. " "):style(icon.style), lines[i] }
		end
	end
	return ui.Text(lines):area(job.area)
end

-- NOTE: This freshness check only compares cache mtime vs source mtime.
-- Cache filename also includes w/h, so resizing naturally changes cache key.
local function cache_is_fresh(job, cache_path)
  local c = fs.cha(cache_path)
  local s = job.file.cha
  return c and c.mtime and s and s.mtime and c.mtime >= s.mtime
end

-- Derive cache path from file_cache base + current w/h
local function get_cache_path(job)
  local base = ya.file_cache({ file = job.file, skip = 0 })
  if not base then
    return nil, "caching-disabled-by-yazi"
  end
  return Url(string.format("%s_w%d_h%d", tostring(base), job.area.w, job.area.h)), nil
end

local function lock_path_for(cache_path)
  return Url(tostring(cache_path) .. ".lock")
end

local function sleep_ms(ms)
  ya.sleep(ms / 1000)
end

local function lock_is_held(cache_path)
  local lock = lock_path_for(cache_path)
  return fs.cha(lock) ~= nil
end

-- Returns true if we can parse the header line (first line) into a number.
-- This is a good "file is fully written" signal.
local function cache_header_ok(cache_path)
  local out = Command("sed")
    :arg({ "-n", "1p", tostring(cache_path) })
    :stdout(Command.PIPED)
    :stderr(Command.PIPED)
    :stdin(Command.NULL)
    :output()

  if not out or not out.status.success then
    return false
  end

  local n = tonumber((out.stdout or ""):match("(%d+)"))
  return n ~= nil
end

-- Wait until cache is safe to read: fresh, unlocked, header readable.
local function wait_for_ready_cache(job, cache_path, timeout_ms)
  local deadline = os.clock() + (timeout_ms / 1000)

  while os.clock() < deadline do
    -- If writer is active, don't even try to read.
    if lock_is_held(cache_path) then
      ya.sleep(0.02) -- 20ms when locked
    else
      if cache_is_fresh(job, cache_path) and cache_header_ok(cache_path) then
        return true
      end
      ya.sleep(0.01) -- 10ms otherwise
    end
  end

  return false
end

-- Try to acquire lock by creating a directory (atomic on POSIX filesystems).
-- Returns true if acquired, false if timed out.
local function acquire_lock(lock_path, timeout_ms)
  timeout_ms = timeout_ms or 500
  local start = os.clock()

  while true do
    local ok, err = fs.create("dir", lock_path)  -- or "dir_all"
    if ok then
      return true
    end

    -- If it already exists, someone else holds the lock -> wait & retry.
    -- (We don't need to pattern-match err; any failure here is treated as "not acquired".)
    if (os.clock() - start) * 1000 > timeout_ms then
      return false
    end

    ya.sleep(0.01)
  end
end

local function release_lock(lock_path)
  fs.remove("dir", lock_path) -- best-effort
end

----------------------------------------------------------------------
-- Cache generation
-- Writes generator output to cache_path, then computes line count and prepends it.
-- Header line: total number of CONTENT lines (excluding header itself).
----------------------------------------------------------------------

local function generate_cache(job, cache_path)
	local source_path = tostring(sanitize_url(job.file.url))
	local tpl = job.args[1]

  if not tpl or tpl == "" then
    ya.err("faster-piper: missing generator command template (job.args[1])")
    return false
  end

  -- Replace "$1" (including quotes) with a safely quoted filename
  local final = tpl:gsub('"$1"', ya.quote(source_path))

  local queries, queries_err = get_queries()
  if not queries then
    ya.err("faster-piper: " .. tostring(queries_err))
    return false
  end

  local quoted_path = ya.quote(tostring(cache_path))
  local prepend = queries.sed_prepend(quoted_path)

  -- 1) Generate content into file
  -- 2) Count lines of *content* (file currently has only content)
  -- 3) Prepend that count as first line
  local cmd = string.format(
    "(%s) > %s && L=$(wc -l < %s) && %s",
    final, quoted_path, quoted_path, prepend
  )

  local child, err = Command("sh")
    :arg({ "-c", cmd })
    :env("w", tostring(job.area.w))
    :env("h", tostring(job.area.h))
    :stdin(Command.NULL)
    :stdout(Command.NULL)
    :stderr(Command.PIPED)
    :spawn()

	if not child then
    ya.err("faster-piper: failed to spawn: " .. tostring(err))
    fs.remove("file", cache_path)
    return false
  end

  local output, werr = child:wait_with_output()
  if not output then
    ya.err("faster-piper: wait failed: " .. tostring(werr))
    fs.remove("file", cache_path)
    return false
  end

	if not output.status.success then
    ya.err(
      "faster-piper: command failed (code=" .. tostring(output.status.code) .. "): " ..
      tostring(output.stderr)
    )
    fs.remove("file", cache_path)
    return false
  end
  return true
end

----------------------------------------------------------------------
-- Ensure cache exists & is fresh; regenerate if needed.
----------------------------------------------------------------------

local function ensure_cache(job, force_cache)
  local want_cache = true
  if not want_cache then
    return nil, "caching-disabled"
  end

  local cache_path, why = get_cache_path(job)
  if not cache_path then
    return nil, why
  end

  -- Fast path
  if cache_is_fresh(job, cache_path) then
    return cache_path
  end

	-- Acquire lock
  local lock_path = lock_path_for(cache_path)
  local ok = acquire_lock(lock_path, TIME_OUT_PREVIEW)
  if not ok then
    -- If still stale and lock didn't clear:
    return nil, "locked-timeout"
  end

  -- IMPORTANT: recheck after waiting!
  if cache_is_fresh(job, cache_path) then
    release_lock(lock_path)
    return cache_path
  end

  -- Generate
  local gen_ok = generate_cache(job, cache_path)

  release_lock(lock_path)

  if not gen_ok then
    return nil, "generate-failed"
  end

  return cache_path
end

----------------------------------------------------------------------
-- Read header line: total number of lines in CONTENT (excluding header).
-- Uses `sed` (portable GNU/BSD).
----------------------------------------------------------------------

local function read_total_lines(cache_path)
  local qpath = tostring(cache_path)
	local out, err = Command("sed")
    :arg({ "-n", "1p", qpath })
    :stdout(Command.PIPED)
    :stderr(Command.PIPED)
    :stdin(Command.NULL)
    :output()

  if not out then
    return nil, err
  end
  if not out.status.success then
    return nil, out.stderr
  end

  local n = tonumber((out.stdout or ""):match("(%d+)"))
  if not n then
    return nil, "invalid header: " .. tostring(out.stdout)
  end
  -- `wc -l` counts newlines, so it may miss the last line if there's no trailing '\n'.
  -- Add +1 so scrolling/clamping sees the real number of lines.
  local total = n + 1
  return total, nil
end

----------------------------------------------------------------------
-- Yazi hooks
----------------------------------------------------------------------

function M:preload(job)
  -- Preload is explicitly configured -> always warm cache
  local cache_path = ensure_cache(job, true)
  return cache_path ~= nil
end

----------------------------------------------------------------------
-- NOTE ABOUT "JUMP TO END" / HUGE SCROLLS (Yazi limitation + workaround)
--
-- Problem:
--   Yazi's preview scrolling model is built around a `skip` integer that
--   is passed into `peek(job)` and represents "how many units to skip"
--   (lines for text previewers). Yazi does NOT provide:
--
--     1) The total number of lines of the previewed content.
--     2) Any callback where `seek()` can read user args (command, caching).
--     3) A reliable shared Lua state between `seek()` and `peek()`.
--
--   In particular:
--     - `seek(job)` is stateless and arg-agnostic. It cannot know whether
--       caching is enabled, which generator is used, or what cache file exists.
--     - We cannot maintain a Lua table indexed by filename to store per-file
--       metadata (like total lines), because Yazi may reload the Lua state
--       between calls. So `seek()` cannot rely on anything computed earlier
--       by `peek()` or `preload()`.
--
-- Consequence:
--   When the user performs a large scroll action (e.g. PageDown held, or
--   "scroll to bottom"), Yazi may ask us to render extremely large skip
--   values. But we cannot clamp skip in `seek()` (we don't know file length),
--   and Yazi itself may sanitize/clamp very large skips in inconsistent ways.
--
-- The only place where we CAN know the "file length" is inside `peek()`:
--   because we embed the total line count in the cache file itself as the
--   first line header.
--
-- But there is a catch:
--   We MUST NOT silently change the rendering range inside `peek()`, because
--   Yazi tracks preview state using the requested skip. If we locally clamp
--   skip without telling Yazi, Yazi believes we are at one skip while we are
--   actually rendering a different one, and scrolling becomes desynchronized.
--
-- Workaround:
--   We implement "jump to end" as a two-step protocol:
--
--     (A) seek() detects a "huge scroll in one action" using ONLY job.units,
--         and emits a special sentinel skip value:
--
--           skip = cur + PEEK_JUMP_THRESHOLD + 1
--
--         The "+1" ensures skip > PEEK_JUMP_THRESHOLD even when cur == 0.
--
--     (B) peek() sees skip > PEEK_JUMP_THRESHOLD, reads `total` from the
--         cache header, and if (total <= PEEK_JUMP_THRESHOLD) then we know
--         this skip is "definitely beyond EOF", so we clamp by EMITTING a
--         NEW peek() call with skip=max_skip (last page), then return:
--
--           ya.emit("peek", { max_skip, only_if = job.file.url })
--           return
--
--         This keeps Yazi's internal state consistent because it re-runs peek
--         with the corrected skip.
--
--     (C) For very large files (total > PEEK_JUMP_THRESHOLD) we cannot jump
--         reliably without knowing the actual length ahead of time. In that
--         case we simply treat the skip as a real skip and do nothing special.
--         This is the best we can do under Yazi's constraints.
--
-- Summary:
--   - seek() cannot know file length -> cannot clamp skip.
--   - peek() CAN know file length via cache header.
--   - peek() MUST NOT locally clamp -> must re-emit peek() with corrected skip.
--   - sentinel skips are used to request "jump-to-end" in a stateless way.
--
-- Do NOT remove this logic unless Yazi gains:
--   - a reliable shared Lua state between calls, OR
--   - total line count passed into preview jobs, OR
--   - a preview API that supports clamping without desync.
----------------------------------------------------------------------

function M:seek(job)
  -- SEEK MUST BE STATELESS AND ARG-AGNOSTIC
  -- Yazi does not provide information in job whether the cache is present
  -- and what command generated the preview content
  local cur = cx.active.preview.skip or 0
  local units = job.units or 0

  -- Candidate skip (absolute)
  local new_skip = cur + units

  -- Fast path: if user scrolls *way* up in one action, jump to top.
  if units < -SKIP_JUMP_THRESHOLD then
    new_skip = 0
  end

  if units > SKIP_JUMP_THRESHOLD then
  	ya.emit("peek", { cur + PEEK_JUMP_THRESHOLD + 1, only_if = sanitize_url(job.file.url) })
	  return
	end

  new_skip = math.max(0, new_skip)
  ya.emit("peek", { new_skip, only_if = sanitize_url(job.file.url) })
end

function M:peek(job)
	local cache_path, why
	ya.dbg({status=is_true(job.args.rely_on_preloader),job=job.args,file=tostring(job.file.url),caller="PEEK"})
	if is_true(job.args.rely_on_preloader) then
		ya.dbg({job=job.args,file=tostring(job.file.url),caller="USE PRELOADER"})
		cache_path, why = get_cache_path(job)
	  if not cache_path then
	    ya.preview_widget(job, ui.Text.parse("piper: " .. tostring(why)):area(job.area))
	    return
	  end
	  ya.dbg({job=job.args,file=tostring(job.file.url),caller="Good cache path"})

	  -- If not ready, wait up to 3s for preloader to produce fresh cache
	  if not cache_is_fresh(job, cache_path) then
	  	ya.dbg({job=job.args,file=tostring(job.file.url),caller="Cache not fresh"})
	    local ok = wait_for_ready_cache(job, cache_path, TIME_OUT_PREVIEW)
	    ya.dbg({job=job.args,file=tostring(job.file.url),caller="Finished waiting"})
	    if not ok then
	      ya.preview_widget(job, ui.Text.parse("piper: preload timed out (cache not produced)"):area(job.area))
	      return
	    end
	    local new_cache_path, why = get_cache_path(job)
	    ya.dbg({job=job.args,file=tostring(job.file.url),newcache=tostring(new_cache_path),cache=tostring(cache_path),caller="Success"})
	  end
	else
		cache_path, why = ensure_cache(job, false)		
	end

  --------------------------------------------------------------------
  -- If caching disabled => run generator directly (old behavior)
  --------------------------------------------------------------------
  if not cache_path then
    ya.preview_widget(job, ui.Text.parse("faster-piper: failed to generate preview"):area(job.area))
    return
  end

    --------------------------------------------------------------------
  -- Cached mode:
  --  - header line 1: total number of content lines
  --  - content begins at line 2
  --  - clamp skip by emitting a corrected peek (DON'T mutate job.skip)
  --------------------------------------------------------------------

  local total, terr = read_total_lines(cache_path)
  if total then
    local limit = job.area.h
    local max_skip = math.max(0, total - limit)
    
    local skip = job.skip or 0

    -- If the file is small enough that PEEK_JUMP_THRESHOLD is guaranteed past EOF,
    -- then a huge skip means "jump to end".
    if total <= PEEK_JUMP_THRESHOLD and skip > PEEK_JUMP_THRESHOLD and skip ~= max_skip then
      ya.emit("peek", { max_skip, only_if = sanitize_url(job.file.url) })
      return
    end

    if skip > max_skip then
      -- IMPORTANT: Don't adjust the range locally.
      -- Tell Yazi to re-run peek at the correct skip so its state stays consistent.
      ya.emit("peek", { max_skip, only_if = sanitize_url(job.file.url) })
      return
    end
  else
    -- Header missing/invalid; don't hang.
    ya.err("faster-piper: failed to read total lines: " .. tostring(terr))
  end

  local limit = job.area.h
  local skip  = job.skip or 0

  -- content starts at line 2 (line 1 is header)
  local start = skip + 2
  local stop  = skip + limit + 1

  local qpath = tostring(cache_path)
  local range = string.format("%d,%dp", start, stop)

  local out, err = Command("sed")
    :arg({ "-n", range, qpath })
    :stdout(Command.PIPED)
    :stderr(Command.PIPED)
    :stdin(Command.NULL)
    :output()

  if not out then
    ya.preview_widget(job, ui.Text.parse("faster-piper: sed(slice): " .. tostring(err)):area(job.area))
    return
  end
  if not out.status.success then
    ya.preview_widget(job, ui.Text.parse("faster-piper: sed(slice): " .. out.stderr):area(job.area))
    return
  end

  -- out.stdout contains the slice (already excludes the header line)
  if job.args.format == "url" then
    local lines = split_lines(out.stdout)
    ya.preview_widget(job, M.format(job, lines))
  else
    ya.preview_widget(job, ui.Text.parse(out.stdout):area(job.area))
  end
end

return M
