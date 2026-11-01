# ATM10-ComputerCraft

Dashboard de supervision CC:Tweaked pour All The Mods 10 (Minecraft 1.21.1).

## Version operationnelle

**V1.0.0** est la premiere baseline operationnelle du dashboard.

Elle regroupe les fonctions validees pendant le developpement V4-V6 et sert de point de reference stable avant les prochaines evolutions.

## Dashboard

Le programme principal est :

```lua
/programs/power.lua
```

Il fonctionne sur un seul Advanced Monitor et propose trois onglets tactiles :

### DASHBOARD

Vue synthetique avec :

- energie FE totale et niveau de charge ;
- etat charge / decharge / stable ;
- etat du reseau ME ;
- stockage ME utilise et espace libre ;
- nombre de ME Drives et de Cells ;
- energie AE ;
- activite de crafting ;
- alertes globales ;
- voyants d'etat vert / orange / rouge / gris ;
- jauges verticales pour l'energie et le stockage ME.

### ENERGIE

Supervision detaillee des stockages FE visibles sur le reseau CC:Tweaked :

- energie totale et capacite ;
- tendance lissee sur 30 secondes ;
- estimation d'autonomie ou de temps de charge ;
- etat individuel des Energy Cubes ;
- jauge globale ;
- pic de consommation observe ;
- uptime.

La variation nette est calculee depuis l'evolution du stockage. Ce n'est pas une mesure directe de la production et de la consommation simultanees.

### ME / AE2

Supervision du reseau Applied Energistics 2 via **Advanced Peripherals ME Bridge** :

- etat ONLINE / OFFLINE ;
- energie AE stockee, capacite, usage et injection ;
- stockage items / fluides / chemicals ;
- nombre de types d'items ;
- Drives et Cells ;
- regroupement des Cells 4K / 16K / 64K / 256K ;
- taux de remplissage individuel des Cells ;
- alertes de saturation ;
- Crafting CPUs et crafts actifs lorsque disponibles.

Les donnees ME lourdes sont mises en cache et rafraichies moins souvent afin de conserver une interface reactive.

## Factory Control - nouveau projet

Le depot contient maintenant un second chantier independant du dashboard V1 : une usine Mekanism pilotee par CC:Tweaked.

Le premier prototype est une cellule de production **Hydrogen / Oxygen** :

```text
Electric Pump
    |
Fluid Tank (Water)
    |
Electrolytic Separator
    |
    +--> Chemical Tank (Hydrogen)
    |
    +--> Chemical Tank (Oxygen)
```

Objectifs du prototype :

- supervision Water / H2 / O2 / Energy ;
- detection des peripheriques Mekanism ;
- arret / reprise controles par CC ;
- gestion de seuils et d'alarmes ;
- base reutilisable pour les futures lignes chimiques ;
- preparation d'un futur export vers la base via Quantum Entangloporter.

Documentation :

- `docs/factory/architecture.md`
- `docs/factory/proto-h2o2.md`

Premier outil de diagnostic :

```lua
programs/factory/peripheral_probe
```

La configuration de reference est dans :

```text
config/factory_h2o2.example.lua
```

Le projet Factory Control est developpe separement afin de ne pas perturber la baseline stable du dashboard V1.0.0.

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

L'installateur :

- met a jour le programme ;
- conserve `/config/power.lua` s'il existe deja ;
- valide la syntaxe Lua avant remplacement ;
- utilise une sauvegarde temporaire pour eviter de casser une installation existante.

## Mise a jour depuis le dashboard

Le bouton tactile `[ MAJ ]` demande une seconde confirmation.

Le programme :

1. telecharge la nouvelle version ;
2. verifie que le fichier est valide ;
3. compile le Lua avant installation ;
4. cree une sauvegarde de la version en cours ;
5. remplace le programme ;
6. restaure l'ancienne version si le remplacement echoue ;
7. redemarre le Computer.

Le fichier `/startup.lua` reste permanent et lance simplement :

```lua
shell.run("/programs/power.lua")
```

## Configuration

Fichier :

```lua
/config/power.lua
```

Parametres principaux :

- `refreshSeconds` : rafraichissement principal ;
- `meRefreshSeconds` : donnees ME rapides ;
- `meHeavyRefreshSeconds` : listes ME lourdes ;
- `peripheralRefreshSeconds` : nouvelle detection des peripheriques ;
- `textScale` : taille du texte du monitor ;
- `monitor` : nom explicite du monitor ou `nil` ;
- `devices` : liste facultative des Energy Cubes a superviser ;
- `lowThreshold` et `warningThreshold` : seuils energie ;
- `trendSeconds` : fenetre de lissage charge/decharge.

## Prerequis

- CC:Tweaked avec HTTP actif ;
- Computer ou Advanced Computer ;
- Advanced Monitor ;
- Wired Modems / Networking Cable ;
- Mekanism Energy Cubes pour la page Energie ;
- Applied Energistics 2 ;
- Advanced Peripherals ME Bridge pour la page ME / AE2.

Le ME Bridge doit etre expose au Computer via un **Wired Modem**.

## Arborescence

```text
ATM10-ComputerCraft/
├── README.md
├── install.lua
├── startup.lua
├── config/
│   └── power.lua
├── programs/
│   └── power.lua
└── archive/
    └── anciennes versions du dashboard
```

## Baseline stable

La branche `release-v1.0.0` correspond a la premiere version operationnelle gelee.
Le developpement futur continue sur `main`.
