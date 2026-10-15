--!nonstrict
-- Shared helpers for every HyperZone entry: where the files are, and the one way to talk to the
-- daemon. Requests go through hzrpc.py over the daemon's control socket (the host can read the
-- daemon's stdout but cannot write to its stdin, so the v4 stdio channel is not available here).

local M = {}

M.PLUGIN = "shashank/hyperzone"
M.PANEL = M.PLUGIN .. ":settings"

function M.dir()
  return noctalia.pluginDir() or ""
end

-- The daemon is the repo's hyperzone.py, one level above this v5/ directory. A copy-install
-- that bundles hyperzone.py next to plugin.toml works too, and the setting overrides both.
function M.daemonPath()
  local custom = noctalia.getConfig("daemon_path")
  if type(custom) == "string" and custom ~= "" then
    return noctalia.expandPath(custom)
  end
  local bundled = M.dir() .. "/hyperzone.py"
  if noctalia.fileExists(bundled) then
    return bundled
  end
  return M.dir() .. "/../hyperzone.py"
end

-- One RPC. cb(result, err) gets exactly one of the two.
function M.rpc(method, params, cb, timeoutMs)
  local argv = { "python3", M.dir() .. "/hzrpc.py", method, noctalia.json.encode(params or {}) or "{}" }
  return noctalia.runAsync(argv, function(res)
    local reply = nil
    if res.stdout ~= nil and res.stdout ~= "" then
      reply = noctalia.json.decode(res.stdout)
    end
    if cb == nil then
      return
    end
    if reply == nil then
      cb(nil, res.timedOut and "request timed out" or ("no reply from the daemon (exit " .. tostring(res.exitCode) .. ")"))
    elseif reply.error ~= nil then
      cb(nil, reply.error.message or "error")
    else
      cb(reply.result or {}, nil)
    end
  end, timeoutMs or 10000)
end

-- Deep copy through JSON (values crossing entries are plain data anyway).
function M.clone(v)
  if v == nil then
    return nil
  end
  return noctalia.json.decode(noctalia.json.encode(v))
end

return M
