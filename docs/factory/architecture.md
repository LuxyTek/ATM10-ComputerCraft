# Factory Control - Architecture

## Objectif

Construire une usine ATM10 independante, concue des le depart pour etre supervisee et pilotee par CC:Tweaked, avec Mekanism comme premiere couche de process industriel.

Le systeme doit rester modulaire : chaque ligne de production est une cellule autonome et le controleur CC ajoute supervision, alarmes et automatisation sans assurer lui-meme le transport des ressources.

## Principes

1. Mekanism transporte les fluides, chemicals et l'energie.
2. CC:Tweaked observe, decide et commande.
3. Chaque cellule garde des buffers physiques mesurables.
4. Une panne du logiciel ne doit pas detruire les ressources.
5. Les noms de peripheriques ne sont pas codes en dur tant que possible.
6. Les seuils de controle sont dans un fichier de configuration.
7. Les futures cellules doivent reutiliser les memes conventions.

## Architecture cible

```text
                  FACTORY CONTROL
                        |
                  Wired Network
                        |
        +---------------+---------------+
        |               |               |
     Cellule 01      Cellule 02      Cellule NN
      H2 / O2          future           future
        |
   +----+----+------------------+
   |         |                  |
 Process   Buffers            Energie
   |         |                  |
Mekanism   Tanks/Cubes       Mekanism
```

## Cellule standard

Une cellule doit exposer au controleur :

- etat du process ;
- entrees disponibles ;
- sorties et niveaux des buffers ;
- energie disponible et consommation ;
- etat des peripheriques ;
- commandes marche/arret lorsque supportees.

## Extension future

Une liaison usine -> base pourra etre ajoutee via Quantum Entangloporter.

Le Quantum Entangloporter sera traite comme une couche d'export et non comme une dependance du process local. La cellule doit donc pouvoir continuer a produire et bufferiser meme si l'export distant est indisponible.
