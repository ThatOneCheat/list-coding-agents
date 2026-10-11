# Module assets (data/catalog.json, report/*). In the module they are files
# next to the code; in the single-file bundle build.ps1 embeds them in
# $script:LcaEmbeddedAssets (text) and $script:LcaEmbeddedBinary (base64).

if (-not (Get-Variable -Name 'LcaEmbeddedAssets' -Scope Script -ErrorAction Ignore)) { $script:LcaEmbeddedAssets = $null }
if (-not (Get-Variable -Name 'LcaEmbeddedBinary' -Scope Script -ErrorAction Ignore)) { $script:LcaEmbeddedBinary = $null }
if (-not (Get-Variable -Name 'LcaModuleRoot' -Scope Script -ErrorAction Ignore)) { $script:LcaModuleRoot = $null }
$script:LcaCatalogCache = $null

function Get-LcaAsset {
    <#
    Returns a text asset by its module-relative path ('data/catalog.json'),
    or with -AsBase64 a binary asset as a base64 string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Name, [switch]$AsBase64)
    $key = $Name.Replace('\', '/')
    if ($AsBase64) {
        if ($null -ne $script:LcaEmbeddedBinary) {
            if (-not $script:LcaEmbeddedBinary.ContainsKey($key)) { throw "embedded asset not found: $key" }
            return ($script:LcaEmbeddedBinary[$key] -replace '\s', '')
        }
    } elseif ($null -ne $script:LcaEmbeddedAssets) {
        if (-not $script:LcaEmbeddedAssets.ContainsKey($key)) { throw "embedded asset not found: $key" }
        return $script:LcaEmbeddedAssets[$key]
    }
    if (-not $script:LcaModuleRoot) { throw 'module root unknown' }
    $p = $script:LcaModuleRoot
    foreach ($seg in $key.Split('/')) { $p = Join-Path -Path $p -ChildPath $seg }
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "asset not found: $key" }
    if ($AsBase64) { return [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($p)) }
    (Read-LcaTextFile -Path $p) -replace "`r`n", "`n"
}

function Test-LcaAsset {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Name, [switch]$Binary)
    $key = $Name.Replace('\', '/')
    if ($Binary -and $null -ne $script:LcaEmbeddedBinary) { return $script:LcaEmbeddedBinary.ContainsKey($key) }
    if (-not $Binary -and $null -ne $script:LcaEmbeddedAssets) { return $script:LcaEmbeddedAssets.ContainsKey($key) }
    if (-not $script:LcaModuleRoot) { return $false }
    $p = $script:LcaModuleRoot
    foreach ($seg in $key.Split('/')) { $p = Join-Path -Path $p -ChildPath $seg }
    Test-Path -LiteralPath $p -PathType Leaf
}

function Get-LcaCatalog {
    <# The parsed agent catalog (data/catalog.json), cached per session. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([switch]$Force)
    if ($script:LcaCatalogCache -and -not $Force) { return $script:LcaCatalogCache }
    $script:LcaCatalogCache = ConvertFrom-LcaJson -Text (Get-LcaAsset -Name 'data/catalog.json')
    $script:LcaCatalogCache
}

function Get-LcaToolVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $script:LcaToolVersion
}
