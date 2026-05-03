param (
    [string]$Port = "",
    [ValidateSet("core", "core2", "cores3")]
    [string]$Board = "core2",
    [ValidateRange(1, 3)]
    [int]$SsChannel = 1,
    [ValidateRange(1, 2)]
    [int]$IntChannel = 1,
    [switch]$SkipUpload,
    [switch]$ExportBinaries
)

$ErrorActionPreference = "Stop"

# Load settings from config.json if exists
$ConfigFile = Join-Path $PSScriptRoot "config.json"
$Config = if (Test-Path $ConfigFile) { Get-Content $ConfigFile | ConvertFrom-Json } else { @{} }

# Override Board if not specified in arguments but present in config
if (!$PSBoundParameters.ContainsKey('Board') -and $Config.Board) {
    $Board = $Config.Board
}

$CoreVersion = "3.2.5"
$BoardMap = @{
    core   = "m5stack:esp32:m5stack_core"
    core2  = "m5stack:esp32:m5stack_core2"
    cores3 = "m5stack:esp32:m5stack_cores3"
}

$SsPinMap = @{
    core   = @(13, 5, 0)
    core2  = @(19, 33, 0)
    cores3 = @(1)           # DIP SW CH1 -> GPIO 1
}
$IntPinMap = @{
    core   = @(35, 34)
    core2  = @(35, 34)
    cores3 = @(10)          # DIP SW CH1 -> GPIO 10
}
$MisoPinMap = @{
    core   = 19
    core2  = 38
    cores3 = 35
}
$SckPinMap = @{
    core   = 18
    core2  = 18
    cores3 = 36
}
$MosiPinMap = @{
    core   = 23
    core2  = 23
    cores3 = 37
}
$UartPinMap = @{
    core   = @(16, 17) # RX, TX
    core2  = @(13, 14) # RX, TX (Port C)
    cores3 = @(18, 17) # RX, TX (Port C)
}

$FQBN = $BoardMap[$Board]
$SketchName = "M5Stack-SwitchController2CoREWirelessSender.ino"

# Validate channel range per board
$MaxSsCh = $SsPinMap[$Board].Count
$MaxIntCh = $IntPinMap[$Board].Count
if ($SsChannel -gt $MaxSsCh) {
    throw "Board '$Board' supports SS CH1-$MaxSsCh only. Got SS CH$SsChannel."
}
if ($IntChannel -gt $MaxIntCh) {
    throw "Board '$Board' supports INT CH1-$MaxIntCh only. Got INT CH$IntChannel."
}

$SelectedSsGpio = $SsPinMap[$Board][$SsChannel - 1]
$SelectedIntGpio = $IntPinMap[$Board][$IntChannel - 1]
$SelectedMisoGpio = $MisoPinMap[$Board]
$SelectedSckGpio = $SckPinMap[$Board]
$SelectedMosiGpio = $MosiPinMap[$Board]
$SelectedUartRxGpio = $UartPinMap[$Board][0]
$SelectedUartTxGpio = $UartPinMap[$Board][1]

# Set Arduino directory (priority: config.json > default)
$DefaultArduinoDir = Join-Path $HOME "Documents/Arduino"
$UserArduinoDir = if ($Config.ArduinoDir) { $Config.ArduinoDir } else { $DefaultArduinoDir }

$UserLibrariesDir = Join-Path $UserArduinoDir "libraries"
$UsbHostShieldDir = Join-Path $UserLibrariesDir "USB_Host_Shield_Library_2.0"

Write-Output "--- M5Stack Build Script (Core v$CoreVersion / Board: $Board) ---"
Write-Output "USB Module DIP: SS CH$SsChannel (GPIO$SelectedSsGpio), INT CH$IntChannel (GPIO$SelectedIntGpio)"
Write-Output "SPI: SCK=$SelectedSckGpio MOSI=$SelectedMosiGpio MISO=$SelectedMisoGpio"
Write-Output "UART(Serial2): RX=$SelectedUartRxGpio TX=$SelectedUartTxGpio"
Write-Output "Using user library root: $UserLibrariesDir"

function Install-M5StackCore {
    param([string]$Version)
    Write-Output "Checking Core m5stack:esp32@$Version..."
    $CoreList = arduino-cli core list | Out-String
    if ($CoreList -match "m5stack:esp32\s+$Version") {
        Write-Output "Core $Version already installed."
        return
    }

    Write-Output "Installing Core..."
    arduino-cli core update-index
    arduino-cli core install m5stack:esp32@$Version
}

function Install-Library {
    param(
        [string]$LibraryName,
        [string]$ExpectedDir
    )

    if (Test-Path $ExpectedDir) {
        Write-Output "Library $LibraryName found: $ExpectedDir"
        return
    }

    Write-Output "Library $LibraryName not found in Documents/Arduino. Installing..."
    arduino-cli lib install "$LibraryName"

    if (!(Test-Path $ExpectedDir)) {
        throw "Library $LibraryName was installed but not found at: $ExpectedDir"
    }

    Write-Output "Library $LibraryName installed: $ExpectedDir"
}

function Update-UsbHostShieldLibrary {
    param([string]$LibDir)

    $avrPinsPath = Join-Path $LibDir "avrpins.h"
    $usbCorePath = Join-Path $LibDir "UsbCore.h"

    if (!(Test-Path $avrPinsPath)) {
        throw "avrpins.h not found: $avrPinsPath"
    }
    if (!(Test-Path $usbCorePath)) {
        throw "UsbCore.h not found: $usbCorePath"
    }

    $avrPinsText = Get-Content -Path $avrPinsPath -Raw
    $avrPinsModified = $false

    # --- Patch 1: Core/Core2 用ピン (ESP32 汎用ブロックに挿入) ---
    # コメントは除いて MAKE_PIN(Pxx, nn) のみで存在確認する
    $esp32PinDefs = @(
        @{ Pin = "P13"; Num = 13; Comment = "Extra SS for M5Stack Core" },
        @{ Pin = "P33"; Num = 33; Comment = "Extra SS for M5Stack Core2" },
        @{ Pin = "P34"; Num = 34; Comment = "Extra INT for M5Stack Core/Core2" },
        @{ Pin = "P35"; Num = 35; Comment = "Extra INT for M5Stack Core/Core2" },
        @{ Pin = "P38"; Num = 38; Comment = "Core2 MISO" }
    )

    $missingEsp32Pins = @()
    foreach ($def in $esp32PinDefs) {
        $pattern = "MAKE_PIN\($($def.Pin),\s*$($def.Num)\)"
        if ($avrPinsText -notmatch $pattern) {
            $missingEsp32Pins += "MAKE_PIN($($def.Pin), $($def.Num)); // $($def.Comment)"
        }
    }

    if ($missingEsp32Pins.Count -gt 0) {
        # ESP32 汎用ブロックの末尾マーカー (MAKE_PIN(P17, 17); // INT) の後に挿入
        $esp32MarkerPattern = 'MAKE_PIN\(P17,\s*17\);\s*// INT'
        $esp32Regex = [regex]$esp32MarkerPattern
        if (!$esp32Regex.IsMatch($avrPinsText)) {
            throw "Could not find ESP32 insertion marker in avrpins.h: $esp32MarkerPattern"
        }
        $insertion = ($missingEsp32Pins -join "`r`n")
        $avrPinsText = $esp32Regex.Replace($avrPinsText, { param($m) $m.Value + "`r`n" + $insertion }, 1)
        $avrPinsModified = $true
        Write-Output "Patched avrpins.h with missing Core/Core2 pin aliases."
    }

    # --- Patch 2: CoreS3 用 P10 (CORES3 専用ブロックに挿入) ---
    # ライブラリが新しく ARDUINO_M5STACK_CORES3 専用ブロックを持つ場合のみ処理する。
    # 古いバージョンでは CoreS3 も ESP32 汎用ブロックで処理されるため、
    # そのケースでは P10 は ESP32 ブロックにすでに存在し、追加不要。
    if ($avrPinsText -match '#elif defined\(ARDUINO_M5STACK_CORES3\)') {
        $coreS3P10Pattern = 'MAKE_PIN\(P10,\s*10\)'
        $coreS3BlockPattern = '(?s)(?<=#elif defined\(ARDUINO_M5STACK_CORES3\)).*?(?=#elif|#else|#endif|\z)'
        $coreS3Block = [regex]::Match($avrPinsText, $coreS3BlockPattern)
        $p10InCoreS3 = $coreS3Block.Success -and ($coreS3Block.Value -match $coreS3P10Pattern)

        if (!$p10InCoreS3) {
            # CORES3 ブロックの末尾マーカー (MAKE_PIN(P14, 14); // INT) の後に挿入
            $coreS3MarkerPattern = 'MAKE_PIN\(P14,\s*14\);\s*// INT'
            $coreS3Regex = [regex]$coreS3MarkerPattern
            if ($coreS3Regex.IsMatch($avrPinsText)) {
                $p10Line = "MAKE_PIN(P10, 10); // CoreS3 INT CH1"
                $avrPinsText = $coreS3Regex.Replace($avrPinsText, { param($m) $m.Value + "`r`n" + $p10Line }, 1)
                $avrPinsModified = $true
                Write-Output "Patched avrpins.h with CoreS3 P10 pin alias."
            }
            else {
                Write-Output "Warning: ARDUINO_M5STACK_CORES3 block found but no P14 marker. Skipping P10 patch (ESP32 block will be used as fallback)."
            }
        }
    }
    else {
        Write-Output "No ARDUINO_M5STACK_CORES3 block in avrpins.h. P10 provided by ESP32 block."
    }

    if ($avrPinsModified) {
        Set-Content -Path $avrPinsPath -Value $avrPinsText -Encoding UTF8
    }
    else {
        Write-Output "avrpins.h already up to date."
    }

    # --- Patch 3: UsbCore.h (CoreS3 / ESP32 両ブロックに #ifndef ガードを追加) ---
    $usbCoreText = Get-Content -Path $usbCorePath -Raw
    if ($usbCoreText -notmatch "USB_HOST_SHIELD_SS_TYPE") {
        $needleCoreS3 = "typedef MAX3421e<P1, P14> MAX3421E; // M5Stack Core S3"
        $replacementCoreS3 = @"
#ifndef USB_HOST_SHIELD_SS_TYPE
#define USB_HOST_SHIELD_SS_TYPE P1
#endif
#ifndef USB_HOST_SHIELD_INT_TYPE
#define USB_HOST_SHIELD_INT_TYPE P14
#endif
typedef MAX3421e<USB_HOST_SHIELD_SS_TYPE, USB_HOST_SHIELD_INT_TYPE> MAX3421E; // M5Stack Core S3 (customizable)
"@
        $needleEsp32 = "typedef MAX3421e<P5, P17> MAX3421E; // ESP32 boards"
        $replacementEsp32 = @"
#ifndef USB_HOST_SHIELD_SS_TYPE
#define USB_HOST_SHIELD_SS_TYPE P5
#endif
#ifndef USB_HOST_SHIELD_INT_TYPE
#define USB_HOST_SHIELD_INT_TYPE P17
#endif
typedef MAX3421e<USB_HOST_SHIELD_SS_TYPE, USB_HOST_SHIELD_INT_TYPE> MAX3421E; // ESP32 boards (customizable)
"@
        $patched = $false
        if ($usbCoreText.Contains($needleCoreS3)) {
            $usbCoreText = $usbCoreText.Replace($needleCoreS3, $replacementCoreS3.Trim())
            $patched = $true
        }
        if ($usbCoreText.Contains($needleEsp32)) {
            $usbCoreText = $usbCoreText.Replace($needleEsp32, $replacementEsp32.Trim())
            $patched = $true
        }
        if ($patched) {
            Set-Content -Path $usbCorePath -Value $usbCoreText -Encoding UTF8
            Write-Output "Patched UsbCore.h for customizable ESP32/CoreS3 SS/INT pins."
        }
        else {
            throw "Expected ESP32/CoreS3 typedef was not found in UsbCore.h"
        }
    }
    else {
        Write-Output "UsbCore.h already patched."
    }
}

# 1. Core
Install-M5StackCore -Version $CoreVersion

# 2. Libraries (Documents/Arduino 配下を必須にする)
if (!(Test-Path $UserLibrariesDir)) {
    New-Item -ItemType Directory -Path $UserLibrariesDir | Out-Null
}

Install-Library -LibraryName "M5Unified" -ExpectedDir (Join-Path $UserLibrariesDir "M5Unified")
Install-Library -LibraryName "USB Host Shield Library 2.0" -ExpectedDir $UsbHostShieldDir
Update-UsbHostShieldLibrary -LibDir $UsbHostShieldDir

# 3. Compile
Write-Output "Compiling $SketchName..."
Write-Output "FQBN: $FQBN"

$SsType = "P$SelectedSsGpio"
$IntType = "P$SelectedIntGpio"

$ExtraFlags = @(
    "-DESP32",
    "-DUSB_HOST_SHIELD_SS_TYPE=$SsType",
    "-DUSB_HOST_SHIELD_INT_TYPE=$IntType",
    "-DPIN_SPI_SCK=$SelectedSckGpio",
    "-DPIN_SPI_MOSI=$SelectedMosiGpio",
    "-DPIN_SPI_MISO=$SelectedMisoGpio",
    "-DPIN_SPI_SS=$SelectedSsGpio",
    "-DUSB_MODULE_SS_CH=$SsChannel",
    "-DUSB_MODULE_INT_CH=$IntChannel",
    "-DUSB_HOST_SHIELD_SS_GPIO=$SelectedSsGpio",
    "-DUSB_HOST_SHIELD_INT_GPIO=$SelectedIntGpio",
    "-DSERIAL2_RX_PIN=$SelectedUartRxGpio",
    "-DSERIAL2_TX_PIN=$SelectedUartTxGpio"
) -join " "

Write-Output "Build flags: $ExtraFlags"

$CompileArgs = @(
    "compile",
    "--fqbn", $FQBN,
    "--libraries", $UserLibrariesDir,
    "--build-property", "build.extra_flags=$ExtraFlags"
)
if ($ExportBinaries) {
    $CompileArgs += "--export-binaries"
    Write-Output "ExportBinaries: enabled"
}
$CompileArgs += "."

& arduino-cli @CompileArgs

if ($LASTEXITCODE -ne 0) {
    Write-Output "Build failed!"
    exit 1
}
Write-Output "Build successful!"

# 4. Export binaries (--export-binaries)
if ($ExportBinaries) {
    $FqbnDir = $FQBN -replace ":", "."
    $BuildOutputDir = Join-Path $PSScriptRoot "build" $FqbnDir
    Write-Output ""
    Write-Output "--- Export Binaries ---"
    Write-Output "Output directory: $BuildOutputDir"
    $BinFiles = Get-ChildItem -Path $BuildOutputDir -Filter "*.bin" -ErrorAction SilentlyContinue
    if ($BinFiles) {
        foreach ($f in $BinFiles) {
            Write-Output "  $($f.FullName)"
        }
    }
    Write-Output "ExportBinaries: done. Skipping upload."
    exit 0
}

# 5. Upload
if ($SkipUpload) {
    Write-Output "SkipUpload specified. Build only."
    exit 0
}

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
}
else {
    Write-Output "Using specified port: $Port"
}

if ($Port) {
    Write-Output "Found port: $Port"
    Write-Output "Uploading to $Port..."
    arduino-cli upload -p $Port --fqbn $FQBN .

    if ($LASTEXITCODE -eq 0) {
        Write-Output "Upload successful!"
    }
    else {
        Write-Output "Upload failed!"
        exit 1
    }
}
else {
    Write-Output "No COM port found. Connect M5Stack and retry."
    exit 1
}
