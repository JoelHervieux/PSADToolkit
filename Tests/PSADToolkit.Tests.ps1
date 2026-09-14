<#
    Tests unitaires Pester pour PSADToolkit.

    Ces tests ne necessitent AUCUN Active Directory : ils valident la structure du
    module, l export des fonctions, l aide integree et la logique des fonctions
    internes (mot de passe, normalisation des accents).
    Ils s executent donc sur n importe quel poste, y compris dans GitHub Actions.

    Lancer : Invoke-Pester -Path .\Tests
#>

BeforeAll {
    $ModuleRoot = Split-Path -Parent $PSScriptRoot
    $ManifestPath = Join-Path $ModuleRoot 'PSADToolkit.psd1'
    Import-Module $ManifestPath -Force -ErrorAction Stop
}

Describe 'Structure du module' {

    It 'Le manifeste est valide' {
        $manifest = Test-ModuleManifest -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'PSADToolkit.psd1') -ErrorAction Stop
        $manifest.Version | Should -Not -BeNullOrEmpty
    }

    It 'Declare une compatibilite PowerShell 2.0' {
        $manifest = Import-PowerShellDataFile -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'PSADToolkit.psd1')
        $manifest.PowerShellVersion | Should -Be '2.0'
    }

    It 'Exporte les 8 fonctions publiques attendues' {
        $expected = @(
            'Test-ADTPrerequisite','New-ADTUser','Import-ADTUserFromCsv',
            'Set-ADTUserGroupMembership','Start-ADTUserOffboarding',
            'Get-ADTInactiveAccount','Get-ADTPrivilegedGroupMember','Export-ADTAccessReport'
        )
        $actual = (Get-Command -Module PSADToolkit -CommandType Function).Name
        foreach ($name in $expected) { $actual | Should -Contain $name }
    }

    It 'N expose pas les fonctions internes' {
        Get-Command -Module PSADToolkit -Name 'Write-ADTLog' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'Aide integree' {
    $functions = @(
        'Test-ADTPrerequisite','New-ADTUser','Import-ADTUserFromCsv',
        'Set-ADTUserGroupMembership','Start-ADTUserOffboarding',
        'Get-ADTInactiveAccount','Get-ADTPrivilegedGroupMember','Export-ADTAccessReport'
    )

    foreach ($function in $functions) {
        It "$function possede une synopsis et un exemple" -TestCases @(@{ ADTFunction=$function }) {
            param($ADTFunction)
            $help = Get-Help $ADTFunction -ErrorAction Stop
            $help.Synopsis | Should -Not -BeNullOrEmpty
            $help.Examples | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Fonctions modifiant AD : support de -WhatIf' {
    $stateChanging = @('New-ADTUser','Import-ADTUserFromCsv','Set-ADTUserGroupMembership','Start-ADTUserOffboarding')

    foreach ($function in $stateChanging) {
        It "$function supporte -WhatIf" -TestCases @(@{ ADTFunction=$function }) {
            param($ADTFunction)
            (Get-Command $ADTFunction).Parameters.Keys | Should -Contain 'WhatIf'
        }
    }
}

Describe 'New-ADTRandomPassword' {

    It 'Respecte la longueur demandee' {
        InModuleScope PSADToolkit {
            (New-ADTRandomPassword -Length 20).Length | Should -Be 20
        }
    }

    It 'Contient majuscule, minuscule, chiffre et caractere special' {
        InModuleScope PSADToolkit {
            1..25 | ForEach-Object {
                $password = New-ADTRandomPassword -Length 14
                $password | Should -Match '[A-Z]'
                $password | Should -Match '[a-z]'
                $password | Should -Match '[0-9]'
                $password | Should -Match '[^A-Za-z0-9]'
            }
        }
    }

    It 'Ne genere jamais deux fois le meme mot de passe' {
        InModuleScope PSADToolkit {
            $set = 1..50 | ForEach-Object { New-ADTRandomPassword -Length 16 }
            ($set | Select-Object -Unique).Count | Should -Be 50
        }
    }

    It 'Refuse une longueur inferieure a 12' {
        InModuleScope PSADToolkit {
            { New-ADTRandomPassword -Length 6 } | Should -Throw
        }
    }
}

Describe 'ConvertTo-ADTAsciiString' {

    It 'Retire les accents francais' {
        InModuleScope PSADToolkit {
            ConvertTo-ADTAsciiString -Text 'Joël Côté' | Should -Be 'JoelCote'
            ConvertTo-ADTAsciiString -Text 'José'      | Should -Be 'Jose'
        }
    }

    It 'Supprime les caracteres interdits dans un SamAccountName' {
        InModuleScope PSADToolkit {
            ConvertTo-ADTAsciiString -Text 'O''Brien' | Should -Be 'OBrien'
            ConvertTo-ADTAsciiString -Text 'a/b\c:d'  | Should -Be 'abcd'
        }
    }

    It 'Gere une chaine vide sans erreur' {
        InModuleScope PSADToolkit {
            ConvertTo-ADTAsciiString -Text '' | Should -Be ''
        }
    }
}
