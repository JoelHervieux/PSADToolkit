# Nomenclature de version

Ce document définit la numérotation de PSADToolkit, l'endroit où chaque version est inscrite et la procédure à suivre pour publier. Il fait autorité : en cas de divergence entre deux fichiers, c'est le manifeste `PSADToolkit.psd1` qui a raison, et `Tests\Test-VersionConsistency.ps1` le vérifie.

## Format

```
MAJEUR.MINEUR.CORRECTIF[-CANAL]
```

Exemples : `3.2.0-test1`, `3.2.0-rc1`, `3.2.0`.

| Élément | Quand il change |
|---|---|
| MAJEUR | Rupture de compatibilité : paramètre public retiré ou renommé, comportement d'écriture AD modifié, abandon d'un système ou d'une version de PowerShell ciblés. |
| MINEUR | Nouvelle fonction publique, nouvel onglet, nouvelle colonne CSV, nouveau paramètre facultatif. Les appels existants continuent de fonctionner. |
| CORRECTIF | Correction de bogue, documentation, tests, message d'erreur. Aucune nouvelle capacité. |
| CANAL | État de validation de la version. Voir ci-dessous. |

## Canaux

| Canal | Signification | Utilisation |
|---|---|---|
| `-testN` | La version n'a pas passé la recette Windows de `VALIDATION.md`. Syntaxe, tests Pester et annuaire simulé peuvent être verts ; l'exécution sur un domaine réel n'est pas prouvée. | Laboratoire uniquement. Simulation cochée. Aucune écriture en production. |
| `-rcN` | La recette Windows est commencée et concluante jusqu'ici, sur une partie seulement des systèmes cibles. | Pilote encadré, sur une OU de test. |
| *(aucun suffixe)* | Recette Windows de `VALIDATION.md` effectuée sur au moins Server 2008 SP2 / PowerShell 2.0 et un serveur récent / PowerShell 5.1. | Production. |

`N` est un entier qui repart à `1` à chaque nouveau numéro de version : `3.0.0-test1`, `3.0.0-test2`, puis `3.0.1-test1`.

Le suffixe ne contient **ni point ni espace** : `test1`, pas `test.1`. PowerShellGet n'accepte dans un suffixe de préversion que des caractères alphanumériques et le trait d'union.

**État actuel : `3.2.0-test1`.** Le passage à 3.2.0 applique la règle MINEUR : le programme d'installation, le lanceur et l'interface simplifiée s'ajoutent sans retirer ni renommer aucune fonction publique. Les appels écrits pour 3.0.0 et 3.1.0 continuent de fonctionner à l'identique, et le manifeste déclare toujours `PowerShellVersion = '2.0'`. Aucune version de ce dépôt n'a encore passé la recette Windows sur un véritable domaine ; depuis 3.2.0, l'interface est en revanche exécutée à chaque publication sur Windows Server 2022 et 2025 avec un annuaire simulé. Tant que le canal reste `test`, la compatibilité annoncée dans `README.md` est une cible technique, pas un résultat mesuré.

## Où la version est inscrite

| Emplacement | Contenu | Qui l'écrit |
|---|---|---|
| `PSADToolkit.psd1` → `ModuleVersion` | Numéro seul : `3.0.0`. **Source de vérité.** | À la main. |
| `PSADToolkit.psd1` → `PrivateData.PSData.Prerelease` | Canal seul : `test1`. Chaîne vide pour une version stable. | À la main. |
| `dist\PSADToolkit-Standalone.ps1` (en-tête) | Version complète : `3.2.0-test1`. | `Build.ps1`, jamais à la main. |
| `Start-PSADToolkit.ps1` (attribut `Title` du XAML) | Version complète. L'opérateur doit voir à l'écran qu'il utilise une version de test. | À la main. |
| `README.md` (titre de niveau 1, encadré d'état, lien direct de téléchargement) | Version complète. | À la main. |
| `CHANGELOG.md` | Une section `## <version complète> - AAAA-MM-JJ` par version, ordre décroissant. | À la main. |
| Étiquette git | `v<version complète>`, par exemple `v3.2.0-test1`. | `git tag`. |
| `PSADToolkit.exe` et `PSADToolkit-Setup-<version>.exe` | Version complète (nom du fichier, écran de désinstallation) ; `MAJEUR.MINEUR.CORRECTIF.0` dans les propriétés du fichier. | `installer\Build-Installer.ps1`, à partir du manifeste. |

`ModuleVersion` reste purement numérique parce que Windows PowerShell 2.0 refuse tout suffixe dans un manifeste. La version complète est reconstituée par concaténation, comme le fait `Build.ps1`.

`VALIDATION.md` n'est pas dans cette liste : il décrit une campagne de validation datée et garde le numéro qu'il a réellement validé.

## Procédure de publication

1. Mettre à jour `ModuleVersion` et `Prerelease` dans `PSADToolkit.psd1`.
2. Ajouter la section correspondante en tête de `CHANGELOG.md`, avec la date du jour.
3. Reporter la version complète dans `README.md` et dans le titre de `Start-PSADToolkit.ps1`.
4. Régénérer le standalone : `.\Build.ps1` sur un poste PowerShell 5.1 ou 7.
5. Vérifier :

   ```powershell
   .\Tests\Test-VersionConsistency.ps1
   .\Tests\Test-ParameterShadowing.ps1
   Invoke-Pester -Path .\Tests -Output Detailed
   .\Tests\Test-Compatibility.ps1
   ```

   `Test-Compatibility.ps1` exige PSScriptAnalyzer. Les contrôles de compatibilité PowerShell 2.0 qui n'en dépendent pas — API interdites, opérateurs apparus en 3.0 — sont aussi couverts par `Tests\Console.Tests.ps1`, qui s'exécute partout.

6. Construire le programme d'installation sur Windows avec Inno Setup 6 : `.\installer\Build-Installer.ps1`. Le pipeline `.github/workflows/windows.yml` le construit, l'installe en silence, ouvre l'interface puis le désinstalle ; il doit être vert.
7. Commiter, puis étiqueter : `git tag -a v3.2.0-test1 -m "PSADToolkit 3.2.0-test1"`.
8. Pousser la branche et l'étiquette : `git push -u origin <branche> --follow-tags`.
9. Publier : envoyer l'étiquette `v<version>`, ou un commit dont le message contient `[publier]`. Après les tests, le parcours de l'interface et les deux installations d'essai, le job **Publication sur la page Releases** de `.github/workflows/windows.yml` vérifie la version, reprend le programme d'installation qui vient d'être testé et crée la release `v<version>` avec `PSADToolkit-Setup-<version>.exe` et `SHA256SUMS.txt`. Une version de canal est publiée comme préversion. Mettre à jour le lien direct de téléchargement de `README.md`.

## Passage en version stable

Retirer le suffixe seulement après avoir exécuté la recette Windows de `VALIDATION.md` sur les deux extrémités de la cible : Server 2008 SP2 / PowerShell 2.0 et un serveur récent / PowerShell 5.1. La campagne est consignée dans `VALIDATION.md` avec sa date et son périmètre, puis la version passe de `X.Y.Z-rcN` à `X.Y.Z` sans autre changement de code. Une correction faite pendant la recette relance un canal : `X.Y.Z+1-test1`.
