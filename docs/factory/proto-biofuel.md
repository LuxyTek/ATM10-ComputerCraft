# Factory BIOFUEL prototype

## V0.1.0

Premier prototype de supervision du module BIOFUEL.

Topologie confirmee :

```text
sophisticatedstorage:barrel_0
        |
        v
ultimateCrushingFactory_0
        |
        v
sophisticatedstorage:barrel_1
```

Mapping :

- `barrel_0` : buffer d'entree, actuellement pommes de terre ;
- `ultimateCrushingFactory_0` : Crushing Factory ;
- `barrel_1` : buffer Bio Fuel.

V0.1.0 est volontairement en lecture seule :

- detection des trois peripheriques ;
- comptage des items dans les deux barrels ;
- affichage du type d'item dominant ;
- etat Redstone de la Crushing Factory ;
- energie et consommation de la Crushing Factory ;
- interface monitor ;
- bouton `[ MAJ ]` avec double confirmation ;
- updater transactionnel partage ;
- autostart.

Aucun AUTO ni commande machine n'est active dans cette version.
