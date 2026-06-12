param(
  [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }),
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$Message) {
  Write-Host "[repair-bundled-plugin-installs] $Message"
}

function ConvertTo-TomlLiteralString([string]$Value) {
  "'" + ($Value -replace "'", "''") + "'"
}

function Set-TomlTableBlock {
  param(
    [string]$Content,
    [string]$TableName,
    [string]$Block
  )

  $escaped = [regex]::Escape("[$TableName]")
  $pattern = "(?ms)^$escaped\r?\n.*?(?=^\[|\z)"
  if ([regex]::IsMatch($Content, $pattern)) {
    return [regex]::Replace($Content, $pattern, $Block.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine, 1)
  }

  return $Content.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $Block.TrimEnd() + [Environment]::NewLine
}

function Assert-UnderPath {
  param(
    [string]$Path,
    [string]$Root
  )

  $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
  $resolvedPath = [System.IO.Path]::GetFullPath($Path)
  if (-not $resolvedPath.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to modify path outside root: $resolvedPath"
  }
}

function Find-BundledMarketplace {
  $candidates = @()

  $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
  if ($codexCommand -and $codexCommand.Source) {
    $resourcesDir = Split-Path -Parent $codexCommand.Source
    $candidates += (Join-Path $resourcesDir "plugins\openai-bundled")
  }

  $configPath = Join-Path $CodexHome "config.toml"
  if (Test-Path $configPath) {
    $configText = Get-Content -Raw -LiteralPath $configPath
    $sourceMatches = [regex]::Matches($configText, "source\s*=\s*['""](?<path>[^'""]*openai-bundled[^'""]*)['""]")
    foreach ($match in $sourceMatches) {
      $candidates += $match.Groups["path"].Value
    }
  }

  $programFilesRoots = @($env:ProgramW6432, $env:ProgramFiles, "$env:SystemDrive\Program Files") |
    Where-Object { $_ } |
    Select-Object -Unique
  foreach ($programFilesRoot in $programFilesRoots) {
    $windowsApps = Join-Path $programFilesRoot "WindowsApps"
    if (Test-Path $windowsApps) {
      $packages = Get-ChildItem -LiteralPath $windowsApps -Directory -Filter "OpenAI.Codex_*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
      foreach ($package in $packages) {
        $candidates += (Join-Path $package.FullName "app\resources\plugins\openai-bundled")
      }
    }
  }

  foreach ($candidate in $candidates | Select-Object -Unique) {
    $marketplace = Join-Path $candidate ".agents\plugins\marketplace.json"
    $computerUse = Join-Path $candidate "plugins\computer-use\.codex-plugin\plugin.json"
    $chrome = Join-Path $candidate "plugins\chrome\.codex-plugin\plugin.json"
    if ((Test-Path $marketplace) -and (Test-Path $computerUse) -and (Test-Path $chrome)) {
      return [System.IO.Path]::GetFullPath($candidate)
    }
  }

  throw "Could not find bundled OpenAI plugin marketplace. Update or reinstall Codex, then retry."
}

function Read-PluginManifest {
  param([string]$PluginRoot)

  $manifestPath = Join-Path $PluginRoot ".codex-plugin\plugin.json"
  if (-not (Test-Path $manifestPath)) {
    return $null
  }

  Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
}

function Remove-ReparseOrEmptyPath {
  param(
    [string]$Path,
    [string]$Root
  )

  Assert-UnderPath -Path $Path -Root $Root
  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }

  $item = Get-Item -LiteralPath $Path -Force
  if ($item.LinkType -eq "Junction" -or $item.LinkType -eq "SymbolicLink") {
    if (-not $DryRun) {
      [System.IO.Directory]::Delete($Path)
    }
    return
  }

  $hasFiles = Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($hasFiles) {
    throw "Refusing to remove non-empty normal path: $Path"
  }

  if (-not $DryRun) {
    Remove-Item -LiteralPath $Path -Recurse -Force
  }
}

function Move-InstalledCacheAside {
  param(
    [string]$Path,
    [string]$Root
  )

  Assert-UnderPath -Path $Path -Root $Root
  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }

  $item = Get-Item -LiteralPath $Path -Force
  if ($item.LinkType -eq "Junction" -or $item.LinkType -eq "SymbolicLink") {
    if (-not $DryRun) {
      [System.IO.Directory]::Delete($Path)
    }
    return
  }

  $manifest = Join-Path $Path ".codex-plugin\plugin.json"
  $hasFiles = Get-ChildItem -LiteralPath $Path -Force -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($hasFiles -and -not (Test-Path -LiteralPath $manifest)) {
    throw "Refusing to replace non-empty cache path without plugin manifest: $Path"
  }

  $backupPath = "$Path.old-$(Get-Date -Format yyyyMMdd-HHmmss)"
  Assert-UnderPath -Path $backupPath -Root $Root
  if (-not $DryRun) {
    Move-Item -LiteralPath $Path -Destination $backupPath
  }
  Write-Step "Moved old cache aside: $backupPath"
}

function Copy-FileBytes {
  param(
    [string]$Source,
    [string]$Destination
  )

  $parent = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $inputStream = [System.IO.File]::Open($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $outputStream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
      $inputStream.CopyTo($outputStream)
    } finally {
      $outputStream.Dispose()
    }
  } finally {
    $inputStream.Dispose()
  }
}

function Copy-TreeBytes {
  param(
    [string]$Source,
    [string]$Destination
  )

  $sourceFull = [System.IO.Path]::GetFullPath($Source).TrimEnd('\') + '\'
  if ($DryRun) {
    Write-Step "Would byte-copy $Source -> $Destination"
    return
  }

  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Get-ChildItem -LiteralPath $Source -Force -Recurse -Directory | ForEach-Object {
    $relative = $_.FullName.Substring($sourceFull.Length)
    New-Item -ItemType Directory -Force -Path (Join-Path $Destination $relative) | Out-Null
  }
  Get-ChildItem -LiteralPath $Source -Force -Recurse -File | ForEach-Object {
    $relative = $_.FullName.Substring($sourceFull.Length)
    Copy-FileBytes -Source $_.FullName -Destination (Join-Path $Destination $relative)
  }
}

function Ensure-LatestJunction {
  param(
    [string]$Name,
    [string]$Source
  )

  $manifest = Read-PluginManifest -PluginRoot $Source
  if (-not $manifest) {
    Write-Step "Skipping $Name; bundled source missing."
    return
  }

  $pluginParent = Join-Path $CodexHome "plugins\cache\openai-bundled\$Name"
  $latestPath = Join-Path $pluginParent "latest"
  New-Item -ItemType Directory -Force -Path $pluginParent | Out-Null
  Assert-UnderPath -Path $latestPath -Root $CodexHome

  $existingManifest = Read-PluginManifest -PluginRoot $latestPath
  if ($existingManifest -and [string]$existingManifest.version -eq [string]$manifest.version) {
    Write-Step "$Name latest cache already current."
    return
  }

  Remove-ReparseOrEmptyPath -Path $latestPath -Root $CodexHome
  if ($DryRun) {
    Write-Step "Would create $Name latest junction: $latestPath -> $Source"
  } else {
    New-Item -ItemType Junction -Path $latestPath -Target $Source | Out-Null
    Write-Step "Created $Name latest junction: $latestPath"
  }
}

function Ensure-LatestCopy {
  param(
    [string]$Name,
    [string]$Source,
    [string[]]$RequiredRelativeFiles = @(".codex-plugin\plugin.json")
  )

  $manifest = Read-PluginManifest -PluginRoot $Source
  if (-not $manifest) {
    Write-Step "Skipping $Name; bundled source missing."
    return $null
  }

  $pluginParent = Join-Path $CodexHome "plugins\cache\openai-bundled\$Name"
  $latestPath = Join-Path $pluginParent "latest"
  $requiredFiles = $RequiredRelativeFiles | ForEach-Object { Join-Path $latestPath $_ }
  New-Item -ItemType Directory -Force -Path $pluginParent | Out-Null
  Assert-UnderPath -Path $latestPath -Root $CodexHome

  $latestItem = if (Test-Path -LiteralPath $latestPath) { Get-Item -LiteralPath $latestPath -Force } else { $null }
  $existingManifest = Read-PluginManifest -PluginRoot $latestPath
  $hasAllRequiredFiles = $true
  foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile)) {
      $hasAllRequiredFiles = $false
    }
  }

  if ($latestItem -and -not $latestItem.LinkType -and $existingManifest -and [string]$existingManifest.version -eq [string]$manifest.version -and $hasAllRequiredFiles) {
    Write-Step "$Name latest cache already current."
    return $latestPath
  }

  Move-InstalledCacheAside -Path $latestPath -Root $CodexHome
  Copy-TreeBytes -Source $Source -Destination $latestPath
  if (-not $DryRun) {
    $copiedManifest = Read-PluginManifest -PluginRoot $latestPath
    if (-not $copiedManifest) {
      throw "$Name cache copy did not produce a plugin manifest."
    }
  }
  Write-Step "Repaired $Name latest cache: $latestPath"
  return $latestPath
}

function Find-RuntimeFile {
  param([string]$FileName)

  $binRoot = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
  if (Test-Path $binRoot) {
    $match = Get-ChildItem -LiteralPath $binRoot -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if ($match) {
      return $match.FullName
    }
  }

  if ($FileName -eq "codex.exe") {
    $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
    if ($codexCommand -and $codexCommand.Source) {
      return $codexCommand.Source
    }
  }

  return $null
}

function ConvertTo-FileUrl {
  param([string]$Path)
  ([System.Uri]::new($Path)).AbsoluteUri
}

function Invoke-ChromeNativeHostInstall {
  param([string]$ChromeRoot)

  if (-not $ChromeRoot) {
    return
  }

  $installScript = Join-Path $ChromeRoot "scripts\installManifest.mjs"
  $checkScript = Join-Path $ChromeRoot "scripts\check-native-host-manifest.js"
  $nodePath = Find-RuntimeFile -FileName "node.exe"
  $nodeReplPath = Find-RuntimeFile -FileName "node_repl.exe"
  $codexCliPath = Find-RuntimeFile -FileName "codex.exe"

  if (-not $nodePath -or -not $nodeReplPath -or -not $codexCliPath -or -not (Test-Path $installScript)) {
    Write-Step "Skipping Chrome native host install; required runtime paths are missing."
    return
  }

  $payload = @{
    codexCliPath = $codexCliPath
    nodePath = $nodePath
    nodeReplPath = $nodeReplPath
  } | ConvertTo-Json -Compress

  if ($DryRun) {
    Write-Step "Would install Chrome native host manifest."
    return
  }

  $tempScript = Join-Path $env:TEMP "codex-install-chrome-native-host-$([Guid]::NewGuid().ToString('N')).mjs"
  $scriptText = @"
import { install } from '$(ConvertTo-FileUrl -Path $installScript)';
await install({ appServerRuntimePaths: $payload });
console.log('installed');
"@
  Set-Content -LiteralPath $tempScript -Value $scriptText -Encoding UTF8
  try {
    & $nodePath $tempScript
    if ($LASTEXITCODE -ne 0) {
      throw "installManifest.mjs exited with code $LASTEXITCODE"
    }
  } finally {
    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
  }

  if (Test-Path $checkScript) {
    & $nodePath $checkScript --json | Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw "Chrome native host manifest check failed with code $LASTEXITCODE"
    }
  }

  Write-Step "Chrome native host manifest installed."
}

function Repair-SkyRuntimeExports {
  $runtimeRoot = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\runtimes\cua_node"
  if (-not (Test-Path -LiteralPath $runtimeRoot)) {
    Write-Step "Skipping @oai/sky export repair; cua_node runtime root is missing."
    return
  }

  $subpath = "./dist/project/cua/sky_js/src/targets/windows/internal/computer_use_client_base.js"
  $relativeTarget = $subpath.TrimStart(".").TrimStart("/").Replace("/", "\")
  $packageJsonFiles = Get-ChildItem -LiteralPath $runtimeRoot -Recurse -File -Filter "package.json" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like "*\node_modules\@oai\sky\package.json" }

  foreach ($packageJsonFile in $packageJsonFiles) {
    $skyRoot = Split-Path -Parent $packageJsonFile.FullName
    $targetFile = Join-Path $skyRoot $relativeTarget
    if (-not (Test-Path -LiteralPath $targetFile)) {
      Write-Step "Skipping @oai/sky export repair; target file missing: $targetFile"
      continue
    }

    $packageJson = Get-Content -Raw -LiteralPath $packageJsonFile.FullName | ConvertFrom-Json
    if (-not $packageJson.exports) {
      $packageJson | Add-Member -NotePropertyName "exports" -NotePropertyValue ([pscustomobject]@{})
    }

    $hasExport = $packageJson.exports.PSObject.Properties.Name -contains $subpath
    if ($hasExport) {
      Write-Step "@oai/sky runtime export already present: $($packageJsonFile.FullName)"
      continue
    }

    if ($DryRun) {
      Write-Step "Would add @oai/sky runtime export: $($packageJsonFile.FullName)"
      continue
    }

    $packageJson.exports | Add-Member -NotePropertyName $subpath -NotePropertyValue $subpath
    $packageJson | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $packageJsonFile.FullName -Encoding UTF8
    Write-Step "Added @oai/sky runtime export: $($packageJsonFile.FullName)"
  }
}

function Enable-PluginInConfig {
  param(
    [string]$MarketplaceRoot,
    [string[]]$PluginNames
  )

  $configPath = Join-Path $CodexHome "config.toml"
  if (-not (Test-Path $configPath)) {
    if ($DryRun) {
      Write-Step "Would create $configPath"
    } else {
      New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null
      New-Item -ItemType File -Force -Path $configPath | Out-Null
    }
  }

  $content = if (Test-Path $configPath) { Get-Content -Raw -LiteralPath $configPath } else { "" }
  $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $newContent = Set-TomlTableBlock -Content $content -TableName "marketplaces.openai-bundled" -Block @"
[marketplaces.openai-bundled]
last_updated = "$timestamp"
source_type = "local"
source = $(ConvertTo-TomlLiteralString $MarketplaceRoot)
"@

  foreach ($pluginName in $PluginNames) {
    $newContent = Set-TomlTableBlock -Content $newContent -TableName "plugins.`"$pluginName@openai-bundled`"" -Block @"
[plugins."$pluginName@openai-bundled"]
enabled = true
"@
  }

  if ($newContent -eq $content) {
    Write-Step "config.toml already contains bundled plugin registrations."
    return
  }

  if ($DryRun) {
    Write-Step "Would update bundled plugin registrations in config.toml"
  } else {
    $backupPath = "$configPath.bak-repair-bundled-plugin-installs-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
    Set-Content -LiteralPath $configPath -Value $newContent -Encoding UTF8
    Write-Step "Updated config.toml; backup: $backupPath"
  }
}

$CodexHome = [System.IO.Path]::GetFullPath($CodexHome)
$bundledRoot = Find-BundledMarketplace
$computerUseRoot = Join-Path $bundledRoot "plugins\computer-use"
$chromeRoot = Join-Path $bundledRoot "plugins\chrome"
$browserRoot = Join-Path $bundledRoot "plugins\browser"

Write-Step "Codex home: $CodexHome"
Write-Step "Bundled marketplace: $bundledRoot"

Enable-PluginInConfig -MarketplaceRoot $bundledRoot -PluginNames @("computer-use", "chrome")
Ensure-LatestJunction -Name "browser" -Source $browserRoot
$computerUseLatestRoot = Ensure-LatestCopy -Name "computer-use" -Source $computerUseRoot
$chromeLatestRoot = Ensure-LatestCopy -Name "chrome" -Source $chromeRoot -RequiredRelativeFiles @(
  ".codex-plugin\plugin.json",
  "scripts\installManifest.mjs",
  "scripts\browser-client.mjs",
  "extension-host\windows\x64\extension-host.exe"
)
Invoke-ChromeNativeHostInstall -ChromeRoot $chromeLatestRoot
Repair-SkyRuntimeExports

Write-Step "Done. If the Chrome row still says disconnected, install or enable the Codex Chrome Extension in Chrome."
