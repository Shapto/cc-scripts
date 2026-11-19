-- startup.lua - fire control server. Runs automatically when the computer boots.
-- 1. Locks every cannon where it is (stops them spinning after a chunk reload)
-- 2. Listens on the ender modem for commands from firecontrol.lua and runs them through cannon.lua

---------------- CONFIG ----------------
local PROTOCOL = "shapto_firecontrol"
local SERVER_NAME = "battery_1"            -- change if you build more than one battery
local PASSWORD = "change-me"               -- must match firecontrol.lua
----------------------------------------

local function lockAllCannons()
    local lockedCount = 0
    for _, peripheralName in ipairs(peripheral.getNames()) do
        if peripheral.hasType(peripheralName, "cannon_mount") then
            local cannonMount = peripheral.wrap(peripheralName)
            local mountInfo = cannonMount.getInfo()
            cannonMount.setComputerControl(true)
            cannonMount.setTargetAngles(mountInfo.yaw, mountInfo.pitch)
            lockedCount = lockedCount + 1
        end
    end
    print(("Locked %d cannon(s) in place."):format(lockedCount))
end

local function findEnderModem()
    return peripheral.find("modem", function(_, modem) return modem.isWireless() end)
end

-- Runs cannon.lua with the given words and returns everything it printed
local function runCannonCommand(commandWords)
    local capturedLines = {}
    local originalPrint, originalPrintError = print, printError
    _G.print = function(...)
        local lineParts = {}
        for _, value in ipairs({ ... }) do table.insert(lineParts, tostring(value)) end
        local line = table.concat(lineParts, " ")
        table.insert(capturedLines, line)
        originalPrint(line)
    end
    _G.printError = function(message)
        table.insert(capturedLines, "! " .. tostring(message))
        originalPrintError(message)
    end

    local runSucceeded, runError = pcall(shell.run, "cannon", table.unpack(commandWords))

    _G.print, _G.printError = originalPrint, originalPrintError
    if not runSucceeded then
        table.insert(capturedLines, "! " .. tostring(runError))
    end
    return capturedLines
end

---------------- MAIN ----------------
sleep(1) -- give the cannons a moment to load in
lockAllCannons()

local enderModem = findEnderModem()
if not enderModem then
    printError("No ender/wireless modem found - remote control disabled. Cannons are still locked.")
    return
end

rednet.open(peripheral.getName(enderModem))
rednet.host(PROTOCOL, SERVER_NAME)
print(("Fire control '%s' listening..."):format(SERVER_NAME))

while true do
    local senderId, message = rednet.receive(PROTOCOL)
    if type(message) == "table" and message.password == PASSWORD and type(message.words) == "table" then
        print(("Command from computer %d: cannon %s"):format(senderId, table.concat(message.words, " ")))
        local outputLines = runCannonCommand(message.words)
        rednet.send(senderId, { lines = outputLines }, PROTOCOL)
    else
        rednet.send(senderId, { lines = { "! Wrong password." } }, PROTOCOL)
    end
end