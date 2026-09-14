function Read-ADTFlexibleCsv {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [char]$Delimiter = ';'
    )

    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($full,[Text.Encoding]::UTF8,$true)
    $result = New-Object System.Collections.ArrayList
    try {
        $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
        $parser.SetDelimiters(@([string]$Delimiter))
        $parser.HasFieldsEnclosedInQuotes = $true
        $header = $parser.ReadFields()
        if (-not $header -or $header.Count -lt 2) { throw 'En-tete CSV invalide : verifier le separateur.' }

        $seen = @{}
        $groupIndex = -1
        $i = 0
        foreach ($rawName in $header) {
            $name = [string]$rawName
            if ($i -eq 0) { $name = $name.TrimStart([char]0xFEFF) }
            $name = $name.Trim()
            if (-not $name -or $seen.ContainsKey($name)) { throw ('Colonne CSV vide ou dupliquee : ' + $name) }
            $header[$i] = $name
            $seen[$name] = $true
            if ($name -eq 'Groups') { $groupIndex = $i }
            $i++
        }

        while (-not $parser.EndOfData) {
            $lineNumber = $parser.LineNumber
            $cells = $parser.ReadFields()
            if (-not $cells) { continue }

            # Beaucoup de CSV administratifs utilisent ; comme separateur du fichier ET
            # dans la cellule Groups sans guillemets. On rattache alors les cellules
            # excedentaires a la colonne Groups au lieu de perdre les groupes suivants.
            if ($cells.Count -gt $header.Count) {
                if ($groupIndex -lt 0) {
                    throw ('Ligne CSV {0} : {1} cellules au lieu de {2}, sans colonne Groups pour absorber les valeurs supplementaires.' -f $lineNumber,$cells.Count,$header.Count)
                }
                $extra = $cells.Count - $header.Count
                $fixed = New-Object string[] $header.Count
                for ($j=0; $j -lt $groupIndex; $j++) { $fixed[$j] = [string]$cells[$j] }
                $groupParts = New-Object System.Collections.ArrayList
                for ($j=$groupIndex; $j -le ($groupIndex + $extra); $j++) {
                    if ([string]$cells[$j]) { [void]$groupParts.Add(([string]$cells[$j]).Trim()) }
                }
                $fixed[$groupIndex] = [string]($groupParts -join ';')
                for ($j=$groupIndex+1; $j -lt $header.Count; $j++) { $fixed[$j] = [string]$cells[$j+$extra] }
                $cells = $fixed
            }

            if ($cells.Count -lt $header.Count) {
                $fixed = New-Object string[] $header.Count
                for ($j=0; $j -lt $header.Count; $j++) {
                    if ($j -lt $cells.Count) { $fixed[$j] = [string]$cells[$j] } else { $fixed[$j] = '' }
                }
                $cells = $fixed
            }

            $obj = New-Object PSObject
            for ($j=0; $j -lt $header.Count; $j++) {
                $obj | Add-Member -MemberType NoteProperty -Name $header[$j] -Value ([string]$cells[$j])
            }
            $obj | Add-Member -MemberType NoteProperty -Name '__ADTLineNumber' -Value ([int]$lineNumber)
            [void]$result.Add($obj)
        }
    } finally {
        $parser.Close()
        $parser.Dispose()
    }
    # Ne pas utiliser la virgule unaire ici : elle transformerait toutes les lignes
    # en un seul objet Object[], et $rows[0] exposerait alors Count/Length au lieu
    # des colonnes du CSV (GivenName, Surname, etc.).
    return $result.ToArray()
}

function Get-ADTCsvRowGroups {
    param($Row,[string[]]$DefaultGroups)
    $items = New-Object System.Collections.ArrayList
    if ($DefaultGroups) {
        foreach ($g in $DefaultGroups) { if ($g -and $g.Trim()) { [void]$items.Add($g.Trim()) } }
    }
    if ($Row.PSObject.Properties['Groups'] -and $Row.Groups) {
        foreach ($g in (([string]$Row.Groups) -split ';')) { if ($g -and $g.Trim()) { [void]$items.Add($g.Trim()) } }
    }
    $seen = @{}
    $result = New-Object System.Collections.ArrayList
    foreach ($g in $items) {
        $key = ([string]$g).ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; [void]$result.Add([string]$g) }
    }
    # Laisser PowerShell enumerer les chaines; les appelants utilisent @() pour
    # obtenir un tableau plat de groupes.
    return [string[]]@($result)
}

function Get-ADTImportTargetOU {
    param($Row,[string]$DefaultOU,[bool]$CreateDepartmentOUs)
    if ($CreateDepartmentOUs) {
        if (-not $DefaultOU) { throw 'Une OU parente doit etre selectionnee pour creer les sous-OU de departement.' }
        $department = ''
        if ($Row.PSObject.Properties['Department']) { $department = ([string]$Row.Department).Trim() }
        if (-not $department) { return $DefaultOU }
        return ('OU=' + (ConvertTo-ADTRdnValue $department) + ',' + $DefaultOU)
    }
    # Lorsqu une OU est choisie dans l interface, elle doit avoir priorite sur toute
    # colonne OU eventuellement presente dans le CSV. Le comportement historique
    # reste disponible en ligne de commande si -DefaultOU n est pas fourni.
    if ($DefaultOU) { return $DefaultOU }
    if ($Row.PSObject.Properties['OU'] -and $Row.OU) { return ([string]$Row.OU).Trim() }
    return $null
}
