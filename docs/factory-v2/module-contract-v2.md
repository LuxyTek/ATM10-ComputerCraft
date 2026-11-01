# Factory Module Contract V2

## But

Le contrat V2 rend un module suffisamment descriptif pour etre integre au Supervisor sans ajouter de code specifique dans le coeur.

Il se compose de deux parties :

1. **definition statique** : identite, ressources, chaines, machines et UI ;
2. **status dynamique** : valeurs courantes publiees par le runtime.

## Definition minimale

Exemple simplifie :

```lua
return {
    contract = 2,

    id = "hdpe",
    label = "HDPE",
    category = "process",

    inputs = {
        { id = "substrate", source = "shared_input" },
        { id = "liquid_ethene" },
        { id = "oxygen" },
    },

    outputs = {
        { id = "hdpe_pellet", buffer = "output" },
    },

    chains = {
        {
            id = "hdpe",
            label = "HDPE",
            controllable = true,
            machines = { "prc" },
        },
    },
}
```

## Identite

Champs requis :

```lua
contract = 2
id = "ethene"
label = "ETHENE"
category = "process"
```

`id` est stable et ne depend jamais du nom d'un peripheral.

## Ressources

Une ressource est une liaison logique.

```lua
{
    id = "oxygen",
    label = "OXYGEN",
    direction = "input",
    metric = "oxygen",
}
```

Le module peut declarer plusieurs consommateurs ou producteurs de la meme ressource.

Le Supervisor ne suppose pas qu'un buffer physique contient un seul type d'item.

## Chaines

```lua
{
    id = "sulfur_trioxide",
    label = "SULFUR TRIOXIDE",
    controllable = true,
    machines = { "so3_infuser" },
    inputs = { "sulfur_dioxide", "oxygen" },
    outputs = { "sulfur_trioxide" },
}
```

Une chaine peut etre affichee meme si aucune machine physique n'est encore mappee.

## Machines

La definition donne un identifiant logique :

```lua
machines = {
    {
        id = "so3_infuser",
        label = "SO3 INFUSER",
        chain = "sulfur_trioxide",
    },
}
```

Le status dynamique fournit ensuite :

```lua
machines = {
    so3_infuser = {
        peripheral = "chemicalInfuser_1",
        state = "RUN",
        energy = 12345,
        maxEnergy = 100000,
        energyUsage = 40,
        controllable = true,
    },
}
```

L'IHM n'a pas besoin de connaitre le type Mekanism exact.

## Status dynamique

Structure cible :

```lua
{
    contract = 2,
    id = "sulfuric",
    version = "2.x",

    runtime = "ACTIVE",
    mode = "AUTO",
    state = "RUN",
    health = "OK",
    reason = "PRODUCTION",

    metrics = {
        oxygen = 0.92,
        sulfur_dioxide = 0.44,
        sulfur_trioxide = 0.30,
        water_vapor = 0.81,
        sulfuric_acid = 0.18,
    },

    resources = {
        sulfur_dioxide = { fill = 0.44 },
        sulfur_trioxide = { fill = 0.30 },
        water_vapor = { fill = 0.81 },
        sulfuric_acid = { fill = 0.18 },
    },

    chains = {
        sulfur_dioxide = {
            enabled = true,
            state = "RUN",
            reason = "PRODUCTION",
        },
    },

    machines = {},
    alarms = {},
}
```

## Actions

Les actions sont separees des statuts.

Actions generiques prevues :

```text
module.set_mode
module.start_all
module.stop_all
chain.set_enabled
machine.start
machine.stop
```

Un module indique les actions qu'il supporte. Le Supervisor ne doit jamais inventer une commande non declaree.

## Regle de compatibilite

Le Core V2 peut fournir temporairement un adaptateur Contract V1 -> V2 pendant la migration. Cet adaptateur est transitoire et doit pouvoir etre retire une fois tous les modules migres.
