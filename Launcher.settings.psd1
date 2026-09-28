@{
    # Parametres du lanceur (Launcher.ps1, PSADToolkit.exe). Une mise a jour de
    # PSADToolkit remplace ce fichier : la version de reference de GliderUI doit
    # suivre celle de l application. Reporter ensuite les reglages modifies.

    PowerShell = @{
        # Version minimale exigee par GliderUI. En dessous, PowerShell 7 est installe.
        MinimumVersion = '7.4.0'
        # Canal suivi pour installer et mettre a jour : 'lts' (support long) ou 'stable'.
        Channel        = 'lts'
        # None, Patch, Minor ou Major. Minor : reste en 7.x.
        UpdatePolicy   = 'Minor'
    }

    GliderUI = @{
        # Version eprouvee avec cette version de PSADToolkit, livree avec l installateur.
        BaselineVersion = '0.4.1'
        # GliderUI est en 0.x : une version MINEURE peut casser l interface. Patch ne
        # suit que les correctifs (0.4.1 -> 0.4.2). Chaque nouvelle version est
        # verifiee avant d etre utilisee ; en cas d echec la precedente est conservee.
        UpdatePolicy    = 'Patch'
    }

    # Frequence de recherche des mises a jour, en heures. 0 = a chaque lancement.
    CheckIntervalHours = 24

    # $false : ne jamais contacter Internet (poste isole). Seuls les paquets livres
    # avec l installateur sont alors utilises.
    AllowOnline = $true
}
