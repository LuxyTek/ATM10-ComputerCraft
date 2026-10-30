# Factory Module Contract v1

## Objectif

Definir le contrat minimal entre un module Factory autonome et le Dashboard central.

Le Dashboard ne lit pas directement les machines d'un module. Chaque module reste responsable de sa logique locale, de ses securites et de son AUTO, puis publie un etat synthetique sur Rednet.

## Transport

- Rednet sur le reseau de modems CC:Tweaked.
- Protocole de statut : `factory.status.v1`.
- Le module diffuse periodiquement une table Lua avec `rednet.broadcast`.
- Le Dashboard decouvre les modules uniquement a partir des statuts recus.
- Aucune commande distante n'existe dans v1.

## Paquet de statut

```lua
{
    contract = 1,

    id = "h2o2",
    label = "H2/O2",
    type = "process",

    version = "0.7.x",

    mode = "AUTO",      -- AUTO | MANUAL
    state = "RUN",      -- RUN | IDLE | HOLD | STOP
    health = "OK",      -- OK | WARN | FAULT

    reason = "LOCAL H2 42 O2 21",

    activeLines = 2,
    totalLines = 3,

    metrics = {
        water = 0.98,
        hydrogen = 0.42,
        oxygen = 0.21,
    },

    alarms = {},
}
```

## Semantique

### mode

- `MANUAL` : decisions prises par l'operateur local.
- `AUTO` : decisions prises par le controleur local du module.

### state

- `RUN` : au moins une ligne produit normalement.
- `IDLE` : module disponible mais aucune production demandee.
- `HOLD` : production volontairement suspendue par une condition de process.
- `STOP` : module arrete manuellement ou indisponible.

### health

- `OK` : aucun probleme detecte.
- `WARN` : module utilisable avec anomalie ou etat degrade.
- `FAULT` : defaut empechant un fonctionnement fiable.

## Dashboard : liveness

Le Dashboard calcule lui-meme l'etat reseau selon l'age du dernier paquet :

- ONLINE : dernier statut < 5 s ;
- STALE : 5 a 10 s ;
- OFFLINE : > 10 s.

Ces seuils sont des parametres du Dashboard et ne font pas partie du contrat du module.

## Evolutions prevues

Une version future pourra ajouter des protocoles separes pour les commandes et acquittements. Le contrat v1 reste volontairement lecture seule.


## Champs optionnels d'affichage

Le contrat v1 accepte des champs optionnels sans modifier les champs obligatoires.

Un module peut publier une liste `details` pour sa page detaillee dans le Dashboard :

```lua
details = {
    { label = "INPUT", value = "POTATO x512" },
    { label = "OUTPUT", value = "BIO FUEL x2048" },
    { label = "CRUSHER", value = "RUN" },
}
```

Le Dashboard V0.2.0 utilise :

- la vue OVERVIEW pour l'etat synthetique de tous les modules ;
- un toucher sur un module pour ouvrir sa page detaillee ;
- les boutons precedent/suivant pour naviguer entre les modules ;
- les `details` lorsqu'ils sont fournis ;
- sinon les `metrics` du contrat comme contenu detaille.

Ces champs restent purement informatifs. Le contrat v1 ne transporte toujours aucune commande distante.
