-- cannon.lua - auto-aim for a Create Big Cannons mount using CC:CBC
--
-- Commands:
--   cannon aim <x> <y> <z> [options]   aim at a block
--   cannon plan <x> <y> <z>            list pitches for every power level (cartridges)
--   cannon fire                        fire with the current aim
--   cannon info                        show what the mount reports
--
-- Options for "aim" (any order):
--   fire        fire once on target
--   steep       use the high arc instead of the flat one
--   power=N     big cartridge with N power (1-4)
--   charges=N   N powder charges
--   lob         power-4 cartridge on the highest arc (refuses flat shots)
--
-- Examples:
--   cannon aim -265 82 -511 power=4 fire
--   cannon aim 64 70 -5 power=1 steep fire
--   cannon aim -265 82 -511 lob fire

---------------- CONFIG ----------------
local CANNON_LENGTH = 4                    -- block held by the mount to muzzle, both included
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

local cannonMount = peripheral.find("cannon_mount")
if not cannonMount then
    printError("No cannon mount found. Put the computer next to the mount or connect it with a wired modem.")
    return
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
local function calculatePitches(cannonPosition, target, muzzleSpeed)
    local muzzleOffset = math.max(CANNON_LENGTH - 1, 0)
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
local function getCannonPosition()
    local mountInfo = cannonMount.getInfo()
    return { x = mountInfo.x, y = mountInfo.y + HELD_BLOCK_HEIGHT_ABOVE_MOUNT, z = mountInfo.z }
end

local function angleDifference(firstAngle, secondAngle)
    return math.abs((firstAngle - secondAngle + 540) % 360 - 180)
end

local function waitUntilAimed(targetYaw, targetPitch)
    local startTime = os.clock()
    while os.clock() - startTime < AIM_TIMEOUT_SECONDS do
        local mountInfo = cannonMount.getInfo()
        if angleDifference(mountInfo.yaw, targetYaw) <= AIM_TOLERANCE_DEGREES and math.abs(mountInfo.pitch - targetPitch) <= AIM_TOLERANCE_DEGREES then
            return true
        end
        sleep(0.1)
    end
    return false
end

local function fire()
    cannonMount.fire(true)
    sleep(0.1)
    cannonMount.fire(false)
    print("Fired!")
end

local function aimAt(target, preferSteep, lobMode)
    local mountInfo = cannonMount.getInfo()
    if not mountInfo.assembled then
        print("Assembling cannon...")
        cannonMount.assemble(true)
        sleep(0.5)
    end

    local cannonPosition = getCannonPosition()
    local targetYaw = calculateYaw(cannonPosition, target)
    local pitchSolutions, airtime = calculatePitches(cannonPosition, target, chargeCount * powerPerCharge)
    if #pitchSolutions == 0 then
        printError("Target out of range (or needs a pitch outside " .. MINIMUM_PITCH .. ".." .. MAXIMUM_PITCH .. ").")
        return false
    end

    local chosenPitch = preferSteep and pitchSolutions[#pitchSolutions] or pitchSolutions[1]

    -- Lob mode: only fire if there is a real high arc within the mount's range
    if lobMode and (#pitchSolutions < 2 or chosenPitch < LOB_MINIMUM_PITCH) then
        printError(("No high arc with a power-4 cartridge (best is %.2f, too flat)."):format(chosenPitch))
        print("Target is too close for lobbing at power 4 - use 'cannon plan' to pick a lower power.")
        return false
    end

    cannonMount.setComputerControl(true)
    cannonMount.setTargetAngles(targetYaw, chosenPitch)
    print(("Aiming: yaw %.2f, pitch %.2f (power %d)"):format(targetYaw, chosenPitch, chargeCount))
    if #pitchSolutions > 1 then
        print(("Other arc: pitch %.2f"):format(preferSteep and pitchSolutions[1] or pitchSolutions[#pitchSolutions]))
    end

    if not waitUntilAimed(targetYaw, chosenPitch) then
        local finalInfo = cannonMount.getInfo()
        printError(("Didn't reach the target angles in time (now yaw %.2f, pitch %.2f). Is the mount powered?"):format(finalInfo.yaw, finalInfo.pitch))
        return false
    end

    local airtimeTicks = airtime(chosenPitch)
    print(("On target. Airtime %.1f ticks (%.2fs), fuze %d"):format(airtimeTicks, airtimeTicks / 20, math.max(1, math.floor(airtimeTicks) - 10)))
    return true
end

local function readTarget()
    local target = { x = tonumber(arguments[2]), y = tonumber(arguments[3]), z = tonumber(arguments[4]) }
    if not (target.x and target.y and target.z) then return nil end
    return target
end

---------------- COMMANDS ----------------
local command = arguments[1]

if command == "aim" then
    local target = readTarget()
    if not target then
        printError("Usage: cannon aim <x> <y> <z> [fire] [steep] [power=N] [charges=N] [lob]")
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

    if aimAt(target, preferSteep, lobMode) and shouldFire then
        fire()
    end

elseif command == "plan" then
    local target = readTarget()
    if not target then
        printError("Usage: cannon plan <x> <y> <z>")
        return
    end
    local cannonPosition = getCannonPosition()
    print(("Yaw %.2f  (big cartridge power levels)"):format(calculateYaw(cannonPosition, target)))
    for testedPower = 1, 4 do
        local pitchSolutions = calculatePitches(cannonPosition, target, testedPower * POWER_PER_CARTRIDGE_LEVEL)
        if #pitchSolutions == 0 then
            print(("power=%d: out of range"):format(testedPower))
        elseif #pitchSolutions == 1 then
            print(("power=%d: %.2f"):format(testedPower, pitchSolutions[1]))
        else
            print(("power=%d: %.2f / steep %.2f"):format(testedPower, pitchSolutions[1], pitchSolutions[#pitchSolutions]))
        end
    end

elseif command == "fire" then
    fire()

elseif command == "info" then
    for fieldName, fieldValue in pairs(cannonMount.getInfo()) do
        print(fieldName .. " = " .. tostring(fieldValue))
    end

else
    print("cannon aim <x> <y> <z> [fire] [steep] [power=N] [charges=N] [lob]")
    print("cannon plan <x> <y> <z>")
    print("cannon fire | cannon info")
end
