--- @since 10.01.2026
local M = {}

-- If Yazi asks for a skip larger than this, jump straight to the last page.
local SKIP_JUMP_THRESHOLD = 999
local PEEK_JUMP_THRESHOLD = 99999999
-- Maximum time allowed for preview (in ms)
local TIME_OUT_LOCK = 5000
local TIME_OUT_PREVIEW = 200
-- Maximum time for stale-lock directories
local LOCK_TTL_SEC = 60

----------------------------------------------------------------------
-- Cache header layout (1-based line numbers)
--
-- We keep ALL header-related offsets centralized here.
-- When adding a new header field:
--   1) insert it into this layout
--   2) bump HEADER.N
--   3) update any reader functions that fetch header fields
----------------------------------------------------------------------

local HEADER = {
  -- Total number of header lines stored at the top of the cache file.
  N = 3,

  -- Which header line contains what (1-based):
  LINE_CMD   = 1, -- raw user-provided command template (job.args[1], unchanged)
  LINE_NLINE = 2, -- number of *content* lines (excludes headers)
  LINE_W     = 3, -- preview width used to generate this cache
}

-- Content starts immediately after the header.
local function content_first_line()
  return HEADER.N + 1
end

----------------------------------------------------------------------
-- Utils
----------------------------------------------------------------------

--- Parse a "truthy/falsey" value into a boolean, with an explicit default.
---
--- This is meant for plugin args / config values that might arrive as:
---   - nil           -> returns `default`
---   - boolean       -> returns that boolean
---   - number        -> 0 = false, non-zero = true
---   - string        -> common on/off values (case-insensitive):
---                      true:  "true", "1", "yes", "on"
---                      false: "false", "0", "no",  "off"
---                      anything else -> returns `default`
---   - other types   -> returns `default`
---
--- param v any            ->  Value to parse.
--- param default boolean  ->  The fallback value used when `v` is nil/unknown.
--- return boolean
local function is_true(v, default)
  assert(type(default) == "boolean", "is_true: default must be a boolean")

  if v == nil then
    return default
  end
  if v == true then
    return true
  end
  if v == false then
    return false
  end
  if type(v) == "number" then
    return v ~= 0
  end
  if type(v) == "string" then
    v = v:lower()
    if v == "true" or v == "1" or v == "yes" or v == "on" then
      return true
    end
    if v == "false" or v == "0" or v == "no" or v == "off" then
      return false
    end
    -- Unknown string: fall back to default (or you can choose to return true)
    return default
  end

  -- Unknown type: fall back to default
  return default
end

----------------------------------------------------------------------
-- fs_path(url) -> string
--
-- Convert Yazi Url into a real filesystem path string for external tools.
--
-- Why:
--   In some views (notably search results), Yazi uses virtual URLs such as:
--     search://dupli:1:1//Users/andrea/file.txt
--   External commands (bat, glow, tar, etc.) expect a plain filesystem path.
--
-- How:
--   Yazi already exposes the underlying path via `url.path`, and also tells
--   us whether this Url comes from search using `url.is_search`.
--
-- Behavior:
--   - For search URLs: return tostring(url.path)
--   - For regular file URLs: return tostring(url)
--   - Defensive fallback: if url.path is missing/empty, fall back to tostring(url)
----------------------------------------------------------------------
local function fs_path(url)
  if url and url.is_search then
    local p = url.path
    if p then
      local s = tostring(p)
      if s ~= "" then
        return s
      end
    end
  end
  return tostring(url)
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

local read_cache_header  -- forward declaration

-- Header-based freshness check:
-- - cache mtime >= source mtime
-- - header parses
-- - header width matches current preview width
-- Returns:
--   ok, hdr
-- where hdr is the parsed header if available.
local function cache_is_fresh(job, cache_path)
  local c = fs.cha(cache_path)
  local s = job.file.cha
  if not (c and c.mtime and s and s.mtime and c.mtime >= s.mtime) then
    return false, nil
  end

  local hdr = read_cache_header(cache_path)
  if not hdr then
    return false, nil
  end

  if hdr.w ~= job.area.w then
    return false, nil
  end

  return true, hdr
end

-- Derive cache path from file_cache base + current w/h
local function get_cache_path(job)
  local base = ya.file_cache({ file = job.file, skip = 0 })
  if not base then
    return nil, "caching-disabled-by-yazi"
  end
  return Url(tostring(base)), nil
end

local function lock_path_for(cache_path)
  local app_id = ya.id and ya.id("app") or nil

  local str_id = "noid"
  if app_id and app_id.value then
    str_id = tostring(app_id.value)
  end
  -- faster-piper lock system
  return Url(string.format("%s_FP_%s.lock", tostring(cache_path), str_id))
end

local function lock_is_held(cache_path)
  local lock = lock_path_for(cache_path)
  return fs.cha(lock) ~= nil
end

-- Wait until cache is safe to read: unlocked + fresh.
-- Returns: ok, hdr
local function wait_for_ready_cache(job, cache_path, timeout_ms)
  local deadline = ya.time() + (timeout_ms / 1000)
  while ya.time() < deadline do
    -- If writer is active, don't even try to read.
    if lock_is_held(cache_path) then
      ya.sleep(0.02) -- 20ms when locked
    else
      if not fs.cha(cache_path) then
        ya.sleep(0.01)
      else
        local ok, hdr = cache_is_fresh(job, cache_path)
        if ok then return true, hdr end
        ya.sleep(0.01)
      end
    end
  end
  return false, nil
end

local function lock_age_seconds(lock_path)
  local c = fs.cha(lock_path)
  if not (c and c.mtime) then
    return math.huge
  end
  return ya.time() - c.mtime
end

local function break_lock_dir(lock_path)
  -- best-effort; ignore failures
  fs.remove("dir_all", lock_path)
end

-- Try to acquire lock by creating a directory (atomic on POSIX filesystems).
-- Returns true if acquired, false if timed out.
local function acquire_lock(lock_path, timeout_ms)
  timeout_ms = timeout_ms or 500
  local deadline = ya.time() + (timeout_ms / 1000)

  while ya.time() < deadline do
    local ok = fs.create("dir", lock_path)
    if ok then
      return true
    end

    -- If it exists and is stale, break it and retry immediately
    if lock_age_seconds(lock_path) > LOCK_TTL_SEC then
      -- ya.dbg({ stale_lock = tostring(lock_path), age = lock_age_seconds(lock_path) })
      break_lock_dir(lock_path)
    else
      ya.sleep(0.01)
    end
  end

  return false
end

local function release_lock(lock_path)
  fs.remove("dir_all", lock_path)
end

----------------------------------------------------------------------
-- Read and validate a full header in ONE call.
-- Returns:
--   hdr = { cmd = <string>, nline = <number>, w = <number> }  on success
--   nil, err                                                  on failure
--
-- Notes:
-- - cmd is returned without trailing newline.
-- - nline and w are parsed as integers.
----------------------------------------------------------------------
read_cache_header = function(cache_path)
  -- Read the first HEADER.N lines at once
  local spec = string.format("1,%dp", HEADER.N)

  local out, err = Command("sed")
    :arg({ "-n", spec, tostring(cache_path) })
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

  local txt = out.stdout or ""
  if txt == "" then
    return nil, "empty cache header"
  end

  -- Split into lines (WITHOUT losing empty cmd lines)
  -- Keep at most HEADER.N lines.
  local lines = {}
  local i = 0
  for line in txt:gmatch("([^\n]*)\n") do
    i = i + 1
    lines[i] = line
    if i >= HEADER.N then break end
  end

  if #lines < HEADER.N then
    return nil, "incomplete cache header (need " .. HEADER.N .. " lines, got " .. #lines .. ")"
  end

  local cmd = lines[HEADER.LINE_CMD]
  local nline = tonumber((lines[HEADER.LINE_NLINE] or ""):match("^%s*(%d+)%s*$"))
  local w = tonumber((lines[HEADER.LINE_W] or ""):match("^%s*(%d+)%s*$"))

  if cmd == nil then
    return nil, "missing cmd header line"
  end
  if not nline then
    return nil, "invalid line-count header: " .. tostring(lines[HEADER.LINE_NLINE])
  end
  if not w then
    return nil, "invalid width header: " .. tostring(lines[HEADER.LINE_W])
  end

  return { cmd = cmd, nline = nline, w = w }, nil
end


----------------------------------------------------------------------
-- Cache generation
--
-- Behavior:
-- - If job.args[1] is present: use it as recipe.
-- - Else: if cache exists and has valid header: reuse cached recipe (LINE_CMD).
-- - Else: fail (no recipe available).
--
-- Always writes a 3-line header:
--   1) command template (exact string we use)
--   2) number of content lines (wc -l, trimmed)
--   3) width used (w, trimmed)
----------------------------------------------------------------------
local function generate_cache(job, cache_path)
  local source_path = fs_path(job.file.url)

  -- 1) Decide template: job.args[1] or cached header
  local tpl = job.args and job.args[1]
  if tpl == "" then tpl = nil end

  if not tpl then
    local cha = fs.cha(cache_path)
    if cha then
      local hdr, herr = read_cache_header(cache_path)
      if hdr and hdr.cmd and hdr.cmd ~= "" then
        tpl = hdr.cmd
      else
        -- header invalid -> cannot recover recipe
        ya.err("faster-piper: cache header invalid; cannot reuse recipe: " .. tostring(herr))
      end
    end
  end

  if not tpl or tpl == "" then
    ya.err("faster-piper: missing generator command template (job.args[1]) and no usable cached header")
    return false
  end

  -- Guard: template must be single-line for env passing + header layout
  if tpl:find("\n", 1, true) then
    ya.err("faster-piper: command template contains newline; unsupported")
    return false
  end

  -- 2) Expand "$1" safely for external tools
  local final = tpl:gsub('"$1"', ya.quote(source_path))

  local quoted_path = ya.quote(tostring(cache_path))
  local tmp_url = Url(tostring(cache_path) .. ".tmp")
  local tmp_path = ya.quote(tostring(tmp_url))

  -- 3) Generate content into cache_path (temporary), then build header+content into tmp, then mv
  --
  -- - We trim whitespace from wc output to avoid leading spaces.
  -- - We also trim $w to be safe.
  local cmd = string.format([[
    (%s) > %s &&
    L=$(wc -l < %s | tr -d '[:space:]') &&
    W=$(printf '%%s' "$w" | tr -d '[:space:]') &&
    { printf '%%s\n' "$FP_TPL"; printf '%%s\n' "$L"; printf '%%s\n' "$W"; cat %s; } > %s &&
    mv %s %s
  ]],
    final,
    quoted_path,
    quoted_path,
    quoted_path,
    tmp_path,
    tmp_path,
    quoted_path
  )

  local child, err = Command("sh")
    :arg({ "-c", cmd })
    :env("w", tostring(job.area.w))
    :env("h", tostring(job.area.h))
    :env("FP_TPL", tpl) -- EXACT template string we used
    :stdin(Command.NULL)
    :stdout(Command.NULL)
    :stderr(Command.PIPED)
    :spawn()

  if not child then
    ya.err("faster-piper: failed to spawn: " .. tostring(err))
    fs.remove("file", cache_path)
    fs.remove("file", tmp_url)
    return false
  end

  local output, werr = child:wait_with_output()
  if not output then
    ya.err("faster-piper: wait failed: " .. tostring(werr))
    fs.remove("file", cache_path)
    fs.remove("file", tmp_url)
    return false
  end

  if not output.status.success then
    ya.err("faster-piper: command failed (code=" .. tostring(output.status.code) .. "): " .. tostring(output.stderr))
    fs.remove("file", cache_path)
    fs.remove("file", tmp_url)
    return false
  end

  -- 4) Sanity-check the newly written header
  local hdr, herr = read_cache_header(cache_path)
  if not hdr then
    ya.err("faster-piper: wrote cache but header sanity-check failed: " .. tostring(herr))
    fs.remove("file", cache_path)
    return false
  end
  return true
end

-- -------------------------------------------------------------------
-- Ensure cache exists & is fresh; regenerate if needed
-- -------------------------------------------------------------------
local function ensure_cache(job)
  local cache_path, why = get_cache_path(job)
  if not cache_path then
    return nil, why
  end

  -- Fresh -> done
  if cache_is_fresh(job, cache_path) then
    return cache_path
  end

  -- Acquire lock
  local lock_path = lock_path_for(cache_path)
  local ok = acquire_lock(lock_path, TIME_OUT_LOCK)
  if not ok then
    return nil, "locked-timeout"
  end

  -- Re-check after acquiring (someone else may have generated it)
  if cache_is_fresh(job, cache_path) then
    release_lock(lock_path)
    return cache_path
  end

  local gen_ok = generate_cache(job, cache_path)

  release_lock(lock_path)

  if not gen_ok then
    return nil, "generate-failed"
  end

  return cache_path
end


----------------------------------------------------------------------
-- Yazi hooks
----------------------------------------------------------------------

function M:preload(job)
  -- Preload is explicitly configured -> always warm cache
  local cache_path = ensure_cache(job)
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
    ya.emit("peek", { cur + PEEK_JUMP_THRESHOLD + 1, only_if = job.file.url })
    return
  end

  new_skip = math.max(0, new_skip)
  ya.emit("peek", { new_skip, only_if = job.file.url })
end

function M:peek(job)
  local cache_path, why
  local hdr, herr

  if is_true(job.args.rely_on_preloader,false) then
    cache_path, why = get_cache_path(job)
    if not cache_path then
      ya.preview_widget(job, ui.Text.parse("faster-piper: " .. tostring(why)):area(job.area))
      return
    end

    local ok
    ok, hdr = cache_is_fresh(job, cache_path)   -- hdr is assured to be nil when ok==false

    if not ok then
      -- If the cache file exists, we can self-heal (resize case) by reusing cmd from header.
      if fs.cha(cache_path) then
        local ensured, ewhy = ensure_cache(job)
        if ensured then
          cache_path = ensured
        else
          ya.preview_widget(job,
            ui.Text.parse("faster-piper: failed to refresh cache: " .. tostring(ewhy)):area(job.area)
          )
          return
        end
      else
        -- Cache file doesn't exist (save-race): wait briefly for preloader to write it.
        local ok2
        ok2, hdr = wait_for_ready_cache(job, cache_path, TIME_OUT_PREVIEW)
        if not ok2 then
          ya.preview_widget(job,
            ui.Text.parse("faster-piper: ⏳ preview is taking longer than expected. Try selecting the file again."):area(job.area)
          )
          return
        end
      end
    end
  else
    cache_path, why = ensure_cache(job)
    if not cache_path then
      ya.preview_widget(job, ui.Text.parse("faster-piper: " .. tostring(why)):area(job.area))
      return
    end
  end

  -- If hdr not already available/reliable, read it once here
  if not hdr then hdr, herr = read_cache_header(cache_path) end

  if hdr then
    local total = hdr.nline
    local limit = job.area.h
    local max_skip = math.max(0, total - limit)

    local skip = job.skip or 0

    if total <= PEEK_JUMP_THRESHOLD and skip > PEEK_JUMP_THRESHOLD and skip ~= max_skip then
      ya.emit("peek", { max_skip, only_if = job.file.url })
      return
    end

    if skip > max_skip then
      ya.emit("peek", { max_skip, only_if = job.file.url })
      return
    end
  else
    ya.err("faster-piper: failed to read cache header: " .. tostring(herr))
  end

  local limit = job.area.h
  local skip  = job.skip or 0

  -- content starts after HEADER.N lines of header
  local start = skip + content_first_line()
  local stop  = start + limit - 1

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

-- -------------------------------------------------------------------
-- entry(): called by `run = 'plugin faster-piper ...'` keybindings
-- -------------------------------------------------------------------
function M:entry(job)
  return
end


return M
