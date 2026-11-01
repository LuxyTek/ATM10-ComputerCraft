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


## Dashboard V0.3.0 - vue MODULES

La V0.3.0 conserve la vue Dashboard V0.2.0 et ajoute un affichage dedie `MODULES`.

Cette vue sert de cartographie operationnelle des cellules Factory :

- chaque module publie via `factory.status.v1` et apparait automatiquement ;
- les modules sont presentes sous forme de cartes avec NETWORK, MODE, STATE, HEALTH et raison courante ;
- toucher une carte ouvre la page detaillee du module ;
- la page detaillee continue d'exploiter `details`, puis `metrics` en repli ;
- la navigation precedent/suivant permet de parcourir les modules sans revenir au Dashboard ;
- le Dashboard central reste en lecture seule dans le contrat v1.

Le pilotage distant n'est volontairement pas ajoute a cette version. Les commandes restent locales a chaque controleur de module afin de valider d'abord l'ergonomie, la supervision et le mapping avant d'introduire un futur protocole de commandes et d'acquittements.


## Separation des IHM

A partir du Dashboard V0.3.1, deux IHM ont des roles distincts.

### Factory Dashboard

Le Dashboard est un deport de supervision destine a la base.

Il affiche uniquement la synthese des modules :
- module ;
- etat reseau ;
- mode ;
- state ;
- health ;
- raison courante.

Il ne permet pas d'ouvrir un module et ne porte aucune commande distante.

### Factory Supervisor

Le Supervisor est l'IHM locale de l'usine.

Sa page principale cartographie les modules detectes sur `factory.status.v1`.
Un toucher sur un module ouvre sa page de supervision complete, alimentee par `details`, `metrics`, les lignes actives et les alarmes publiees.

La V0.1.0 du Supervisor reste en lecture seule. Le controle distant fera l'objet d'un protocole separe lorsque l'ergonomie et le contrat de supervision seront valides.
