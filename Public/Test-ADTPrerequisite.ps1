function Test-ADTPrerequisite {
<#
.SYNOPSIS
    Verifie Windows PowerShell, LDAP et l acces au domaine sans exiger RSAT.
.EXAMPLE
    Test-ADTPrerequisite -Server 'dc01.contoso.local'
#>
    [CmdletBinding()]
    param([string]$Server,[System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential)
    $messages = New-Object System.Collections.ArrayList
    $ready = $false; $domainName = ''; $mode = ''; $dc = ''; $elevated = $false
    try {
        if ($PSVersionTable.PSVersion.Major -lt 2) { throw 'Windows PowerShell 2.0 minimum requis.' }
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Ce module LDAP necessite Windows et .NET Framework.' }
        if ($PSVersionTable.PSVersion.Major -gt 5) { throw 'Lancer avec Windows PowerShell (powershell.exe), pas PowerShell 7 (pwsh.exe).' }
        Add-Type -AssemblyName System.DirectoryServices -ErrorAction Stop
        $domain = Get-ADTNativeDomain -Server $Server -Credential $Credential -ErrorAction Stop
        $domainName = $domain.DNSRoot; $mode = $domain.DomainMode; $dc = $domain.Server; $ready = $true
        [void]$messages.Add('Connexion LDAP reussie. Les droits d ecriture dependent des delegations AD du compte.')
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        try { $principal = New-Object System.Security.Principal.WindowsPrincipal($id); $elevated = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator) } finally { $id.Dispose() }
    } catch { [void]$messages.Add($_.Exception.Message) }
    New-Object PSObject -Property @{ PowerShellVersion=[string]$PSVersionTable.PSVersion; IsElevated=$elevated; ADModuleAvailable=([bool](Get-Module -ListAvailable -Name ActiveDirectory)); ADModuleLoaded=([bool](Get-Module ActiveDirectory)); Backend='LDAP signe et chiffre (ADSI)'; DomainReachable=$ready; DomainName=$domainName; DomainMode=$mode; Server=$dc; Ready=$ready; Messages=($messages -join ' | ') }
}
