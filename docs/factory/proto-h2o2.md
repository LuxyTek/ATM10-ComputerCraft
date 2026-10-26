# Prototype 01 - Production H2 / O2

## But

Valider une premiere cellule industrielle Mekanism pilotee par CC:Tweaked.

Le prototype doit produire de l'Hydrogen et de l'Oxygen a partir d'eau, stocker les deux chemicals dans des buffers externes et exposer suffisamment de telemetrie pour qu'un ordinateur puisse comprendre l'etat de la ligne.

## Chaine de process

```text
Source d'eau
    |
Electric Pump
    |
Fluid Tank - Water Buffer
    |
Electrolytic Separator
    |
    +--> Chemical Tank - Hydrogen
    |
    +--> Chemical Tank - Oxygen
```

L'alimentation electrique est locale et passe par un Energy Cube servant de buffer energetique.

## Peripheriques CC attendus

Obligatoires pour le prototype :

- Electrolytic Separator
- Fluid Tank eau
- Chemical Tank Hydrogen
- Chemical Tank Oxygen
- Energy Cube
- Monitor
- Advanced Computer

Optionnel au premier stade :

- Electric Pump

Chaque bloc supervise est expose au reseau CC via Wired Modem.

## Telemetrie minimale

### Water

- contenu du Fluid Tank
- capacite
- pourcentage de remplissage
- niveau interne du Separator

### Hydrogen / Oxygen

- contenu des Chemical Tanks
- capacite
- pourcentage de remplissage
- niveaux internes du Separator

### Energie

- energie stockee
- capacite
- pourcentage
- consommation du Separator

## Etats prevus

```text
STARTUP
  -> SELF_CHECK
  -> READY
  -> RUN
  -> HOLD_WATER
  -> HOLD_POWER
  -> HOLD_BUFFER
  -> FAULT
```

## Seuils initiaux proposes

| Condition | Arret | Reprise |
| --- | ---: | ---: |
| Eau | < 10 % | > 40 % |
| Energie | < 15 % | > 30 % |
| H2 | > 95 % | < 80 % |
| O2 | > 95 % | < 80 % |

Ces valeurs sont des valeurs de depart et devront etre validees en jeu.

## Modes futurs

- BALANCED : conserve H2 et O2
- H2_PRIORITY : autorise la gestion du surplus O2
- O2_PRIORITY : autorise la gestion du surplus H2

Le prototype commence en BALANCED uniquement.

## Critere de validation

Le prototype est valide si l'operateur peut, depuis le monitor :

- savoir si la ligne fonctionne ;
- connaitre Water / H2 / O2 / Energy ;
- comprendre pourquoi la ligne est arretee ;
- verifier que tous les peripheriques repondent ;
- commander un arret et un redemarrage propres.


## V0.2 - Controle manuel

La V0.2 ajoute un pilotage manuel global des Electrolytic Separators depuis le monitor.

- `[ START ]` -> `setRedstoneMode("DISABLED")`
- `[ STOP ]` -> `setRedstoneMode("HIGH")`
- l'etat affiche peut etre `RUN`, `STOP` ou `MIXED`
- le nombre de Separators reste dynamique : tout nouveau Separator detecte dans la cellule est inclus dans la commande globale

Important : le mode STOP utilise `HIGH` sans signal redstone externe. Un Separator recevant un signal redstone physique pourrait donc fonctionner malgre le STOP logiciel.

Aucun automatisme de seuil n'est encore actif en V0.2.


## V0.2.1 - Reactivite et demarrage automatique

Correctifs alignes sur le dashboard V1 :

- boucle UI separee de la collecte de telemetrie via `parallel.waitForAny` ;
- les appels Mekanism ne bloquent plus la gestion des touches du monitor ;
- updater base sur `http.request` et les evenements `http_success` / `http_failure` ;
- timeout explicite des telechargements ;
- `/startup.lua` permanent lance `/programs/factory/h2o2.lua` apres reboot ;
- le fichier startup fait partie du manifeste de mise a jour.

La configuration locale `/config/factory_h2o2.lua` reste preservee.


## V0.3.0 - Controle de cellule complet

START / STOP pilote maintenant toute la cellule H2/O2 :

- tous les Electrolytic Separators detectes ;
- toutes les Electric Pumps detectees ;
- RUN correspond a Separators + Pumps en mode `DISABLED` ;
- STOP correspond a Separators + Pumps en mode `HIGH` ;
- MIXED indique que les machines ne partagent pas toutes le meme etat.

Reactivite :

- le clic START / STOP ne fait plus directement les appels peripheriques ;
- l'UI affiche immediatement `START EN COURS...` ou `STOP EN COURS...` ;
- une boucle de controle independante execute ensuite la commande ;
- les commandes vers les machines sont lancees en parallele via `parallel.waitForAll` ;
- la telemetrie est relue a la fin de l'action et l'UI affiche le resultat SEP/PUMP.

L'architecture reste dynamique : ajouter ou retirer une ligne change automatiquement le nombre de machines controlees.


## V0.4.0 - Controle individuel des machines

Une page `MACHINES` complete le controle global du module.

- liste dynamique de toutes les Electric Pumps et Electrolytic Separators detectes ;
- etat individuel `RUN`, `STOP` ou autre mode Mekanism ;
- bouton `START` / `STOP` propre a chaque machine ;
- commandes individuelles executees dans la boucle de controle, sans bloquer l'UI ;
- pagination automatique si le nombre de machines depasse la hauteur du monitor ;
- `START ALL` / `STOP ALL` restent disponibles sur la page Overview.

Cette version ne cree volontairement aucune association Pump <-> Separator a partir des suffixes de noms CC.
La future notion de ligne utilisera une association logique explicite afin de rester fiable apres modification ou remplacement d'une machine.


## V0.4.1 - Fiabilite des commandes

Correction d'un cas ou les controles pouvaient rester bloques apres plusieurs START/STOP.

- suppression du `parallel.waitForAll` imbrique pour les commandes globales ;
- les ordres vers les machines sont envoyes de facon sequentielle dans la boucle de controle, tandis que l'UI reste independante et reactive ;
- toutes les commandes sont encapsulees dans `pcall` ;
- le verrou `controlPending` est toujours libere apres une commande, y compris en cas d'erreur ;
- watchdog de 5 secondes : un verrou reste trop longtemps est automatiquement reinitialise ;
- la collecte de telemetrie est protegee afin qu'une erreur peripherique transitoire ne termine pas le programme.

Cette version vise la robustesse avant l'ajout des lignes logiques.


## V0.5.0 - Lignes logiques

Ajout d'un niveau de controle entre le module complet et les machines individuelles.

Mapping confirme :

- LINE 1 : `electricPump_2` + `electrolyticSeparator_2`
- LINE 2 : `electricPump_1` + `electrolyticSeparator_0`
- LINE 3 : `electricPump_0` + `electrolyticSeparator_1`

La page `LINES` affiche l'etat de chaque couple et permet un START / STOP par ligne.

Etats :

- `RUN` : Pump + Separator en marche ;
- `STOP` : Pump + Separator arretes ;
- `MIXED` : les deux machines n'ont pas le meme etat ;
- `MISSING` : une des deux machines n'est pas presente sur le reseau.

Le mapping est porte par la configuration et n'est pas deduit des suffixes CC.

Correction UI incluse : chaque ecriture revient sur un fond noir par defaut, ce qui supprime les bandes rouges/vertes heritees des boutons.


## V0.5.1 - Nettoyage UI lignes

- la page `LINES` n'affiche plus les noms techniques Pump / Separator ;
- elle affiche uniquement `LINE X`, l'etat de la ligne et le bouton START / STOP ;
- la page `MACHINES` indique maintenant la ligne logique de chaque Pump et Separator ;
- une machine non associee est affichee `UNASSIGNED`.


## V0.6.0 - Lignes integrees a l'Overview

Simplification de la navigation :

- suppression de l'onglet `LINES` ;
- seuls `OVERVIEW` et `MACHINES` restent en navigation principale ;
- l'Overview contient maintenant un bloc compact `LINES` ;
- chaque ligne y conserve son etat et son bouton START / STOP ;
- la page `MACHINES` reste la vue detaillee avec le rattachement de chaque machine a sa ligne.

Le controle logique des lignes ne change pas ; seule la presentation est simplifiee.
