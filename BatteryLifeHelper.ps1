[CmdletBinding()]
param(
    [ValidateSet('menu', 'status', 'optimize', 'restore', 'report', 'auto')]
    [string]$Action = 'menu',

    [ValidateSet('standard', 'aggressive', 'extreme')]
    [string]$Profile = 'standard',

    [ValidateRange(1, 60)]
    [int]$DisplayTimeoutMinutes = 3,

    [ValidateRange(1, 180)]
    [int]$SleepTimeoutMinutes = 10,

    [ValidateRange(5, 720)]
    [int]$HibernateTimeoutMinutes = 30,

    [ValidateRange(1, 120)]
    [int]$DiskTimeoutMinutes = 5,

    [ValidateRange(5, 100)]
    [int]$ProcessorMaxPercent = 60,

    [ValidateRange(5, 100)]
    [int]$AutoThresholdPercent = 35,

    [ValidateRange(15, 3600)]
    [int]$CheckIntervalSeconds = 60,

    [switch]$RunOnce
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$script:HelperPlanName = 'Codex Battery Saver'
$script:ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:StatePath = Join-Path $script:ScriptRoot 'battery-helper-state.json'
$script:ReportRoot = Join-Path $script:ScriptRoot 'reports'
$script:WirelessSubGroupGuid = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
$script:WirelessPowerModeGuid = '12bbebe6-58d6-4636-95bb-3217ef867c1a'
$script:DimmedBrightnessGuid = 'f1fbfde2-a960-4165-9f88-50667911ce96'
$script:UserProvidedParameters = @{} + $PSBoundParameters

function Write-Step {
    param([string]$Message)
    Write-Host "[*] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[+] $Message" -ForegroundColor Green
}

function Write-Note {
    param([string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Yellow
}

function Get-ProfileSettings {
    param([string]$SelectedProfile)

    switch ($SelectedProfile) {
        'standard' {
            return [pscustomobject]@{
                Profile                       = 'standard'
                DisplayTimeoutMinutes         = 3
                SleepTimeoutMinutes           = 10
                HibernateTimeoutMinutes       = 30
                DiskTimeoutMinutes            = 5
                ProcessorMinPercent           = 5
                ProcessorMaxPercent           = 60
                EnergyPreferencePercent       = 75
                ProcessorBoostMode            = 3
                CoolingPolicy                 = 0
                DisplayBrightnessPercent      = 40
                DimmedBrightnessPercent       = 20
                AdaptiveBrightnessEnabled     = 1
                WirelessPowerSavingMode       = 3
                PcieLinkStatePowerManagement  = 2
            }
        }
        'aggressive' {
            return [pscustomobject]@{
                Profile                       = 'aggressive'
                DisplayTimeoutMinutes         = 2
                SleepTimeoutMinutes           = 7
                HibernateTimeoutMinutes       = 15
                DiskTimeoutMinutes            = 3
                ProcessorMinPercent           = 5
                ProcessorMaxPercent           = 40
                EnergyPreferencePercent       = 85
                ProcessorBoostMode            = 3
                CoolingPolicy                 = 0
                DisplayBrightnessPercent      = 30
                DimmedBrightnessPercent       = 15
                AdaptiveBrightnessEnabled     = 1
                WirelessPowerSavingMode       = 3
                PcieLinkStatePowerManagement  = 2
            }
        }
        'extreme' {
            return [pscustomobject]@{
                Profile                       = 'extreme'
                DisplayTimeoutMinutes         = 1
                SleepTimeoutMinutes           = 5
                HibernateTimeoutMinutes       = 10
                DiskTimeoutMinutes            = 1
                ProcessorMinPercent           = 5
                ProcessorMaxPercent           = 30
                EnergyPreferencePercent       = 90
                ProcessorBoostMode            = 0
                CoolingPolicy                 = 0
                DisplayBrightnessPercent      = 25
                DimmedBrightnessPercent       = 10
                AdaptiveBrightnessEnabled     = 1
                WirelessPowerSavingMode       = 3
                PcieLinkStatePowerManagement  = 2
            }
        }
    }
}

function Resolve-OptimizationSettings {
    $settings = Get-ProfileSettings -SelectedProfile $Profile

    if ($script:UserProvidedParameters.ContainsKey('DisplayTimeoutMinutes')) {
        $settings.DisplayTimeoutMinutes = $DisplayTimeoutMinutes
    }

    if ($script:UserProvidedParameters.ContainsKey('SleepTimeoutMinutes')) {
        $settings.SleepTimeoutMinutes = $SleepTimeoutMinutes
    }

    if ($script:UserProvidedParameters.ContainsKey('HibernateTimeoutMinutes')) {
        $settings.HibernateTimeoutMinutes = $HibernateTimeoutMinutes
    }

    if ($script:UserProvidedParameters.ContainsKey('DiskTimeoutMinutes')) {
        $settings.DiskTimeoutMinutes = $DiskTimeoutMinutes
    }

    if ($script:UserProvidedParameters.ContainsKey('ProcessorMaxPercent')) {
        $settings.ProcessorMaxPercent = $ProcessorMaxPercent
    }

    return $settings
}

function Invoke-PowerCfg {
    param([string[]]$Arguments)

    $output = & powercfg @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $detail = ($output | ForEach-Object { $_.ToString().TrimEnd() } | Where-Object { $_ }) -join [Environment]::NewLine
        if (-not $detail) {
            $detail = 'powercfg returned a non-zero exit code.'
        }

        throw "powercfg $($Arguments -join ' ') failed.`n$detail"
    }

    return $output
}

function Get-GuidFromText {
    param([object[]]$Text)

    $joined = ($Text | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    $match = [regex]::Match($joined, '([a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12})')

    if (-not $match.Success) {
        throw 'Could not find a power plan GUID in the powercfg output.'
    }

    return $match.Groups[1].Value
}

function Get-SchemeInventory {
    $output = Invoke-PowerCfg @('/list')
    $schemes = @()

    foreach ($line in $output) {
        $match = [regex]::Match($line.ToString(), 'Power Scheme GUID:\s*([a-fA-F0-9\-]+)\s+\((.+)\)(\s+\*)?')
        if ($match.Success) {
            $schemes += [pscustomobject]@{
                Guid     = $match.Groups[1].Value
                Name     = $match.Groups[2].Value
                IsActive = $match.Groups[3].Success
            }
        }
    }

    return $schemes
}

function Get-ActiveScheme {
    $scheme = Get-SchemeInventory | Where-Object { $_.IsActive } | Select-Object -First 1

    if (-not $scheme) {
        throw 'Could not determine the active Windows power plan.'
    }

    return $scheme
}

function Get-State {
    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Note 'The saved state file could not be read, so it will be ignored.'
        return $null
    }
}

function Save-State {
    param([pscustomobject]$State)

    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
}

function Remove-State {
    if (Test-Path -LiteralPath $script:StatePath) {
        Remove-Item -LiteralPath $script:StatePath -Force
    }
}

function Format-RemainingTime {
    param([int]$Seconds)

    if ($Seconds -lt 0) {
        return 'Unknown'
    }

    $time = [TimeSpan]::FromSeconds($Seconds)
    if ($time.TotalHours -ge 1) {
        return ('{0}h {1}m' -f [math]::Floor($time.TotalHours), $time.Minutes)
    }

    return ('{0}m' -f [math]::Max(1, $time.Minutes))
}

function Format-ChargeStatus {
    param([object]$RawStatus)

    $value = [int]$RawStatus
    if ($value -eq 0) {
        return 'Normal'
    }

    $labels = @()
    if ($value -band 1) { $labels += 'High' }
    if ($value -band 2) { $labels += 'Low' }
    if ($value -band 4) { $labels += 'Critical' }
    if ($value -band 8) { $labels += 'Charging' }
    if ($value -band 128) { $labels += 'No battery detected' }
    if ($value -eq 255) { $labels += 'Unknown' }

    if (-not $labels) {
        return $value.ToString()
    }

    return ($labels -join ', ')
}

function Set-OptionalDcValue {
    param(
        [string]$SubGroup,
        [string]$Setting,
        [string]$Value,
        [string]$Label
    )

    try {
        Invoke-PowerCfg @('/setdcvalueindex', 'SCHEME_CURRENT', $SubGroup, $Setting, $Value) | Out-Null
    }
    catch {
        Write-Note "Skipped $Label because Windows rejected that power setting on this laptop."
    }
}

function Get-PowerStatus {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop | Out-Null
        $status = [System.Windows.Forms.SystemInformation]::PowerStatus
        $powerLine = $status.PowerLineStatus.ToString()

        return [pscustomobject]@{
            PowerLineStatus = $powerLine
            BatteryPercent  = if ($status.BatteryLifePercent -ge 0) { [math]::Round($status.BatteryLifePercent * 100) } else { $null }
            Remaining       = if ($powerLine -eq 'Online') { 'Plugged in' } else { Format-RemainingTime -Seconds $status.BatteryLifeRemaining }
            ChargeStatus    = Format-ChargeStatus -RawStatus $status.BatteryChargeStatus
        }
    }
    catch {
        return [pscustomobject]@{
            PowerLineStatus = 'Unknown'
            BatteryPercent  = $null
            Remaining       = 'Unknown'
            ChargeStatus    = 'Unknown'
        }
    }
}

function Get-WatcherSnapshot {
    $power = Get-PowerStatus
    $active = Get-ActiveScheme
    $state = Get-State

    return [pscustomobject]@{
        Power        = $power
        ActiveScheme = $active
        State        = $state
        HelperActive = ($active.Name -eq $script:HelperPlanName)
    }
}

function Show-Status {
    $power = Get-PowerStatus
    $active = Get-ActiveScheme
    $state = Get-State
    $schemes = Get-SchemeInventory

    $restoreSummary = 'None saved yet'
    $savedProfile = 'None saved yet'
    if ($state) {
        $restorePlan = $schemes | Where-Object { $_.Guid -eq $state.previousSchemeGuid } | Select-Object -First 1
        if ($restorePlan) {
            $restoreSummary = $restorePlan.Name
        }
        elseif ($state.previousSchemeName) {
            $restoreSummary = "$($state.previousSchemeName) (missing)"
        }

        if ($state.profile) {
            $savedProfile = $state.profile
        }
    }

    $pluggedIn = switch ($power.PowerLineStatus) {
        'Online'  { 'Yes' }
        'Offline' { 'No' }
        default   { 'Unknown' }
    }

    $batteryLevel = if ($null -ne $power.BatteryPercent) { "$($power.BatteryPercent)%" } else { 'Unknown' }
    $helperPlanActive = if ($active.Name -eq $script:HelperPlanName) { 'Yes' } else { 'No' }

    Write-Host ''
    Write-Host 'Battery Life Helper Status' -ForegroundColor White
    Write-Host '--------------------------' -ForegroundColor DarkGray
    Write-Host ('Active power plan : {0}' -f $active.Name)
    Write-Host ('Helper plan active: {0}' -f $helperPlanActive)
    Write-Host ('Plugged in        : {0}' -f $pluggedIn)
    Write-Host ('Battery level     : {0}' -f $batteryLevel)
    Write-Host ('Time remaining    : {0}' -f $power.Remaining)
    Write-Host ('Charge state      : {0}' -f $power.ChargeStatus)
    Write-Host ('Saved profile     : {0}' -f $savedProfile)
    Write-Host ('Restore point     : {0}' -f $restoreSummary)
    Write-Host ''
}

function Apply-BatteryTuning {
    param([pscustomobject]$Settings)

    Write-Step 'Applying battery-friendly settings to the temporary power plan.'
    Invoke-PowerCfg @('/change', 'monitor-timeout-dc', $Settings.DisplayTimeoutMinutes) | Out-Null
    Invoke-PowerCfg @('/change', 'standby-timeout-dc', $Settings.SleepTimeoutMinutes) | Out-Null
    Invoke-PowerCfg @('/change', 'hibernate-timeout-dc', $Settings.HibernateTimeoutMinutes) | Out-Null
    Invoke-PowerCfg @('/change', 'disk-timeout-dc', $Settings.DiskTimeoutMinutes) | Out-Null
    Set-OptionalDcValue -SubGroup 'SUB_PROCESSOR' -Setting 'PROCTHROTTLEMIN' -Value $Settings.ProcessorMinPercent -Label 'minimum processor state'
    Set-OptionalDcValue -SubGroup 'SUB_PROCESSOR' -Setting 'PROCTHROTTLEMAX' -Value $Settings.ProcessorMaxPercent -Label 'maximum processor state'
    Set-OptionalDcValue -SubGroup 'SUB_PROCESSOR' -Setting 'PERFEPP' -Value $Settings.EnergyPreferencePercent -Label 'processor energy preference'
    Set-OptionalDcValue -SubGroup 'SUB_PROCESSOR' -Setting 'PERFBOOSTMODE' -Value $Settings.ProcessorBoostMode -Label 'processor boost mode'
    Set-OptionalDcValue -SubGroup 'SUB_PROCESSOR' -Setting 'SYSCOOLPOL' -Value $Settings.CoolingPolicy -Label 'system cooling policy'
    Set-OptionalDcValue -SubGroup 'SUB_VIDEO' -Setting 'VIDEONORMALLEVEL' -Value $Settings.DisplayBrightnessPercent -Label 'display brightness'
    Set-OptionalDcValue -SubGroup 'SUB_VIDEO' -Setting $script:DimmedBrightnessGuid -Value $Settings.DimmedBrightnessPercent -Label 'dimmed display brightness'
    Set-OptionalDcValue -SubGroup 'SUB_VIDEO' -Setting 'ADAPTBRIGHT' -Value $Settings.AdaptiveBrightnessEnabled -Label 'adaptive brightness'
    Set-OptionalDcValue -SubGroup 'SUB_PCIEXPRESS' -Setting 'ASPM' -Value $Settings.PcieLinkStatePowerManagement -Label 'PCIe link state power management'
    Set-OptionalDcValue -SubGroup $script:WirelessSubGroupGuid -Setting $script:WirelessPowerModeGuid -Value $Settings.WirelessPowerSavingMode -Label 'wireless adapter power saving'
    Invoke-PowerCfg @('/setactive', 'SCHEME_CURRENT') | Out-Null
}

function Optimize-BatteryLife {
    $settings = Resolve-OptimizationSettings
    $state = Get-State
    $schemes = Get-SchemeInventory

    if ($state) {
        $existingHelper = $schemes | Where-Object { $_.Guid -eq $state.optimizedSchemeGuid } | Select-Object -First 1
        if ($existingHelper) {
            Write-Step "Reusing the saved helper plan '$($existingHelper.Name)' with the '$($settings.Profile)' profile."
            Invoke-PowerCfg @('/setactive', $existingHelper.Guid) | Out-Null
            Apply-BatteryTuning -Settings $settings
            Save-State ([pscustomobject]@{
                    previousSchemeGuid  = $state.previousSchemeGuid
                    previousSchemeName  = $state.previousSchemeName
                    optimizedSchemeGuid = $existingHelper.Guid
                    optimizedSchemeName = $script:HelperPlanName
                    createdAt           = $state.createdAt
                    profile             = $settings.Profile
                    settings            = $settings
                })
            Write-Success 'Battery saver plan is active.'
            Show-Status
            return
        }
    }

    $active = Get-ActiveScheme
    if ($active.Name -eq $script:HelperPlanName) {
        throw "The helper plan is already active, but the restore state is missing. Switch to another plan in Windows first, then retry."
    }

    $namedHelper = $schemes | Where-Object { $_.Name -eq $script:HelperPlanName } | Select-Object -First 1
    if ($namedHelper) {
        if ($namedHelper.IsActive) {
            throw "A plan named '$($script:HelperPlanName)' is already active. Restore it manually from Windows power settings before retrying."
        }

        Write-Step 'Removing an older helper plan before creating a fresh copy.'
        Invoke-PowerCfg @('/delete', $namedHelper.Guid) | Out-Null
    }

    Write-Step "Duplicating the current power plan '$($active.Name)' for the '$($settings.Profile)' profile."
    try {
        $duplicateOutput = Invoke-PowerCfg @('/duplicatescheme', $active.Guid)
    }
    catch {
        throw "Windows refused to duplicate the current power plan. $($_.Exception.Message)"
    }
    $newGuid = Get-GuidFromText -Text $duplicateOutput

    Invoke-PowerCfg @('/changename', $newGuid, $script:HelperPlanName, 'Temporary battery-friendly plan created by Battery Life Helper') | Out-Null
    Invoke-PowerCfg @('/setactive', $newGuid) | Out-Null
    Apply-BatteryTuning -Settings $settings

    Save-State ([pscustomobject]@{
            previousSchemeGuid  = $active.Guid
            previousSchemeName  = $active.Name
            optimizedSchemeGuid = $newGuid
            optimizedSchemeName = $script:HelperPlanName
            createdAt           = (Get-Date).ToString('o')
            profile             = $settings.Profile
            settings            = $settings
        })

    Write-Success "Battery saver plan created and activated using the '$($settings.Profile)' profile."
    Show-Status
}

function Restore-PreviousPlan {
    $state = Get-State
    if (-not $state) {
        Write-Note 'No saved battery-saver state was found, so there is nothing to restore.'
        Show-Status
        return
    }

    $schemes = Get-SchemeInventory
    $originalPlan = $schemes | Where-Object { $_.Guid -eq $state.previousSchemeGuid } | Select-Object -First 1

    if (-not $originalPlan) {
        Write-Note "The original plan '$($state.previousSchemeName)' is missing, so the helper plan cannot be restored automatically."
        Write-Note 'The saved state file has been kept in case you want to fix the plan manually and try again.'
        Show-Status
        return
    }

    Write-Step "Switching back to '$($originalPlan.Name)'."
    Invoke-PowerCfg @('/setactive', $originalPlan.Guid) | Out-Null

    $helperPlan = (Get-SchemeInventory) | Where-Object { $_.Guid -eq $state.optimizedSchemeGuid } | Select-Object -First 1
    if ($helperPlan) {
        Write-Step 'Removing the temporary helper power plan.'
        Invoke-PowerCfg @('/delete', $helperPlan.Guid) | Out-Null
    }

    Remove-State
    Write-Success 'Original power plan restored.'
    Show-Status
}

function New-Reports {
    if (-not (Test-Path -LiteralPath $script:ReportRoot)) {
        New-Item -ItemType Directory -Path $script:ReportRoot | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $batteryReport = Join-Path $script:ReportRoot "battery-report-$timestamp.html"
    $energyReport = Join-Path $script:ReportRoot "energy-report-$timestamp.html"

    Write-Step 'Generating a battery usage report.'
    Invoke-PowerCfg @('/batteryreport', '/output', $batteryReport) | Out-Null
    if (-not (Test-Path -LiteralPath $batteryReport)) {
        throw "powercfg reported success, but the battery report file was not created at $batteryReport"
    }
    Write-Success "Battery report saved to $batteryReport"

    try {
        Write-Step 'Generating a short energy efficiency report.'
        Invoke-PowerCfg @('/energy', '/duration', '10', '/output', $energyReport) | Out-Null
        if (Test-Path -LiteralPath $energyReport) {
            Write-Success "Energy report saved to $energyReport"
        }
        else {
            Write-Note 'The energy report command finished, but no HTML file was created.'
        }
    }
    catch {
        Write-Note 'The battery report was created, but the energy report could not be generated in this session.'
        Write-Note $_.Exception.Message
    }
}

function Start-AutoMode {
    Write-Host ''
    Write-Host 'Battery Auto Mode' -ForegroundColor White
    Write-Host '-----------------' -ForegroundColor DarkGray
    Write-Host ('Profile          : {0}' -f $Profile)
    Write-Host ('Trigger threshold: {0}%' -f $AutoThresholdPercent)
    Write-Host ('Check interval   : {0} seconds' -f $CheckIntervalSeconds)
    if ($RunOnce) {
        Write-Host 'Watcher mode     : Run once'
    }
    else {
        Write-Host 'Watcher mode     : Continuous'
        Write-Host 'Stop watcher     : Press Ctrl+C'
    }
    Write-Host ''

    $lastMode = $null

    while ($true) {
        $snapshot = Get-WatcherSnapshot
        $power = $snapshot.Power
        $batteryLevel = if ($null -ne $power.BatteryPercent) { $power.BatteryPercent } else { $null }

        if ($power.PowerLineStatus -eq 'Online') {
            if ($snapshot.HelperActive -and $snapshot.State) {
                Write-Step 'Laptop is plugged in, so the original power plan will be restored.'
                Restore-PreviousPlan
                $lastMode = 'charging-restored'
            }
            elseif ($snapshot.HelperActive -and -not $snapshot.State) {
                if ($lastMode -ne 'charging-helper-without-state') {
                    Write-Note 'The helper plan is active, but no restore state is saved. Restore manually before using auto mode.'
                    $lastMode = 'charging-helper-without-state'
                }
            }
            elseif ($lastMode -ne 'charging-monitor') {
                Write-Step 'Laptop is plugged in. Auto mode is waiting for battery use.'
                $lastMode = 'charging-monitor'
            }
        }
        elseif ($power.PowerLineStatus -eq 'Offline') {
            if ($null -eq $batteryLevel) {
                if ($lastMode -ne 'battery-unknown') {
                    Write-Note 'Battery percentage could not be read yet, so auto mode is waiting.'
                    $lastMode = 'battery-unknown'
                }
            }
            elseif ($batteryLevel -le $AutoThresholdPercent) {
                if (-not $snapshot.HelperActive) {
                    Write-Step ("Battery is at {0}%, so the '{1}' saver profile will be enabled." -f $batteryLevel, $Profile)
                    Optimize-BatteryLife
                    $lastMode = 'optimized'
                }
                elseif ($lastMode -ne 'optimized-active') {
                    Write-Step ("Battery saver is already active at {0}% battery." -f $batteryLevel)
                    $lastMode = 'optimized-active'
                }
            }
            elseif ($lastMode -ne 'battery-monitor') {
                Write-Step ("Battery is at {0}%. Auto mode will switch at {1}%." -f $batteryLevel, $AutoThresholdPercent)
                $lastMode = 'battery-monitor'
            }
        }
        elseif ($lastMode -ne 'power-unknown') {
            Write-Note 'Power source could not be determined, so auto mode is waiting.'
            $lastMode = 'power-unknown'
        }

        if ($RunOnce) {
            break
        }

        Start-Sleep -Seconds $CheckIntervalSeconds
    }
}

function Show-Menu {
    Write-Host ''
    Write-Host 'Battery Life Helper' -ForegroundColor White
    Write-Host '--------------------' -ForegroundColor DarkGray
    Write-Host '1. Show battery status'
    Write-Host ("2. Turn on battery saver plan ({0} profile)" -f $Profile)
    Write-Host '3. Restore previous power plan'
    Write-Host '4. Generate battery and energy reports'
    Write-Host ("5. Start auto mode ({0}% trigger, {1} profile)" -f $AutoThresholdPercent, $Profile)
    Write-Host '6. Exit'
    Write-Host ''

    $choice = Read-Host 'Choose an option'
    switch ($choice) {
        '1' { Show-Status }
        '2' { Optimize-BatteryLife }
        '3' { Restore-PreviousPlan }
        '4' { New-Reports }
        '5' { Start-AutoMode }
        '6' { return }
        default { Write-Note 'That option was not recognized.' }
    }
}

try {
    switch ($Action) {
        'menu'     { Show-Menu }
        'status'   { Show-Status }
        'optimize' { Optimize-BatteryLife }
        'restore'  { Restore-PreviousPlan }
        'report'   { New-Reports }
        'auto'     { Start-AutoMode }
    }
}
catch {
    Write-Host ''
    Write-Host "Battery Life Helper could not complete the '$Action' action." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Tip: if Windows blocks power-plan changes, reopen PowerShell as Administrator and try again.' -ForegroundColor DarkYellow
    exit 1
}
