# Decisions du lanceur : quelle version installer ou retenir, quand verifier les mises
# a jour. Aucune de ces fonctions ne touche au reseau : elles se testent directement,
# sous Windows PowerShell 5.1 comme sous PowerShell 7.
BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'Tools\ADTDependency.ps1')
}

Describe 'Choix des mises a jour' {
    It 'Politique Patch : suit les correctifs sans changer de version mineure' {
        Select-ADTUpdateCandidate -Current '0.4.1' -Available @('0.4.0', '0.4.2', '0.4.3', '0.5.0', '1.0.0') -Policy Patch |
            Should -Be '0.4.3'
    }

    It 'Politique Minor : reste dans la version majeure' {
        Select-ADTUpdateCandidate -Current '7.4.6' -Available @('7.4.7', '7.6.1', '8.0.0') -Policy Minor | Should -Be '7.6.1'
    }

    It 'Politique Major : prend la plus haute version' {
        Select-ADTUpdateCandidate -Current '7.4.6' -Available @('7.6.1', '8.0.0') -Policy Major | Should -Be '8.0.0'
    }

    It 'Politique None : jamais de mise a jour' {
        Select-ADTUpdateCandidate -Current '0.4.1' -Available @('0.4.2') -Policy None | Should -BeNullOrEmpty
    }

    It 'Ne propose ni retour arriere ni version identique' {
        Select-ADTUpdateCandidate -Current '0.4.1' -Available @('0.4.1', '0.3.9') -Policy Major | Should -BeNullOrEmpty
    }

    It 'Ecarte les preversions et les versions deja refusees' {
        Select-ADTUpdateCandidate -Current '0.4.1' -Available @('0.4.2', '0.4.3-beta1') -Policy Patch -Rejected @('0.4.2') |
            Should -BeNullOrEmpty
    }

    It 'Accepte le prefixe v des etiquettes de publication' {
        Select-ADTUpdateCandidate -Current '7.4.6' -Available @('v7.4.11') -Policy Minor | Should -Be '7.4.11'
    }

    It 'Ignore une version courante illisible' {
        Select-ADTUpdateCandidate -Current 'inconnue' -Available @('1.0.0') -Policy Major | Should -BeNullOrEmpty
    }
}

Describe 'Frequence des verifications' {
    BeforeAll { $now = [datetime]'2026-09-28T12:00:00Z' }

    It 'Verifie quand aucune verification n a eu lieu' {
        Test-ADTUpdateDue -LastCheck '' -IntervalHours 24 -Now $now | Should -BeTrue
    }

    It 'Attend la fin de l intervalle' {
        Test-ADTUpdateDue -LastCheck '2026-09-28T02:00:00.0000000Z' -IntervalHours 24 -Now $now | Should -BeFalse
        Test-ADTUpdateDue -LastCheck '2026-09-27T11:00:00.0000000Z' -IntervalHours 24 -Now $now | Should -BeTrue
    }

    It 'Reverifie si la date est illisible ou dans le futur' {
        Test-ADTUpdateDue -LastCheck 'hier' -IntervalHours 24 -Now $now | Should -BeTrue
        Test-ADTUpdateDue -LastCheck '2026-10-05T00:00:00.0000000Z' -IntervalHours 24 -Now $now | Should -BeTrue
    }

    It 'Intervalle nul : verifie a chaque lancement' {
        Test-ADTUpdateDue -LastCheck '2026-09-28T11:59:00.0000000Z' -IntervalHours 0 -Now $now | Should -BeTrue
    }
}

Describe 'Paquets livres avec l installateur' {
    BeforeAll {
        $folder = Join-Path ([System.IO.Path]::GetTempPath()) ('adt-prereq-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $folder
        foreach ($name in @('PowerShell-7.4.6-win-x64.msi', 'PowerShell-7.4.11-win-x64.msi', 'PowerShell-7.6.0-win-arm64.msi',
                'GliderUI.0.4.1.nupkg', 'GliderUI.Server.win-x64.0.4.1.nupkg', 'lisezmoi.txt')) {
            Set-Content -Path (Join-Path $folder $name) -Value 'x'
        }
    }
    AfterAll { Remove-Item -LiteralPath $folder -Recurse -Force }

    It 'Retient la plus haute version pour l architecture demandee' {
        $found = Find-ADTBundledPackage -Folder $folder -Pattern '^PowerShell-(?<v>\d+\.\d+\.\d+)-win-x64\.msi$'
        [string]$found.Version | Should -Be '7.4.11'
    }

    It 'Trouve une version precise' {
        $found = Find-ADTBundledPackage -Folder $folder -Pattern '^PowerShell-(?<v>\d+\.\d+\.\d+)-win-x64\.msi$' -Version '7.4.6'
        Split-Path -Leaf $found.Path | Should -Be 'PowerShell-7.4.6-win-x64.msi'
    }

    It 'Ne confond pas GliderUI et son serveur' {
        $found = Find-ADTBundledPackage -Folder $folder -Pattern '^GliderUI\.(?<v>\d+\.\d+\.\d+)\.nupkg$'
        Split-Path -Leaf $found.Path | Should -Be 'GliderUI.0.4.1.nupkg'
    }

    It 'Rend $null sans dossier ni correspondance' {
        Find-ADTBundledPackage -Folder (Join-Path $folder 'absent') -Pattern '.*' | Should -BeNullOrEmpty
        Find-ADTBundledPackage -Folder $folder -Pattern '^Rien-(?<v>\d+\.\d+\.\d+)$' | Should -BeNullOrEmpty
    }
}

Describe 'Installation hors ligne d un module' {
    It 'Extrait un .nupkg sans ses metadonnees NuGet' {
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ('adt-nupkg-' + [guid]::NewGuid().ToString('N'))
        $source = Join-Path $work 'source'
        $modules = Join-Path $work 'Modules'
        $null = New-Item -ItemType Directory -Path $source, $modules
        try {
            Set-Content -Path (Join-Path $source 'Demo.Module.psd1') -Value "@{ ModuleVersion = '1.2.3' }"
            Set-Content -Path (Join-Path $source 'Demo.Module.nuspec') -Value '<package><metadata><id>Demo.Module</id><version>1.2.3</version></metadata></package>'
            Set-Content -LiteralPath (Join-Path $source '[Content_Types].xml') -Value '<Types/>'
            $null = New-Item -ItemType Directory -Path (Join-Path $source '_rels')
            Set-Content -Path (Join-Path $source '_rels\.rels') -Value '<Relationships/>'
            $package = Join-Path $work 'Demo.Module.1.2.3.nupkg'
            [System.IO.Compression.ZipFile]::CreateFromDirectory($source, $package)

            $info = Get-ADTNupkgInfo -Path $package
            $info.Id | Should -Be 'Demo.Module'
            $info.Version | Should -Be '1.2.3'

            $target = Install-ADTNupkgModule -Path $package -ModuleRoot $modules
            $target | Should -Be (Join-Path $modules 'Demo.Module\1.2.3')
            Test-Path -LiteralPath (Join-Path $target 'Demo.Module.psd1') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $target 'Demo.Module.nuspec') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $target '_rels') | Should -BeFalse
            @(Get-ChildItem -LiteralPath $target -Force).Count | Should -Be 1
        } finally { Remove-Item -LiteralPath $work -Recurse -Force }
    }
}

Describe 'Etat du lanceur' {
    It 'Relit ce qu il a ecrit, et tolere un fichier abime' {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ('adt-state-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            Write-ADTState -Path $path -State @{ LastCheck = '2026-09-28T12:00:00.0000000Z'; KnownGood = @('0.4.1', '0.4.2') }
            $state = Read-ADTState -Path $path
            $state['LastCheck'] | Should -Not -BeNullOrEmpty
            @($state['KnownGood']) | Should -Be @('0.4.1', '0.4.2')

            Set-Content -Path $path -Value '{ abime'
            (Read-ADTState -Path $path).Count | Should -Be 0
        } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Adresse de telechargement de PowerShell' {
    It 'Vise la publication officielle' {
        Get-ADTPowerShellMsiUrl -Version 'v7.4.6' -Architecture x64 |
            Should -Be 'https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.msi'
    }
}

Describe 'Scripts du lanceur' {
    It 'Se chargent sans erreur de syntaxe sous cette version de PowerShell' {
        foreach ($relative in @('Launcher.ps1', 'Tools\ADTDependency.ps1', 'Tools\Initialize-ADTEnvironment.ps1')) {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $relative), [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because $relative
        }
    }

    It 'Parametres du lanceur valides' {
        $settings = Import-PowerShellDataFile -Path (Join-Path $root 'Launcher.settings.psd1')
        ConvertTo-ADTVersion $settings.PowerShell.MinimumVersion | Should -Not -BeNullOrEmpty
        ConvertTo-ADTVersion $settings.GliderUI.BaselineVersion | Should -Not -BeNullOrEmpty
        @('lts', 'stable') | Should -Contain $settings.PowerShell.Channel
        @('None', 'Patch', 'Minor', 'Major') | Should -Contain $settings.PowerShell.UpdatePolicy
        @('None', 'Patch', 'Minor', 'Major') | Should -Contain $settings.GliderUI.UpdatePolicy
    }

    It 'La version de reference de GliderUI est celle que l interface verifie' {
        $settings = Import-PowerShellDataFile -Path (Join-Path $root 'Launcher.settings.psd1')
        $workflow = [System.IO.File]::ReadAllText((Join-Path $root '.github\workflows\windows.yml'))
        $workflow | Should -BeLike ('*GliderUI -Version ' + $settings.GliderUI.BaselineVersion + '*')
    }
}
