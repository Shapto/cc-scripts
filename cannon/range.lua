-- range.lua - maximum range of a Create Big Cannons cannon (CBC 5.11.7 physics)
--
-- Usage:
--   range                     table for big cartridges, power 1-4, target at cannon height
--   range power=4             one big cartridge power level
--   range charges=3           powder charges
--   range height=-20          target 20 blocks BELOW the cannon (+20 = above)
--   range y=70                target at world height 70 (needs the cannon mount connected)
--
-- Options can be combined, e.g. "range power=4 y=64"

---------------- CONFIG (keep in sync with cannon.lua) ----------------
local CANNON_LENGTH = 4
local POWER_PER_CARTRIDGE_LEVEL = 2
local POWER_PER_POWDER_CHARGE = 3.315
local GRAVITY = -0.05
local DRAG = 0.01
local HELD_BLOCK_HEIGHT_ABOVE_MOUNT = 1
local MINIMUM_PITCH = -30
local MAXIMUM_PITCH = 60
local MAXIMUM_SIMULATED_TICKS = 4000
------------------------------------------------------------------------

local arguments = { ... }

-- Tick-by-tick, exactly like the mod: returns horizontal distance where the shell
-- comes back down to heightDifference, plus the airtime in ticks (nil if it never does)
local function landingDistance(muzzleSpeed, pitchDegrees, heightDifference)
    local pitchRadians = math.rad(pitchDegrees)
    local muzzleOffset = math.max(CANNON_LENGTH - 1, 0)
    local horizontalPosition = muzzleOffset * math.cos(pitchRadians)
    local verticalPosition = muzzleOffset * math.sin(pitchRadians)
    local horizontalVelocity = muzzleSpeed * math.cos(pitchRadians)
    local verticalVelocity = muzzleSpeed * math.sin(pitchRadians)

    for tick = 1, MAXIMUM_SIMULATED_TICKS do
        local horizontalAcceleration = -DRAG * horizontalVelocity
        local verticalAcceleration = -DRAG * verticalVelocity + GRAVITY
        local nextHorizontal = horizontalPosition + horizontalVelocity + 0.5 * horizontalAcceleration
        local nextVertical = verticalPosition + verticalVelocity + 0.5 * verticalAcceleration

        if verticalVelocity < 0 and nextVertical <= heightDifference and heightDifference <= verticalPosition then
            local crossingFraction = (verticalPosition - heightDifference) / (verticalPosition - nextVertical)
            return horizontalPosition + (nextHorizontal - horizontalPosition) * crossingFraction, tick - 1 + crossingFraction
        end

        horizontalPosition, verticalPosition = nextHorizontal, nextVertical
        horizontalVelocity = horizontalVelocity + horizontalAcceleration
        verticalVelocity = verticalVelocity + verticalAcceleration
    end
    return nil
end

-- Finds the pitch (within the mount's limits) that gives the longest range
local function maximumRange(muzzleSpeed, heightDifference)
    local bestDistance, bestPitch, bestAirtime = nil, nil, nil
    for scannedPitch = MINIMUM_PITCH, MAXIMUM_PITCH, 0.5 do
        local reachedDistance, airtimeTicks = landingDistance(muzzleSpeed, scannedPitch, heightDifference)
        if reachedDistance and (not bestDistance or reachedDistance > bestDistance) then
            bestDistance, bestPitch, bestAirtime = reachedDistance, scannedPitch, airtimeTicks
        end
    end
    if not bestPitch then return nil end

    -- Refine around the best scanned angle
    local searchStep = 0.25
    for _ = 1, 12 do
        for _, candidatePitch in ipairs({ bestPitch - searchStep, bestPitch + searchStep }) do
            if candidatePitch >= MINIMUM_PITCH and candidatePitch <= MAXIMUM_PITCH then
                local reachedDistance, airtimeTicks = landingDistance(muzzleSpeed, candidatePitch, heightDifference)
                if reachedDistance and reachedDistance > bestDistance then
                    bestDistance, bestPitch, bestAirtime = reachedDistance, candidatePitch, airtimeTicks
                end
            end
        end
        searchStep = searchStep / 2
    end
    return bestDistance, bestPitch, bestAirtime
end

local function printRangeLine(label, muzzleSpeed, heightDifference)
    local bestDistance, bestPitch, bestAirtime = maximumRange(muzzleSpeed, heightDifference)
    if not bestDistance then
        print(("%s: can't reach that height"):format(label))
        return
    end
    print(("%s: max %d blocks at %.1f deg (%.1fs)"):format(label, math.floor(bestDistance), bestPitch, bestAirtime / 20))

    local lobDistance = landingDistance(muzzleSpeed, MAXIMUM_PITCH, heightDifference)
    if lobDistance then
        print(("   high arcs possible from %d blocks"):format(math.floor(lobDistance)))
    end
end

---------------- ARGUMENTS ----------------
local chargeCount, powerPerCharge, propellantName = nil, POWER_PER_CARTRIDGE_LEVEL, "power"
local heightDifference = 0
local heightLabel = "same height"

for _, currentArgument in ipairs(arguments) do
    local cartridgeText = string.match(currentArgument, "^power=(%d+)$")
    if cartridgeText then
        chargeCount, powerPerCharge, propellantName = tonumber(cartridgeText), POWER_PER_CARTRIDGE_LEVEL, "power"
    end
    local powderText = string.match(currentArgument, "^charges=(%d+)$")
    if powderText then
        chargeCount, powerPerCharge, propellantName = tonumber(powderText), POWER_PER_POWDER_CHARGE, "charges"
    end
    local heightText = string.match(currentArgument, "^height=(%-?%d+)$")
    if heightText then
        heightDifference = tonumber(heightText)
        heightLabel = ("%+d blocks"):format(heightDifference)
    end
    local worldHeightText = string.match(currentArgument, "^y=(%-?%d+)$")
    if worldHeightText then
        local cannonMount = peripheral.find("cannon_mount")
        if not cannonMount then
            printError("y= needs the cannon mount connected. Use height= instead.")
            return
        end
        local cannonHeight = cannonMount.getInfo().y + HELD_BLOCK_HEIGHT_ABOVE_MOUNT
        heightDifference = tonumber(worldHeightText) - cannonHeight
        heightLabel = ("y=%s (%+d blocks)"):format(worldHeightText, heightDifference)
    end
end

---------------- OUTPUT ----------------
print("Target height: " .. heightLabel)
if chargeCount then
    printRangeLine(("%s=%d"):format(propellantName, chargeCount), chargeCount * powerPerCharge, heightDifference)
else
    for testedPower = 1, 4 do
        printRangeLine(("%s=%d"):format(propellantName, testedPower), testedPower * POWER_PER_CARTRIDGE_LEVEL, heightDifference)
    end
end