# Factory V2 - Plan de migration

## Baselines

- Fonctionnelle gelee : `backup/factory-v0.12.2-pre-refactor`
- Chantier : `refactor/factory-v2`

## LOT 1 - Socle documentaire

- architecture cible ;
- contrat module V2 ;
- arborescence cible ;
- regles de migration.

Aucun comportement en jeu ne change.

## LOT 2 - Core minimal

Creer :

- registry ;
- loader ;
- status/control bus V2 ;
- compatibilite avec les statuts V1 si necessaire.

Critere : le Core charge des definitions sans connaitre les modules par leur nom.

## LOT 3 - UI generique

Extraire du Supervisor :

- widgets ;
- Overview generique ;
- Machines generique ;
- Flow Map.

Critere : une definition de test peut etre affichee sans ajouter de `renderXxx()`.

## LOT 4 - Module pilote H2/O2

Migrer H2/O2 en premier car il couvre :

- plusieurs lignes ;
- plusieurs machines ;
- buffers ;
- controles ;
- ressources partagees.

Critere : comportement identique a la baseline.

## LOT 5 - Modules simples

Migrer :

1. Biofuel ;
2. HDPE.

## LOT 6 - Ethene

Valider :

- plusieurs lignes ;
- conversion gas -> liquid ;
- shared input buffer ;
- Substrate ;
- dependances H2 / Biofuel.

## LOT 7 - Sulfuric Acid

Valider :

- quatre chaines ;
- machines groupees par chaine ;
- chain ON/OFF en AUTO ;
- O2 partage ;
- multiples outputs.

## LOT 8 - Installer / updater

Unifier :

- installation ;
- packages ;
- manifests ;
- startup.

## LOT 9 - Nettoyage

Seulement apres equivalence fonctionnelle :

- supprimer les installateurs devenus inutiles ;
- supprimer manifests historiques ;
- deplacer ou supprimer scripts legacy ;
- mettre a jour README racine ;
- figer une release V2.

## Regle de validation

Aucun LOT ne remplace le precedent sans test en jeu lorsque le changement peut affecter le comportement des machines.
