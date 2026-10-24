# ATM10-ComputerCraft

Scripts CC:Tweaked pour All The Mods 10 (Minecraft 1.21.1).

## Power Monitor

Dashboard de stockage d'energie pour un ou plusieurs blocs compatibles avec le type generique CC:Tweaked `energy_storage`, notamment les Energy Cubes Mekanism relies au reseau par Wired Modems.

Affichage :

- energie totale stockee ;
- capacite totale ;
- pourcentage de charge ;
- barre de charge ;
- variation nette estimee en FE/t ;
- etat individuel des stockages detectes.

> La variation nette est calculee a partir de l'evolution du stockage. Ce n'est pas une mesure directe de la production et de la consommation simultanees.

## Installation

Sur le Computer CC:Tweaked :

```lua
wget run https://raw.githubusercontent.com/LuxyTek/ATM10-ComputerCraft/main/install.lua
```

Puis :

```lua
programs/power
```

Pour installer egalement le lancement automatique :

```lua
wget run https://raw.githubusercontent.com/LuxyTek/ATM10-ComputerCraft/main/install.lua startup
```

L'installateur met a jour le programme mais conserve `/config/power.lua` s'il existe deja.

## Configuration

Modifier :

```lua
edit /config/power.lua
```

Par defaut, le programme detecte tous les peripheriques `energy_storage` visibles sur le reseau. Si d'autres machines energetiques sont connectees au meme reseau ComputerCraft, renseigner explicitement leurs noms dans `devices` pour ne compter que les Energy Cubes souhaites.

Pour afficher les noms de peripheriques disponibles :

```lua
peripherals
```

## Prerequis

- CC:Tweaked avec HTTP active ;
- un Computer ou Advanced Computer ;
- un Monitor ;
- Wired Modems / Networking Cable pour exposer les Energy Cubes et le monitor au computer.

CC:Tweaked fournit `getEnergy()` et `getEnergyCapacity()` via son peripherique generique `energy_storage`. Les valeurs sont exprimees en FE.
