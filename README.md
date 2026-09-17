# PSADToolkit 3.0.0-test4

Administration Active Directory avec interface graphique en français, import CSV et rapports HTML. L'interface est bâtie sur **[GliderUI](https://github.com/mdgrs-mei/GliderUI)** (Avalonia) et exige **PowerShell 7.4 ou supérieur**. Les fonctions du module restent utilisables en ligne de commande depuis **Windows PowerShell 2.0 à 5.1**. Les contrôleurs de domaine visés vont de **Windows Server 2008 SP2 à Windows Server 2025** : l'accès se fait en LDAP par ADSI / .NET, donc **RSAT et AD Web Services ne sont pas nécessaires** et rien n'est installé sur le contrôleur de domaine.

**Version `3.0.0-test4` — canal de test.** Le canal `test` signifie que cette version n'a pas encore passé la recette Windows décrite dans `VALIDATION.md` : ne pas s'en servir pour des écritures en production. Le passage en 3.0.0 marque le remplacement de l'interface Windows Forms par GliderUI et l'abandon de Windows PowerShell comme moteur de l'interface. La nomenclature, la portée de chaque numéro et la procédure de publication sont décrites dans `VERSIONING.md`.

> GliderUI annonce lui-même une phase de prototypage avec des ruptures d'API fréquentes. Épingler la version installée et relire `CHANGELOG.md` avant toute mise à jour.

## Démarrage

1. Installer **PowerShell 7.4 ou supérieur**. Il s'installe **à côté** de Windows PowerShell 5.1 et ne le remplace pas.

   - Téléchargement direct : [github.com/PowerShell/PowerShell/releases/latest](https://github.com/PowerShell/PowerShell/releases/latest) — prendre le fichier `PowerShell-<version>-win-x64.msi`.
   - Ou en ligne de commande : `winget install --id Microsoft.PowerShell -e`
   - Procédure détaillée : [Installation de PowerShell sur Windows — Microsoft](https://learn.microsoft.com/fr-fr/powershell/scripting/install/installing-powershell-on-windows)

   Vérifier ensuite la version depuis `pwsh.exe` :

   ```powershell
   $PSVersionTable.PSVersion
   ```

2. Installer le module [GliderUI](https://www.powershellgallery.com/packages/GliderUI) et son serveur :

   ```powershell
   Install-PSResource -Name GliderUI
   Install-GLIServer
   ```

   `Install-GLIServer` télécharge l'exécutable Avalonia correspondant à la plateforme. Le relancer après chaque mise à jour du module.
3. Extraire complètement le ZIP dans un dossier local (par exemple `C:\Outils\PSADToolkit`). Ne pas lancer depuis l'intérieur de l'archive.
4. Double-cliquer sur **Lancer.cmd**. Il repère `pwsh.exe` et démarre l'interface. Le mode STA n'est plus nécessaire : GliderUI affiche la fenêtre dans un processus serveur distinct.
5. Saisir le **nom DNS complet d'un contrôleur de domaine**, par exemple `dc01.contoso.local`, puis cliquer sur **Tester la connexion**. Laisser vide pour utiliser le domaine du compte Windows courant.
6. Pour employer une autre identité, cocher **Autre compte**, saisir `DOMAINE\utilisateur` ou un UPN et son mot de passe. Les droits délégués dans AD sont nécessaires ; être administrateur local ne donne pas automatiquement ces droits.
7. Choisir un onglet, remplir les champs, puis cliquer sur **Exécuter**. Pour les modifications AD, la **simulation est cochée par défaut**. Décocher seulement après vérification : une confirmation récapitule la cible et l'action.

Les résultats s'affichent dans le tableau. Agrandir la fenêtre ou défiler horizontalement pour lire toutes les colonnes. Vérifier **Status**, **Error** et **Messages**. `Partiel` signifie que certaines modifications ont déjà été appliquées : examiner l'état du compte avant de relancer.

L'interface reste réactive pendant les opérations. Une seule opération est autorisée à la fois. Attendre sa fin avant de fermer. Les mots de passe générés sont masqués dans le tableau et exclus de l'export standard ; la case **Afficher / exporter les mots de passe générés** permet de les consulter ou de les exporter explicitement. Ils restent en mémoire jusqu'au prochain traitement ou à la fermeture.

## Compatibilité et prérequis

| Rôle | Système | Prérequis |
|---|---|---|
| Poste qui affiche l'interface | Windows 10 / 11, ou Windows Server 2016 à 2025 avec bureau | [PowerShell 7.4+](https://github.com/PowerShell/PowerShell/releases/latest), module [GliderUI](https://www.powershellgallery.com/packages/GliderUI) et `Install-GLIServer` |
| Contrôleurs de domaine administrés | Windows Server 2008 SP2 à 2025 | Aucun composant à installer : accès LDAP / ADSI depuis le poste d'administration |
| Utilisation en ligne de commande | Tout hôte Windows joignant le domaine | Windows PowerShell 2.0 à 5.1, ou PowerShell 7 ; `.NET` et `System.DirectoryServices` du système |
| Server Core | Windows Server sans bureau | Ligne de commande seulement : lancer l'interface depuis un poste d'administration |

**L'interface ne s'exécute plus sous Windows PowerShell.** `powershell.exe` ne dépasse pas la version 5.1 ; [PowerShell 7.4+](https://github.com/PowerShell/PowerShell/releases/latest) est exigé par GliderUI. Lancer l'interface avec `pwsh.exe`, ce que fait `Lancer.cmd`. Les serveurs qui ne peuvent pas recevoir PowerShell 7, dont Server 2008 SP2, restent administrables : installer PSADToolkit sur un poste d'administration moderne, qui joint le contrôleur de domaine en LDAP.

**Le backend reste Windows.** GliderUI est multiplateforme, mais `System.DirectoryServices` ne l'est pas : l'interface refuse de démarrer ailleurs que sous Windows.

**Les fonctions du module restent compatibles Windows PowerShell 2.0.** Le manifeste déclare toujours `PowerShellVersion = '2.0'` et `Tests\Test-Compatibility.ps1` continue de le vérifier pour `Private`, `Public` et le standalone. Seule l'interface a changé de moteur.

La compatibilité ci-dessus est une **cible technique**, pas une certification obtenue sur chaque système. Le contrôle de syntaxe et les tests avec annuaire simulé ont été exécutés ; l'interface GliderUI n'a encore été exécutée sur aucune machine, et les écritures sur un véritable domaine 2008–2025 doivent être validées dans un laboratoire Windows. Le comportement dépend aussi des stratégies d'authentification, des délégations et des composants installés. Les versions futures de Windows Server ne sont pas garanties.

## Connexion et dépannage

- Utiliser un **FQDN de contrôleur de domaine accessible en écriture**, sans `LDAP://`, numéro de port ni chemin. Le serveur effectivement trouvé est affiché après le test et réutilisé par les opérations.
- DNS, horloge et accès réseau au domaine doivent être corrects. Le transport utilise LDAP avec authentification intégrée, signature et chiffrement de session (`Secure | Signing | Sealing`). Aucun repli vers une liaison LDAP anonyme ou un simple bind non protégé n'est prévu.
- Le test de connexion confirme la lecture du domaine, **pas les droits de modification**. Les politiques de mot de passe peuvent refuser une valeur générée.
- Si Windows bloque le fichier téléchargé, ouvrir les propriétés du ZIP et choisir **Débloquer**, si proposé, avant de l'extraire à nouveau. Le lanceur utilise `RemoteSigned` pour son processus uniquement. Une stratégie de groupe ou une obligation de signature peut toujours s'imposer ; faire signer les scripts si nécessaire.
- Une session élevée n'est normalement pas nécessaire pour les opérations AD déléguées. Les modifications d'un partage ou de ses ACL utilisent l'identité de la **session Windows courante**, même si un autre compte est fourni pour LDAP.
- Journal par défaut : `%LOCALAPPDATA%\PSADToolkit\PSADToolkit.log`. Paramètre `-LogPath` disponible en ligne de commande. Les erreurs de journalisation sont affichées comme avertissements. Aucun mot de passe n'est volontairement écrit dans ce journal.

## Les onglets

| Onglet | Action |
|---|---|
| Créer un compte | Prénom, nom, OU, identifiant automatique ou imposé, groupes, courriel, service, fonction, dossier personnel facultatif |
| Importer un CSV | Aperçu obligatoire avant lancement, sélection de l’OU dans l’arborescence, création facultative d’une sous-OU par département, lecture de tous les groupes, choix `;` ou `,` et option d’ignorer les identifiants existants |
| Groupes | Ajouter ou retirer plusieurs utilisateurs à plusieurs groupes ; listes séparées par `;` |
| Départ | Sauvegarder l'état et les groupes, désactiver, réinitialiser le mot de passe, retirer les groupes, annoter et déplacer |
| Comptes inactifs | Seuil en jours, OU facultative, comptes désactivés et jamais connectés |
| Privilèges | Membres des groupes à privilèges du domaine sélectionné, y compris groupes imbriqués et groupes principaux |
| Rapport HTML | Rapport consolidé et exports CSV facultatifs |

Les paramètres avancés, dont `Manager`, `Company`, `Office`, `UserPrincipalNameSuffix` et un mot de passe initial fourni en `SecureString`, restent accessibles en ligne de commande.

## CSV d'exemple

Le dossier `Examples\Tests-CSV` contient onze fichiers de test — cas nominaux, séparateur `,`, groupes non entourés de guillemets, accents, sous-OU par département, volume, et cinq fichiers qui doivent être refusés. Voir `Examples\Tests-CSV\LISEZMOI.md`.

Le fichier `Examples\nouveaux-employes.csv` utilise `;` comme séparateur. La colonne `Groups` accepte plusieurs groupes séparés par `;`. Les guillemets restent recommandés, mais PSADToolkit 2.1 sait aussi reconstruire les groupes quand un export CSV a utilisé `;` à la fois comme séparateur du fichier et comme séparateur de groupes :

```csv
GivenName;Surname;SamAccountName;OU;Groups
Joël;Hervieux;jhervieux;OU=Employes,DC=contoso,DC=local;"GS-Employes;GS-VPN"
```

Adapter les OU, noms de groupes, domaine et gestionnaires avant d'utiliser l'exemple. Enregistrer en UTF-8, idéalement avec BOM pour les anciens outils Windows. Les colonnes `GivenName` et `Surname` sont obligatoires ; chaque ligne doit avoir une OU ou utiliser `DefaultOU`.

Le fichier entier est contrôlé avant toute création : structure, champs obligatoires, collisions entre identifiants explicitement fournis après normalisation et accès aux OU. Les groupes sont résolus dans tout le domaine par `sAMAccountName`, `Name` ou `CN`. Un groupe introuvable ou non accessible est signalé dans l’aperçu mais ne bloque plus tout l’import : l’utilisateur peut être créé avec le statut `Partiel`, et seuls les groupes résolus sont appliqués. Dans l’interface, la sélection du fichier CSV ouvre immédiatement l’arborescence Active Directory afin de choisir l’OU de destination. Cette OU choisie a priorité sur une éventuelle colonne `OU` du CSV. Un aperçu affiche ensuite le département, l’OU cible et tous les groupes avant de poursuivre. Si l’option de création des sous-OU est cochée, l’OU choisie devient l’OU parente et chaque valeur `Department` est utilisée pour créer ou réutiliser une sous-OU. Une course avec un autre administrateur reste possible entre la vérification et la création. Le statut de chaque création fait foi. La simulation ne réserve aucun identifiant dans AD.

Un identifiant imposé déjà utilisé provoque un échec, sauf si `SkipExisting` est demandé à l'import. Les identifiants automatiques reçoivent un suffixe numérique en cas de collision. Le CN du nouvel objet est basé sur l'identifiant unique ; son `displayName` reste le prénom et le nom.

Le rapport de mots de passe facultatif est **en clair** : choisir un emplacement à accès restreint et le supprimer après transmission. Les mots de passe de comptes partiellement créés peuvent ne pas avoir été acceptés ; vérifier leur statut avant distribution.

## Ligne de commande

Depuis Windows PowerShell ou PowerShell 7, dans le dossier extrait :

```powershell
Import-Module .\PSADToolkit.psd1 -Force
Test-ADTPrerequisite -Server 'dc01.contoso.local'

New-ADTUser -GivenName 'Joel' -Surname 'Hervieux' `
    -Path 'OU=Employes,DC=contoso,DC=local' `
    -Server 'dc01.contoso.local' -WhatIf

Import-ADTUserFromCsv -Path .\Examples\nouveaux-employes.csv `
    -Server 'dc01.contoso.local' -WhatIf

Start-ADTUserOffboarding -Identity 'jhervieux' `
    -BackupPath 'C:\SauvegardesAD' -Server 'dc01.contoso.local' -WhatIf

Export-ADTAccessReport -Path 'C:\Rapports\AD.html' `
    -Server 'dc01.contoso.local'
```

Pour utiliser un autre compte : `$cred = Get-Credential`, puis ajouter `-Credential $cred` à la commande. Retirer `-WhatIf` pour appliquer les modifications après revue. `Get-Help New-ADTUser -Full` et les autres aides décrivent les paramètres.

### Version autonome

Copier `dist\PSADToolkit-Standalone.ps1`, puis le charger avec un point suivi d'une espace :

```powershell
. .\PSADToolkit-Standalone.ps1
Test-ADTPrerequisite
```

Le standalone fournit les fonctions en ligne de commande, sans rien installer, y compris sous Windows PowerShell 2.0. **L'interface, elle, exige le dossier complet**, PowerShell 7.4+ et GliderUI ; elle se lance avec `Lancer.cmd`. Pour régénérer le standalone après modification des sources, exécuter `Build.ps1` sur un poste de développement avec PowerShell 5.1 ou 7.

## Sauvegardes de départ et limites

Avant toute modification, le départ écrit un CSV des groupes secondaires et un CLIXML de l'état lu, comprenant le DN d'origine, les groupes, le groupe principal, la description et l'activation. Si l'une des sauvegardes échoue, AD n'est pas modifié. Après sauvegarde, le compte est désactivé **avant** les autres actions. Un échec ultérieur est indiqué comme `Partiel` avec les étapes réellement terminées.

Ces fichiers servent à reconstruire manuellement l'état du compte : **il n'y a pas de restauration automatique**. L'ancien mot de passe n'est pas récupérable. La désactivation ne garantit pas la fermeture instantanée de toutes les sessions ou l'invalidation de tous les tickets existants. Le groupe principal n'est pas retiré ; les appartenances d'autres domaines peuvent nécessiter une intervention séparée.

Les rapports sont limités au **domaine sélectionné**, pas à toute la forêt. Dans un domaine enfant, les groupes Enterprise Admins et Schema Admins du domaine racine doivent être audités séparément. Les erreurs sont indiquées par `NON AUDITE`; les objets `foreignSecurityPrincipal` restent des identités externes à vérifier. Une lecture tronquée de `memberOf` est interrompue explicitement pour éviter de sauvegarder ou de présenter une liste incomplète.

L'inactivité utilise `lastLogonTimestamp`, dont la réplication peut être retardée d'environ 9 à 14 jours. Un compte jamais utilisé est comparé à sa date de création ; un compte créé hier n'est plus classé comme inactif depuis 90 jours. La recherche est paginée, mais les rapports peuvent charger beaucoup de comptes en mémoire : utiliser une OU pour limiter le volume. Le filtre OU ne limite pas l'inventaire des groupes à privilèges du domaine.

Pour les dossiers personnels, les ACL héritées sont conservées et une règle `Modify` est ajoutée au **SID réel du nouveau compte**. Le partage et sa racine doivent donc déjà avoir des permissions adaptées ; l'outil ne reconfigure pas toute la sécurité du partage.

## Vérification

Voir `VALIDATION.md`. Les tests Pester nécessitent un poste de développement moderne, **pas** l'ancien serveur cible :

```powershell
Invoke-Pester -Path .\Tests -Output Detailed
.\Tests\Test-Compatibility.ps1
.\Tests\Test-VersionConsistency.ps1
.\Tests\Test-ParameterShadowing.ps1
```

`Test-VersionConsistency.ps1` échoue si un fichier annonce une version différente de celle du manifeste. Le lancer avant toute étiquette git, comme indiqué dans `VERSIONING.md`.

`Test-ParameterShadowing.ps1` échoue si une boucle `foreach` réutilise le nom d'un paramètre typé. Les noms de variables PowerShell sont insensibles à la casse et la contrainte de type du paramètre vaut pour toute la fonction : la boucle se casse alors sur une conversion impossible, comme en 3.0.0-test2 où la grille de résultats ne pouvait plus s'afficher.

Le pipeline GitHub Actions est configuré pour reconstruire et vérifier sous Windows PowerShell 5.1. Cette configuration ne signifie pas qu'une exécution GitHub Actions a été lancée lors de cette livraison.

## Références techniques

- [Versions Windows Server — Microsoft](https://learn.microsoft.com/en-us/windows/release-health/windows-server-release-info) : Server 2025 est la version LTSC actuelle dans la source consultée.
- [Authentification DirectoryServices — Microsoft](https://learn.microsoft.com/en-us/dotnet/api/system.directoryservices.authenticationtypes) : authentification intégrée, signature et chiffrement de session.
- [Dialecte LDAP ADSI — Microsoft](https://learn.microsoft.com/en-us/windows/win32/adsi/ldap-dialect) : recherches LDAP et paramètres de pagination.
- [Attribut memberOf — Microsoft](https://learn.microsoft.com/en-us/windows/win32/adschema/a-memberof) : appartenance aux groupes dans le schéma AD, notamment sur Server 2008.
- [PowerShell — versions publiées](https://github.com/PowerShell/PowerShell/releases/latest) et [installation sur Windows — Microsoft](https://learn.microsoft.com/fr-fr/powershell/scripting/install/installing-powershell-on-windows) : PowerShell 7 cohabite avec Windows PowerShell 5.1.
- [GliderUI — PowerShell Gallery](https://www.powershellgallery.com/packages/GliderUI) et [dépôt GitHub](https://github.com/mdgrs-mei/GliderUI) : moteur de l'interface, bâti sur Avalonia. Le dépôt annonce une phase de prototypage avec des ruptures d'API.

Licence MIT — voir `LICENSE`.
