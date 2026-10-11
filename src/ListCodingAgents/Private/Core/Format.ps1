# Small formatting helpers shared by the terminal renderer, the JSON export
# and the report. Invariant culture everywhere so output does not change with
# the user's locale ("2,5 GB" vs "2.5 GB").

function Format-LcaSize {
    <#
    Formats megabytes. $null -> '' (unknown); 0 -> '0 MB' (v1 printed
    '<0.1 MB' for an empty fleet); otherwise MB/GB like v1.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Mb)
    if ($null -eq $Mb -or "$Mb" -eq '') { return '' }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $v = [double]$Mb
    if ($v -le 0) { return '0 MB' }
    if ($v -lt 0.1) { return '<0.1 MB' }
    if ($v -ge 1024) { return ($v / 1024).ToString('N1', $inv) + ' GB' }
    if ($v -ge 10) { return $v.ToString('N0', $inv) + ' MB' }
    $v.ToString('N1', $inv) + ' MB'
}

function Format-LcaAge {
    <# 'today', 'yesterday', '12d ago', '3mo ago', '2y ago' relative to Now. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Date, [Parameter(Mandatory = $true)][System.DateTimeOffset]$Now)
    if ($null -eq $Date) { return '' }
    $d = ConvertTo-LcaDateTimeOffset -Value $Date
    if ($null -eq $d) { return '' }
    $days = ($Now - $d).TotalDays
    if ($days -lt 1) { return 'today' }
    if ($days -lt 2) { return 'yesterday' }
    if ($days -lt 60) { return ('{0}d ago' -f [int][math]::Floor($days)) }
    if ($days -lt 365) { return ('{0}mo ago' -f [int][math]::Floor($days / 30)) }
    ('{0}y ago' -f [int][math]::Floor($days / 365))
}

function ConvertTo-LcaDateTimeOffset {
    <# Accepts DateTimeOffset, DateTime or an ISO string; returns $null otherwise. #>
    [CmdletBinding()]
    [OutputType([System.DateTimeOffset])]
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.DateTimeOffset]) { return $Value }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) { return New-Object System.DateTimeOffset ([datetime]::SpecifyKind($Value, [System.DateTimeKind]::Local)) }
        return New-Object System.DateTimeOffset ($Value)
    }
    $parsed = [System.DateTimeOffset]::MinValue
    if ([System.DateTimeOffset]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) {
        return $parsed
    }
    $null
}

function ConvertTo-LcaIsoString {
    <# ISO 8601 with UTC offset (v1 exported local time without one). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Value)
    $d = ConvertTo-LcaDateTimeOffset -Value $Value
    if ($null -eq $d) { return $null }
    $d.ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-LcaRoundedNumber {
    [CmdletBinding()]
    [OutputType([double])]
    param([AllowNull()]$Value, [int]$Digits = 1)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    [math]::Round([double]$Value, $Digits)
}
