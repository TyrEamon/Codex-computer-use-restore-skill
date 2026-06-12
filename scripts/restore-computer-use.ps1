param(
  [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }),
  [switch]$DryRun,
  [switch]$OpenSettings
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$Message) {
  Write-Host "[restore-computer-use] $Message"
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
    throw "Refusing to modify path outside Codex home: $resolvedPath"
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

  $configuredRoot = Join-Path $CodexHome "plugins\cache\openai-bundled"
  if (Test-Path $configuredRoot) {
    $candidates += $configuredRoot
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

  $localCandidates = @(
    (Join-Path $env:LOCALAPPDATA "OpenAI\Codex\resources\plugins\openai-bundled"),
    (Join-Path $env:LOCALAPPDATA "Programs\Codex\resources\plugins\openai-bundled")
  )
  $candidates += $localCandidates

  foreach ($candidate in $candidates | Select-Object -Unique) {
    $marketplace = Join-Path $candidate ".agents\plugins\marketplace.json"
    $plugin = Join-Path $candidate "plugins\computer-use\.codex-plugin\plugin.json"
    if ((Test-Path $marketplace) -and (Test-Path $plugin)) {
      return [System.IO.Path]::GetFullPath($candidate)
    }
  }

  throw "Could not find bundled Computer Use plugin. Update or reinstall Codex, then retry."
}

$CodexHome = [System.IO.Path]::GetFullPath($CodexHome)
$configPath = Join-Path $CodexHome "config.toml"
$bundledRoot = Find-BundledMarketplace
$pluginRoot = Join-Path $bundledRoot "plugins\computer-use"
$pluginManifest = Join-Path $pluginRoot ".codex-plugin\plugin.json"
$pluginJson = Get-Content -Raw -LiteralPath $pluginManifest | ConvertFrom-Json
$version = [string]$pluginJson.version
if (-not $version) {
  throw "Computer Use plugin manifest did not contain a version."
}

Write-Step "Codex home: $CodexHome"
Write-Step "Bundled plugin: $pluginRoot"
Write-Step "Computer Use version: $version"

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
$marketplaceBlock = @"
[marketplaces.openai-bundled]
last_updated = "$timestamp"
source_type = "local"
source = $(ConvertTo-TomlLiteralString $bundledRoot)
"@

$pluginBlock = @"
[plugins."computer-use@openai-bundled"]
enabled = true
"@

$newContent = Set-TomlTableBlock -Content $content -TableName "marketplaces.openai-bundled" -Block $marketplaceBlock
$newContent = Set-TomlTableBlock -Content $newContent -TableName 'plugins."computer-use@openai-bundled"' -Block $pluginBlock

if ($newContent -ne $content) {
  if ($DryRun) {
    Write-Step "Would update $configPath"
  } else {
    $backupPath = "$configPath.bak-restore-computer-use-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
    Set-Content -LiteralPath $configPath -Value $newContent -Encoding UTF8
    Write-Step "Updated config.toml; backup: $backupPath"
  }
} else {
  Write-Step "config.toml already contains Computer Use registration."
}

$cacheParent = Join-Path $CodexHome "plugins\cache\openai-bundled\computer-use"
$cacheVersionPath = Join-Path $cacheParent $version
Assert-UnderPath -Path $cacheParent -Root $CodexHome
Assert-UnderPath -Path $cacheVersionPath -Root $CodexHome

if (Test-Path $cacheVersionPath) {
  $existingManifest = Join-Path $cacheVersionPath ".codex-plugin\plugin.json"
  if (Test-Path $existingManifest) {
    Write-Step "Plugin cache entry already exists: $cacheVersionPath"
  } else {
    $children = Get-ChildItem -LiteralPath $cacheVersionPath -Force -Recurse -ErrorAction SilentlyContinue
    $hasFiles = $children | Where-Object { -not $_.PSIsContainer } | Select-Object -First 1
    if ($hasFiles) {
      throw "Refusing to replace non-empty cache path without a plugin manifest: $cacheVersionPath"
    }
    if ($DryRun) {
      Write-Step "Would replace empty cache path with a junction: $cacheVersionPath"
    } else {
      Remove-Item -LiteralPath $cacheVersionPath -Recurse -Force
      New-Item -ItemType Junction -Path $cacheVersionPath -Target $pluginRoot | Out-Null
      Write-Step "Created plugin cache junction: $cacheVersionPath"
    }
  }
} else {
  if ($DryRun) {
    Write-Step "Would create cache junction: $cacheVersionPath -> $pluginRoot"
  } else {
    New-Item -ItemType Directory -Force -Path $cacheParent | Out-Null
    New-Item -ItemType Junction -Path $cacheVersionPath -Target $pluginRoot | Out-Null
    Write-Step "Created plugin cache junction: $cacheVersionPath"
  }
}

if ($OpenSettings) {
  if ($DryRun) {
    Write-Step "Would open codex://settings/computer-use"
  } else {
    Start-Process "codex://settings/computer-use"
    Write-Step "Opened Computer Use settings."
  }
}

Write-Step "Done. Restart Codex if the settings page does not refresh immediately."
