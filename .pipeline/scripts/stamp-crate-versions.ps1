# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

<#
.SYNOPSIS
  Stamps publishable crate manifests with the version for the current build.

.DESCRIPTION
  Official builds retain the source version. Non-official scheduled builds use a
  nightly version, while other non-official builds use a unique dev version.
  mssql-mock-tds is kept aligned with mssql-tds, including its dependency version.
  All inputs and planned edits are validated before logging versions or writing.
  See README.md for supported manifest syntax and version inputs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BuildReason,

    [Parameter(Mandatory = $true)]
    [string]$BuildId,

    [string]$IsOfficial = 'False',

    [string[]]$Crates = @('mssql-tds', 'mssql-mock-tds'),

    [switch]$WhatIf,

    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..'))
)

$ErrorActionPreference = 'Stop'

function Assert-SemVer {
    param([Parameter(Mandatory = $true)][string]$Version)

    $number = '(?:0|[1-9][0-9]*)'
    $identifier = '(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
    $pattern = "\A$number\.$number\.$number(?:-$identifier(?:\.$identifier)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z"
    if ($Version -cnotmatch $pattern) {
        throw 'Expected a valid single-line SemVer version.'
    }
    foreach ($component in ($Version -split '[-+]', 2)[0].Split('.')) {
        $value = [uint64]0
        if (-not [uint64]::TryParse($component, [ref]$value)) {
            throw 'SemVer core components must fit a Cargo unsigned 64-bit integer.'
        }
    }
}

function Get-PackageVersionMatch {
    param([Parameter(Mandatory = $true)][string]$Content, [Parameter(Mandatory = $true)][string]$Path)

    $sections = [regex]::Matches($Content, '(?ms)^[ \t]*\[[ \t]*package[ \t]*\][ \t]*(?:#[^\r\n]*)?(?:\r?\n|\z).*?(?=^[ \t]*\[|\z)')
    # Quoted/dotted package keys and multiline strings need a TOML parser; do
    # not let them introduce a second declaration that a line matcher misses.
    if ($sections.Count -ne 1 -or
        $Content -match '(?m)^[ \t]*(?:\[\[?[ \t]*["'']|\[\[[ \t]*package\b|\[[ \t]*package[ \t]*\.[ \t]*(?:version\b|["''])|package[ \t]*[.=])') {
        throw "Expected one bare [package] table in $Path"
    }

    $section = $sections[0]
    if ($section.Value -match '(?m)^[ \t]*["'']' -or $section.Value -match '"""|''''''') {
        throw "Quoted package keys and multiline package strings are unsupported in $Path"
    }
    $declarations = [regex]::Matches($section.Value, '(?m)^[ \t]*version\b')
    $versions = [regex]::Matches($section.Value, '(?m)^[ \t]*version[ \t]*=[ \t]*"(?<version>[^"\r\n]*)"[ \t]*(?:#[^\r\n]*)?\r?$')
    if ($declarations.Count -ne 1 -or $versions.Count -ne 1) {
        throw "Expected one literal package version in $Path"
    }
    $version = $versions[0].Groups['version']
    Assert-SemVer -Version $version.Value
    if ($version.Value -match '-(?:dev|nightly)\.[0-9]{8}(?:\.|$)') {
        throw "Source manifest is already stamped with a build version in $Path"
    }
    return [pscustomobject]@{
        Version = $version.Value
        Index = $section.Index + $version.Index
        Length = $version.Length
    }
}

function Set-PackageVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)]$VersionMatch
    )

    return $Content.Substring(0, $VersionMatch.Index) + $Version +
        $Content.Substring($VersionMatch.Index + $VersionMatch.Length)
}

function Set-MssqlTdsDependencyVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $declarations = [regex]::Matches($Content, '(?m)^[ \t]*(?:mssql-tds|["'']mssql-tds["''])[ \t]*[=.]')
    $sections = [regex]::Matches($Content, '(?ms)^[ \t]*\[dependencies\][ \t]*(?:#[^\r\n]*)?(?:\r?\n|\z).*?(?=^[ \t]*\[|\z)')
    if ($declarations.Count -ne 1 -or $sections.Count -ne 1 -or
        $Content -match '(?m)^[ \t]*\[[^\r\n]*mssql-tds') {
        throw "Expected one inline mssql-tds dependency in [dependencies] in $Path"
    }

    $section = $sections[0]
    if ($section.Value -match '(?m)^[ \t]*["'']' -or $section.Value -match '"""|''''''') {
        throw "Quoted dependency keys and multiline dependency strings are unsupported in $Path"
    }
    $dependencies = [regex]::Matches($section.Value, '(?m)^[ \t]*mssql-tds[ \t]*=[ \t]*\{(?<fields>[^{}\r\n]*)\}[ \t]*(?:#[^\r\n]*)?\r?$')
    if ($dependencies.Count -ne 1) {
        throw "Expected one single-line mssql-tds inline dependency in $Path"
    }
    $fields = $dependencies[0].Groups['fields']
    $keys = [regex]::Matches($fields.Value, '(?:\A|,)[ \t]*version\b')
    $versions = [regex]::Matches($fields.Value, '(?:\A|,)[ \t]*version[ \t]*=[ \t]*"(?<version>[^"\r\n]*)"[ \t]*(?=,|\z)')
    if ($keys.Count -ne 1 -or $versions.Count -ne 1 -or
        $fields.Value -match '(?:\A|,)[ \t]*["'']|\\') {
        throw "Expected one literal mssql-tds dependency version with bare keys in $Path"
    }
    $versionMatch = $versions[0].Groups['version']
    Assert-SemVer -Version $versionMatch.Value
    $index = $section.Index + $fields.Index + $versionMatch.Index
    return $Content.Substring(0, $index) + $Version +
        $Content.Substring($index + $versionMatch.Length)
}

if ($BuildReason -cnotmatch '\A[A-Za-z][A-Za-z0-9]*\z') {
    throw 'BuildReason must be an ASCII alphanumeric reason beginning with a letter.'
}
if ($BuildId -cnotmatch '\A[1-9][0-9]*\z') {
    throw 'BuildId must be a positive decimal integer without leading zeroes.'
}
$isOfficialBuild = $false
if ($IsOfficial -notmatch '\A(?:True|False)\z' -or -not [bool]::TryParse($IsOfficial, [ref]$isOfficialBuild)) {
    throw 'IsOfficial must be True or False.'
}
if ([string]::IsNullOrWhiteSpace($RepositoryRoot) -or $RepositoryRoot -match '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]|##(?:vso\[|\[)') {
    throw 'RepositoryRoot must be a nonempty path without control characters or logging commands.'
}
if ($Crates.Count -eq 0) {
    throw 'Crates must contain at least one crate directory.'
}
$seen = @{}
$manifests = foreach ($crate in $Crates) {
    if ($crate -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_-]*\z' -or $seen.ContainsKey($crate)) {
        throw 'Crates must contain unique bare crate directory names.'
    }
    $seen[$crate] = $true
    $path = Join-Path (Join-Path $RepositoryRoot $crate) 'Cargo.toml'
    $content = Get-Content -LiteralPath $path -Raw
    $versionMatch = Get-PackageVersionMatch -Content $content -Path $path
    [pscustomobject]@{ Path = $path; Crate = $crate; Content = $content; VersionMatch = $versionMatch }
}
$baseVersion = @($manifests)[0].VersionMatch.Version
$dateStamp = Get-Date -Format 'yyyyMMdd'

if ($isOfficialBuild) {
    $crateVersion = $baseVersion
}
else {
    if ($baseVersion.Contains('+')) {
        throw 'Non-official builds do not support source build metadata.'
    }
    if ($BuildReason -eq 'Schedule') {
        $crateVersion = "$baseVersion-nightly.$dateStamp"
    }
    else {
        $crateVersion = "$baseVersion-dev.$dateStamp.$BuildId"
    }
}
Assert-SemVer -Version $crateVersion

$edits = foreach ($manifest in $manifests) {
    $updated = Set-PackageVersion -Content $manifest.Content -Version $crateVersion -VersionMatch $manifest.VersionMatch
    if ($manifest.Crate -eq 'mssql-mock-tds') {
        $updated = Set-MssqlTdsDependencyVersion -Content $updated -Version $crateVersion -Path $manifest.Path
    }
    [pscustomobject]@{ Path = $manifest.Path; Content = $manifest.Content; Updated = $updated }
}

Write-Host "Build reason:  $BuildReason"
Write-Host "Base version:  $baseVersion"
Write-Host "Crate version: $crateVersion"

foreach ($edit in $edits) {
    $path = $edit.Path
    if ($WhatIf) {
        Write-Host "[WhatIf] Would patch $path -> version = `"$crateVersion`""
    }
    elseif ($edit.Content -ne $edit.Updated) {
        Set-Content -LiteralPath $path -Value $edit.Updated -NoNewline
        Write-Host "Patched $path -> version = `"$crateVersion`""
    }
    else {
        Write-Host "$path already uses version `"$crateVersion`""
    }
}

if (-not $WhatIf) {
    Write-Host "##vso[task.setvariable variable=crateVersion]$crateVersion"
    Write-Host "##vso[task.setvariable variable=crateVersion;isOutput=true]$crateVersion"
}

Write-Host "Done. Crate version: $crateVersion"
