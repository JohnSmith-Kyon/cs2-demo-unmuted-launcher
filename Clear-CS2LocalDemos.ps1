[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Alias('List')]
    [switch]$ListOnly,

    [switch]$Yes,

    [switch]$Permanent,

    [switch]$IncludeCache
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$LauncherName = 'CS2DemoUnmutedLauncher'
$DemoPattern = '*demo_unmuted_*'
$DemoNameRegex = '^(?:demo_unmuted_[0-9a-f]{16}\.dem|\.demo_unmuted_[0-9a-f]{16}\.dem\.pending-[0-9a-f]{32}(?:\.partial)?)$'
$CfgPattern = 'cs2_demo_unmuted_*.cfg'
$CfgNameRegex = '^cs2_demo_unmuted_[0-9a-f]{16}\.cfg$'
$LauncherMutexName = 'Local\CS2DemoUnmutedLauncher-v1'

function Write-Step {
    param([string]$Message)
    Write-Host ("[CS2 Demo Cleanup] {0}" -f $Message) -ForegroundColor Cyan
}

function Get-NormalizedPath {
    param([string]$LiteralPath)

    return [IO.Path]::GetFullPath($LiteralPath).TrimEnd([char[]]@('\', '/'))
}

function Assert-ExactPath {
    param(
        [string]$Actual,
        [string]$Expected,
        [string]$Description
    )

    $actualPath = Get-NormalizedPath -LiteralPath $Actual
    $expectedPath = Get-NormalizedPath -LiteralPath $Expected
    if (-not $actualPath.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing an unexpected $Description path: $actualPath"
    }
}

function Assert-SafeLeafFile {
    param(
        [IO.FileInfo]$Item,
        [string]$ExpectedParent,
        [string]$ExpectedNameRegex,
        [string]$Description
    )

    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing a reparse-point $Description file: $($Item.FullName)"
    }

    $parentItem = Get-Item -LiteralPath $ExpectedParent -Force -ErrorAction Stop
    if (-not $parentItem.PSIsContainer -or
        ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing an unsafe $Description parent directory: $ExpectedParent"
    }

    Assert-ExactPath -Actual $Item.Directory.FullName -Expected $ExpectedParent -Description "$Description parent"
    $regexOptions = [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    if (-not [regex]::IsMatch($Item.Name, $ExpectedNameRegex, $regexOptions)) {
        throw "Refusing an unexpected $Description file: $($Item.FullName)"
    }
}

function Get-SafeDirectoryStats {
    param([string]$LiteralPath)

    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($LiteralPath)
    [UInt64]$fileCount = 0
    [UInt64]$totalBytes = 0

    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $currentItem = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (-not $currentItem.PSIsContainer) {
            throw "Expected a directory but found a file: $current"
        }
        if (($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing a launcher-owned directory tree containing a reparse point: $current"
        }

        foreach ($child in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing a launcher-owned directory tree containing a reparse point: $($child.FullName)"
            }

            if ($child.PSIsContainer) {
                $pending.Push($child.FullName)
            }
            else {
                $fileCount++
                $totalBytes += [UInt64]$child.Length
            }
        }
    }

    return [PSCustomObject]@{
        FileCount = $fileCount
        TotalBytes = $totalBytes
    }
}

function Find-SteamAndCs2 {
    $steamRoots = New-Object 'System.Collections.Generic.List[string]'

    foreach ($registryLocation in @(
        @{ Path = 'HKCU:\Software\Valve\Steam'; Name = 'SteamPath' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam'; Name = 'InstallPath' },
        @{ Path = 'HKLM:\SOFTWARE\Valve\Steam'; Name = 'InstallPath' }
    )) {
        try {
            $properties = Get-ItemProperty -LiteralPath $registryLocation.Path -ErrorAction Stop
            $value = $properties.($registryLocation.Name)
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $steamRoots.Add([IO.Path]::GetFullPath($value))
            }
        }
        catch {
            # Continue with other registry keys and conventional paths.
        }
    }

    foreach ($candidate in @(
        'C:\Program Files (x86)\Steam',
        'C:\Program Files\Steam'
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $steamRoots.Add($candidate)
        }
    }

    $seenSteamRoots = @{}
    foreach ($steamRootCandidate in $steamRoots) {
        $steamRoot = [IO.Path]::GetFullPath($steamRootCandidate)
        $steamKey = $steamRoot.ToLowerInvariant()
        if ($seenSteamRoots.ContainsKey($steamKey)) {
            continue
        }
        $seenSteamRoots[$steamKey] = $true

        $steamExe = Join-Path $steamRoot 'steam.exe'
        if (-not (Test-Path -LiteralPath $steamExe -PathType Leaf)) {
            continue
        }

        $libraries = New-Object 'System.Collections.Generic.List[string]'
        $libraries.Add($steamRoot)
        $libraryFile = Join-Path (Join-Path $steamRoot 'steamapps') 'libraryfolders.vdf'

        if (Test-Path -LiteralPath $libraryFile -PathType Leaf) {
            $libraryText = [IO.File]::ReadAllText($libraryFile)
            foreach ($match in [regex]::Matches($libraryText, '"path"\s+"([^"]+)"')) {
                $libraryPath = $match.Groups[1].Value.Replace('\\', '\')
                if (-not [string]::IsNullOrWhiteSpace($libraryPath)) {
                    $libraries.Add([IO.Path]::GetFullPath($libraryPath))
                }
            }
        }

        $seenLibraries = @{}
        foreach ($libraryCandidate in $libraries) {
            $library = [IO.Path]::GetFullPath($libraryCandidate)
            $libraryKey = $library.ToLowerInvariant()
            if ($seenLibraries.ContainsKey($libraryKey)) {
                continue
            }
            $seenLibraries[$libraryKey] = $true

            $steamApps = Join-Path $library 'steamapps'
            $manifest = Join-Path $steamApps 'appmanifest_730.acf'
            if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
                continue
            }

            $manifestText = [IO.File]::ReadAllText($manifest)
            $installMatch = [regex]::Match($manifestText, '"installdir"\s+"([^"]+)"')
            if (-not $installMatch.Success) {
                continue
            }

            $installDirectory = $installMatch.Groups[1].Value.Replace('\\', '\')
            $gameRoot = Join-Path (Join-Path $steamApps 'common') $installDirectory
            $csgoDirectory = Join-Path (Join-Path $gameRoot 'game') 'csgo'
            $cs2Exe = Join-Path (Join-Path (Join-Path (Join-Path $gameRoot 'game') 'bin') 'win64') 'cs2.exe'

            if ((Test-Path -LiteralPath $csgoDirectory -PathType Container) -and
                (Test-Path -LiteralPath $cs2Exe -PathType Leaf)) {
                return [PSCustomObject]@{
                    CsgoDirectory = $csgoDirectory
                    Cs2Exe = $cs2Exe
                }
            }
        }
    }

    throw 'Steam app 730 (Counter-Strike 2) could not be located.'
}

function Add-OwnedDirectoryTarget {
    param(
        [System.Collections.Generic.List[object]]$Targets,
        [string]$LiteralPath,
        [string]$ExpectedPath,
        [string]$Category
    )

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        return
    }

    Assert-ExactPath -Actual $LiteralPath -Expected $ExpectedPath -Description $Category
    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        throw "Refusing an unexpected non-directory $Category target: $LiteralPath"
    }

    $stats = Get-SafeDirectoryStats -LiteralPath $item.FullName
    $Targets.Add([PSCustomObject]@{
        Category = $Category
        Kind = 'Directory'
        Path = $item.FullName
        FileCount = [UInt64]$stats.FileCount
        TotalBytes = [UInt64]$stats.TotalBytes
    })
}

function Add-OwnedFileTargets {
    param(
        [System.Collections.Generic.List[object]]$Targets,
        [string]$ParentDirectory,
        [string]$Filter,
        [string]$ExpectedNameRegex,
        [string]$Category
    )

    if (-not (Test-Path -LiteralPath $ParentDirectory -PathType Container)) {
        return
    }

    $parentItem = Get-Item -LiteralPath $ParentDirectory -Force -ErrorAction Stop
    if (-not $parentItem.PSIsContainer -or
        ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing an unsafe $Category parent directory: $ParentDirectory"
    }

    foreach ($item in @(Get-ChildItem -LiteralPath $ParentDirectory -Filter $Filter -File -Force -ErrorAction Stop)) {
        Assert-SafeLeafFile -Item $item -ExpectedParent $ParentDirectory `
            -ExpectedNameRegex $ExpectedNameRegex -Description $Category
        $Targets.Add([PSCustomObject]@{
            Category = $Category
            Kind = 'File'
            Path = $item.FullName
            FileCount = [UInt64]1
            TotalBytes = [UInt64]$item.Length
        })
    }
}

function Get-OwnedTargets {
    param(
        [string]$CsgoDirectory,
        [string]$CacheRoot,
        [bool]$ShouldIncludeCache
    )

    $targets = New-Object 'System.Collections.Generic.List[object]'
    $launcherDemoDirectory = Join-Path (Join-Path $CsgoDirectory 'demos') $LauncherName
    $cfgDirectory = Join-Path $CsgoDirectory 'cfg'

    Add-OwnedFileTargets -Targets $targets -ParentDirectory $launcherDemoDirectory -Filter $DemoPattern `
        -ExpectedNameRegex $DemoNameRegex -Category 'processed demo'
    if ($ShouldIncludeCache) {
        Add-OwnedDirectoryTarget -Targets $targets -LiteralPath $CacheRoot `
            -ExpectedPath $CacheRoot -Category 'launcher cache directory'
    }
    Add-OwnedFileTargets -Targets $targets -ParentDirectory $cfgDirectory -Filter $CfgPattern `
        -ExpectedNameRegex $CfgNameRegex -Category 'playback config'

    return $targets.ToArray()
}

function Assert-OwnedTargetStillSafe {
    param(
        [object]$Target,
        [string]$CsgoDirectory,
        [string]$CacheRoot
    )

    if (-not (Test-Path -LiteralPath $Target.Path)) {
        return $false
    }

    switch ($Target.Category) {
        'processed demo' {
            $item = Get-Item -LiteralPath $Target.Path -Force -ErrorAction Stop
            if ($item.PSIsContainer) {
                throw "Refusing an unexpected processed demo directory: $($Target.Path)"
            }
            Assert-SafeLeafFile -Item $item `
                -ExpectedParent (Join-Path (Join-Path $CsgoDirectory 'demos') $LauncherName) `
                -ExpectedNameRegex $DemoNameRegex -Description $Target.Category
        }
        'launcher cache directory' {
            Assert-ExactPath -Actual $Target.Path -Expected $CacheRoot -Description $Target.Category
            [void](Get-SafeDirectoryStats -LiteralPath $Target.Path)
        }
        'playback config' {
            $item = Get-Item -LiteralPath $Target.Path -Force -ErrorAction Stop
            if ($item.PSIsContainer) {
                throw "Refusing an unexpected playback config directory: $($Target.Path)"
            }
            Assert-SafeLeafFile -Item $item -ExpectedParent (Join-Path $CsgoDirectory 'cfg') `
                -ExpectedNameRegex $CfgNameRegex -Description $Target.Category
        }
        default {
            throw "Refusing an unknown cleanup category: $($Target.Category)"
        }
    }

    return $true
}

function Format-ByteSize {
    param([UInt64]$Bytes)

    if ($Bytes -ge [UInt64]1GB) {
        return ('{0:N2} GiB' -f ([double]$Bytes / 1GB))
    }
    if ($Bytes -ge [UInt64]1MB) {
        return ('{0:N1} MiB' -f ([double]$Bytes / 1MB))
    }
    if ($Bytes -ge [UInt64]1KB) {
        return ('{0:N1} KiB' -f ([double]$Bytes / 1KB))
    }
    return ("$Bytes bytes")
}

function Show-CleanupPlan {
    param(
        [object[]]$Targets,
        [string]$CsgoDirectory,
        [bool]$IsPermanent
    )

    Write-Step ("CS2 data directory: {0}" -f $CsgoDirectory)
    Write-Host 'Protected by design: csgo\replays, .dem files in the csgo root, and Wmpvp ZIP archives.' -ForegroundColor Green
    Write-Host ''

    if ($Targets.Count -eq 0) {
        Write-Host 'No launcher-owned demo artifacts were found.' -ForegroundColor Green
        return
    }

    [UInt64]$totalFiles = 0
    [UInt64]$totalBytes = 0
    foreach ($target in $Targets) {
        $totalFiles += [UInt64]$target.FileCount
        $totalBytes += [UInt64]$target.TotalBytes
        Write-Host ("[{0}] {1}" -f $target.Category, $target.Path)
        Write-Host ("    {0:N0} file(s), {1}" -f $target.FileCount, (Format-ByteSize -Bytes $target.TotalBytes))
    }

    Write-Host ''
    Write-Host ("Total: {0:N0} file(s), {1}" -f $totalFiles, (Format-ByteSize -Bytes $totalBytes)) -ForegroundColor Yellow
    if ($IsPermanent) {
        Write-Host 'Mode: PERMANENT deletion (cannot be recovered).' -ForegroundColor Red
    }
    else {
        Write-Host 'Mode: move to the Windows Recycle Bin.' -ForegroundColor Yellow
    }
}

function Assert-Cs2NotRunning {
    if (@(Get-Process -Name 'cs2' -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'CS2 is running. Close the game before performing cleanup. ListOnly and WhatIf remain available.'
    }
}

function Remove-OwnedTarget {
    param(
        [object]$Target,
        [bool]$UsePermanentDeletion
    )

    if ($UsePermanentDeletion) {
        if ($Target.Kind -eq 'Directory') {
            [IO.Directory]::Delete($Target.Path, $true)
        }
        else {
            [IO.File]::Delete($Target.Path)
        }
        return
    }

    Add-Type -AssemblyName Microsoft.VisualBasic
    if ($Target.Kind -eq 'Directory') {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
            $Target.Path,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
        )
    }
    else {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
            $Target.Path,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
        )
    }
}

$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
if ([string]::IsNullOrWhiteSpace($localAppData)) {
    throw 'The Local Application Data directory could not be located.'
}
$cacheRoot = Join-Path $localAppData $LauncherName

$isWhatIf = [bool]$WhatIfPreference
$isDryRun = $ListOnly -or $isWhatIf
$cleanupMutex = $null
$ownsCleanupMutex = $false

try {
    $installation = Find-SteamAndCs2

    if (-not $isDryRun) {
        Assert-Cs2NotRunning
        $cleanupMutex = New-Object Threading.Mutex($false, $LauncherMutexName)
        try {
            $ownsCleanupMutex = $cleanupMutex.WaitOne(0)
        }
        catch [Threading.AbandonedMutexException] {
            $ownsCleanupMutex = $true
        }
        if (-not $ownsCleanupMutex) {
            throw 'The demo launcher is currently running. Wait for it to finish before cleanup.'
        }
    }

    $targets = @(Get-OwnedTargets -CsgoDirectory $installation.CsgoDirectory -CacheRoot $cacheRoot `
        -ShouldIncludeCache ([bool]$IncludeCache))
    Show-CleanupPlan -Targets $targets -CsgoDirectory $installation.CsgoDirectory -IsPermanent ([bool]$Permanent)

    if ($targets.Count -eq 0 -or $ListOnly) {
        return
    }

    if (-not $isWhatIf) {
        if (-not $Yes) {
            $firstAnswer = Read-Host 'Type DELETE to continue, or press Enter to cancel'
            if ($firstAnswer -cne 'DELETE') {
                Write-Host 'Cleanup canceled. Nothing was removed.' -ForegroundColor Yellow
                return
            }
        }

        if ($Permanent) {
            Write-Host ''
            Write-Host 'Permanent deletion bypasses the Recycle Bin.' -ForegroundColor Red
            $secondAnswer = Read-Host 'Type PERMANENT DELETE to confirm irreversible deletion'
            if ($secondAnswer -cne 'PERMANENT DELETE') {
                Write-Host 'Cleanup canceled. Nothing was removed.' -ForegroundColor Yellow
                return
            }
        }

        Assert-Cs2NotRunning
    }

    $operation = if ($Permanent) { 'Permanently delete' } else { 'Move to Recycle Bin' }
    [UInt64]$removedTargets = 0
    [UInt64]$removedFiles = 0
    [UInt64]$removedBytes = 0

    foreach ($target in $targets) {
        if (-not $PSCmdlet.ShouldProcess($target.Path, $operation)) {
            continue
        }

        if (-not (Assert-OwnedTargetStillSafe -Target $target -CsgoDirectory $installation.CsgoDirectory -CacheRoot $cacheRoot)) {
            Write-Warning ("Target disappeared before cleanup and was skipped: {0}" -f $target.Path)
            continue
        }

        if (-not $isWhatIf) {
            Assert-Cs2NotRunning
        }
        Remove-OwnedTarget -Target $target -UsePermanentDeletion ([bool]$Permanent)
        $removedTargets++
        $removedFiles += [UInt64]$target.FileCount
        $removedBytes += [UInt64]$target.TotalBytes
        Write-Host ("Removed: {0}" -f $target.Path) -ForegroundColor Green
    }

    if ($isWhatIf) {
        Write-Host ''
        Write-Host 'Preview complete. Nothing was removed.' -ForegroundColor Green
    }
    else {
        Write-Host ''
        Write-Host ("Cleanup complete: {0:N0} target(s), {1:N0} file(s), {2}." -f
            $removedTargets, $removedFiles, (Format-ByteSize -Bytes $removedBytes)) -ForegroundColor Green
    }
}
finally {
    if ($ownsCleanupMutex) {
        $cleanupMutex.ReleaseMutex()
    }
    if ($null -ne $cleanupMutex) {
        $cleanupMutex.Dispose()
    }
}
