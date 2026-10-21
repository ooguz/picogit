-- SPDX-License-Identifier: GPL-3.0-or-later
-- pkt-line framing and side-band-64k demultiplexing.
--
-- A pkt-line is a 4-digit hex length (including the 4 bytes themselves)
-- followed by the payload; "0000" is a flush packet, "0001" a delimiter
-- and "0002" a response-end packet (protocol v2).
local util = require("util")

local M = {}

M.FLUSH = "0000"
M.DELIM = "0001"
M.RESPONSE_END = "0002"
M.MAX_DATA = 65516

function M.encode(data)
  if #data > M.MAX_DATA then error("pkt-line payload too long") end
  return ("%04x"):format(#data + 4) .. data
end

-- A text line: payload with a trailing LF.
function M.line(text)
  return M.encode(text .. "\n")
end

local Reader = {}
Reader.__index = Reader

-- reader(read_fn): read_fn(n) returns up to n bytes or nil at EOF.
function M.reader(read_fn)
  return setmetatable({ read_fn = read_fn, buf = "", pos = 1 }, Reader)
end

-- Return exactly n bytes, or nil if the stream ends first.
function Reader:take(n)
  local avail = #self.buf - self.pos + 1
  if avail < n then
    local parts = { self.buf:sub(self.pos) }
    while avail < n do
      local d = self.read_fn(65536)
      if not d then return nil end
      parts[#parts + 1] = d
      avail = avail + #d
    end
    self.buf = table.concat(parts)
    self.pos = 1
  end
  local s = self.buf:sub(self.pos, self.pos + n - 1)
  self.pos = self.pos + n
  return s
end

-- Read one packet: returns kind ("data", "flush", "delim", "end") and the
-- payload for data packets, or nil at end of stream.
function Reader:read()
  local hdr = self:take(4)
  if not hdr then return nil end
  local len = tonumber(hdr, 16)
  if not len or not hdr:match("^%x%x%x%x$") then
    util.die("protocol error: bad pkt-line header %q", hdr)
  end
  if len == 0 then return "flush" end
  if len == 1 then return "delim" end
  if len == 2 then return "end" end
  if len < 4 then util.die("protocol error: bad pkt-line length %d", len) end
  local data = self:take(len - 4)
  if not data then util.die("protocol error: unexpected end of stream") end
  if util.verbose and len < 1000 then
    util.trace("pkt< %s", (data:gsub("\n$", "")))
  end
  return "data", data
end

-- Like read() but requires a data packet and strips the trailing LF.
function Reader:read_line()
  local kind, data = self:read()
  if kind ~= "data" then return nil, kind end
  return (data:gsub("\n$", ""))
end

-- Writes remote progress messages (side-band channel 2) to stderr as
-- "remote: ..." lines, keeping carriage-return progress updates intact.
function M.progress_writer()
  local pending = ""
  return function(msg)
    if util.quiet then return end
    pending = pending .. msg
    while true do
      local s, e = pending:find("[\r\n]")
      if not s then break end
      local line = pending:sub(1, s - 1)
      io.stderr:write("remote: ", line, pending:sub(s, s))
      pending = pending:sub(e + 1)
    end
  end
end

-- Demultiplex side-band-64k packets until a flush packet (or the end of
-- the stream): channel 1 goes to on_data, 2 to on_progress, 3 is a fatal
-- error reported by the remote.
function M.demux(reader, on_data, on_progress)
  while true do
    local kind, data = reader:read()
    if kind == nil or kind == "flush" then return end
    if kind == "data" then
      local band = data:byte(1)
      if band == 1 then
        on_data(data:sub(2))
      elseif band == 2 then
        if on_progress then on_progress(data:sub(2)) end
      elseif band == 3 then
        util.die("remote error: %s", (data:sub(2):gsub("\n$", "")))
      else
        util.die("protocol error: bad side-band channel %s", tostring(band))
      end
    end
  end
end

return M
