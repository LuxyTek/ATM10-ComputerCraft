# Factory Core V2

Coeur generique de Factory Control V2.

## Composants actuels

- `contract.lua` : validation des definitions et statuts Contract V2.
- `loader.lua` : chargement securise des definitions Lua.
- `registry.lua` : decouverte, enregistrement et topologie des modules.
- `status_adapter.lua` : adaptation transitoire des statuts V1 vers V2.
- `bus.lua` : protocoles `factory.status.v2` et `factory.control.v2`.

## Regle fondamentale

Le Core ne connait aucun module industriel concret.

Il ne contient donc aucune condition specifique a H2/O2, Biofuel, Ethene,
HDPE ou Sulfuric Acid.

## Registry

Le registre scanne par defaut :

```text
/programs/factory/modules/<module>/definition.lua
```

Les dossiers commencant par `.` ou `_` sont ignores.

Le registre fournit notamment :

- `get(id)`
- `list()`
- `ids()`
- `producers(resourceId)`
- `consumers(resourceId)`
- `resources()`
- `topology()`

La topologie est derivee des inputs/outputs declares par les modules.

## Compatibilite V1

`status_adapter.lua` transforme temporairement les paquets
`factory.status.v1` en representation Contract V2.

Cette couche est uniquement une aide a la migration et sera retiree lorsque
tous les modules seront natifs V2.

## Test

Le test minimal est :

```text
/programs/factory/tools/core_v2_smoke_test.lua
```

Il verifie :

- chargement de deux definitions fictives ;
- validation Contract V2 ;
- construction automatique d'une liaison de ressource ;
- adaptation d'un statut Contract V1.

Il ne touche a aucun module reel.
