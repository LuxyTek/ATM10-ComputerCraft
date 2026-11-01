# Factory Control V2

Cette documentation decrit la refonte modulaire de Factory Control.

## Objectif

Faire evoluer l'usine actuelle vers une architecture dans laquelle :

- le coeur du Supervisor ne connait pas les modules individuellement ;
- chaque module declare ses ressources, chaines, machines et capacites ;
- les vues Overview / Machines sont generees a partir du contrat commun ;
- le Flow Map est construit depuis une topologie de ressources ;
- l'ajout d'un module ne demande pas de modifier le coeur du Supervisor ;
- les programmes independants du projet Factory restent clairement separes.

## Etat de la migration

La branche `refactor/factory-v2` est le chantier V2.

La branche `backup/factory-v0.12.2-pre-refactor` fige la baseline fonctionnelle avant refonte.

Pendant les premiers LOTs, les scripts Factory historiques restent presents et fonctionnels. La nouvelle architecture est construite a cote, puis les modules sont migres un par un.

## Documents

- `architecture.md` : architecture logicielle cible.
- `module-contract-v2.md` : contrat declaratif des modules.
- `repository-layout.md` : organisation cible du depot.
- `migration-plan.md` : ordre de migration et criteres de validation.
