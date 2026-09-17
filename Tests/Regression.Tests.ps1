# Run these mocked regressions on a development workstation with Pester 5.
BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSADToolkit.psd1') -Force
}
Describe 'Escaping and CSV input' {
    It 'Escapes LDAP filter metacharacters without changing Unicode' {
        InModuleScope PSADToolkit {
            ConvertTo-ADTLdapValue 'Joël*)(x=*)' | Should -Be 'Joël\2a\29\28x=\2a\29'
        }
    }
    It 'Escapes RDN separators and leading/trailing spaces' {
        InModuleScope PSADToolkit {
            ConvertTo-ADTRdnValue ' Joël, A+ ' | Should -Be '\20Joël\, A\+\20'
        }
    }
    It 'Resolves a group by CN/name when sAMAccountName does not match' {
        InModuleScope PSADToolkit {
            Mock Search-ADTDirectory {
                param($LDAPFilter)
                if ($LDAPFilter -like '*sAMAccountName=*') { return @() }
                if ($LDAPFilter -like '*name=*' -or $LDAPFilter -like '*cn=*') { return [pscustomobject]@{Name='GS-VPN';DistinguishedName='CN=GS-VPN,OU=Groupes,DC=test,DC=local'} }
            }
            $g=Get-ADTNativeGroup -Identity 'GS-VPN'
            $g.DistinguishedName | Should -Be 'CN=GS-VPN,OU=Groupes,DC=test,DC=local'
        }
    }
    It 'Returns flat CSV row objects with the expected headers' {
        InModuleScope PSADToolkit {
            $path=Join-Path $script:ADTModuleRoot 'Examples/nouveaux-employes.csv'
            $rows=@(Read-ADTFlexibleCsv -Path $path -Delimiter ';')
            $rows.Count | Should -BeGreaterThan 0
            @($rows[0].PSObject.Properties | ForEach-Object { $_.Name }) | Should -Contain 'GivenName'
            @($rows[0].PSObject.Properties | ForEach-Object { $_.Name }) | Should -Contain 'Surname'
            @($rows[0].PSObject.Properties | ForEach-Object { $_.Name }) | Should -Not -Contain 'LongLength'
        }
    }
    It 'Keeps every group from the supplied example CSV' {
        InModuleScope PSADToolkit {
            $path=Join-Path $script:ADTModuleRoot 'Examples/nouveaux-employes.csv'
            Test-ADTCsvShape -Path $path -Delimiter ';'
            $rows=@(Read-ADTFlexibleCsv -Path $path -Delimiter ';')
            $rows[2].Groups | Should -Be 'GS-TousEmployes;GS-Ventes;GS-VPN'
            @(Get-ADTCsvRowGroups -Row $rows[2]).Count | Should -Be 3
        }
    }
    It 'Folds extra CSV cells back into Groups instead of dropping groups' {
        # Beaucoup d exports utilisent ; comme separateur de colonnes ET de groupes,
        # sans guillemets. Les cellules excedentaires sont alors rattachees a Groups
        # plutot que perdues : c est le cas couvert par
        # Examples/Tests-CSV/03-groupes-non-quotes.csv.
        $path=Join-Path $TestDrive 'bad.csv'
        "GivenName;Surname;Groups`nA;B;G1;G2" | Set-Content $path
        InModuleScope PSADToolkit -Parameters @{Path=$path} {
            param($Path)
            Test-ADTCsvShape -Path $Path -Delimiter ';' | Should -BeTrue
            $rows=@(Read-ADTFlexibleCsv -Path $Path -Delimiter ';')
            $rows[0].Groups | Should -Be 'G1;G2'
            @(Get-ADTCsvRowGroups -Row $rows[0]).Count | Should -Be 2
        }
    }
    It 'Rejects extra CSV cells when no Groups column can absorb them' {
        $path=Join-Path $TestDrive 'sans-groupes.csv'
        "GivenName;Surname;Department`nA;B;TI;surplus" | Set-Content $path
        InModuleScope PSADToolkit -Parameters @{Path=$path} {
            param($Path)
            { Test-ADTCsvShape -Path $Path -Delimiter ';' } | Should -Throw '*cellules*'
        }
    }
}
Describe 'OU selection priority' {
    It 'Uses the selected DefaultOU instead of the CSV OU column' {
        InModuleScope PSADToolkit {
            $row=New-Object PSObject -Property @{OU='OU=CSV,DC=test,DC=local';Department='TI'}
            Get-ADTImportTargetOU -Row $row -DefaultOU 'OU=Choisie,DC=test,DC=local' -CreateDepartmentOUs $false | Should -Be 'OU=Choisie,DC=test,DC=local'
        }
    }
    It 'Creates the department target under the selected OU' {
        InModuleScope PSADToolkit {
            $row=New-Object PSObject -Property @{OU='OU=CSV,DC=test,DC=local';Department='TI'}
            Get-ADTImportTargetOU -Row $row -DefaultOU 'OU=Choisie,DC=test,DC=local' -CreateDepartmentOUs $true | Should -Be 'OU=TI,OU=Choisie,DC=test,DC=local'
        }
    }
}

Describe 'Identifier lookup failures' {
    It 'Stops if directory uniqueness cannot be checked' {
        InModuleScope PSADToolkit {
            Mock Get-ADTNativeUser { throw 'LDAP unavailable' }
            { Resolve-ADTSamAccountName -GivenName 'Joel' -Surname 'Cote' } | Should -Throw '*unicite*'
        }
    }
    It 'Rejects an explicit identifier which already exists' {
        InModuleScope PSADToolkit {
            Mock Get-ADTNativeUser { [pscustomobject]@{SamAccountName='jcote'} }
            { Resolve-ADTSamAccountName -Requested 'jcote' } | Should -Throw '*existe deja*'
        }
    }
}
Describe 'Provisioning and import' {
    BeforeEach {
        Mock -ModuleName PSADToolkit Test-ADTPrerequisite { [pscustomobject]@{Ready=$true;Server='dc.test.local'} }
        Mock -ModuleName PSADToolkit Get-ADTNativeDomain { [pscustomobject]@{DNSRoot='test.local'} }
        Mock -ModuleName PSADToolkit Get-ADTNativeObject { [pscustomobject]@{Name='OU'} }
        Mock -ModuleName PSADToolkit Get-ADTNativeGroup { [pscustomobject]@{Name='G1'} }
        Mock -ModuleName PSADToolkit Write-ADTLog {}
    }
    It 'Never creates a user or reveals a password during WhatIf' {
        InModuleScope PSADToolkit {
            Mock Get-ADTNativeUser {}
            Mock New-ADTNativeUser { throw 'Unexpected mutation' }
            $r=New-ADTUser -GivenName A -Surname B -Path 'OU=Users,DC=test,DC=local' -WhatIf
            $r.Status | Should -Be 'Simulation'
            $r.Password | Should -BeNullOrEmpty
            Should -Invoke New-ADTNativeUser -Times 0 -Exactly
        }
    }
    It 'Marks a failed group assignment as partial and pins the selected DC' {
        InModuleScope PSADToolkit {
            Mock Get-ADTNativeUser { [pscustomobject]@{DistinguishedName='CN=ab,DC=test,DC=local'} } -ParameterFilter {$Identity}
            Mock Get-ADTNativeUser {} -ParameterFilter {$Filter}
            Mock New-ADTNativeUser {}
            Mock Add-ADTNativeGroupMember { throw 'Access denied' }
            $r=New-ADTUser -GivenName A -Surname B -Path 'OU=Users,DC=test,DC=local' -Groups G1 -Confirm:$false
            $r.Status | Should -Be 'Partiel'
            $r.Error | Should -Match 'Access denied'
            Should -Invoke New-ADTNativeUser -Times 1 -ParameterFilter {$Server -eq 'dc.test.local'}
        }
    }
    It 'Does not abort the whole CSV when a referenced group is missing' {
        $path=Join-Path $TestDrive 'missing-group.csv'
        "GivenName;Surname;OU;Groups`nA;B;OU=Users,DC=test,DC=local;MissingGroup" | Set-Content $path
        InModuleScope PSADToolkit -Parameters @{Path=$path} {
            param($Path)
            Mock Get-ADTNativeGroup { throw 'Groupe introuvable : MissingGroup' }
            Mock New-ADTUser { [pscustomobject]@{SamAccountName='ab';DisplayName='A B';Status='Partiel';Password='';DistinguishedName='CN=ab,OU=Users,DC=test,DC=local';Groups='';HomeDirectory='';Error='Groupe non applique'} }
            $r=Import-ADTUserFromCsv -Path $Path -Confirm:$false
            @($r).Count | Should -Be 1
            Should -Invoke New-ADTUser -Times 1 -Exactly
        }
    }
    It 'Validates every row before writing the first user' {
        $path=Join-Path $TestDrive 'missing.csv'
        "GivenName;Surname;OU`nA;B;OU=Users,DC=test,DC=local`nC;;OU=Users,DC=test,DC=local" | Set-Content $path
        InModuleScope PSADToolkit -Parameters @{Path=$path} {
            param($Path)
            Mock New-ADTUser { throw 'Unexpected mutation' }
            { Import-ADTUserFromCsv -Path $Path -Confirm:$false } | Should -Throw '*prenom/nom*'
            Should -Invoke New-ADTUser -Times 0 -Exactly
        }
    }
    It 'Rejects identifiers which collide after accent normalization' {
        $path=Join-Path $TestDrive 'duplicate.csv'
        "GivenName;Surname;SamAccountName;OU`nA;B;joël;OU=Users,DC=test,DC=local`nC;D;joel;OU=Users,DC=test,DC=local" | Set-Content $path -Encoding UTF8
        InModuleScope PSADToolkit -Parameters @{Path=$path} {
            param($Path)
            Mock New-ADTUser {}
            { Import-ADTUserFromCsv -Path $Path -Confirm:$false } | Should -Throw '*duplique*'
            Should -Invoke New-ADTUser -Times 0 -Exactly
        }
    }
    It 'Passes server and credential to SkipExisting lookups' {
        $path=Join-Path $TestDrive 'existing.csv'
        "GivenName;Surname;SamAccountName;OU`nA;B;ab;OU=Users,DC=test,DC=local" | Set-Content $path
        InModuleScope PSADToolkit -Parameters @{Path=$path} {
            param($Path)
            $cred=New-Object PSCredential('TEST\admin',(ConvertTo-ADTSecurePassword -Text 'mock-only'))
            Mock Get-ADTNativeUser { [pscustomobject]@{SamAccountName='ab'} }
            Mock New-ADTUser {}
            $r=Import-ADTUserFromCsv -Path $Path -SkipExisting -Credential $cred -Confirm:$false
            $r.Status | Should -Be 'Ignore'
            Should -Invoke Get-ADTNativeUser -Times 1 -ParameterFilter {$Server -eq 'dc.test.local' -and $Credential.UserName -eq 'TEST\admin'}
            Should -Invoke New-ADTUser -Times 0 -Exactly
        }
    }
}
Describe 'Offboarding guarantees' {
    BeforeEach {
        Mock -ModuleName PSADToolkit Test-ADTPrerequisite { [pscustomobject]@{Ready=$true;Server='dc.test.local'} }
        Mock -ModuleName PSADToolkit Get-ADTNativeUser { [pscustomobject]@{SamAccountName='ab';DistinguishedName='CN=ab,DC=test,DC=local';MemberOf=@('CN=G1,DC=test,DC=local');Description='Existing';Enabled=$true} }
        Mock -ModuleName PSADToolkit Write-ADTLog {}
        Mock -ModuleName PSADToolkit Disable-ADTNativeAccount {}
        Mock -ModuleName PSADToolkit Set-ADTNativePassword {}
        Mock -ModuleName PSADToolkit Remove-ADTNativeGroupMember {}
        Mock -ModuleName PSADToolkit Set-ADTNativeUser {}
    }
    It 'Performs zero backup or AD writes in simulation' {
        InModuleScope PSADToolkit {
            Mock Export-Clixml { throw 'Unexpected file write' }
            $r=Start-ADTUserOffboarding -Identity ab -WhatIf
            $r.Status | Should -Be 'Simulation'
            Should -Invoke Export-Clixml -Times 0 -Exactly
            Should -Invoke Disable-ADTNativeAccount -Times 0 -Exactly
            Should -Invoke Set-ADTNativePassword -Times 0 -Exactly
            Should -Invoke Remove-ADTNativeGroupMember -Times 0 -Exactly
        }
    }
    It 'Does not mutate AD after a failed backup' {
        InModuleScope PSADToolkit -Parameters @{Path=$TestDrive} {
            param($Path)
            Mock Export-Clixml { throw 'Disk full' }
            $r=Start-ADTUserOffboarding -Identity ab -BackupPath $Path -Confirm:$false
            $r.Status | Should -Be 'Echec'
            $r.Error | Should -Match 'Disk full'
            Should -Invoke Disable-ADTNativeAccount -Times 0 -Exactly
            Should -Invoke Set-ADTNativePassword -Times 0 -Exactly
        }
    }
    It 'Disables first, exposes reset failure and continues group removal' {
        InModuleScope PSADToolkit -Parameters @{Path=$TestDrive} {
            param($Path)
            $script:disabledForTest=$false
            Mock Disable-ADTNativeAccount { $script:disabledForTest=$true }
            Mock Set-ADTNativePassword { if (-not $script:disabledForTest) { throw 'Wrong order' }; throw 'Password rejected' }
            $r=Start-ADTUserOffboarding -Identity ab -BackupPath $Path -Confirm:$false
            $r.Status | Should -Be 'Partiel'
            $r.Error | Should -Match 'Password rejected'
            Should -Invoke Remove-ADTNativeGroupMember -Times 1
            Test-Path $r.BackupFile | Should -BeTrue
            Test-Path $r.StateFile | Should -BeTrue
        }
    }
}
Describe 'Inactive accounts' {
    It 'Does not mark a newly created unused account as 90 days inactive' {
        InModuleScope PSADToolkit {
            Mock Test-ADTPrerequisite { [pscustomobject]@{Ready=$true} }
            Mock Get-ADTNativeUser {
                [pscustomobject]@{SamAccountName='new';Enabled=$true;LastLogonDate=$null;whenCreated=(Get-Date).AddDays(-1)}
                [pscustomobject]@{SamAccountName='old';Enabled=$true;LastLogonDate=$null;whenCreated=(Get-Date).AddDays(-120)}
            }
            $r=@(Get-ADTInactiveAccount -DaysInactive 90)
            $r.Count | Should -Be 1
            $r[0].SamAccountName | Should -Be 'old'
        }
    }
}
