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


## V0.6.1 - Tri des machines par ligne

La page `MACHINES` est maintenant triee selon l'ordre logique des lignes configurees :

- LINE 1 : Pump puis Separator ;
- LINE 2 : Pump puis Separator ;
- LINE 3 : Pump puis Separator ;
- machines `UNASSIGNED` a la fin.

Ce tri suit l'ordre de `config.lines` et ne depend pas des suffixes CC.


## V0.7.0 - Mode AUTO

Premier controle automatique du prototype H2/O2.

### Modes

- `MANUAL` reste le mode de demarrage apres reboot ;
- `AUTO` est active explicitement depuis l'Overview ;
- en AUTO, les commandes globales, par ligne et par machine sont verrouillees ;
- repasser en MANUAL ne modifie pas l'etat courant des machines.

### Regulation des lignes

La regulation utilise le buffer le plus rempli entre H2 et O2.

- sous ~30 % : cible 3 lignes ;
- zone intermediaire : cible 2 lignes ;
- au-dessus d'environ 70 % : cible 1 ligne ;
- a 95 % : arret complet ;
- apres un arret buffer, reprise seulement sous 80 %.

Une hysteresis de 5 points est appliquee aux changements 3/2/1 lignes pour eviter les commutations rapides autour des seuils.

L'ordre de priorite suit `config.lines` : LINE 1, puis LINE 2, puis LINE 3.

### Securite eau

- sous 10 % d'eau : arret de toutes les lignes ;
- reprise uniquement lorsque l'eau remonte a 40 %.

### Energie

La reserve electrique externe n'est volontairement pas encore utilisee par l'AUTO. Les energies internes des Separators ne sont pas considerees comme un buffer usine fiable. Le controle energie sera ajoute apres validation d'un Energy Cube ou autre buffer externe sur le reseau CC.


## V0.7.1 - Buffers locaux avec Quantum Entangloporters non supervises

Chaque Chemical Tank H2/O2 dispose d'un Quantum Entangloporter non present sur le reseau CC.

L'AUTO ne tente pas d'estimer le contenu des QE. Ils sont consideres comme une reserve externe inconnue.

Regle retenue :

- les Chemical Tanks locaux restent les buffers de regulation ;
- le tank local le moins rempli pilote la demande de production ;
- un tank local a 0 % est donc une forte demande, meme si le QE peut encore contenir du gaz ;
- le ralentissement 3 / 2 / 1 lignes suit le niveau du tank local le moins rempli ;
- l'arret "buffers pleins" ne se produit que lorsque H2 ET O2 atteignent chacun le seuil `chemicalStop` ;
- apres cet arret, la production est reautorisee des qu'au moins un des deux tanks retombe sous `chemicalResume`.

Cette logique evite qu'un tank H2 naturellement plus vite rempli a cause du ratio de production 2:1 ne bride prematurement le remplissage du tank O2.


## V0.7.2 - Publication vers le Factory Dashboard

Le module H2/O2 publie maintenant un statut normalise sur Rednet via `factory.status.v1`.

La logique locale du module reste autonome : le Dashboard est uniquement observateur.

Donnees publiees :

- identite du module ;
- version ;
- mode MANUAL / AUTO ;
- etat RUN / IDLE / HOLD / STOP ;
- sante OK / WARN / FAULT ;
- nombre de lignes actives ;
- niveaux locaux WATER / H2 / O2 ;
- raison synthetique de l'etat ;
- alarmes de synthese.

Exemples de raisons publiees :

- `DEMAND H2 27%` ;
- `DEMAND O2 41%` ;
- `HOLD WATER 8%` ;
- `BUFFER HOLD` ;
- `BUFFER FULL` ;
- `FAULT CONTROL`.

Le contenu des Quantum Entangloporters reste volontairement inconnu : les niveaux publies correspondent aux buffers locaux supervises.


## V0.7.3 - Anti-blocage des Separators par saturation d'un gaz

Probleme observe en fonctionnement reel : H2 peut atteindre 100 % alors que O2 est encore demande. Les buffers internes H2 des Electrolytic Separators se remplissent alors et la machine cesse toute electrolyse, ce qui bloque aussi la production O2.

Correction :

- si H2 local atteint `overflowEnable` (98 %) alors que O2 reste sous le seuil de fin de production, la sortie H2 de chaque Separator passe en `DUMPING_EXCESS` ;
- si O2 sature avant H2, la meme logique est appliquee symetriquement a la sortie O2 ;
- la sortie concernee repasse en `IDLE` lorsque son buffer local redescend sous `overflowDisable` (90 %) ou lorsque l'autre gaz n'a plus besoin de production ;
- si aucune ligne ne doit tourner, les deux sorties reviennent en `IDLE` ;
- au demarrage du programme en MANUAL, les modes de dumping geres par l'AUTO sont remis en `IDLE`.

Le programme utilise les methodes Mekanism :

- `getLeftOutputDumpingMode` / `setLeftOutputDumpingMode` ;
- `getRightOutputDumpingMode` / `setRightOutputDumpingMode` ;
- mode `DUMPING_EXCESS`.

Pour la recette eau du module H2/O2, H2 est la sortie gauche et O2 la sortie droite. Le code tente d'abord d'identifier le chemical reellement present avant d'utiliser ce mapping connu comme fallback.

Le mode `DUMPING_EXCESS` ne vide pas les Chemical Tanks externes : il ne concerne que le buffer interne du Separator et permet d'eviter le blocage du process lorsqu'un des deux produits ne peut plus etre evacue.


## V0.7.4 - Niveaux internes dans MACHINES

La page `MACHINES` affiche maintenant la telemetrie interne de chaque machine sur une seconde ligne.

### Electric Pump

- pourcentage du buffer fluide interne.

Exemple :

```text
PUMP  electricPump_2   LINE 1   RUN   [ AUTO ]
      FLUID 100.0%
```

### Electrolytic Separator

- pourcentage d'eau dans le buffer d'entree ;
- pourcentage H2 dans le buffer chimique interne ;
- pourcentage O2 dans le buffer chimique interne.

Exemple :

```text
SEP   electrolyticSeparator_2   LINE 1   RUN   [ AUTO ]
      WATER 100.0%   H2 98.4%   O2 12.7%
```

La pagination a ete adaptee au format deux lignes par machine.

Correction associee : le fallback de mapping des sorties du Separator suit le mapping Mekanism 1.21.x, avec O2 a gauche et H2 a droite.


## V0.7.5 - Overflow en DUMPING complet

Le mode `DUMPING_EXCESS` s'est revele insuffisant en fonctionnement reel : le buffer interne du gaz sature pouvait encore se remplir assez vite pour bloquer le Separator apres environ une seconde.

Correction :

- lorsqu'un gaz local atteint le seuil d'overflow et que l'autre gaz doit encore etre produit, la sortie concernee passe maintenant en `DUMPING` complet ;
- seuls les Separators appartenant aux lignes actives sont concernes ;
- le gaz sature est donc evacue en continu depuis le buffer interne du Separator ;
- l'autre gaz peut continuer a etre produit sans interruption ;
- lorsque le Chemical Tank local du gaz sature redescend sous `overflowDisable` (90 %), la sortie repasse en `IDLE` afin de recommencer a remplir le buffer local ;
- si la production s'arrete ou si le module repasse en MANUAL, les sorties gerees par l'AUTO reviennent en `IDLE`.

Exemple :

```text
H2 100 % / O2 65 %
=> H2 output = DUMPING
=> O2 continue a etre produit

H2 < 90 %
=> H2 output = IDLE
=> le H2 local recommence a se remplir normalement
```
