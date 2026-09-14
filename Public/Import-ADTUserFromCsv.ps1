function Import-ADTUserFromCsv {
<#
.SYNOPSIS
    Cree en masse des comptes Active Directory a partir d un fichier CSV.
.DESCRIPTION
    Compatible Windows PowerShell 2.0+ et Windows Server 2008 SP2 a 2025.
    Accepte les groupes multiples dans la colonne Groups, meme si les points-virgules
    n ont pas ete entoures de guillemets dans un CSV separe par des points-virgules.
    Lorsque -DefaultOU est fourni, il a priorite sur une eventuelle colonne OU du CSV.
    Avec -CreateDepartmentOUs, -DefaultOU devient l OU parente et une sous-OU est
    creee automatiquement pour chaque valeur Department.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
        [string]$Path,
        [char]$Delimiter = ';',
        [string]$DefaultOU,
        [string[]]$DefaultGroups,
        [switch]$CreateDepartmentOUs,
        [string]$PasswordReportPath,
        [string]$HomeDirectoryRoot,
        [string]$HomeDrive,
        [ValidateRange(12, 128)][int]$PasswordLength = 16,
        [switch]$SkipExisting,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    if ($LogPath) { $script:ADTLogPath = $LogPath }
    Write-ADTLog -Level 'INFO' -Message ("=== Debut import CSV : {0} ===" -f $Path)

    [void](Test-ADTCsvShape -Path $Path -Delimiter $Delimiter)
    $rows = @(Read-ADTFlexibleCsv -Path $Path -Delimiter $Delimiter)
    if ($rows.Count -eq 0) { throw 'Le fichier CSV ne contient aucune ligne.' }

    $columns = @($rows[0].PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($column in @('GivenName','Surname')) {
        $found = $false
        foreach ($existing in $columns) { if ($existing -eq $column) { $found = $true } }
        if (-not $found) { throw ("Colonne obligatoire absente : {0}. Colonnes trouvees : {1}" -f $column,($columns -join ', ')) }
    }

    $hasOUColumn = $false
    foreach ($existing in $columns) { if ($existing -eq 'OU') { $hasOUColumn = $true } }
    if ($CreateDepartmentOUs -and -not $DefaultOU) { throw 'Selectionner une OU parente avant de demander la creation automatique des sous-OU.' }
    if (-not $CreateDepartmentOUs -and -not $hasOUColumn -and -not $DefaultOU) { throw "Aucune colonne 'OU' dans le CSV et aucun -DefaultOU fourni." }

    $common = @{}
    if ($Credential) { $common['Credential'] = $Credential }
    $prereq = Test-ADTPrerequisite -Server $Server -Credential $Credential
    if (-not $prereq.Ready) { throw $prereq.Messages }
    $Server = $prereq.Server
    $common['Server'] = $Server

    if ($CreateDepartmentOUs) {
        try { Get-ADTNativeObject -Identity $DefaultOU @common -ErrorAction Stop | Out-Null }
        catch { throw ("OU parente inaccessible : {0}" -f $DefaultOU) }
    }

    $seen = @{}
    $validation = New-Object System.Collections.ArrayList
    $groupWarnings = @{}
    foreach ($row in $rows) {
        $line = [int]$row.__ADTLineNumber
        if (-not ([string]$row.GivenName).Trim() -or -not ([string]$row.Surname).Trim()) { [void]$validation.Add("Ligne $line : prenom/nom manquant.") }

        $targetOU = Get-ADTImportTargetOU -Row $row -DefaultOU $DefaultOU -CreateDepartmentOUs ([bool]$CreateDepartmentOUs)
        if (-not $targetOU) { [void]$validation.Add("Ligne $line : OU manquante.") }
        elseif (-not $CreateDepartmentOUs) {
            try { Get-ADTNativeObject -Identity $targetOU @common -ErrorAction Stop | Out-Null }
            catch { [void]$validation.Add("Ligne $line : OU inaccessible : $targetOU") }
        }

        $rowGroups = @(Get-ADTCsvRowGroups -Row $row -DefaultGroups $DefaultGroups)
        $lineGroupWarnings = New-Object System.Collections.ArrayList
        foreach ($g in $rowGroups) {
            try { Get-ADTNativeGroup -Identity $g @common -ErrorAction Stop | Out-Null }
            catch {
                $detail = $_.Exception.Message
                [void]$lineGroupWarnings.Add(('Groupe non applique {0} : {1}' -f $g,$detail))
                Write-Warning ("Ligne $line : groupe non resolu : $g - $detail")
            }
        }
        if ($lineGroupWarnings.Count) { $groupWarnings[$line] = ($lineGroupWarnings -join ' | ') }

        if ($row.PSObject.Properties['SamAccountName'] -and $row.SamAccountName) {
            $normalized = (ConvertTo-ADTAsciiString $row.SamAccountName).ToLowerInvariant()
            if ($normalized.Length -gt 20) { $normalized = $normalized.Substring(0,20) }
            if (-not $normalized) { [void]$validation.Add("Ligne $line : identifiant invalide.") }
            elseif ($seen.ContainsKey($normalized)) { [void]$validation.Add("Ligne $line : identifiant duplique apres normalisation : $normalized") }
            else { $seen[$normalized] = $true }
        }
    }
    if ($validation.Count) { throw ($validation -join "`n") }

    if (-not $PSCmdlet.ShouldProcess($Path,('Importer {0} ligne(s) dans {1}' -f $rows.Count,$Server))) {
        if (-not $WhatIfPreference) { return }
    }

    $results = New-Object System.Collections.ArrayList
    $createdOUs = @{}

    foreach ($row in $rows) {
        $lineNumber = [int]$row.__ADTLineNumber
        if (-not $row.GivenName -and -not $row.Surname) { continue }

        $targetOU = Get-ADTImportTargetOU -Row $row -DefaultOU $DefaultOU -CreateDepartmentOUs ([bool]$CreateDepartmentOUs)
        $groupList = @(Get-ADTCsvRowGroups -Row $row -DefaultGroups $DefaultGroups)

        if ($WhatIfPreference) {
            $previewError = ''
            if ($groupWarnings.ContainsKey($lineNumber)) { $previewError = [string]$groupWarnings[$lineNumber] }
            [void]$results.Add((New-Object PSObject -Property @{
                SamAccountName = [string]$row.SamAccountName
                DisplayName = (([string]$row.GivenName + ' ' + [string]$row.Surname).Trim())
                Status = 'Simulation'
                Password = ''
                DistinguishedName = $targetOU
                Groups = ($groupList -join ';')
                HomeDirectory = ''
                Error = $previewError
            } | Select-Object SamAccountName,DisplayName,Status,Password,DistinguishedName,Groups,HomeDirectory,Error))
            continue
        }

        if ($CreateDepartmentOUs) {
            $department = ''
            if ($row.PSObject.Properties['Department']) { $department = ([string]$row.Department).Trim() }
            if ($department) {
                $deptKey = $department.ToLowerInvariant()
                if (-not $createdOUs.ContainsKey($deptKey)) {
                    $targetOU = Ensure-ADTNativeOU -BaseDN $DefaultOU -Name $department -Server $Server -Credential $Credential
                    $createdOUs[$deptKey] = $targetOU
                    Write-ADTLog -Level 'INFO' -Message ("OU departement prete : {0}" -f $targetOU)
                } else { $targetOU = $createdOUs[$deptKey] }
            }
        }

        $params = @{
            GivenName = $row.GivenName
            Surname = $row.Surname
            Path = $targetOU
            PasswordLength = $PasswordLength
            ErrorAction = 'Stop'
            Confirm = $false
        }
        foreach ($optional in @('SamAccountName','DisplayName','Title','Department','Company','Office','EmailAddress','Manager')) {
            if ($row.PSObject.Properties[$optional] -and $row.$optional) { $params[$optional] = $row.$optional }
        }
        if ($groupList.Count -gt 0) { $params['Groups'] = [string[]]$groupList }
        if ($HomeDirectoryRoot) { $params['HomeDirectoryRoot'] = $HomeDirectoryRoot }
        if ($HomeDrive) { $params['HomeDrive'] = $HomeDrive }
        if ($Server) { $params['Server'] = $Server }
        if ($Credential) { $params['Credential'] = $Credential }

        if ($SkipExisting -and $row.PSObject.Properties['SamAccountName'] -and $row.SamAccountName) {
            $normalized = (ConvertTo-ADTAsciiString $row.SamAccountName).ToLowerInvariant()
            if ($normalized.Length -gt 20) { $normalized = $normalized.Substring(0,20) }
            $exists = Get-ADTNativeUser -Filter "SamAccountName -eq '$normalized'" -ErrorAction Stop @common
            if ($exists) {
                [void]$results.Add((New-Object PSObject -Property @{
                    SamAccountName=$row.SamAccountName; DisplayName=''; Status='Ignore'; Password=''; DistinguishedName=$targetOU; Groups=($groupList -join ';'); HomeDirectory=''; Error='Compte deja existant'
                } | Select-Object SamAccountName,DisplayName,Status,Password,DistinguishedName,Groups,HomeDirectory,Error))
                continue
            }
        }

        $result = New-ADTUser @params
        if ($result) { [void]$results.Add($result) }
    }

    if ($PasswordReportPath -and -not $WhatIfPreference) {
        try {
            $results | Where-Object { $_.Status -eq 'Cree' -or $_.Status -eq 'Partiel' } | Select-Object SamAccountName,DisplayName,Password | Export-Csv -Path $PasswordReportPath -NoTypeInformation -Delimiter $Delimiter -Encoding UTF8 -ErrorAction Stop
            Write-Warning ("Mots de passe exportes en clair vers {0}. Supprimer ce fichier des qu il a servi." -f $PasswordReportPath)
        } catch { Write-ADTLog -Level 'ERROR' -Message ("Export des mots de passe echoue : " + $_.Exception.Message) }
    }

    $created = @($results | Where-Object { $_.Status -eq 'Cree' }).Count
    $failed = @($results | Where-Object { $_.Status -eq 'Echec' }).Count
    $skipped = @($results | Where-Object { $_.Status -eq 'Ignore' }).Count
    Write-ADTLog -Level 'INFO' -Message ("=== Fin import : {0} crees, {1} echecs, {2} ignores ===" -f $created,$failed,$skipped)
    return $results
}
