# The ONE JSON export (schema/coding-agents.schema.json). coding-agents.json,
# -Format json and the HTML report's embedded data all come from
# ConvertTo-LcaExport, so they can never disagree.

function ConvertTo-LcaCommandExport {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([AllowNull()]$Command)
    if ($null -eq $Command) { return $null }
    [ordered]@{ exe = $Command.Exe; args = @($Command.Arguments); display = $Command.Display }
}

function ConvertTo-LcaAgentExport {
    <# One agent as an ordered dictionary with the schema's camelCase keys. #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory = $true)]$Agent)
    $a = $Agent
    $upd = ''; if ($a.UpdateCommand) { $upd = $a.UpdateCommand.Display }
    $unin = ''; if ($a.UninstallCommand) { $unin = $a.UninstallCommand.Display }
    [ordered]@{
        id               = $a.Id
        name             = $a.Name
        displayName      = $a.DisplayName
        vendor           = $a.Vendor
        homepage         = $a.Homepage
        catalogId        = $a.CatalogId
        verified         = [bool]$a.Verified
        tier             = $a.Tier
        kind             = $a.Kind
        score            = [int]$a.Score
        why              = $a.Why
        evidence         = @($a.Evidence | ForEach-Object {
                [ordered]@{ signal = $_.Signal; label = $_.Label; weight = [int]$_.Weight; source = $_.Source; detail = $_.Detail }
            })
        command          = $a.Command
        source           = $a.Source
        path             = $a.Path
        method           = $a.Method
        channel          = $a.Channel
        package          = $a.Package
        packageDir       = $a.PackageDir
        sources          = @($a.Sources)
        shadowedBy       = @($a.Shadows)
        version          = $a.Version
        versionSource    = $a.VersionSource
        previousVersion  = $a.PreviousVersion
        latest           = $a.Latest
        updateStatus     = $a.UpdateStatus
        updateReason     = $a.UpdateReason
        updateCmd        = $upd
        updateCommand    = (ConvertTo-LcaCommandExport -Command $a.UpdateCommand)
        uninstallCmd     = $unin
        uninstallCommand = (ConvertTo-LcaCommandExport -Command $a.UninstallCommand)
        uninstallNote    = $a.UninstallNote
        sizeMB           = (ConvertTo-LcaRoundedNumber -Value $a.InstallSizeMB -Digits 2)
        installRoot      = $a.InstallRoot
        installSizeMB    = (ConvertTo-LcaRoundedNumber -Value $a.InstallSizeMB -Digits 2)
        dataDirs         = @($a.DataDirs)
        dataSizeMB       = (ConvertTo-LcaRoundedNumber -Value $a.DataSizeMB -Digits 2)
        lastUsed         = (ConvertTo-LcaIsoString -Value $a.LastUsed)
        usage            = $a.Usage
        stale            = ($a.Usage -eq 'stale')
        sessions30d      = [int]$a.Sessions30d
        mcpServers       = [int]$a.McpCount
        mcp              = @($a.McpServers | ForEach-Object { [ordered]@{ name = $_.Name; transport = $_.Transport } })
        loggedIn         = [bool]$a.LoggedIn
        isNew            = [bool]$a.IsNew
    }
}

function ConvertTo-LcaExport {
    <#
    Scan -> ordered dictionary matching schema/coding-agents.schema.json.
    Agents are the display-scope rows (as v1's -Json: editors only with
    -IncludeEditors). -Redact strips the user name and host name.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory = $true)]$Scan, [Parameter(Mandatory = $true)]$Context, [switch]$Redact)
    $inScope = @(Select-LcaAgentInScope -Context $Context -Agent $Scan.Agents)
    $sorted = @($inScope | Sort-Object -Property @{ Expression = { if ($_.Tier -eq 'detected') { 0 } else { 1 } } }, @{ Expression = { $_.Name } })
    $h = $Scan.Health
    $c = $Scan.Changes
    $export = [ordered]@{
        schemaVersion = [int]$Scan.SchemaVersion
        tool          = [ordered]@{ name = 'list-coding-agents'; version = $Scan.ToolVersion }
        generatedAt   = (ConvertTo-LcaIsoString -Value $Scan.GeneratedAt)
        host          = $Scan.HostName
        user          = $Scan.UserName
        platform      = $Scan.Platform
        powershell    = $Scan.PowerShell
        redacted      = [bool]$Redact
        scope         = [ordered]@{
            includeEditors    = [bool]$Scan.Scope.IncludeEditors
            includeExtensions = [bool]$Scan.Scope.IncludeExtensions
            wingetScanned     = [bool]$Scan.Scope.WingetScanned
            partial           = [bool]$Scan.Scope.Partial
            partialReason     = $Scan.Scope.PartialReason
        }
        summary       = [ordered]@{
            detected   = [int]$h.DetectedCount
            possible   = [int]$h.PossibleCount
            channels   = [int]$h.Channels
            totalMB    = [double]$h.TotalMB
            reclaimMB  = [double]$h.ReclaimMB
            active30   = [int]$h.Active30
            rank       = $h.Rank
            deadWeight = @($h.DeadWeight)
            conflicts  = @($h.Conflicts)
            outdated   = @($h.Outdated)
        }
        changes       = [ordered]@{
            previousScan   = $(if ($c.PreviousDate) { [string]$c.PreviousDate } else { $null })
            new            = @($c.New)
            gone           = @($c.Gone)
            versionChanges = @($c.VersionChanges | ForEach-Object { [ordered]@{ name = $_.Name; from = $_.From; to = $_.To } })
        }
        history       = @($Scan.History | ForEach-Object {
                $e = [ordered]@{ d = [string]$_.d; c = [int]$_.c; mb = [double]$_.mb }
                $v = Get-LcaProperty -InputObject $_ -Name 'v'
                if ($v) { $e['v'] = $v }
                $e
            })
        agents        = @($sorted | ForEach-Object { ConvertTo-LcaAgentExport -Agent $_ })
        diagnostics   = @($Scan.Diagnostics | ForEach-Object { [ordered]@{ source = $_.Source; level = $_.Level; message = $_.Message } })
    }
    if ($Redact) {
        $export = ConvertTo-LcaRedacted -InputObject $export -HomeDir $Scan.HomeDir -UserName $Scan.UserName
        $export['host'] = $null
        $export['user'] = $null
        $export['redacted'] = $true
    }
    $export
}

function ConvertTo-LcaRedacted {
    <#
    Deep copy with every string scrubbed: the home directory becomes '~' and
    any remaining occurrence of the user name becomes '<user>'.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()]$InputObject, [AllowNull()][string]$HomeDir, [AllowNull()][string]$UserName)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string]) {
        $s = $InputObject
        if ($HomeDir -and $HomeDir.Length -gt 1) {
            $s = [regex]::Replace($s, ('(?i)' + [regex]::Escape($HomeDir.TrimEnd('\', '/'))), '~')
            $alt = $HomeDir.TrimEnd('\', '/').Replace('\', '/')
            $s = [regex]::Replace($s, ('(?i)' + [regex]::Escape($alt)), '~')
        }
        if ($UserName -and $UserName.Length -ge 2) {
            $s = [regex]::Replace($s, ('(?i)(?<![A-Za-z0-9])' + [regex]::Escape($UserName) + '(?![A-Za-z0-9])'), '<user>')
        }
        return $s
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in @($InputObject.Keys)) { $o[$k] = ConvertTo-LcaRedacted -InputObject $InputObject[$k] -HomeDir $HomeDir -UserName $UserName }
        return $o
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = @(foreach ($i in $InputObject) { , (ConvertTo-LcaRedacted -InputObject $i -HomeDir $HomeDir -UserName $UserName) })
        return , $list
    }
    if ($InputObject -is [pscustomobject]) {
        $o = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) { $o[$p.Name] = ConvertTo-LcaRedacted -InputObject $p.Value -HomeDir $HomeDir -UserName $UserName }
        return $o
    }
    $InputObject
}
