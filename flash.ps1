param (
    [string]$Port = "",
    [ValidateSet("core", "core2")]
    [string]$Board = "core2",
    [string]$BinDir = ""
)

$ErrorActionPreference = "Stop"

# Load settings from config.json if exists
$ConfigFile = Join-Path $PSScriptRoot "config.json"
$Config = if (Test-Path $ConfigFile) { Get-Content $ConfigFile | ConvertFrom-Json } else { @{} }

# Override Board if not specified in arguments but present in config
if (!$PSBoundParameters.ContainsKey('Board') -and $Config.Board) {
    $Board = $Config.Board
}

$BoardMap = @{
    core  = "m5stack:esp32:m5stack_core"
    core2 = "m5stack:esp32:m5stack_core2"
}

$FQBN = $BoardMap[$Board]
$SketchName = "M5Stack-SwitchController2CoREWirelessSender"

Write-Output "--- M5Stack Flash Script (Board: $Board) ---"
Write-Output "FQBN: $FQBN"

# Check arduino-cli
if (!(Get-Command "arduino-cli" -ErrorAction SilentlyContinue)) {
    Write-Error @"
arduino-cli not found.
Please install arduino-cli: https://arduino.github.io/arduino-cli/installation/
"@
    exit 1
}

# Determine BinDir
if ($BinDir -eq "") {
    $FqbnDir = $FQBN -replace ":", "."
    $DefaultBinDir = Join-Path $PSScriptRoot "build" $FqbnDir
    if (Test-Path $DefaultBinDir) {
        $BinDir = $DefaultBinDir
        Write-Output "Using default binary directory: $BinDir"
    } else {
        # Try to find any subdirectory under build/
        $BuildRoot = Join-Path $PSScriptRoot "build"
        if (Test-Path $BuildRoot) {
            $dirs = Get-ChildItem -Path $BuildRoot -Directory -ErrorAction SilentlyContinue
            if ($dirs.Count -gt 0) {
                $BinDir = $dirs[0].FullName
                Write-Output "Auto-detected binary directory: $BinDir"
            }
        }
    }
}

if ($BinDir -eq "" -or !(Test-Path $BinDir)) {
    Write-Error @"
No binary directory found.
Run '.\build.ps1 -ExportBinaries' first to build, or specify -BinDir with the path to your downloaded binaries.
Example: .\flash.ps1 -BinDir C:\Downloads\SwitchSender
"@
    exit 1
}

# Verify .bin file exists
$BinFile = ""
if (Test-Path $BinDir -PathType Leaf) {
    # Directly pointed to a file
    $BinFile = (Get-Item $BinDir).FullName
} else {
    # Search in directory
    $SketchBin = Join-Path $BinDir "$SketchName.ino.bin"
    if (Test-Path $SketchBin) {
        $BinFile = $SketchBin
    } else {
        Write-Output "Searching for .bin files in: $BinDir"
        $bins = Get-ChildItem -Path $BinDir -Filter "*.bin" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch "bootloader|partitions" }
        if ($bins.Count -eq 0) {
            Write-Error "No .bin file found in: $BinDir"
            Write-Output "Files in directory:"
            Get-ChildItem -Path $BinDir | Select-Object Name
            exit 1
        }
        $BinFile = $bins[0].FullName
    }
}

if ($BinFile -ne "") {
    Write-Output "Binary: $BinFile"
    
    # Check for related files (required for ESP32)
    $BaseName = $BinFile -replace "\.bin$", ""
    $BootFile = "$BaseName.bootloader.bin"
    $PartFile = "$BaseName.partitions.bin"
    
    if (!(Test-Path $BootFile) -or !(Test-Path $PartFile)) {
        Write-Warning "Missing bootloader or partitions file in the same directory."
        Write-Warning "Expected: $(Split-Path $BootFile -Leaf) and $(Split-Path $PartFile -Leaf)"
        Write-Warning "Uploading might fail if these are required for your board."
    }
} else {
    Write-Error "Could not determine binary file path."
    exit 1
}

# Detect COM port
if ($Port -eq "") {
    Write-Output "Detecting COM port..."
    $BoardListOutput = arduino-cli board list | Out-String
    Write-Output $BoardListOutput

    $Lines = $BoardListOutput -split "`r`n"
    foreach ($Line in $Lines) {
        if ($Line -match "(COM\d+)") {
            $Port = $matches[1]
            break
        }
    }
} else {
    Write-Output "Using specified port: $Port"
}

if ($Port -eq "") {
    Write-Error "No COM port found. Connect M5Stack and retry, or specify -Port."
    exit 1
}

Write-Output "Port: $Port"
Write-Output "Uploading pre-built binary..."

arduino-cli upload -p $Port --fqbn $FQBN --input-file $BinFile

if ($LASTEXITCODE -eq 0) {
    Write-Output "Upload successful!"
} else {
    Write-Output "Upload failed!"
    exit 1
}
