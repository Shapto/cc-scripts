-- install.lua - downloads programs from the cc-scripts repo
-- Usage: install <program>   e.g. "install cannon"
--        install list

local REPOSITORY_URL = "https://raw.githubusercontent.com/Shapto/cc-scripts/main/"

local PROGRAMS = {
    cannon = { "cannon/cannon.lua", "cannon/range.lua" },
    mechhud = { "mech/mechhud.lua" },
    geoscan = { "tools/geoscan.lua" },
}

local arguments = { ... }
local programName = arguments[1]

if not programName or programName == "list" then
    print("Available programs:")
    for availableName in pairs(PROGRAMS) do
        print("  " .. availableName)
    end
    return
end

local programFiles = PROGRAMS[programName]
if not programFiles then
    printError("Unknown program: " .. programName .. " (try 'install list')")
    return
end

for _, repositoryPath in ipairs(programFiles) do
    local fileName = fs.getName(repositoryPath)
    local response, errorMessage = http.get(REPOSITORY_URL .. repositoryPath)
    if not response then
        printError("Failed to download " .. repositoryPath .. ": " .. tostring(errorMessage))
    else
        local fileHandle = fs.open(fileName, "w")
        fileHandle.write(response.readAll())
        fileHandle.close()
        response.close()
        print("Installed " .. fileName)
    end
end
