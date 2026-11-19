-- firecontrol.lua - remote for the fire control server (pocket computer with an ender modem)
-- Usage: firecontrol <anything you'd type after "cannon">
--   firecontrol aim -265 82 -511 lob fire
--   firecontrol plan 64 70 -5
--   firecontrol list

---------------- CONFIG ----------------
local PROTOCOL = "shapto_firecontrol"
local SERVER_NAME = "battery_1"
local PASSWORD = "change-me"               -- must match startup.lua
local REPLY_TIMEOUT_SECONDS = 120          -- aiming + lob flights can take a while
----------------------------------------

local commandWords = { ... }
if #commandWords == 0 then
    print("firecontrol <cannon command>, e.g. firecontrol aim -265 82 -511 lob fire")
    return
end

local enderModem = peripheral.find("modem", function(_, modem) return modem.isWireless() end)
if not enderModem then
    printError("No ender modem. Craft the pocket computer with an ender modem.")
    return
end
rednet.open(peripheral.getName(enderModem))

local serverId = rednet.lookup(PROTOCOL, SERVER_NAME)
if not serverId then
    printError("Can't find fire control '" .. SERVER_NAME .. "'. Is its chunk loaded?")
    return
end

rednet.send(serverId, { password = PASSWORD, words = commandWords }, PROTOCOL)
print("Sent. Waiting for the battery...")

local replyId, reply = rednet.receive(PROTOCOL, REPLY_TIMEOUT_SECONDS)
if not replyId then
    printError("No reply (timed out).")
    return
end

for _, line in ipairs(reply.lines or {}) do
    if string.sub(line, 1, 2) == "! " then
        printError(string.sub(line, 3))
    else
        print(line)
    end
end