function Export-CodingAgentReport {
    <#
    .SYNOPSIS
        Writes the HTML report and/or the JSON export for a scan.

    .DESCRIPTION
        Takes a scan from Get-CodingAgent -AsScan (or runs one) and writes
        coding-agents.html (self-contained, no network requests) and/or
        coding-agents.json (schema/coding-agents.schema.json) to -OutDir.

    .PARAMETER Scan
        A ListCodingAgents.Scan from Get-CodingAgent -AsScan. When omitted a
        new scan runs.

    .PARAMETER OutDir
        Output folder. Defaults to the current directory.

    .PARAMETER Format
        html, json or both. Default: html.

    .PARAMETER Redact
        Strip the user name and host name from the files (for sharing).

    .PARAMETER Open
        Open the HTML report afterwards.

    .PARAMETER PassThru
        Emit the written files as FileInfo objects.

    .EXAMPLE
        Get-CodingAgent -AsScan -All | Export-CodingAgentReport -Format html, json -OutDir ./out
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(ValueFromPipeline = $true)]$Scan,
        [string]$OutDir,
        [ValidateSet('html', 'json')][string[]]$Format = @('html'),
        [switch]$Redact,
        [switch]$Open,
        [switch]$PassThru
    )
    process {
        if (-not $Scan) { $Scan = Get-CodingAgent -AsScan }
        $ctx = Get-LcaProperty -InputObject $Scan -Name 'Context'
        if (-not $ctx) { throw 'Export-CodingAgentReport: pass a scan from Get-CodingAgent -AsScan' }
        if (-not $OutDir) { $OutDir = (Get-Location).ProviderPath }
        $export = ConvertTo-LcaExport -Scan $Scan -Context $ctx -Redact:$Redact
        foreach ($f in $Format) {
            if ($f -eq 'json') {
                $p = Join-Path -Path $OutDir -ChildPath 'coding-agents.json'
                Write-LcaTextFile -Path $p -Content ((ConvertTo-LcaJson -InputObject $export) + "`n")
            } else {
                $p = Join-Path -Path $OutDir -ChildPath 'coding-agents.html'
                Write-LcaTextFile -Path $p -Content (ConvertTo-LcaReportHtml -Export $export)
                if ($Open) { Open-LcaReport -Path $p }
            }
            if ($PassThru) { Get-Item -LiteralPath $p }
        }
    }
}
