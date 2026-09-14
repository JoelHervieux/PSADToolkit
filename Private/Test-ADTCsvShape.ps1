function Test-ADTCsvShape {
    param([string]$Path,[char]$Delimiter)
    $rows = @(Read-ADTFlexibleCsv -Path $Path -Delimiter $Delimiter)
    if ($rows.Count -eq 0) { throw 'Le fichier CSV ne contient aucune ligne.' }
    return $true
}
