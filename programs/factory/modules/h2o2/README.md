# H2/O2 - Factory Module V2

Premier module reel migre vers l'architecture V2.

## Etat actuel

La logique industrielle reste pour l'instant dans le runtime legacy :

```text
/programs/factory/h2o2.lua
```

Ce dossier fournit la couche V2 autour de ce runtime sans modifier son
comportement.

## Fichiers

- `definition.lua` : ressources, 3 lignes et 6 machines logiques.
- `legacy_adapter.lua` : transforme le statut V1 H2/O2 en Contract V2.
- `control_adapter.lua` : traduit les actions V2 vers les events legacy.
- `config.example.lua` : mapping physique de reference.

## IDs logiques

```text
line_1
|-- line_1_pump
`-- line_1_separator

line_2
|-- line_2_pump
`-- line_2_separator

line_3
|-- line_3_pump
`-- line_3_separator
```

Ces IDs ne changent pas si les noms de peripherals CC changent.

## Ressources

Input :

- `water`

Outputs :

- `hydrogen`
- `oxygen`

## Controle

Le runtime legacy permet :

- AUTO / MANUAL ;
- START / STOP global ;
- START / STOP par ligne en MANUAL ;
- START / STOP machine en MANUAL.

`chain.start` / `chain.stop` sont distincts de `chain.set_enabled`.
H2/O2 n'a pas de permission persistante par ligne en AUTO.
