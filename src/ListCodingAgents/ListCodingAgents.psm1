# ListCodingAgents module loader. build.ps1 inlines the same files, in the
# same order, into the single-file list-coding-agents.ps1.
Set-StrictMode -Version Latest

$script:LcaModuleRoot = $PSScriptRoot
$script:LcaEmbeddedAssets = $null
$script:LcaEmbeddedBinary = $null

$lcaFiles = @(
    Get-ChildItem -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'Private') -Filter '*.ps1' -Recurse -File
    Get-ChildItem -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'Public') -Filter '*.ps1' -File
)
$lcaRoot = $PSScriptRoot
$lcaOrdered = $lcaFiles | Sort-Object -Property @{ Expression = {
        $rel = $_.FullName.Substring($lcaRoot.Length + 1).Replace('\', '/')
        # Private before Public, then ordinal by relative path (matches build.ps1)
        $rank = '1'
        if ($rel.StartsWith('Private/')) { $rank = '0' }
        $rank + '|' + $rel.ToLowerInvariant()
    }
}
foreach ($lcaFile in $lcaOrdered) { . $lcaFile.FullName }
Remove-Variable -Name lcaFiles, lcaRoot, lcaOrdered, lcaFile -ErrorAction Ignore

Export-ModuleMember -Function 'Get-CodingAgent', 'Update-CodingAgent', 'Export-CodingAgentReport'
