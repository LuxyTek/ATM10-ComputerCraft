# Factory V2 - Arborescence cible

```text
ATM10-ComputerCraft/
|
|-- README.md
|
|-- docs/
|   |-- factory-v2/
|   |   |-- README.md
|   |   |-- architecture.md
|   |   |-- module-contract-v2.md
|   |   |-- repository-layout.md
|   |   `-- migration-plan.md
|   |
|   `-- apps/
|       `-- power-dashboard.md
|
|-- programs/
|   |-- factory/
|   |   |-- core/
|   |   |   |-- supervisor.lua
|   |   |   |-- dashboard.lua
|   |   |   |-- registry.lua
|   |   |   |-- status_bus.lua
|   |   |   `-- updater.lua
|   |   |
|   |   |-- ui/
|   |   |   |-- flow_map.lua
|   |   |   |-- overview.lua
|   |   |   |-- machines.lua
|   |   |   `-- widgets.lua
|   |   |
|   |   |-- modules/
|   |   |   |-- h2o2/
|   |   |   |-- biofuel/
|   |   |   |-- ethene/
|   |   |   |-- hdpe/
|   |   |   `-- sulfuric_acid/
|   |   |
|   |   `-- tools/
|   |       |-- peripheral_probe.lua
|   |       `-- status_simulator.lua
|   |
|   |-- power/
|   |
|   `-- standalone/
|
|-- installer/
|   |-- install.lua
|   `-- packages.lua
|
`-- startup/
    |-- factory_supervisor.lua
    |-- factory_dashboard.lua
    `-- power.lua
```

## Regles

### programs/factory/core

Aucune connaissance d'un module industriel concret.

Interdit par exemple :

```lua
if module.id == "ethene" then ...
```

dans le coeur final.

### programs/factory/ui

Contient uniquement des renderers et composants generiques.

### programs/factory/modules

Un dossier par module. Un module ne doit pas modifier les fichiers d'un autre module.

Structure cible :

```text
modules/ethene/
|-- definition.lua
|-- runtime.lua
`-- config.example.lua
```

### programs/factory/tools

Outils de diagnostic ou developpement. Ils ne font pas partie du runtime obligatoire.

### programs/standalone

Programmes CC sans dependance a Factory Control.

### installer

Un installateur unique avec plusieurs packages remplace progressivement les installateurs specifiques historiques.

## Fichiers historiques

Pendant la migration, les anciens fichiers sous `programs/factory/*.lua` restent presents.

Ils ne seront supprimes ou deplaces qu'apres validation fonctionnelle de leur equivalent V2.
