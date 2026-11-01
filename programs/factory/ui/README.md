# Factory UI V2

Renderers generiques du Supervisor.

## Fichiers

- `widgets.lua` : primitives de dessin, couleurs, barres, boutons, boites.
- `overview.lua` : vue generique d'un module depuis sa definition + son status.
- `machines.lua` : machines regroupees automatiquement par chaine.
- `flow_map.lua` : placement des modules et liens derives du Registry.
- `../tools/ui_v2_smoke_test.lua` : demonstration sans module reel.

## Regle fondamentale

Aucun renderer V2 ne connait H2/O2, Biofuel, Ethene, HDPE ou Sulfuric Acid.

Les vues utilisent uniquement :

- la definition Contract V2 ;
- le status Contract V2 ;
- les actions declarees ;
- la topologie fournie par le Registry.

## Overview

L'Overview affiche generiquement :

- runtime ;
- mode ;
- state ;
- health ;
- reason ;
- inputs ;
- outputs ;
- chaines / sous-modules.

Un bouton de chaine n'est affiche que si :

- la chaine est `controllable=true` ;
- le module declare `chain.set_enabled` ;
- le Supervisor autorise les controles.

## Machines

La vue Machines regroupe les machines selon `chain.machines`.

Une chaine sans machine reste visible avec :

```text
AUCUNE MACHINE MAPPEE
```

Les controles START/STOP ne sont proposes qu'en MANUAL et uniquement si le
module declare les actions correspondantes.

## Flow Map

Le Flow Map demande au Registry :

- la liste des modules ;
- les producteurs ;
- les consommateurs ;
- les liaisons de ressources.

Le layout V2 initial est volontairement generique. L'esthetique pourra etre
amelioree sans remettre de logique specifique aux modules dans le renderer.
