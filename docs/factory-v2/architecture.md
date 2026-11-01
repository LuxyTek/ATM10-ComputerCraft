# Factory Control V2 - Architecture

## Principes

Factory V2 separe quatre responsabilites qui se sont progressivement melangees dans la V1 :

1. **Core** : cycle de vie, registre, communication, mise a jour.
2. **Modules** : logique industrielle et acces aux peripheriques.
3. **UI** : composants generiques, vues module, vue machines, Flow Map.
4. **Definitions** : description declarative des ressources, chaines et machines.

Le Supervisor orchestre. Il ne doit plus contenir de fonctions telles que
`renderEthene()`, `renderHdpe()` ou `renderSulfuric()`.

## Architecture

```text
                    FACTORY SUPERVISOR
                           |
              +------------+------------+
              |                         |
          CORE / REGISTRY              UI
              |                         |
        module discovery         generic renderers
              |                         |
      +-------+-------+          +------+------+
      |       |       |          |             |
     H2O2   ETHENE   HDPE     OVERVIEW      MACHINES
      |       |       |          |
      +-------+-------+------> FLOW MAP
              |
         STATUS / CONTROL
              |
       physical peripherals
```

## Responsabilite d'un module

Un module possede :

- sa logique AUTO / MANUAL ;
- ses securites ;
- la lecture de ses peripheriques ;
- les commandes physiques ;
- son etat runtime ;
- une definition declarative utilisable par le Supervisor.

Le module ne dessine pas directement l'IHM centrale.

## Definition declarative

Chaque module expose une definition statique permettant au Supervisor de connaitre :

- son identite ;
- ses entrees et sorties ;
- ses chaines ou sous-modules ;
- ses machines ;
- les buffers associes ;
- les actions autorisees ;
- sa position ou ses contraintes de topologie, si necessaire.

Les donnees dynamiques arrivent dans les statuts du module.

## Ressources

Les flux sont nommes par un identifiant stable :

```text
hydrogen
oxygen
biofuel
ethene_gas
liquid_ethene
substrate
sulfur
sulfur_dioxide
sulfur_trioxide
water_vapor
sulfuric_acid
hdpe_pellet
```

Un module declare seulement les ressources qu'il produit et consomme.
Le Flow Map relie automatiquement producteurs et consommateurs.

## Sous-modules / chaines

Une chaine est une partie logique d'un module, par exemple pour Sulfuric Acid :

```text
sulfur_dioxide
sulfur_trioxide
water_vapor
sulfuric_acid
```

Chaque chaine peut exposer :

- un etat ;
- un buffer ;
- des inputs ;
- des outputs ;
- plusieurs machines ;
- une action ON/OFF si le module la supporte.

La vue MACHINES regroupe automatiquement les machines par chaine.

## Controle

Deux niveaux sont distincts :

### Controle de chaine

Peut rester utilisable en AUTO lorsqu'il represente une autorisation persistante :

```text
chain.enabled = true / false
```

### Controle machine

Commande physique directe. Par convention :

- visible en AUTO ;
- verrouille en AUTO ;
- START / STOP disponible en MANUAL.

## Factory Dashboard

Le Dashboard distant reste une vue de synthese :

- NETWORK ;
- RUNTIME ;
- MODE ;
- STATE ;
- HEALTH ;
- raison principale.

Il ne porte pas la logique de process.

## Supervisor

Le Supervisor local :

- charge le registre ;
- recoit les statuts ;
- affiche le Flow Map ;
- affiche les vues generiques ;
- relaie les commandes vers le runtime du module ;
- gere l'update.

## Compatibilite

La migration V2 ne doit pas modifier le comportement industriel d'un module tant que celui-ci n'est pas explicitement migre et valide en jeu.
