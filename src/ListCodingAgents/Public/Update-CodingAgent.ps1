function Update-CodingAgent {
    <#
    .SYNOPSIS
        Updates outdated AI coding agents through their own package manager.

    .DESCRIPTION
        Runs each agent's update command (an executable plus an argument array;
        nothing is re-parsed by a shell) after ShouldProcess confirmation,
        checks the exit code, then re-reads the version and prints
        "before -> after".

        Without -InputObject, runs Get-CodingAgent -CheckUpdates and updates
        every outdated agent (or the ones matching -Name).

    .PARAMETER Name
        Only update agents whose name, id or command matches these patterns.

    .PARAMETER InputObject
        Agent objects from Get-CodingAgent -CheckUpdates.

    .PARAMETER Force
        Do not ask for confirmation (for non-interactive runs). -WhatIf still
        wins.

    .PARAMETER PassThru
        Emit one result object per agent: { Name, Before, After, Status, ExitCode, Command }.

    .EXAMPLE
        Update-CodingAgent -WhatIf

    .EXAMPLE
        Get-CodingAgent -CheckUpdates -Name claude | Update-CodingAgent -Force
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Name')]
    [OutputType('ListCodingAgents.UpdateResult')]
    param(
        [Parameter(ParameterSetName = 'Name', Position = 0)][SupportsWildcards()][string[]]$Name,
        [Parameter(ParameterSetName = 'InputObject', Mandatory = $true, ValueFromPipeline = $true)][psobject[]]$InputObject,
        [switch]$Force,
        [switch]$PassThru
    )
    begin {
        $queue = New-Object System.Collections.Generic.List[object]
    }
    process {
        if ($PSCmdlet.ParameterSetName -eq 'InputObject') { foreach ($i in $InputObject) { $queue.Add($i) } }
    }
    end {
        if ($PSCmdlet.ParameterSetName -eq 'Name') {
            foreach ($a in @(Get-CodingAgent -Name $Name -CheckUpdates -All)) { $queue.Add($a) }
        }
        $todo = @($queue | Where-Object { $_.UpdateStatus -eq 'outdated' -and $_.UpdateCommand })
        foreach ($a in $todo) {
            $cmd = $a.UpdateCommand
            $target = '{0} {1} -> {2}' -f $a.Name, $a.Version, $a.Latest
            $result = [pscustomobject]@{
                PSTypeName = 'ListCodingAgents.UpdateResult'
                Name = $a.Name; Before = $a.Version; After = $null; Status = 'skipped'; ExitCode = $null; Command = $cmd.Display
            }
            if ($PSCmdlet.ShouldProcess($target, $cmd.Display) -and ($Force -or $PSCmdlet.ShouldContinue($cmd.Display, "Update $($a.Name)?"))) {
                $r = Invoke-LcaProcess -FilePath $cmd.Exe -ArgumentList $cmd.Arguments -TimeoutSec 900
                $result.ExitCode = $r.ExitCode
                if ($r.Failed) {
                    $result.Status = 'failed'
                    Write-Warning ('{0}: update failed ({1})' -f $a.Name, $r.Error)
                } else {
                    $result.Status = 'updated'
                    $result.After = $a.Latest
                }
                Write-Verbose ('{0}: {1} -> {2} [{3}]' -f $a.Name, $result.Before, $result.After, $result.Status)
            }
            if ($PassThru) { $result }
        }
    }
}
