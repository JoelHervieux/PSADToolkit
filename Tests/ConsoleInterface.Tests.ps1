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

Describe 'Verification des types GliderUI au demarrage' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $entry = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $root 'Start-PSADToolkit.ps1'), [ref]$null, [ref]$null)

        # La liste verifiee au demarrage, extraite du script lui-meme.
        $assignment = @($entry.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text -eq '$requiredTypes'
                }, $true))
        $script:PreflightTypes = @(& ([scriptblock]::Create($assignment[0].Right.Extent.Text)))

        # Les types employes par l interface, releves dans l ARBRE SYNTAXIQUE : un
        # nom de type cite dans un commentaire ou dans une chaine XAML n en est pas
        # un, et une recherche textuelle s y laisserait prendre.
        $script:UiFiles = @(Get-Item (Join-Path $root 'Start-PSADToolkit.ps1')) +
        @(Get-ChildItem -Path (Join-Path $root 'UI') -Filter '*.ps1')
        $script:UsedTypeNames = New-Object System.Collections.ArrayList
        foreach ($file in $script:UiFiles) {
            $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $nodes = @($fileAst.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.TypeExpressionAst] -or
                        $node -is [System.Management.Automation.Language.TypeConstraintAst]
                    }, $true))
            foreach ($node in $nodes) {
                $name = [string]$node.TypeName.FullName
                if (-not $name) { continue }
                if (-not $script:UsedTypeNames.Contains($name)) { [void]$script:UsedTypeNames.Add($name) }
            }
        }

        # ObservableCollection est generique : son nom simple ne se resout pas, la
        # verification de demarrage ne peut donc pas le controler.
        $script:CoverageExclusions = @('GliderUI.System.Collections.ObjectModel.ObservableCollection')

        $script:UsedGliderNames = New-Object System.Collections.ArrayList
        foreach ($name in $script:UsedTypeNames) {
            if ($name -notlike 'GliderUI.*') { continue }
            # Un type generique se presente sous la forme Nom[Argument] : ne garder
            # que le type porteur, et traiter son argument comme un type a part.
            $bare = $name
            $bracket = $bare.IndexOf('[')
            if ($bracket -ge 0) { $bare = $bare.Substring(0, $bracket) }
            if (-not $script:UsedGliderNames.Contains($bare)) { [void]$script:UsedGliderNames.Add($bare) }
        }

        # Noms courts que l interface ne doit plus employer nus.
        $script:ForbiddenShortNames = @(
            'Window', 'Button', 'TextBlock', 'TextBox', 'CheckBox', 'ComboBox', 'NumericUpDown',
            'StackPanel', 'Grid', 'TreeView', 'TreeViewItem', 'TabControl', 'TabItem', 'ScrollViewer',
            'ContentControl', 'Border', 'DataGrid', 'ColumnDefinition', 'RowDefinition', 'GridLength',
            'ContextMenu', 'MenuItem', 'Separator', 'Thickness', 'AvaloniaRuntimeXamlLoader',
            'EventCallback', 'DataSource', 'DataSourcePropertyComparer',
            'FolderPickerOpenOptions', 'FilePickerOpenOptions', 'FilePickerSaveOptions'
        )
    }

    It 'Ecrit les types GliderUI en toutes lettres, jamais en nom court' {
        # Regression : sur Windows Server 2016 avec GliderUI 0.4.1, la resolution par
        # nom court via using namespace echoue la ou le nom complet se resout.
        # L interface s arretait sur "Impossible de trouver le type
        # [AvaloniaRuntimeXamlLoader]" apres avoir passe la verification de demarrage.
        foreach ($name in $script:UsedTypeNames) {
            $script:ForbiddenShortNames | Should -Not -Contain $name `
                -Because ('[' + $name + '] doit etre ecrit en toutes lettres')
        }
    }

    It 'Verifie le chargeur XAML avant de construire la fenetre' {
        # C est le type sur lequel l interface echouait au premier lancement reel,
        # avec un message qui ne disait pas quoi faire.
        $script:PreflightTypes | Should -Contain 'GliderUI.Avalonia.Markup.Xaml.AvaloniaRuntimeXamlLoader'
    }

    It 'Couvre tous les types GliderUI que l interface emploie' {
        # Les menus contextuels et le separateur sont volontairement absents : la
        # console les construit dans un try/catch et se rabat sur ses boutons.
        $optional = @('ContextMenu', 'MenuItem', 'Separator')
        foreach ($name in $script:UsedGliderNames) {
            if ($script:CoverageExclusions -contains $name) { continue }
            $short = ($name -split '\.')[-1]
            if ($optional -contains $short) { continue }
            $script:PreflightTypes | Should -Contain $name `
                -Because ($name + ' est employe par l interface mais absent de la verification de demarrage')
        }
    }

    It 'Ne verifie que des types reellement utilises' {
        foreach ($full in $script:PreflightTypes) {
            $script:UsedGliderNames | Should -Contain $full -Because ($full + ' est verifie au demarrage mais jamais utilise')
        }
    }

    It 'Laisse les types de confort hors de la verification bloquante' {
        foreach ($name in @('ContextMenu', 'MenuItem', 'Separator')) {
            foreach ($full in $script:PreflightTypes) {
                $full.EndsWith('.' + $name) | Should -BeFalse -Because ($name + ' doit rester facultatif')
            }
        }
    }
}
