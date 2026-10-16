# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

<#
.SYNOPSIS
  Uploads the collected wheels to the Azure Artifacts PyPI feed.

.DESCRIPTION
  Azure Artifacts' PyPI endpoint rejects --skip-existing (UnsupportedConfiguration),
  so each run must carry a unique version (dev/nightly builds stamp a .dev<date>
  segment; releases bump the base version). Credentials come from the .pypirc that
  TwineAuthenticate@1 writes.

.PARAMETER FeedName
  Twine repository name matching the .pypirc entry from TwineAuthenticate@1
  (typically $(pythonFeedName)).

.PARAMETER ConfigFile
  Path to the .pypirc written by TwineAuthenticate@1 (typically $(PYPIRC_PATH)).

.PARAMETER DistDir
  Directory containing the wheels to upload (typically $(distDir)).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$FeedName,
    [Parameter(Mandatory = $true)][string]$ConfigFile,
    [Parameter(Mandatory = $true)][string]$DistDir
)

$ErrorActionPreference = 'Stop'

$wheels = @(Get-ChildItem $DistDir -Filter *.whl -File)
if ($wheels.Count -eq 0) {
    Write-Error "No wheels found to upload in $DistDir"
    exit 1
}

Write-Host "Uploading $($wheels.Count) wheel(s) to feed '$FeedName' ..."
twine upload -r $FeedName --config-file $ConfigFile (Join-Path $DistDir '*.whl')
