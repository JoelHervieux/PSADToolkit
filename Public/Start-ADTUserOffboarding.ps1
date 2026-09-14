function Start-ADTUserOffboarding {
<#
.SYNOPSIS
    Sauvegarde les acces, desactive un compte puis execute son depart.
.DESCRIPTION
    Le CSV des groupes et le CLIXML de l etat initial doivent tous deux etre ecrits
    avant de modifier AD. Le mot de passe precedent et les sessions deja ouvertes
    ne sont pas restaurables par cette sauvegarde. Les echecs partiels sont exposes.
.EXAMPLE
    Start-ADTUserOffboarding -Identity 'jcote' -BackupPath C:\Offboarding -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param(
        [Parameter(Mandatory=$true,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
        [Alias('SamAccountName','User')][string[]]$Identity,
        [string]$DisabledOU,[string]$BackupPath='.',[switch]$KeepGroups,[switch]$NoPasswordReset,
        [string]$Reason='Depart de l employe',[string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,[string]$LogPath
    )
    begin {
        if ($LogPath) { $script:ADTLogPath=$LogPath }
        $pre = Test-ADTPrerequisite -Server $Server -Credential $Credential
        if (-not $pre.Ready) { throw $pre.Messages }
        $common = @{ Server=$pre.Server }
        if ($Credential) { $common['Credential']=$Credential }
        if ($DisabledOU) { Get-ADTNativeObject -Identity $DisabledOU @common -ErrorAction Stop | Out-Null }
    }
    process {
        foreach ($id in $Identity) {
            $steps=New-Object System.Collections.ArrayList; $errors=New-Object System.Collections.ArrayList
            $status='Echec'; $sam=$id; $backupFile=''; $stateFile=''
            try {
                $u = Get-ADTNativeUser -Identity $id @common -ErrorAction Stop
                $sam=$u.SamAccountName
                if ($PSCmdlet.ShouldProcess($u.DistinguishedName,'Sauvegarder, desactiver et traiter le depart')) {
                    if (-not (Test-Path -LiteralPath $BackupPath)) { New-Item -Path $BackupPath -ItemType Directory -ErrorAction Stop | Out-Null }
                    $token=(Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N')
                    $backupFile=Join-Path $BackupPath ('offboarding-'+$sam+'-'+$token+'.csv')
                    $stateFile=Join-Path $BackupPath ('offboarding-'+$sam+'-'+$token+'.clixml')
                    $u | Export-Clixml -Path $stateFile -ErrorAction Stop
                    $rows=@()
                    foreach ($dn in $u.MemberOf) { if ($dn) { $rows += New-Object PSObject -Property @{ SamAccountName=$sam; GroupDN=$dn; OriginalDN=$u.DistinguishedName; BackupDate=(Get-Date).ToString('o') } } }
                    if ($rows.Count) { $rows | Select-Object SamAccountName,GroupDN,OriginalDN,BackupDate | Export-Csv -Path $backupFile -NoTypeInformation -Encoding UTF8 -ErrorAction Stop }
                    else { Set-Content -Path $backupFile -Value '"SamAccountName","GroupDN","OriginalDN","BackupDate"' -Encoding UTF8 -ErrorAction Stop }
                    [void]$steps.Add('Sauvegardes ecrites')
                    # Disable first; a later password/group failure must not leave the account enabled.
                    Disable-ADTNativeAccount -Identity $u.DistinguishedName @common -ErrorAction Stop
                    [void]$steps.Add('Compte desactive')
                    if (-not $NoPasswordReset) {
                        try {
                            $password=ConvertTo-ADTSecurePassword -Text (New-ADTRandomPassword -Length 24)
                            Set-ADTNativePassword -Identity $u.DistinguishedName -NewPassword $password -Reset @common -ErrorAction Stop
                            [void]$steps.Add('Mot de passe reinitialise')
                        } catch { [void]$errors.Add('Mot de passe : '+$_.Exception.Message) }
                        finally { if ($password) { $password.Dispose(); $password=$null } }
                    }
                    if (-not $KeepGroups) {
                        foreach ($dn in $u.MemberOf) {
                            if (-not $dn) { continue }
                            try { Remove-ADTNativeGroupMember -Identity $dn -Members $u.DistinguishedName -Confirm:$false @common -ErrorAction Stop; [void]$steps.Add('Retire : '+$dn) }
                            catch { [void]$errors.Add('Groupe '+$dn+' : '+$_.Exception.Message) }
                        }
                    }
                    try {
                        $note='[{0}] {1} - {2}\{3}' -f (Get-Date -Format 'yyyy-MM-dd'),$Reason,$env:USERDOMAIN,$env:USERNAME
                        if ($u.Description) { $note += ' | '+$u.Description }
                        if ($note.Length -gt 1024) { $note=$note.Substring(0,1024) }
                        Set-ADTNativeUser -Identity $u.DistinguishedName -Description $note @common -ErrorAction Stop
                        [void]$steps.Add('Description mise a jour')
                    } catch { [void]$errors.Add('Description : '+$_.Exception.Message) }
                    if ($DisabledOU) {
                        try { Move-ADTNativeObject -Identity $u.DistinguishedName -TargetPath $DisabledOU @common -ErrorAction Stop; [void]$steps.Add('Compte deplace') }
                        catch { [void]$errors.Add('Deplacement : '+$_.Exception.Message) }
                    }
                    $status='Termine'
                    if ($errors.Count) { $status='Partiel' }
                } else { $status='Annule'; if ($WhatIfPreference) { $status='Simulation' } }
            } catch { [void]$errors.Add($_.Exception.Message); if ($steps.Count) { $status='Partiel' } }
            if (-not $WhatIfPreference) { Write-ADTLog -Message ('Depart {0} : {1}. Etapes: {2}. Erreurs: {3}' -f $sam,$status,($steps -join '; '),($errors -join ' | ')) }
            New-Object PSObject -Property @{ SamAccountName=$sam; Status=$status; Steps=($steps -join ' > '); BackupFile=$backupFile; StateFile=$stateFile; Error=($errors -join ' | ') }
        }
    }
}
