-- cannon.lua - auto-aim for one or more Create Big Cannons mounts using CC:CBC
--
-- Connect every cannon mount with wired modems (right-click each modem to activate it).
-- All connected cannons aim at the same target, each with its own angles.
--
-- Commands:
--   cannon aim <x> <y> <z> [options]   aim all cannons at a block
--   cannon plan <x> <y> <z>            list pitches for every power level (cartridges), per cannon
--   cannon fire [stagger=S]            fire all cannons with their current aim
--   cannon list                        show connected cannons
--   cannon info                        show what each mount reports
--
-- Options for "aim" (any order):
--   fire        fire once all cannons are on target
--   steep       use the high arc instead of the flat one
--   power=N     big cartridge with N power (1-4)
--   charges=N   N powder charges
--   lob         power-4 cartridge on the highest arc (cannons that can't lob are skipped)
--   stagger=S   wait S seconds between each cannon's shot (default: all at once)
--   only=NAME   use just one cannon (name from "cannon list")
--
-- Examples:
--   cannon aim -265 82 -511 power=4 fire
--   cannon aim -265 82 -511 lob fire stagger=0.5

---------------- CONFIG ----------------
local DEFAULT_CANNON_LENGTH = 4            -- block held by the mount to muzzle, both included
local CANNON_LENGTHS = {                   -- per-cannon lengths, if some cannons are different
    -- ["cannon_mount_0"] = 4,
    -- ["cannon_mount_1"] = 6,
}
local DEFAULT_POWER = 4                    -- used when you don't give power= or charges=
local POWER_PER_CARTRIDGE_LEVEL = 2        -- big cartridges (normal CBC, confirmed by test shot)
local POWER_PER_POWDER_CHARGE = 3.315      -- powder charges in your pack (one test shot)
local GRAVITY = -0.05                      -- mortar stone: -0.025 | Nether: -0.055 | End: -0.04
local DRAG = 0.01                          -- Nether: 0.011 | End: 0
local HELD_BLOCK_HEIGHT_ABOVE_MOUNT = 1    -- the cannon block sits on top of the mount
local MINIMUM_PITCH = -30
local MAXIMUM_PITCH = 60
local LOB_MINIMUM_PITCH = 30               -- lob mode refuses anything flatter than this
local AIM_TOLERANCE_DEGREES = 0.05
local AIM_TIMEOUT_SECONDS = 60
----------------------------------------

local arguments = { ... }

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local chargeCount = DEFAULT_POWER
local powerPerCharge = POWER_PER_CARTRIDGE_LEVEL

---------------- FIND CANNONS ----------------
local function findCannons(onlyName)
    local cannons = {}
    for _, peripheralName in ipairs(peripheral.getNames()) do
        if peripheral.hasType(peripheralName, "cannon_mount") then
            if not onlyName or peripheralName == onlyName then
                table.insert(cannons, {
                    name = peripheralName,
                    mount = peripheral.wrap(peripheralName),
                    length = CANNON_LENGTHS[peripheralName] or DEFAULT_CANNON_LENGTH,
                })
            end
        end
    end
    table.sort(cannons, function(firstCannon, secondCannon) return firstCannon.name < secondCannon.name end)
    return cannons
end

---------------- BALLISTICS ----------------
local positionFactor = 1 - DRAG / 2
local velocityRetention = 1 - DRAG

local function velocitySum(ticks)
    if DRAG == 0 then return ticks end
    return (1 - velocityRetention ^ ticks) / DRAG
end

local function verticalDistance(verticalSpeed, ticks)
    if DRAG == 0 then return verticalSpeed * ticks + GRAVITY * ticks * ticks / 2 end
    local summedVelocity = velocitySum(ticks)
    return positionFactor * (verticalSpeed * summedVelocity + (GRAVITY / DRAG) * (ticks - summedVelocity)) + GRAVITY * ticks / 2
end

local function ticksToCover(horizontalSpeed, horizontalDistance)
    if horizontalSpeed <= 0 then return nil end
    if DRAG == 0 then return horizontalDistance / (positionFactor * horizontalSpeed) end
    local remainingFraction = 1 - horizontalDistance * DRAG / (positionFactor * horizontalSpeed)
    if remainingFraction <= 0 then return nil end
    return math.log(remainingFraction) / math.log(velocityRetention)
end

-- Minecraft yaw: 0 = south, 90 = west, 180 = north, 270 = east (same as the goggles)
local function calculateYaw(cannonPosition, target)
    local deltaX = target.x - cannonPosition.x
    local deltaZ = target.z - cannonPosition.z
    return math.deg(atan2(-deltaX, deltaZ)) % 360
end

-- Returns a list of pitch solutions (lowest first) and an airtime function
local function calculatePitches(cannonPosition, target, muzzleSpeed, cannonLength)
    local muzzleOffset = math.max(cannonLength - 1, 0)
    local horizontalDistance = math.sqrt((target.x - cannonPosition.x) ^ 2 + (target.z - cannonPosition.z) ^ 2)
    local heightDifference = target.y - cannonPosition.y

    local function heightError(pitchDegrees)
        local pitchRadians = math.rad(pitchDegrees)
        local remainingDistance = horizontalDistance - muzzleOffset * math.cos(pitchRadians)
        if remainingDistance < 0 then return nil end
        local ticks = ticksToCover(muzzleSpeed * math.cos(pitchRadians), remainingDistance)
        if not ticks then return nil end
        return muzzleOffset * math.sin(pitchRadians) + verticalDistance(muzzleSpeed * math.sin(pitchRadians), ticks) - heightDifference
    end

    local function airtime(pitchDegrees)
        local pitchRadians = math.rad(pitchDegrees)
        return ticksToCover(muzzleSpeed * math.cos(pitchRadians), horizontalDistance - muzzleOffset * math.cos(pitchRadians))
    end

    local solutions = {}
    local previousPitch, previousError = MINIMUM_PITCH, heightError(MINIMUM_PITCH)
    for scannedPitch = MINIMUM_PITCH + 0.25, MAXIMUM_PITCH, 0.25 do
        local scannedError = heightError(scannedPitch)
        if previousError and scannedError and (previousError < 0) ~= (scannedError < 0) then
            local lowerPitch, lowerError, upperPitch = previousPitch, previousError, scannedPitch
            for _ = 1, 50 do
                local middlePitch = (lowerPitch + upperPitch) / 2
                local middleError = heightError(middlePitch)
                if not middleError then break end
                if (middleError < 0) == (lowerError < 0) then
                    lowerPitch, lowerError = middlePitch, middleError
                else
                    upperPitch = middlePitch
                end
            end
            table.insert(solutions, (lowerPitch + upperPitch) / 2)
        end
        previousPitch, previousError = scannedPitch, scannedError
    end
    return solutions, airtime
end

---------------- CANNON CONTROL ----------------
local function getCannonPosition(cannon)
    local mountInfo = cannon.mount.getInfo()
    return { x = mountInfo.x, y = mountInfo.y + HELD_BLOCK_HEIGHT_ABOVE_MOUNT, z = mountInfo.z }
end

local function angleDifference(firstAngle, secondAngle)
    return math.abs((firstAngle - secondAngle + 540) % 360 - 180)
end

local function waitUntilAimed(cannon, targetYaw, targetPitch)
    local startTime = os.clock()
    while os.clock() - startTime < AIM_TIMEOUT_SECONDS do
        local mountInfo = cannon.mount.getInfo()
        if angleDifference(mountInfo.yaw, targetYaw) <= AIM_TOLERANCE_DEGREES and math.abs(mountInfo.pitch - targetPitch) <= AIM_TOLERANCE_DEGREES then
            return true
        end
        sleep(0.1)
    end
    return false
end

local function fireCannon(cannon)
    cannon.mount.fire(true)
    sleep(0.1)
    cannon.mount.fire(false)
    print(cannon.name .. ": fired!")
end

local function fireAll(cannons, staggerSeconds)
    if staggerSeconds and staggerSeconds > 0 then
        for cannonIndex, cannon in ipairs(cannons) do
            fireCannon(cannon)
            if cannonIndex < #cannons then sleep(staggerSeconds) end
        end
        return
    end
    local fireTasks = {}
    for _, cannon in ipairs(cannons) do
        table.insert(fireTasks, function() fireCannon(cannon) end)
    end
    parallel.waitForAll(table.unpack(fireTasks))
end

-- Works out the angles for one cannon. Returns a firing solution or nil (and prints why)
local function solveForCannon(cannon, target, preferSteep, lobMode)
    local mountInfo = cannon.mount.getInfo()
    if not mountInfo.assembled then
        print(cannon.name .. ": assembling...")
        cannon.mount.assemble(true)
        sleep(0.5)
    end

    local cannonPosition = getCannonPosition(cannon)
    local targetYaw = calculateYaw(cannonPosition, target)
    local pitchSolutions, airtime = calculatePitches(cannonPosition, target, chargeCount * powerPerCharge, cannon.length)
    if #pitchSolutions == 0 then
        printError(cannon.name .. ": target out of range.")
        return nil
    end

    local chosenPitch = preferSteep and pitchSolutions[#pitchSolutions] or pitchSolutions[1]
    if lobMode and (#pitchSolutions < 2 or chosenPitch < LOB_MINIMUM_PITCH) then
        printError(("%s: too close to lob at power 4 (best %.2f)"):format(cannon.name, chosenPitch))
        return nil
    end

    return { cannon = cannon, yaw = targetYaw, pitch = chosenPitch, airtimeTicks = airtime(chosenPitch) }
end

-- Aims every cannon at once. Returns the list of cannons that are on target
local function aimAll(cannons, target, preferSteep, lobMode)
    local firingSolutions = {}
    for _, cannon in ipairs(cannons) do
        local firingSolution = solveForCannon(cannon, target, preferSteep, lobMode)
        if firingSolution then
            cannon.mount.setComputerControl(true)
            cannon.mount.setTargetAngles(firingSolution.yaw, firingSolution.pitch)
            print(("%s: yaw %.2f, pitch %.2f, %.1fs flight"):format(cannon.name, firingSolution.yaw, firingSolution.pitch, firingSolution.airtimeTicks / 20))
            table.insert(firingSolutions, firingSolution)
        end
    end

    local readyCannons = {}
    local waitTasks = {}
    for _, firingSolution in ipairs(firingSolutions) do
        table.insert(waitTasks, function()
            if waitUntilAimed(firingSolution.cannon, firingSolution.yaw, firingSolution.pitch) then
                table.insert(readyCannons, firingSolution.cannon)
            else
                printError(firingSolution.cannon.name .. ": didn't reach its angles in time. Is it powered?")
            end
        end)
    end
    if #waitTasks > 0 then
        parallel.waitForAll(table.unpack(waitTasks))
    end

    table.sort(readyCannons, function(firstCannon, secondCannon) return firstCannon.name < secondCannon.name end)
    print(("%d of %d cannons on target."):format(#readyCannons, #cannons))
    return readyCannons
end

local function readTarget()
    local target = { x = tonumber(arguments[2]), y = tonumber(arguments[3]), z = tonumber(arguments[4]) }
    if not (target.x and target.y and target.z) then return nil end
    return target
end

local function readNamedOption(optionName)
    for argumentIndex = 2, #arguments do
        local optionValue = string.match(arguments[argumentIndex], "^" .. optionName .. "=(.+)$")
        if optionValue then return optionValue end
    end
    return nil
end

---------------- COMMANDS ----------------
local command = arguments[1]
local cannons = findCannons(readNamedOption("only"))

if command ~= nil and #cannons == 0 then
    printError("No cannon mounts found. Connect them with wired modems (right-click each modem to activate it).")
    return
end

if command == "aim" then
    local target = readTarget()
    if not target then
        printError("Usage: cannon aim <x> <y> <z> [fire] [steep] [power=N] [charges=N] [lob] [stagger=S] [only=NAME]")
        return
    end

    local shouldFire, preferSteep, lobMode = false, false, false
    for argumentIndex = 5, #arguments do
        local currentArgument = arguments[argumentIndex]
        if currentArgument == "fire" then shouldFire = true end
        if currentArgument == "steep" then preferSteep = true end
        if currentArgument == "lob" then
            chargeCount = 4
            powerPerCharge = POWER_PER_CARTRIDGE_LEVEL
            preferSteep = true
            lobMode = true
        end
        local cartridgeText = string.match(currentArgument, "^power=(%d+)$")
        if cartridgeText then
            chargeCount = tonumber(cartridgeText)
            powerPerCharge = POWER_PER_CARTRIDGE_LEVEL
        end
        local powderText = string.match(currentArgument, "^charges=(%d+)$")
        if powderText then
            chargeCount = tonumber(powderText)
            powerPerCharge = POWER_PER_POWDER_CHARGE
        end
    end

    local readyCannons = aimAll(cannons, target, preferSteep, lobMode)
    if shouldFire and #readyCannons > 0 then
        fireAll(readyCannons, tonumber(readNamedOption("stagger")))
    end

elseif command == "plan" then
    local target = readTarget()
    if not target then
        printError("Usage: cannon plan <x> <y> <z>")
        return
    end
    for _, cannon in ipairs(cannons) do
        local cannonPosition = getCannonPosition(cannon)
        print(("%s - yaw %.2f"):format(cannon.name, calculateYaw(cannonPosition, target)))
        for testedPower = 1, 4 do
            local pitchSolutions = calculatePitches(cannonPosition, target, testedPower * POWER_PER_CARTRIDGE_LEVEL, cannon.length)
            if #pitchSolutions == 0 then
                print(("  power=%d: out of range"):format(testedPower))
            elseif #pitchSolutions == 1 then
                print(("  power=%d: %.2f"):format(testedPower, pitchSolutions[1]))
            else
                print(("  power=%d: %.2f / steep %.2f"):format(testedPower, pitchSolutions[1], pitchSolutions[#pitchSolutions]))
            end
        end
    end

elseif command == "fire" then
    fireAll(cannons, tonumber(readNamedOption("stagger")))

elseif command == "list" then
    for _, cannon in ipairs(cannons) do
        local cannonPosition = getCannonPosition(cannon)
        print(("%s at %d %d %d (length %d)"):format(cannon.name, cannonPosition.x, cannonPosition.y, cannonPosition.z, cannon.length))
    end

elseif command == "info" then
    for _, cannon in ipairs(cannons) do
        print("== " .. cannon.name .. " ==")
        for fieldName, fieldValue in pairs(cannon.mount.getInfo()) do
            print("  " .. fieldName .. " = " .. tostring(fieldValue))
        end
    end

else
    print("cannon aim <x> <y> <z> [fire] [steep] [power=N] [charges=N] [lob] [stagger=S] [only=NAME]")
    print("cannon plan <x> <y> <z>")
    print("cannon fire [stagger=S] | cannon list | cannon info")
end
