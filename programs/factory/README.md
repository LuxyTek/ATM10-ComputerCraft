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

## Architecture logicielle prevue

Lorsque le materiel du prototype aura ete valide :

```text
programs/factory/
├── peripheral_probe.lua
├── startup.lua
├── controller.lua
├── process_h2o2.lua
├── peripherals.lua
├── alarms.lua
├── ui.lua
└── logger.lua
```

On evitera de figer cette structure plus loin avant le retour du prototype reel.
