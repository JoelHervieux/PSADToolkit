# Verifie la console graphique sans lancer GliderUI ni Avalonia : l analyse porte sur
# l arbre syntaxique reel des fichiers d interface.
BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $manifest = Import-PowerShellDataFile -Path (Join-Path $root 'PSADToolkit.psd1')
    $exported = @($manifest.FunctionsToExport)

    $uiFiles = @(Get-ChildItem -Path (Join-Path $root 'UI') -Filter '*.ps1' | Sort-Object Name)
    $entryPoint = Join-Path $root 'Start-PSADToolkit.ps1'

    $trees = @{}
    foreach ($file in (@($uiFiles) + @(Get-Item $entryPoint))) {
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
        if ($errors) { throw ($file.Name + ' : ' + ($errors.Message -join '; ')) }
        $trees[$file.Name] = $ast
    }

    # Toutes les fonctions definies par l interface et par les helpers prives.
    $localFunctions = New-Object System.Collections.ArrayList
    foreach ($ast in $trees.Values) {
        foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            [void]$localFunctions.Add($definition.Name)
        }
    }
    foreach ($file in (Get-ChildItem -Path (Join-Path $root 'Private') -Filter '*.ps1')) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
        foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            [void]$localFunctions.Add($definition.Name)
        }
    }

    function Get-ADTTestCommandArgument {
        # Valeur litterale passee a un parametre nomme d une commande donnee.
        param($Ast, [string]$CommandName, [string]$ParameterName)
        $values = New-Object System.Collections.ArrayList
        foreach ($call in $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            if ([string]$call.GetCommandName() -ne $CommandName) { continue }
            $elements = @($call.CommandElements)
            for ($index = 0; $index -lt $elements.Count - 1; $index++) {
                $element = $elements[$index]
                if (-not ($element -is [System.Management.Automation.Language.CommandParameterAst])) { continue }
                if ($element.ParameterName -ne $ParameterName) { continue }
                $next = $elements[$index + 1]
                if ($next -is [System.Management.Automation.Language.StringConstantExpressionAst]) { [void]$values.Add($next.Value) }
            }
        }
        return @($values)
    }
}

Describe 'Interface de la console' {
    It 'Charge tous les fichiers du dossier UI depuis le point d entree' {
        $source = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'Start-PSADToolkit.ps1'))
        foreach ($file in $uiFiles) {
            $source | Should -BeLike ('*' + $file.Name + '*') -Because ('UI/' + $file.Name + ' doit etre charge')
        }
    }

    It 'Charge les helpers prives dont l interface a besoin' {
        $source = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'Start-PSADToolkit.ps1'))
        foreach ($helper in @('DirectoryBackend.ps1', 'DirectoryConsole.ps1', 'DirectoryWrite.ps1',
                'CsvHelpers.ps1', 'Format-ADTDisplay.ps1', 'LogonHours.ps1', 'ObjectStatus.ps1')) {
            $source | Should -BeLike ('*' + $helper + '*') -Because $helper
        }
    }

    It 'N ecrit dans Active Directory que par des fonctions exportees du module' {
        $commands = New-Object System.Collections.ArrayList
        foreach ($ast in $trees.Values) {
            foreach ($name in (Get-ADTTestCommandArgument -Ast $ast -CommandName 'Invoke-ADTUiConsoleWrite' -ParameterName 'Command')) {
                [void]$commands.Add($name)
            }
            foreach ($name in (Get-ADTTestCommandArgument -Ast $ast -CommandName 'Invoke-ADTUiCommand' -ParameterName 'Command')) {
                [void]$commands.Add($name)
            }
        }
        @($commands).Count | Should -BeGreaterThan 8
        foreach ($name in @($commands)) { $exported | Should -Contain $name -Because $name }
    }

    It 'N appelle aucune fonction ADT qui ne soit ni exportee ni definie localement' {
        foreach ($entry in $trees.GetEnumerator()) {
            foreach ($call in $entry.Value.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $name = [string]$call.GetCommandName()
                if (-not $name -or $name -notmatch '^[A-Za-z]+-ADT') { continue }
                if ($exported -contains $name) { continue }
                $localFunctions | Should -Contain $name -Because ($entry.Key + ' appelle ' + $name)
            }
        }
    }

    It 'Ne reference que des actions de console reellement definies' {
        # Les barres de boutons reprennent les entrees des menus contextuels par
        # leur libelle : un libelle renomme d un cote doit faire echouer ici.
        $console = $trees['Console.ps1']
        $headers = New-Object System.Collections.ArrayList
        foreach ($pair in $console.FindAll({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $true)) {
            foreach ($item in $pair.KeyValuePairs) {
                if ([string]$item.Item1.Extent.Text -ne 'Header') { continue }
                $value = $item.Item2.Extent.Text.Trim("'", '"', ' ')
                [void]$headers.Add($value)
            }
        }
        $referenced = @(Get-ADTTestCommandArgument -Ast $console -CommandName 'Get-ADTUiConsoleAction' -ParameterName 'Header')
        @($referenced).Count | Should -BeGreaterThan 8
        foreach ($name in $referenced) { $headers | Should -Contain $name -Because $name }
    }

    It 'Branche les evenements de confort de maniere tolerante' {
        # Menu contextuel, double-clic et selection multiple ne doivent jamais etre
        # appeles directement : une version de GliderUI qui ne les expose pas ferait
        # echouer la construction de la fenetre.
        foreach ($entry in $trees.GetEnumerator()) {
            if ($entry.Key -eq 'Common.ps1') { continue }
            $text = $entry.Value.Extent.Text
            $text | Should -Not -BeLike '*.AddDoubleTapped(*' -Because $entry.Key
            $text | Should -Not -BeLike '*.AddContextRequested(*' -Because $entry.Key
        }
    }

    It 'Place la console avant les onglets historiques' {
        $source = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'Start-PSADToolkit.ps1'))
        $console = $source.IndexOf('$consoleTab.Header')
        $loop = $source.IndexOf('foreach ($spec in $specs) {')
        $console | Should -BeGreaterThan 0
        $loop | Should -BeGreaterThan 0
        $console | Should -BeLessThan $loop
    }

    It 'Expose chaque action du menu contextuel aussi par un bouton' {
        # Le clic droit reste un confort : toute action doit avoir un equivalent
        # visible, sinon une version de GliderUI sans ContextMenu amputerait l outil.
        $console = $trees['Console.ps1']
        $referenced = @(Get-ADTTestCommandArgument -Ast $console -CommandName 'Get-ADTUiConsoleAction' -ParameterName 'Header')
        foreach ($name in @('Nouvel utilisateur', 'Nouveau groupe', 'Nouvelle unite d organisation',
                'Importer un CSV dans cette OU', 'Reinitialiser le mot de passe...', 'Activer', 'Desactiver',
                'Deverrouiller', 'Gerer les groupes...', 'Horaires de connexion...', 'Deplacer...', 'Supprimer...')) {
            $referenced | Should -Contain $name -Because ($name + ' doit rester accessible par un bouton')
        }
    }
}

Describe 'Formats affiches par l interface' {
    It 'Met en forme les valeurs des grilles par la culture plutot que par une conversion implicite' {
        $source = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'Start-PSADToolkit.ps1'))
        $source | Should -BeLike '*Format-ADTUiCellValue*'
        $source | Should -BeLike '*Format-ADTDateTime*'
        # La conversion brute en chaine rendait un format invariant dans la grille.
        $source | Should -Not -BeLike '*$values[$path] = [string]$item.$path*'
    }
}
