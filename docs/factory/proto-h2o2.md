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
