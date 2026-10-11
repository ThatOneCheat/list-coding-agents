# Dot-source from a test file's BeforeAll:
#   BeforeAll { . (Join-Path $PSScriptRoot '../Helpers/Bootstrap.ps1') }
# Loads the module from src/ and the fixture helpers. Sets $RepoRoot.
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../..')).ProviderPath
Import-Module -Name (Join-Path -Path $RepoRoot -ChildPath 'src/ListCodingAgents/ListCodingAgents.psd1') -Force
Import-Module -Name (Join-Path -Path $RepoRoot -ChildPath 'tests/Helpers/Fixture.psm1') -Force
$IsWin = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
$IsDesktop = $PSVersionTable.PSEdition -ne 'Core'
