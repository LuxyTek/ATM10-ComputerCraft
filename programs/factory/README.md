# Factory Control Programs

Ce dossier contient les programmes du projet d'usine pilotee par CC:Tweaked.

## Etat actuel

Le premier prototype est la cellule H2/O2 Mekanism.

Aucune logique d'automatisation de production n'est encore active. On commence par identifier et valider les peripheriques reels du reseau.

## Outil disponible

### peripheral_probe.lua

Diagnostic en lecture seule :

```lua
programs/factory/peripheral_probe
```

Il affiche :

- nom CC de chaque peripherique ;
- type de peripherique ;
- methodes exposees ;
- principales telemetries Mekanism lorsqu'elles sont disponibles.

Le script ne modifie aucun parametre de machine.

## Mise a jour

Le bouton tactile `[ MAJ ]` est une exigence permanente de toutes les futures IHM Factory, y compris les prototypes.

Contrairement au dashboard V1 monofichier, Factory utilise un updater multi-fichiers :

- `lib/updater.lua` : telechargement, validation, sauvegarde et rollback ;
- `update_manifest.lua` : liste des fichiers a maintenir ;
- la configuration locale n'est pas ecrasee.

La premiere IHM H2/O2 integrera ce bouton des sa V0.1.

## Architecture logicielle prevue

Lorsque le materiel du prototype aura ete valide :

```text
programs/factory/
├── peripheral_probe.lua
├── update_manifest.lua
├── lib/
│   └── updater.lua
├── startup.lua
├── controller.lua
├── process_h2o2.lua
├── peripherals.lua
├── alarms.lua
├── ui.lua
└── logger.lua
```

On evitera de figer cette structure plus loin avant le retour du prototype reel.
