# Progress reporting for the scan phases. Workstream D owns the rendering.

function Write-LcaProgress {
    <#
    Reports scan progress (Write-Progress) unless the context says to stay
    quiet. -Completed clears the bar.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [string]$Status = '',
        [int]$PercentComplete = -1,
        [switch]$Completed
    )
    if ($Context.Data.ContainsKey('quiet') -and $Context.Data['quiet']) { return }
    if ($Completed) { Write-Progress -Activity 'list-coding-agents' -Completed; return }
    Write-Progress -Activity 'list-coding-agents' -Status $Status -PercentComplete $PercentComplete
}
