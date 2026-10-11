BeforeDiscovery {
    $IsWin = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    $IsDesktop = $PSVersionTable.PSEdition -ne 'Core'
}
BeforeAll { . (Join-Path $PSScriptRoot '../Helpers/Bootstrap.ps1') }

Describe 'New-LcaAgent' {
    It 'defaults every property and keeps arrays independent' {
        InModuleScope ListCodingAgents {
            $a = New-LcaAgent -Property @{ Name = 'claude' }
            $b = New-LcaAgent -Property @{ Name = 'codex' }
            $a.PSObject.TypeNames[0] | Should -Be 'ListCodingAgents.Agent'
            $a.Id | Should -Be 'claude'
            $a.DisplayName | Should -Be 'claude'
            $a.Kind | Should -Be 'cli'
            $a.UpdateStatus | Should -Be 'unknown'
            $a.Usage | Should -Be 'unknown'
            $a.Shadows = @('x')
            @($b.Shadows).Count | Should -Be 0
        }
    }
    It 'rejects unknown properties (frozen contract)' {
        InModuleScope ListCodingAgents {
            { New-LcaAgent -Property @{ Nmae = 'typo' } } | Should -Throw '*unknown property*'
        }
    }
}

Describe 'New-LcaCommand' {
    It 'keeps an argument array and renders a paste-safe display' {
        InModuleScope ListCodingAgents {
            $c = New-LcaCommand -Exe 'npm' -Arguments @('i', '-g', '@anthropic-ai/claude-code@latest')
            $c.Arguments | Should -Be @('i', '-g', '@anthropic-ai/claude-code@latest')
            $c.Display | Should -Be 'npm i -g @anthropic-ai/claude-code@latest'
            $d = New-LcaCommand -Exe 'winget' -Arguments @('upgrade', '--id', 'A.B $(rm -rf ~)', "it's")
            $d.Display | Should -Be "winget upgrade --id 'A.B `$(rm -rf ~)' 'it''s'"
        }
    }
}

Describe 'Format-LcaSize' {
    It 'formats <In> as "<Out>"' -TestCases @(
        @{ In = $null; Out = '' }
        @{ In = 0; Out = '0 MB' }
        @{ In = 0.0; Out = '0 MB' }
        @{ In = 0.04; Out = '<0.1 MB' }
        @{ In = 5.26; Out = '5.3 MB' }
        @{ In = 123.4; Out = '123 MB' }
        @{ In = 2560; Out = '2.5 GB' }
    ) {
        param($In, $Out)
        InModuleScope ListCodingAgents -Parameters @{ In = $In; Out = $Out } {
            param($In, $Out)
            Format-LcaSize -Mb $In | Should -BeExactly $Out
        }
    }
    It 'ignores the current culture' {
        $saved = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
            InModuleScope ListCodingAgents { Format-LcaSize -Mb 2560 | Should -BeExactly '2.5 GB' }
        } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $saved }
    }
}

Describe 'Dates' {
    It 'exports ISO 8601 with a UTC offset' {
        InModuleScope ListCodingAgents {
            $d = [DateTimeOffset]::new(2026, 10, 11, 8, 30, 0, [TimeSpan]::FromHours(2))
            ConvertTo-LcaIsoString -Value $d | Should -Be '2026-10-11T08:30:00+02:00'
            ConvertTo-LcaIsoString -Value $null | Should -BeNullOrEmpty
        }
    }
    It 'formats ages relative to the injected clock' {
        InModuleScope ListCodingAgents {
            $now = [DateTimeOffset]::new(2026, 10, 11, 12, 0, 0, [TimeSpan]::Zero)
            Format-LcaAge -Date $now.AddHours(-2) -Now $now | Should -Be 'today'
            Format-LcaAge -Date $now.AddDays(-1.5) -Now $now | Should -Be 'yesterday'
            Format-LcaAge -Date $now.AddDays(-12) -Now $now | Should -Be '12d ago'
            Format-LcaAge -Date $now.AddDays(-95) -Now $now | Should -Be '3mo ago'
            Format-LcaAge -Date $now.AddDays(-800) -Now $now | Should -Be '2y ago'
        }
    }
}

Describe 'JSON and files' {
    It 'keeps empty and one-element arrays as arrays (v1 wrote an empty file / an object)' {
        InModuleScope ListCodingAgents {
            ConvertTo-LcaJson -InputObject @() | Should -Be '[]'
            (ConvertTo-LcaJson -InputObject @([ordered]@{ a = 1 }) -Compress) | Should -Be '[{"a":1}]'
        }
    }
    It 'writes BOM-less UTF-8 and replaces atomically' {
        $p = Join-Path $TestDrive 'out/x.json'
        InModuleScope ListCodingAgents -Parameters @{ P = $p } {
            param($P)
            Write-LcaTextFile -Path $P -Content '{"a":"caf\u00e9"}'
            Write-LcaTextFile -Path $P -Content '{"a":2}'
        }
        $bytes = [System.IO.File]::ReadAllBytes($p)
        $bytes[0] | Should -Be ([byte][char]'{')
        [System.IO.File]::ReadAllText($p) | Should -Be '{"a":2}'
        @(Get-ChildItem -LiteralPath (Split-Path $p) -Filter '*.tmp').Count | Should -Be 0
    }
    It 'parses JSON with a BOM' {
        InModuleScope ListCodingAgents {
            $o = ConvertFrom-LcaJson -Text ([string][char]0xFEFF + '{"a":[1]}')
            $o.a | Should -Be @(1)
        }
    }
    It 'reads missing properties safely under StrictMode' {
        InModuleScope ListCodingAgents {
            $o = ConvertFrom-LcaJson -Text '{"a":1}'
            Get-LcaProperty -InputObject $o -Name 'b' -Default 'd' | Should -Be 'd'
            Get-LcaProperty -InputObject $o -Name 'a' | Should -Be 1
            Get-LcaProperty -InputObject @{ k = 'v' } -Name 'k' | Should -Be 'v'
        }
    }
}

Describe 'Diagnostics' {
    It 'records, scrubs and exposes diagnostics' {
        InModuleScope ListCodingAgents {
            Clear-LcaDiagnostic
            Add-LcaDiagnostic -Source 'test' -Message 'token sk-ant-FAKE-0000 and ghp_FAKE0000 leaked; "apiKey": "hunter2"'
            $d = @(Get-LcaDiagnostic)
            $d.Count | Should -Be 1
            $d[0].Message | Should -Not -Match 'sk-ant-FAKE-0000|ghp_FAKE0000|hunter2'
            $d[0].Message | Should -Match '<redacted>'
        }
    }
    It 'omits exception text when asked (parser errors can quote file content)' {
        InModuleScope ListCodingAgents {
            Clear-LcaDiagnostic
            try { throw 'secret-content-xyz' } catch { Add-LcaDiagnostic -Source 't' -Message 'bad file' -ErrorRecord $_ -NoExceptionText }
            (Get-LcaDiagnostic)[0].Message | Should -Not -Match 'secret-content-xyz'
        }
    }
}

Describe 'Redaction' {
    It 'replaces the home directory and user name in every string' {
        InModuleScope ListCodingAgents {
            $o = [ordered]@{ path = '/home/alice/.claude'; list = @('C:\Users\alice\x', 'alicex'); n = 3; nested = [ordered]@{ s = 'by alice' } }
            $r = ConvertTo-LcaRedacted -InputObject $o -HomeDir '/home/alice' -UserName 'alice'
            $r.path | Should -Be '~/.claude'
            $r.list[0] | Should -Be 'C:\Users\<user>\x'
            $r.list[1] | Should -Be 'alicex'
            $r.n | Should -Be 3
            $r.nested.s | Should -Be 'by <user>'
        }
    }
}

Describe 'Export schema' {
    BeforeAll {
        $schemaPath = Join-Path $RepoRoot 'schema/coding-agents.schema.json'
        $fx = New-LcaFixture -Root (Join-Path $TestDrive 'schema')
        [void](Add-LcaFixtureNpmPackage -Fixture $fx -Name '@anthropic-ai/claude-code' -Version '1.0.9' -Description 'agentic coding tool' -Bin @{ claude = 'cli.js' })
        $export = Use-LcaFixture -Fixture $fx {
            InModuleScope ListCodingAgents {
                $ctx = New-LcaContext -Options @{ NoProbe = $true }
                $scan = Invoke-LcaScan -Context $ctx
                ConvertTo-LcaJson -InputObject (ConvertTo-LcaExport -Scan $scan -Context $ctx)
            }
        }
    }
    It 'produces JSON that validates against schema/coding-agents.schema.json' -Skip:$IsDesktop {
        $ok = Test-Json -Json $export -SchemaFile $schemaPath -ErrorVariable sv -ErrorAction SilentlyContinue
        $ok | Should -BeTrue -Because (($sv | ForEach-Object { $_.ToString() }) -join '; ')
    }
    It 'contains the fixture agent' {
        $o = $export | ConvertFrom-Json
        $o.schemaVersion | Should -Be 2
        @($o.agents | Where-Object { $_.name -eq 'claude' }).Count | Should -Be 1
    }
}

Describe 'Module surface' {
    It 'exports exactly the three public cmdlets' {
        (Get-Command -Module ListCodingAgents | ForEach-Object Name | Sort-Object) | Should -Be @('Export-CodingAgentReport', 'Get-CodingAgent', 'Update-CodingAgent')
    }
    It 'manifest version matches the tool version' {
        $m = Import-PowerShellDataFile -Path (Join-Path $RepoRoot 'src/ListCodingAgents/ListCodingAgents.psd1')
        InModuleScope ListCodingAgents { $script:LcaToolVersion } | Should -Be $m.ModuleVersion
    }
}
