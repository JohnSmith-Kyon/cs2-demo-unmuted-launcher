[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$DemoPath,

    [switch]$NoLaunch,

    [switch]$ForceReprocess,

    [switch]$RestartIfRunning,

    [string]$PatcherPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$PatcherVersion = 'v0.1.0-beta.1'
$PatcherArchiveName = 'OdyCSUnmuter-Beta-v0.1.0-beta.1-windows-x64.zip'
$PatcherUrl = 'https://github.com/OdyCS/OdyCSUnmuter/releases/download/v0.1.0-beta.1/OdyCSUnmuter-Beta-v0.1.0-beta.1-windows-x64.zip'
$PatcherArchiveSha256 = 'AC2BA60F93B1B498A71CBD7A6EFB9C25D6B89D2D6BF761CF1351DF1E15537A66'
$PatcherExeSha256 = '5EB05E1F597B5509FB2A9A886D1014512D15419E48426932CF903114AB6DB475'
$LauncherName = 'CS2DemoUnmutedLauncher'
$CfgPrefix = 'cs2_demo_unmuted_'
$LauncherSchemaVersion = 3
$MaximumDemoBytes = [UInt64][UInt32]::MaxValue

function Write-Step {
    param([string]$Message)
    Write-Host ("[CS2 Demo] {0}" -f $Message) -ForegroundColor Cyan
}

function Get-Sha256 {
    param([string]$LiteralPath)
    return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Assert-AvailableSpace {
    param(
        [string]$Directory,
        [UInt64]$RequiredBytes,
        [string]$Purpose
    )

    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Directory))
    $drive = New-Object IO.DriveInfo($root)
    if ($drive.IsReady -and [UInt64]$drive.AvailableFreeSpace -lt $RequiredBytes) {
        throw ("Not enough free space on {0} for {1}. Need about {2:N1} GB; available {3:N1} GB." -f
            $root, $Purpose, ($RequiredBytes / 1GB), ($drive.AvailableFreeSpace / 1GB))
    }
}

function Assert-NoReparsePoints {
    param([string]$RootDirectory)

    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($RootDirectory)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $currentItem = Get-Item -LiteralPath $current -Force
        if (($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to remove a cache tree containing a reparse point: $current"
        }

        foreach ($child in @(Get-ChildItem -LiteralPath $current -Force)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to remove a cache tree containing a reparse point: $($child.FullName)"
            }
            if ($child.PSIsContainer) {
                $pending.Push($child.FullName)
            }
        }
    }
}

function Remove-OwnedDirectory {
    param(
        [string]$LiteralPath,
        [string]$AllowedParent,
        [string]$RequiredPrefix
    )

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Container)) {
        return
    }

    $resolved = (Resolve-Path -LiteralPath $LiteralPath).ProviderPath
    $parent = [IO.Path]::GetFullPath($AllowedParent).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $leaf = [IO.Path]::GetFileName($resolved)

    if (-not $resolved.StartsWith($parent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a directory outside the launcher cache: $resolved"
    }
    if (-not $leaf.StartsWith($RequiredPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove an unexpected cache directory: $resolved"
    }

    Assert-NoReparsePoints -RootDirectory $resolved
    Get-ChildItem -LiteralPath $resolved -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.IsReadOnly) {
            $_.IsReadOnly = $false
        }
    }
    [IO.Directory]::Delete($resolved, $true)
}

function Resolve-DemoPath {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = Read-Host 'Enter the local .dem or .zip path'
    }

    $Value = [Environment]::ExpandEnvironmentVariables($Value.Trim().Trim('"'))
    $resolved = @(Resolve-Path -LiteralPath $Value -ErrorAction Stop)

    if ($resolved.Count -ne 1 -or (Test-Path -LiteralPath $resolved[0].ProviderPath -PathType Container)) {
        throw "Expected one local demo file: $Value"
    }

    $extension = [IO.Path]::GetExtension($resolved[0].ProviderPath)
    if ($extension -ine '.dem' -and $extension -ine '.zip') {
        throw "Only .dem and .zip inputs are supported: $($resolved[0].ProviderPath)"
    }

    return $resolved[0].ProviderPath
}

function Find-SteamAndCs2 {
    $steamRoots = New-Object 'System.Collections.Generic.List[string]'

    try {
        $registrySteamPath = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath
        if (-not [string]::IsNullOrWhiteSpace($registrySteamPath)) {
            $steamRoots.Add([IO.Path]::GetFullPath($registrySteamPath))
        }
    }
    catch {
        # Fall through to conventional locations.
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
                    SteamExe = $steamExe
                    GameRoot = $gameRoot
                    CsgoDirectory = $csgoDirectory
                    Cs2Exe = $cs2Exe
                }
            }
        }
    }

    throw 'Steam app 730 (Counter-Strike 2) could not be located.'
}

function Download-VerifiedFile {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$ExpectedSha256
    )

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
        # PowerShell 7 does not need this compatibility setting.
    }

    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -UserAgent 'CS2DemoUnmutedLauncher/1.0'
    $actual = Get-Sha256 -LiteralPath $Destination
    if ($actual -ne $ExpectedSha256) {
        throw "Downloaded file failed SHA-256 verification. Expected $ExpectedSha256, got $actual"
    }
}

function Ensure-Patcher {
    param(
        [string]$CacheRoot,
        [string]$OverridePath
    )

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        $resolvedOverride = (Resolve-Path -LiteralPath $OverridePath -ErrorAction Stop).ProviderPath
        if ((Get-Sha256 -LiteralPath $resolvedOverride) -ne $PatcherExeSha256) {
            throw 'The supplied patcher does not match the audited executable SHA-256.'
        }
        return $resolvedOverride
    }

    $toolsParent = Join-Path $CacheRoot 'tools'
    $toolRoot = Join-Path $toolsParent ("odycsunmuter-{0}" -f $PatcherVersion)
    $exePath = Join-Path $toolRoot 'OdyCSUnmuter.exe'

    if (Test-Path -LiteralPath $exePath -PathType Leaf) {
        if ((Get-Sha256 -LiteralPath $exePath) -eq $PatcherExeSha256) {
            return $exePath
        }
        Remove-OwnedDirectory -LiteralPath $toolRoot -AllowedParent $toolsParent -RequiredPrefix 'odycsunmuter-'
    }

    New-Item -ItemType Directory -Path $toolsParent -Force | Out-Null
    $downloadParent = Join-Path $CacheRoot 'downloads'
    New-Item -ItemType Directory -Path $downloadParent -Force | Out-Null
    $downloadRoot = Join-Path $downloadParent ("download-{0}" -f [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $downloadRoot | Out-Null

    try {
        $archivePath = Join-Path $downloadRoot $PatcherArchiveName
        $unpackedPath = Join-Path $downloadRoot 'unpacked'

        Write-Step ("Downloading audited patcher {0}..." -f $PatcherVersion)
        Download-VerifiedFile -Url $PatcherUrl -Destination $archivePath -ExpectedSha256 $PatcherArchiveSha256
        Expand-Archive -LiteralPath $archivePath -DestinationPath $unpackedPath

        $unpackedExe = Join-Path $unpackedPath 'OdyCSUnmuter.exe'
        if (-not (Test-Path -LiteralPath $unpackedExe -PathType Leaf)) {
            throw 'The verified release archive did not contain OdyCSUnmuter.exe.'
        }
        if ((Get-Sha256 -LiteralPath $unpackedExe) -ne $PatcherExeSha256) {
            throw 'The executable inside the verified release archive failed verification.'
        }

        if (Test-Path -LiteralPath $toolRoot) {
            Remove-OwnedDirectory -LiteralPath $toolRoot -AllowedParent $toolsParent -RequiredPrefix 'odycsunmuter-'
        }
        [IO.Directory]::Move($unpackedPath, $toolRoot)
        return (Join-Path $toolRoot 'OdyCSUnmuter.exe')
    }
    finally {
        Remove-OwnedDirectory -LiteralPath $downloadRoot -AllowedParent $downloadParent -RequiredPrefix 'download-'
    }
}

function Get-DemoFromInput {
    param(
        [string]$InputPath,
        [string]$WorkDirectory
    )

    if ([IO.Path]::GetExtension($InputPath) -ieq '.dem') {
        $inputLength = [UInt64](Get-Item -LiteralPath $InputPath).Length
        if ($inputLength -lt 16 -or $inputLength -gt $MaximumDemoBytes) {
            throw ("The demo size is outside the supported PBDEMS2 16-byte to 4-GB range: {0}" -f $inputLength)
        }
        return [PSCustomObject]@{
            Path = $InputPath
            Name = [IO.Path]::GetFileName($InputPath)
        }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($InputPath)
    try {
        $entries = @($archive.Entries | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.Name) -and
            [IO.Path]::GetExtension($_.Name) -ieq '.dem'
        })

        if ($entries.Count -ne 1) {
            $names = @($entries | ForEach-Object { $_.FullName }) -join ', '
            throw "Expected exactly one .dem inside the ZIP; found $($entries.Count). Entries: $names"
        }

        $entry = $entries[0]
        $entryLength = [UInt64]$entry.Length
        if ($entryLength -lt 16 -or $entryLength -gt $MaximumDemoBytes) {
            throw ("The demo inside the ZIP is outside the supported PBDEMS2 16-byte to 4-GB range: {0}" -f $entryLength)
        }
        Assert-AvailableSpace -Directory $WorkDirectory -RequiredBytes ($entryLength + [UInt64](256MB)) -Purpose 'ZIP extraction'

        $extractedPath = Join-Path $WorkDirectory 'input.dem'
        $inputStream = $entry.Open()
        try {
            $outputStream = [IO.File]::Create($extractedPath)
            try {
                $inputStream.CopyTo($outputStream)
            }
            finally {
                $outputStream.Dispose()
            }
        }
        finally {
            $inputStream.Dispose()
        }

        return [PSCustomObject]@{
            Path = $extractedPath
            Name = [IO.Path]::GetFileName($entry.Name)
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Assert-Source2Demo {
    param([string]$LiteralPath)

    $stream = [IO.File]::OpenRead($LiteralPath)
    try {
        $header = New-Object byte[] 8
        if ($stream.Read($header, 0, $header.Length) -ne $header.Length) {
            throw 'The demo is too short to contain a Source 2 header.'
        }
        if ([Text.Encoding]::ASCII.GetString($header) -ne "PBDEMS2`0") {
            throw 'The selected file is not a PBDEMS2 Counter-Strike 2 demo.'
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Read-VarUInt32 {
    param(
        [IO.Stream]$Stream,
        [string]$Context
    )

    [UInt64]$value = 0
    for ($index = 0; $index -lt 5; $index++) {
        $raw = $Stream.ReadByte()
        if ($raw -lt 0) {
            throw "Unexpected end of demo while reading a varint at $Context."
        }
        if ($index -eq 4 -and (($raw -band 0xF0) -ne 0)) {
            throw "Invalid 32-bit varint at $Context."
        }

        [UInt64]$part = $raw -band 0x7F
        $value = $value -bor ($part -shl (7 * $index))
        if (($raw -band 0x80) -eq 0) {
            return [UInt32]$value
        }
    }

    throw "Invalid 32-bit varint at $Context."
}

function Get-DemoStructureIndex {
    param([string]$LiteralPath)

    $stream = [IO.File]::Open($LiteralPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 16) {
            throw 'The demo is too short to contain its 16-byte header.'
        }

        $header = New-Object byte[] 16
        if ($stream.Read($header, 0, $header.Length) -ne $header.Length -or
            [Text.Encoding]::ASCII.GetString($header, 0, 8) -ne "PBDEMS2`0") {
            throw 'The selected file is not a PBDEMS2 Counter-Strike 2 demo.'
        }

        $fileInfoOffsets = New-Object 'System.Collections.Generic.List[UInt64]'
        $spawnGroupsOffsets = New-Object 'System.Collections.Generic.List[UInt64]'
        [UInt64]$recordCount = 0
        [UInt64]$stopCount = 0

        while ($stream.Position -lt $stream.Length) {
            [UInt64]$recordOffset = $stream.Position
            $context = "record offset $recordOffset"
            [UInt32]$rawCommand = Read-VarUInt32 -Stream $stream -Context $context
            [void](Read-VarUInt32 -Stream $stream -Context $context) # tick
            [UInt32]$payloadSize = Read-VarUInt32 -Stream $stream -Context $context

            [UInt64]$remaining = $stream.Length - $stream.Position
            if ([UInt64]$payloadSize -gt $remaining) {
                throw "Demo record at offset $recordOffset extends beyond the physical end of the file."
            }

            # EDemoCommands::DemIsCompressed is bit 0x40.
            [UInt32]$command = if (($rawCommand -band 0x40) -ne 0) {
                $rawCommand - 0x40
            }
            else {
                $rawCommand
            }

            switch ($command) {
                0 { $stopCount++ }
                2 { $fileInfoOffsets.Add($recordOffset) }
                15 { $spawnGroupsOffsets.Add($recordOffset) }
            }

            [void]$stream.Seek([Int64]$payloadSize, [IO.SeekOrigin]::Current)
            $recordCount++
        }

        if ($stream.Position -ne $stream.Length) {
            throw 'The demo record stream did not end exactly at the physical end of the file.'
        }

        return [PSCustomObject]@{
            Length = [UInt64]$stream.Length
            RecordCount = $recordCount
            StopCount = $stopCount
            HeaderFileInfoOffset = [UInt32][BitConverter]::ToUInt32($header, 8)
            HeaderSpawnGroupsOffset = [UInt32][BitConverter]::ToUInt32($header, 12)
            FileInfoOffsets = @($fileInfoOffsets)
            SpawnGroupsOffsets = @($spawnGroupsOffsets)
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Assert-DemoFooterOffsets {
    param([string]$LiteralPath)

    $index = Get-DemoStructureIndex -LiteralPath $LiteralPath
    if ($index.StopCount -lt 1) {
        throw 'The rewritten demo contains no DemStop record.'
    }
    if ($index.FileInfoOffsets.Count -ne 1) {
        throw "Expected exactly one DemFileInfo record; found $($index.FileInfoOffsets.Count)."
    }
    if ($index.SpawnGroupsOffsets.Count -ne 1) {
        throw "Expected exactly one DemSpawnGroups record; found $($index.SpawnGroupsOffsets.Count)."
    }

    [UInt64]$fileInfoOffset = $index.FileInfoOffsets[0]
    [UInt64]$spawnGroupsOffset = $index.SpawnGroupsOffsets[0]
    if ($fileInfoOffset -gt [UInt32]::MaxValue -or $spawnGroupsOffset -gt [UInt32]::MaxValue) {
        throw 'The rewritten demo footer offsets do not fit in the PBDEMS2 32-bit header.'
    }
    if ($spawnGroupsOffset -ge $fileInfoOffset) {
        throw 'The DemSpawnGroups footer record is not before DemFileInfo as expected.'
    }
    if ($index.HeaderFileInfoOffset -ne [UInt32]$fileInfoOffset -or
        $index.HeaderSpawnGroupsOffset -ne [UInt32]$spawnGroupsOffset) {
        throw ("Demo footer offsets are inconsistent. Header FileInfo/SpawnGroups={0}/{1}; actual={2}/{3}." -f
            $index.HeaderFileInfoOffset,
            $index.HeaderSpawnGroupsOffset,
            $fileInfoOffset,
            $spawnGroupsOffset)
    }

    return $index
}

function Repair-DemoFooterOffsets {
    param([string]$LiteralPath)

    $index = Get-DemoStructureIndex -LiteralPath $LiteralPath
    if ($index.StopCount -lt 1 -or
        $index.FileInfoOffsets.Count -ne 1 -or
        $index.SpawnGroupsOffsets.Count -ne 1) {
        throw ("Cannot safely repair footer offsets: Stop={0}, FileInfo={1}, SpawnGroups={2}." -f
            $index.StopCount,
            $index.FileInfoOffsets.Count,
            $index.SpawnGroupsOffsets.Count)
    }

    [UInt64]$fileInfoOffset = $index.FileInfoOffsets[0]
    [UInt64]$spawnGroupsOffset = $index.SpawnGroupsOffsets[0]
    if ($fileInfoOffset -gt [UInt32]::MaxValue -or
        $spawnGroupsOffset -gt [UInt32]::MaxValue -or
        $spawnGroupsOffset -ge $fileInfoOffset) {
        throw 'The discovered footer offsets cannot be represented safely in the PBDEMS2 header.'
    }

    $stream = [IO.File]::Open($LiteralPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        [void]$stream.Seek(8, [IO.SeekOrigin]::Begin)
        $fileInfoBytes = [BitConverter]::GetBytes([UInt32]$fileInfoOffset)
        $stream.Write($fileInfoBytes, 0, $fileInfoBytes.Length)
        $spawnGroupsBytes = [BitConverter]::GetBytes([UInt32]$spawnGroupsOffset)
        $stream.Write($spawnGroupsBytes, 0, $spawnGroupsBytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }

    return Assert-DemoFooterOffsets -LiteralPath $LiteralPath
}

function Invoke-DemoPatcher {
    param(
        [string]$PatcherExe,
        [string]$InputDemo,
        [string]$OutputDemo
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $previousConsoleOutputEncoding = [Console]::OutputEncoding
    $previousOutputEncoding = $OutputEncoding
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    $captured = @()
    $safeLines = @()
    $exitCode = $null
    try {
        # Windows PowerShell 5.1 turns any native stderr into a terminating
        # NativeCommandError when the script-wide preference is Stop. It can
        # also decode UTF-8 native output with the active OEM code page, which
        # permanently corrupts non-ASCII player names before the report is
        # written. Temporarily make native output explicitly UTF-8.
        [Console]::OutputEncoding = $utf8NoBom
        $OutputEncoding = $utf8NoBom
        $ErrorActionPreference = 'Continue'
        $captured = @(& $PatcherExe $InputDemo $OutputDemo 2>&1)
        $exitCode = $LASTEXITCODE
        $safeLines = @($captured | ForEach-Object {
            [regex]::Replace($_.ToString(), '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '?')
        })
        foreach ($line in $safeLines) {
            Write-Host $line
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        $OutputEncoding = $previousOutputEncoding
        [Console]::OutputEncoding = $previousConsoleOutputEncoding
    }

    if ($exitCode -ne 0) {
        throw "The demo patcher failed with exit code $exitCode."
    }

    return $safeLines -join [Environment]::NewLine
}

function Get-AudioByteCount {
    param([string]$ReportText)

    $match = [regex]::Match($ReportText, 'Total encoded voice bytes:\s*([0-9]+)')
    if (-not $match.Success) {
        throw 'The patcher completed without a readable voice-audio report.'
    }
    return [UInt64]::Parse($match.Groups[1].Value)
}

function Write-PlaybackConfig {
    param(
        [string]$CsgoDirectory,
        [string]$RelativeDemoPath,
        [string]$ConfigName
    )

    $cfgDirectory = Join-Path $CsgoDirectory 'cfg'
    New-Item -ItemType Directory -Path $cfgDirectory -Force | Out-Null
    $cfgPath = Join-Path $cfgDirectory $ConfigName

    $relativeForConsole = $RelativeDemoPath.Replace('\', '/')
    $lines = @(
        'echo "[CS2 Demo] Enabling all recorded voice slots..."',
        'voice_modenable 1',
        'tv_listen_voice_indices -1',
        'tv_listen_voice_indices_h -1',
        'cl_demo_predict 0',
        ("playdemo `"{0}`"" -f $relativeForConsole)
    )

    [IO.File]::WriteAllLines($cfgPath, $lines, (New-Object Text.UTF8Encoding($false)))
    return $cfgPath
}

$inputPath = $null
$workDirectory = $null
$cacheRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) $LauncherName
$workParent = Join-Path $cacheRoot 'work'
$scriptExitCode = 0
$launcherMutex = New-Object Threading.Mutex($false, 'Local\CS2DemoUnmutedLauncher-v1')
$ownsLauncherMutex = $false

try {
    try {
        $ownsLauncherMutex = $launcherMutex.WaitOne(0)
    }
    catch [Threading.AbandonedMutexException] {
        $ownsLauncherMutex = $true
    }
    if (-not $ownsLauncherMutex) {
        throw 'Another copy of this launcher is already running.'
    }

    $inputPath = Resolve-DemoPath -Value $DemoPath
    Write-Step ("Input: {0}" -f $inputPath)

    $installation = Find-SteamAndCs2
    Write-Step ("CS2: {0}" -f $installation.GameRoot)

    New-Item -ItemType Directory -Path $workParent -Force | Out-Null
    $workDirectory = Join-Path $workParent ("run-{0}" -f [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workDirectory | Out-Null

    $demo = Get-DemoFromInput -InputPath $inputPath -WorkDirectory $workDirectory
    Assert-Source2Demo -LiteralPath $demo.Path

    Write-Step 'Hashing the uncompressed demo...'
    $demoHash = Get-Sha256 -LiteralPath $demo.Path
    $shortHash = $demoHash.Substring(0, 16).ToLowerInvariant()

    $outputRelativeDirectory = Join-Path 'demos' $LauncherName
    $outputDirectory = Join-Path $installation.CsgoDirectory $outputRelativeDirectory
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

    $outputName = "demo_unmuted_$shortHash.dem"
    $cfgNameForDemo = "$CfgPrefix$shortHash.cfg"
    $outputDemo = Join-Path $outputDirectory $outputName
    $reportDirectory = Join-Path $cacheRoot 'reports'
    $reportPath = Join-Path $reportDirectory ("$demoHash.txt")
    $manifestPath = Join-Path $reportDirectory ("$demoHash.json")
    New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null

    $reportText = $null
    $cachedReportText = $null
    $canReuse = (-not $ForceReprocess) -and
        (Test-Path -LiteralPath $outputDemo -PathType Leaf) -and
        (Test-Path -LiteralPath $reportPath -PathType Leaf) -and
        (Test-Path -LiteralPath $manifestPath -PathType Leaf)

    if ($canReuse) {
        try {
            $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
            $cachedReportText = [IO.File]::ReadAllText($reportPath)
            $cachedAudioBytes = Get-AudioByteCount -ReportText $cachedReportText
            $cachedStructure = Assert-DemoFooterOffsets -LiteralPath $outputDemo
            if ($manifest.SchemaVersion -ne $LauncherSchemaVersion -or
                $manifest.SourceSha256 -ne $demoHash -or
                $manifest.PatcherVersion -ne $PatcherVersion -or
                $manifest.PatcherExeSha256 -ne $PatcherExeSha256 -or
                $manifest.OutputFileName -ne $outputName -or
                [UInt64]$manifest.OutputLength -ne [UInt64](Get-Item -LiteralPath $outputDemo).Length -or
                $manifest.OutputSha256 -ne (Get-Sha256 -LiteralPath $outputDemo) -or
                $manifest.ReportSha256 -ne (Get-Sha256 -LiteralPath $reportPath) -or
                [UInt64]$manifest.EncodedVoiceBytes -ne [UInt64]$cachedAudioBytes -or
                [UInt64]$manifest.RecordCount -ne [UInt64]$cachedStructure.RecordCount -or
                [UInt32]$manifest.FileInfoOffset -ne [UInt32]$cachedStructure.HeaderFileInfoOffset -or
                [UInt32]$manifest.SpawnGroupsOffset -ne [UInt32]$cachedStructure.HeaderSpawnGroupsOffset) {
                $canReuse = $false
                Write-Warning 'The processed-demo cache failed integrity verification and will be rebuilt.'
            }
        }
        catch {
            $canReuse = $false
            Write-Warning 'The processed-demo cache manifest is invalid and will be rebuilt.'
        }
    }

    if ($canReuse) {
        Assert-Source2Demo -LiteralPath $outputDemo
        $reportText = $cachedReportText
        Write-Step ("Reusing verified processed copy: {0}" -f $outputDemo)
    }
    else {
        $patcherExe = Ensure-Patcher -CacheRoot $cacheRoot -OverridePath $PatcherPath
        $demoLength = [UInt64](Get-Item -LiteralPath $demo.Path).Length
        $requiredOutputSpace = ($demoLength * [UInt64]2) + [UInt64](512MB)
        Assert-AvailableSpace -Directory $outputDirectory -RequiredBytes $requiredOutputSpace -Purpose 'safe demo rewriting'
        Write-Step 'Rewriting mute flags, listener masks, and speaker identities...'
        $pendingOutput = Join-Path $outputDirectory (".{0}.pending-{1}" -f $outputName, [Guid]::NewGuid().ToString('N'))
        try {
            $reportText = Invoke-DemoPatcher -PatcherExe $patcherExe -InputDemo $demo.Path -OutputDemo $pendingOutput
            Assert-Source2Demo -LiteralPath $pendingOutput
            Write-Step 'Repairing and verifying PBDEMS2 footer offsets...'
            $footerStructure = Repair-DemoFooterOffsets -LiteralPath $pendingOutput
            $reportText = $reportText.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine +
                'LAUNCHER STRUCTURE VERIFICATION' + [Environment]::NewLine +
                ("  Outer records:           {0}" -f $footerStructure.RecordCount) + [Environment]::NewLine +
                ("  DemFileInfo offset:      {0}" -f $footerStructure.HeaderFileInfoOffset) + [Environment]::NewLine +
                ("  DemSpawnGroups offset:   {0}" -f $footerStructure.HeaderSpawnGroupsOffset)
            $pendingAudioBytes = Get-AudioByteCount -ReportText $reportText
            if ($pendingAudioBytes -eq 0) {
                throw 'This demo contains no recorded voice bytes; no launcher can reconstruct missing speech.'
            }

            Copy-Item -LiteralPath $pendingOutput -Destination $outputDemo -Force
            Assert-Source2Demo -LiteralPath $outputDemo
            $outputItem = Get-Item -LiteralPath $outputDemo
            $outputHash = Get-Sha256 -LiteralPath $outputDemo

            # Include a BOM so Windows PowerShell 5.1 and older Windows editors
            # reliably recognize player names as UTF-8. JSON and CS2 cfg files
            # intentionally remain UTF-8 without BOM.
            [IO.File]::WriteAllText($reportPath, $reportText, (New-Object Text.UTF8Encoding($true)))
            $reportHash = Get-Sha256 -LiteralPath $reportPath
            $manifestJson = [ordered]@{
                SchemaVersion = $LauncherSchemaVersion
                SourceSha256 = $demoHash
                PatcherVersion = $PatcherVersion
                PatcherExeSha256 = $PatcherExeSha256
                OutputFileName = $outputName
                OutputLength = [UInt64]$outputItem.Length
                OutputSha256 = $outputHash
                ReportSha256 = $reportHash
                EncodedVoiceBytes = [UInt64]$pendingAudioBytes
                RecordCount = [UInt64]$footerStructure.RecordCount
                FileInfoOffset = [UInt32]$footerStructure.HeaderFileInfoOffset
                SpawnGroupsOffset = [UInt32]$footerStructure.HeaderSpawnGroupsOffset
            } | ConvertTo-Json
            [IO.File]::WriteAllText($manifestPath, $manifestJson, (New-Object Text.UTF8Encoding($false)))
        }
        finally {
            if (Test-Path -LiteralPath $pendingOutput -PathType Leaf) {
                [IO.File]::Delete($pendingOutput)
            }
        }
    }

    $audioBytes = Get-AudioByteCount -ReportText $reportText
    if ($audioBytes -eq 0) {
        throw 'This demo contains no recorded voice bytes; no launcher can reconstruct missing speech.'
    }

    $relativeDemo = Join-Path $outputRelativeDirectory $outputName
    $cfgPath = Write-PlaybackConfig -CsgoDirectory $installation.CsgoDirectory -RelativeDemoPath $relativeDemo -ConfigName $cfgNameForDemo

    Write-Host ''
    Write-Host 'Ready.' -ForegroundColor Green
    Write-Host ("  Processed demo: {0}" -f $outputDemo)
    Write-Host ("  Voice bytes:    {0:N0}" -f $audioBytes)
    Write-Host ("  Voice report:   {0}" -f $reportPath)
    Write-Host ("  Playback cfg:   {0}" -f $cfgPath)

    if ($NoLaunch) {
        Write-Host ''
        Write-Host ("NoLaunch selected. In the CS2 console run: exec {0}" -f $cfgNameForDemo)
        return
    }

    $runningCs2 = @(Get-Process -Name 'cs2' -ErrorAction SilentlyContinue)
    if ($runningCs2.Count -gt 0) {
        if ($RestartIfRunning) {
            Write-Warning 'RestartIfRunning selected: requesting a normal CS2 shutdown before playback.'
            $closeRequested = $false
            foreach ($process in $runningCs2) {
                $closeRequested = $process.CloseMainWindow() -or $closeRequested
            }
            if (-not $closeRequested) {
                throw 'CS2 could not be asked to close normally. Exit it manually and run the launcher again.'
            }
            $runningCs2 | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
            if (@(Get-Process -Name 'cs2' -ErrorAction SilentlyContinue).Count -gt 0) {
                throw 'CS2 did not close normally within 15 seconds. Exit it manually and run the launcher again.'
            }
            Start-Sleep -Seconds 2
        }
        else {
            $manualCommand = "exec $cfgNameForDemo"
            $clipboardCommand = Get-Command Set-Clipboard -ErrorAction SilentlyContinue
            if ($null -ne $clipboardCommand) {
                Set-Clipboard -Value $manualCommand
                Write-Warning 'CS2 is already running, so Steam cannot reliably forward startup console arguments.'
                Write-Warning 'For the most reliable first test, fully exit CS2 and run this launcher again.'
                Write-Host ("The command has been copied to the clipboard. Open the CS2 console and run: {0}" -f $manualCommand)
            }
            else {
                Write-Warning ("CS2 is already running. Open its console and run: {0}" -f $manualCommand)
                Write-Warning 'For the most reliable first test, fully exit CS2 and run this launcher again.'
            }
            return
        }
    }

    Write-Step 'Launching CS2 through Steam...'
    Start-Process -FilePath $installation.SteamExe -ArgumentList @(
        '-applaunch',
        '730',
        '-novid',
        '+exec',
        $cfgNameForDemo
    ) | Out-Null
}
catch {
    Write-Host ''
    Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    $scriptExitCode = 1
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($workDirectory)) {
        Remove-OwnedDirectory -LiteralPath $workDirectory -AllowedParent $workParent -RequiredPrefix 'run-'
    }
    if ($ownsLauncherMutex) {
        $launcherMutex.ReleaseMutex()
    }
    $launcherMutex.Dispose()
}

if ($scriptExitCode -eq 1) {
    exit 1
}
