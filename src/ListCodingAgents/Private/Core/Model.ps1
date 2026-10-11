# The one result model. Every scanner produces ListCodingAgents.Agent objects
# through New-LcaAgent so that every property always exists (StrictMode) and
# the JSON export, the terminal renderer and the HTML report all read the
# same shape. FROZEN CONTRACT: add a property only through a contract change.

$script:LcaAgentDefaults = [ordered]@{
    # identity / detection
    Id            = $null      # catalog id, else the lowercase name
    Name          = $null      # command basename, package display name, extension id ...
    DisplayName   = $null      # catalog displayName, else Name
    Vendor        = $null
    Homepage      = $null
    CatalogId     = $null      # set when a catalog entry matched
    Verified      = $false     # catalog entry is verified against primary sources
    Command       = $null      # basename found on PATH ($null for winget/registry/extension-only rows)
    Kind          = 'cli'      # cli | editor | extension
    Tier          = 'possible' # detected | possible | excluded (excluded only kept for -Explain)
    Score         = 0
    Evidence      = @()        # ListCodingAgents.Evidence objects
    Why           = ''         # v1-style comma-separated signal labels (-ShowReasons)
    # install
    Channel       = 'unknown'  # npm pnpm bun pipx uv pip cargo brew scoop choco winget vscode registry standalone unknown
    Method        = 'unknown'  # display label for Channel ('standalone installer', 'pip / uv' ...)
    Source        = ''         # what was found: a path, a winget id, an extension folder
    Path          = $null      # resolved command path when on PATH
    Package       = $null      # package name / id in its channel
    PackageDir    = $null      # package directory when known (npm, pipx venv, extension dir ...)
    Sources       = @()        # scanners that saw it: path npm winget registry pipx uv cargo brew scoop choco vscode ...
    ChannelData   = $null      # hashtable of channel-specific facts for later phases (registry UninstallString,
                               # InstallLocation, pipx venv, brew formula, winget Available ...). Not exported.
    Shadows       = @()        # later PATH entries with the same command name (paths)
    Installs      = @()        # every install of this agent seen: { Path, Channel, Version, Active } (Active = wins on PATH)
    EditorHost    = $null      # for kind 'extension': the editor it is installed in (vscode, cursor, windsurf ...)
    # versions / updates
    Version       = $null
    VersionSource = $null      # package | pe | probe | probe-cache | winget | registry | manifest
    PreviousVersion = $null    # version recorded by the previous scan when it changed
    Latest        = $null
    UpdateStatus  = 'unknown'  # current | outdated | unknown
    UpdateReason  = 'not checked'  # why the status is unknown
    UpdateCommand = $null      # ListCodingAgents.Command (Exe, Arguments, Display)
    UninstallCommand = $null   # ListCodingAgents.Command or $null
    UninstallNote = $null      # e.g. 'no safe uninstall command known'
    # footprint / usage
    InstallRoot   = $null
    InstallSizeMB = $null
    DataDirs      = @()
    DataSizeMB    = $null
    LastUsed      = $null      # [DateTimeOffset] or $null
    Usage         = 'unknown'  # active | stale | unknown
    Sessions30d   = 0
    McpCount      = 0
    McpServers    = @()        # { Name, Transport } - names only, never config values
    LoggedIn      = $false     # credential FILE or KEY NAME present; values are never read out
    IsNew         = $false
}

function New-LcaAgent {
    <# Creates a ListCodingAgents.Agent with every property defaulted. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Constructor: builds an in-memory object and changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([hashtable]$Property = @{})
    $o = [ordered]@{ PSTypeName = 'ListCodingAgents.Agent' }
    foreach ($k in $script:LcaAgentDefaults.Keys) {
        $v = $script:LcaAgentDefaults[$k]
        if ($v -is [array]) { $v = @() }
        if ($k -eq 'ChannelData') { $v = @{} }
        $o[$k] = $v
    }
    foreach ($k in $Property.Keys) {
        if (-not $script:LcaAgentDefaults.Contains($k)) { throw "New-LcaAgent: unknown property '$k'" }
        $o[$k] = $Property[$k]
    }
    if (-not $o['DisplayName']) { $o['DisplayName'] = $o['Name'] }
    if (-not $o['Id'] -and $o['Name']) { $o['Id'] = ([string]$o['Name']).ToLowerInvariant() }
    [pscustomobject]$o
}

function New-LcaEvidence {
    <#
    One scoring signal: Signal (machine id), Label (human text, as v1 printed
    it), Weight, Source (where the signal came from: name, path, npm, pe,
    winget, catalog:<id> ...) and an optional Detail.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Constructor: builds an in-memory object and changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Signal,
        [Parameter(Mandatory = $true)][string]$Label,
        [int]$Weight = 0,
        [string]$Source = '',
        [string]$Detail = ''
    )
    [pscustomobject]@{
        PSTypeName = 'ListCodingAgents.Evidence'
        Signal     = $Signal
        Label      = $Label
        Weight     = $Weight
        Source     = $Source
        Detail     = $Detail
    }
}

function ConvertTo-LcaDisplayArgument {
    <#
    Quotes one token for copy/paste into PowerShell (the shell this tool runs
    in): plain tokens stay bare (paths like C:\Tools\x.exe included); anything
    else becomes a single-quoted literal. Commas would turn into arrays and a
    bare @name would splat, so both are quoted.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Token)
    if ($Token -eq '') { return "''" }
    if ($Token -match '^[A-Za-z0-9@%+=:./\\_\-]+$' -and $Token -notmatch '^@[A-Za-z_][A-Za-z0-9_]*$') { return $Token }
    "'" + $Token.Replace("'", "''") + "'"
}

function New-LcaCommand {
    <#
    A command the user (or Update-CodingAgent) can run: an executable plus an
    argument ARRAY - never a string that gets re-parsed. Display is a
    PowerShell rendering that parses back to exactly Exe + Arguments (a
    quoted executable gets the call operator: & 'C:\Program Files\x.exe' /S).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Constructor: builds an in-memory object and changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [AllowEmptyCollection()][string[]]$Arguments = @()
    )
    $exeText = ConvertTo-LcaDisplayArgument -Token $Exe
    if ($exeText.StartsWith("'")) { $exeText = '& ' + $exeText }
    $disp = @($exeText) + @($Arguments | ForEach-Object { ConvertTo-LcaDisplayArgument -Token $_ })
    [pscustomobject]@{
        PSTypeName = 'ListCodingAgents.Command'
        Exe        = $Exe
        Arguments  = @($Arguments)
        Display    = ($disp -join ' ')
    }
}

function Get-LcaChannelLabel {
    <# Human label for a channel id; keeps v1's labels where v1 had them. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Channel)
    switch ($Channel) {
        'standalone' { return 'standalone installer' }
        'pip' { return 'pip' }
        'registry' { return 'installed app' }
        'vscode' { return 'editor extension' }
        { -not $_ } { return 'unknown' }
        default { return $Channel }
    }
}

function Get-LcaChannelOrder {
    <# Sort order of channels in reports (v1 order first). #>
    [CmdletBinding()]
    [OutputType([int])]
    param([string]$Channel)
    $order = @('npm', 'winget', 'pip / uv', 'pipx', 'uv', 'pip', 'scoop', 'cargo', 'bun', 'pnpm', 'brew', 'choco',
        'standalone', 'standalone installer', 'registry', 'installed app', 'vscode', 'editor extension', 'unknown')
    $i = [array]::IndexOf($order, $Channel)
    if ($i -lt 0) { return 50 }
    $i
}
