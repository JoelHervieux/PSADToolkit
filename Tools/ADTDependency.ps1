<#
    Prerequis de l interface : PowerShell 7 et GliderUI.

    Fonctions partagees par le lanceur (Launcher.ps1, execute par Windows PowerShell
    5.1) et par Initialize-ADTEnvironment.ps1 (execute par PowerShell 7). Le code
    reste donc compatible Windows PowerShell 5.1 : ni operateur ternaire, ni ??, ni
    [Type]::new().

    Les fonctions de decision - quelle version retenir, faut-il verifier les mises a
    jour - ne touchent ni au reseau ni au disque : Tests\Launcher.Tests.ps1 les
    exerce directement.
#>

function ConvertTo-ADTVersion {
    # '7.4.6', 'v7.4.6' ou '0.4.1' -> [version]. Une preversion (7.5.0-rc.1) ou une
    # chaine illisible rend $null : on ne propose jamais une preversion d office.
    param([string]$Text)
    if (-not $Text) { return $null }
    $clean = $Text.Trim()
    if ($clean.StartsWith('v') -or $clean.StartsWith('V')) { $clean = $clean.Substring(1) }
    if ($clean -notmatch '^\d+(\.\d+){1,3}$') { return $null }
    return [version]$clean
}

function Select-ADTUpdateCandidate {
<#
    Rend la plus haute version disponible, superieure a la version courante, que la
    politique autorise ; $null s il n y en a pas.
      None  : jamais de mise a jour ;
      Patch : meme MAJEUR.MINEUR (0.4.1 -> 0.4.3, pas 0.5.0) ;
      Minor : meme MAJEUR (7.4.6 -> 7.6.1, pas 8.0.0) ;
      Major : toute version superieure.
    Les versions deja refusees (echec de verification) sont ecartees.
#>
    param(
        [string]$Current,
        [string[]]$Available,
        [ValidateSet('None', 'Patch', 'Minor', 'Major')][string]$Policy = 'Patch',
        [string[]]$Rejected = @()
    )
    if ($Policy -eq 'None') { return $null }
    $currentVersion = ConvertTo-ADTVersion $Current
    if (-not $currentVersion) { return $null }
    $best = $null
    foreach ($item in @($Available)) {
        $candidate = ConvertTo-ADTVersion $item
        if (-not $candidate) { continue }
        if ($candidate -le $currentVersion) { continue }
        if (@($Rejected) -contains $candidate.ToString()) { continue }
        if ($Policy -eq 'Patch' -and ($candidate.Major -ne $currentVersion.Major -or $candidate.Minor -ne $currentVersion.Minor)) { continue }
        if ($Policy -eq 'Minor' -and $candidate.Major -ne $currentVersion.Major) { continue }
        if (-not $best -or $candidate -gt $best) { $best = $candidate }
    }
    if ($best) { return $best.ToString() }
    return $null
}

function Test-ADTUpdateDue {
    # Vrai si la derniere verification est absente, illisible ou plus ancienne que
    # l intervalle. Une date dans le futur (horloge corrigee) compte comme due.
    param([string]$LastCheck, [int]$IntervalHours = 24, [datetime]$Now = (Get-Date))
    if ($IntervalHours -le 0) { return $true }
    if (-not $LastCheck) { return $true }
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
    if (-not [datetime]::TryParse($LastCheck, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $true }
    $elapsed = $Now.ToUniversalTime() - $parsed.ToUniversalTime()
    if ($elapsed.TotalHours -lt 0) { return $true }
    return ($elapsed.TotalHours -ge $IntervalHours)
}

function Find-ADTBundledPackage {
<#
    Paquet embarque de plus haute version dans un dossier. Pattern est une
    expression reguliere sur le nom du fichier, avec un groupe nomme v pour la
    version : '^GliderUI\.(?<v>\d+\.\d+\.\d+)\.nupkg$'.
#>
    param([string]$Folder, [string]$Pattern, [string]$Version)
    if (-not $Folder -or -not (Test-Path -LiteralPath $Folder)) { return $null }
    $best = $null
    foreach ($file in @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue)) {
        $match = [regex]::Match($file.Name, $Pattern, 'IgnoreCase')
        if (-not $match.Success) { continue }
        $found = ConvertTo-ADTVersion $match.Groups['v'].Value
        if (-not $found) { continue }
        if ($Version -and $found.ToString() -ne $Version) { continue }
        if (-not $best -or $found -gt $best.Version) {
            $best = New-Object PSObject -Property @{ Path = $file.FullName; Version = $found }
        }
    }
    return $best
}

function Get-ADTPowerShellMsiUrl {
    param([string]$Version, [ValidateSet('x64', 'arm64', 'x86')][string]$Architecture = 'x64')
    $clean = (ConvertTo-ADTVersion $Version).ToString()
    return ('https://github.com/PowerShell/PowerShell/releases/download/v{0}/PowerShell-{0}-win-{1}.msi' -f $clean, $Architecture)
}

function Get-ADTArchitecture {
    # Architecture du systeme, pas du processus : un lanceur 32 bits sur Windows 64
    # bits doit quand meme installer PowerShell 64 bits.
    $value = [string]$env:PROCESSOR_ARCHITEW6432
    if (-not $value) { $value = [string]$env:PROCESSOR_ARCHITECTURE }
    switch -Regex ($value) {
        'ARM64' { return 'arm64' }
        'AMD64|IA64' { return 'x64' }
        default { return 'x86' }
    }
}

function Get-ADTPowerShellInstall {
<#
    PowerShell 7 installes sur ce poste, du plus recent au plus ancien : objets
    Path / Version. La version est lue dans le fichier lui-meme, pas dans son nom
    de dossier : "7" ou "7-preview" ne disent rien de la version reelle.
#>
    $paths = New-Object System.Collections.ArrayList
    foreach ($base in @($env:ProgramFiles, $env:ProgramW6432, ${env:ProgramFiles(x86)})) {
        if (-not $base) { continue }
        foreach ($folder in @(Get-ChildItem -LiteralPath (Join-Path $base 'PowerShell') -Directory -ErrorAction SilentlyContinue)) {
            [void]$paths.Add((Join-Path $folder.FullName 'pwsh.exe'))
        }
    }
    foreach ($command in @(Get-Command -Name pwsh.exe -CommandType Application -ErrorAction SilentlyContinue)) {
        [void]$paths.Add([string]$command.Source)
    }

    $seen = @{}
    $result = New-Object System.Collections.ArrayList
    foreach ($path in $paths) {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
        $key = $path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($path)
        $match = [regex]::Match([string]$info.ProductVersion, '^(\d+\.\d+\.\d+)')
        if (-not $match.Success) { continue }
        # Une preversion porte un suffixe (7.6.0-preview.3) : ne pas la retenir.
        if ([string]$info.ProductVersion -match '^\d+\.\d+\.\d+-') { continue }
        [void]$result.Add((New-Object PSObject -Property @{ Path = $path; Version = [version]$match.Groups[1].Value }))
    }
    return @($result | Sort-Object -Property Version -Descending)
}

function Get-ADTModuleRoot {
    # Dossier des modules de PowerShell 7 pour une portee.
    param([ValidateSet('CurrentUser', 'AllUsers')][string]$Scope = 'CurrentUser')
    if ($Scope -eq 'AllUsers') { return (Join-Path $env:ProgramFiles 'PowerShell\Modules') }
    $documents = [string][Environment]::GetFolderPath('MyDocuments')
    if (-not $documents) { $documents = Join-Path $env:USERPROFILE 'Documents' }
    return (Join-Path $documents 'PowerShell\Modules')
}

function Get-ADTNupkgInfo {
    # Identifiant et version lus dans le .nuspec : le nom du fichier peut mentir.
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -notlike '*.nuspec' -or $entry.FullName -like '*/*') { continue }
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try { $content = $reader.ReadToEnd() } finally { $reader.Dispose() }
            $id = [regex]::Match($content, '<id>\s*([^<]+?)\s*</id>').Groups[1].Value
            $version = [regex]::Match($content, '<version>\s*([^<]+?)\s*</version>').Groups[1].Value
            return (New-Object PSObject -Property @{ Id = $id; Version = $version })
        }
    } finally { $archive.Dispose() }
    throw ('Aucun .nuspec dans ' + $Path + ' : ce n est pas un paquet NuGet.')
}

function Install-ADTNupkgModule {
<#
    Installe un module a partir d un .nupkg, sans reseau : un .nupkg est une archive
    ZIP dont le contenu, debarrasse des metadonnees NuGet, est le module lui-meme.
    Rend le dossier cree. Leve une erreur si le manifeste attendu est absent.
#>
    param([string]$Path, [string]$ModuleRoot)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $info = Get-ADTNupkgInfo -Path $Path
    if (-not $info.Id -or -not (ConvertTo-ADTVersion $info.Version)) {
        throw ('Paquet illisible : ' + $Path)
    }
    $target = Join-Path $ModuleRoot (Join-Path $info.Id $info.Version)
    $staging = $target + '.partial'
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    $null = New-Item -Path $staging -ItemType Directory -Force
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Path, $staging)
        foreach ($name in @('_rels', 'package', '[Content_Types].xml')) {
            $item = Join-Path $staging $name
            if (Test-Path -LiteralPath $item) { Remove-Item -LiteralPath $item -Recurse -Force }
        }
        Get-ChildItem -LiteralPath $staging -Filter '*.nuspec' -File | Remove-Item -Force
        # Les noms d entree ZIP sont encodes en URL (%20...) : les retablir.
        foreach ($file in @(Get-ChildItem -LiteralPath $staging -Recurse -File | Where-Object { $_.Name -match '%[0-9A-Fa-f]{2}' })) {
            Rename-Item -LiteralPath $file.FullName -NewName ([uri]::UnescapeDataString($file.Name))
        }
        if (-not (Test-Path -LiteralPath (Join-Path $staging ($info.Id + '.psd1')))) {
            throw ('Le paquet {0} ne contient pas {1}.psd1.' -f $Path, $info.Id)
        }
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        Move-Item -LiteralPath $staging -Destination $target
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return $target
}

function ConvertTo-ADTHashtable {
    # ConvertFrom-Json rend des PSCustomObject sous Windows PowerShell 5.1.
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $table = @{}
        foreach ($property in $InputObject.PSObject.Properties) { $table[$property.Name] = ConvertTo-ADTHashtable $property.Value }
        return $table
    }
    if ($InputObject -is [array]) {
        $items = @()
        foreach ($item in $InputObject) { $items += , (ConvertTo-ADTHashtable $item) }
        return , $items
    }
    return $InputObject
}

function Read-ADTState {
    # Etat du lanceur : dates de verification, versions validees ou refusees. Un
    # fichier absent ou abime rend un etat vide : on reverifie, sans echouer.
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @{} }
    try {
        $text = [System.IO.File]::ReadAllText($Path)
        if (-not $text.Trim()) { return @{} }
        $state = ConvertTo-ADTHashtable (ConvertFrom-Json -InputObject $text)
        if ($state -is [System.Collections.IDictionary]) { return $state }
    } catch { Write-Verbose ('Etat illisible, ignore : ' + $_.Exception.Message) }
    return @{}
}

function Write-ADTState {
    param([string]$Path, [hashtable]$State)
    $folder = Split-Path -Parent $Path
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -Path $folder -ItemType Directory -Force }
    $json = ConvertTo-Json -InputObject $State -Depth 5
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-ADTLauncherLog {
    param([string]$Path, [string]$Message)
    if (-not $Path) { return }
    try {
        $folder = Split-Path -Parent $Path
        if ($folder -and -not (Test-Path -LiteralPath $folder)) { $null = New-Item -Path $folder -ItemType Directory -Force }
        $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $Message
        [System.IO.File]::AppendAllText($Path, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Verbose ('Journal du lanceur non ecrit : ' + $_.Exception.Message) }
}
