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

**Etat : valide en jeu sous CC:Tweaked.**

Cree :

- `core/contract.lua` ;
- `core/loader.lua` ;
- `core/registry.lua` ;
- `core/status_adapter.lua` ;
- `core/bus.lua` ;
- `tools/core_v2_smoke_test.lua`.

Le Core charge les definitions depuis `modules/<id>/definition.lua`, valide
le Contract V2, construit les relations producteurs/consommateurs et accepte
temporairement les statuts Contract V1 via un adaptateur.

Critere structurel atteint : aucun nom de module industriel n'est code dans
les fichiers du Core.

Validation runtime effectuee : le smoke test a confirme le loader, le Registry,
la topologie automatique et l'adaptateur Contract V1 -> V2.

## LOT 3 - UI generique

**Etat : valide en jeu sous CC:Tweaked.**

Cree :

- `ui/widgets.lua` ;
- `ui/overview.lua` ;
- `ui/machines.lua` ;
- `ui/flow_map.lua` ;
- `tools/ui_v2_smoke_test.lua`.

Aucun renderer V2 ne contient de nom de module industriel. Overview, Machines
et Flow Map utilisent uniquement les definitions Contract V2, les statuts et
la topologie du Registry.

Critere structurel atteint : une definition de test peut etre affichee sans
ajouter de `renderXxx()`.

Validation effectuee : Overview, Machines et Flow Map ont ete testes sur
Advanced Monitor. Le Flow Map derive et dessine les liens de ressources depuis
la topologie du Registry.

## LOT 4 - Module pilote H2/O2

**Etat : couche V2 implementee, validation en jeu restante.**

Cree :

- `modules/h2o2/definition.lua` ;
- `modules/h2o2/legacy_adapter.lua` ;
- `modules/h2o2/control_adapter.lua` ;
- `modules/h2o2/config.example.lua` ;
- `tools/h2o2_v2_smoke_test.lua`.

La logique industrielle reste temporairement dans le runtime legacy
`programs/factory/h2o2.lua`. Le module V2 lui ajoute des IDs logiques stables,
un statut Contract V2 et une traduction des commandes V2 vers les events
legacy.

Cette etape permet de valider l'architecture V2 sans modifier le comportement
AUTO, les seuils ou les securites H2/O2.

Validation restante : verifier Overview + Machines generiques avec le fixture
H2/O2, puis tester l'adaptation d'un statut H2/O2 reel avant de remplacer le
runtime legacy.

Critere final : comportement identique a la baseline.

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
