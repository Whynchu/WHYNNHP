-- scripts/ezlibs-scripts/ezconfig.lua

print("[ezconfig] loading config... (trace follows)")
if debug and debug.traceback then
  print(debug.traceback("[ezconfig] traceback", 2))
else
  print("[ezconfig] debug.traceback unavailable")
end

local ezconfig = require('ezlibs-config')
if ezconfig == nil then
  error('[ezconfig] ezlibs requires a ezlibs-config.lua in the root of your server!')
end

return ezconfig
