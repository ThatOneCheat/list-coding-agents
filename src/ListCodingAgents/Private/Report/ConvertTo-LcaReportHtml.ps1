# HTML report assembly. The report is ONE self-contained file: template +
# CSS + JS + fonts (base64 WOFF2) + the scan export embedded as
# <script type="application/json">, rendered client-side with DOM APIs.

function ConvertTo-LcaScriptJson {
    <#
    JSON that is safe inside <script type="application/json">: '<', '>' and
    '&' are escaped (no "</script>" or "<!--" breakout) as are U+2028/2029.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$InputObject)
    $json = ConvertTo-LcaJson -InputObject $InputObject -Compress
    $json.Replace('<', '\u003c').Replace('>', '\u003e').Replace('&', '\u0026').Replace([string][char]0x2028, '\u2028').Replace([string][char]0x2029, '\u2029')
}

function Get-LcaReportFontCss {
    <# @font-face rules with embedded fonts; empty when no fonts are bundled. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $faces = @(
        @{ Family = 'Syne'; File = 'report/fonts/syne-latin.woff2'; Weight = '600 800' },
        @{ Family = 'JetBrains Mono'; File = 'report/fonts/jetbrains-mono-latin.woff2'; Weight = '400 700' }
    )
    $sb = New-Object System.Text.StringBuilder
    foreach ($f in $faces) {
        if (-not (Test-LcaAsset -Name $f.File -Binary)) { continue }
        $b64 = Get-LcaAsset -Name $f.File -AsBase64
        [void]$sb.Append("@font-face{font-family:'" + $f.Family + "';font-style:normal;font-weight:" + $f.Weight +
            ";font-display:swap;src:url(data:font/woff2;base64," + $b64 + ") format('woff2')}`n")
    }
    $sb.ToString()
}

function ConvertTo-LcaReportHtml {
    <# Builds the report from an export (ConvertTo-LcaExport). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)]$Export)
    $template = Get-LcaAsset -Name 'report/template.html'
    $css = Get-LcaAsset -Name 'report/report.css'
    $js = Get-LcaAsset -Name 'report/report.js'
    $fonts = Get-LcaReportFontCss
    $data = ConvertTo-LcaScriptJson -InputObject $Export
    # Plain string replacement (no regex) - data never passes through a
    # replacement-pattern parser. DATA goes last so its content can't be
    # mistaken for another placeholder.
    $html = $template.Replace('/*{{FONTS}}*/', $fonts).Replace('/*{{CSS}}*/', $css).Replace('/*{{JS}}*/', $js)
    $html.Replace('{{DATA}}', $data)
}
