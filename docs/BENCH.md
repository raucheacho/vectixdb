# Benchmarks

Mesures du 16 octobre 2026, Apple M1 Pro, macOS, VectixDB 0.1.0 (ReleaseSafe) et Zvec 0.7.0 (paquet PyPI).

## Protocole

- 100 000 vecteurs de dimension 384, tirés autour de 200 centres (plus proche de vrais embeddings qu'un bruit uniforme), et 300 requêtes tirées de la même façon. Les deux moteurs lisent les **mêmes fichiers** (`bench/zvec_bench.py gen`).
- HNSW m = 16, ef_construction = 200, ef = 64, k = 10, cosinus. Insertion par lots de 1 000.
- Champs : `group = i % 100` (un filtre `group = 7` garde 1 %) et `lang` parmi 5 valeurs (`lang = en` garde 20 %).
- Rappel@10 mesuré contre le cosinus exact sur les vecteurs f32 d'origine, filtre appliqué.
- VectixDB : `vectix bench --vectors cmp/vecs.f32 --qvectors cmp/queries.f32 [--f32]`. Zvec : `python bench/zvec_bench.py run cmp int8|f32`.

Reproduire :

```sh
python bench/zvec_bench.py gen cmp 100000 384 300
python bench/zvec_bench.py run cmp int8
zig-out/bin/vectix bench --vectors cmp/vecs.f32 --qvectors cmp/queries.f32 --dir cmp/vectix-int8
```

## Résultats

VectixDB après la construction HNSW parallèle (8 threads), le checksum CRC32C matériel et le décodage en bloc des instantanés. Les chiffres de la première mesure (construction sur un thread) sont entre parenthèses.

### Vecteurs quantifiés int8

| | VectixDB | Zvec |
| --- | --- | --- |
| Ingestion | 26 671 docs/s (4 760) | 8 737 docs/s (insertion + optimize) |
| Taille sur disque | 63 Mio | 216 Mio |
| Réouverture | 0,08 s (0,28 s) | 0,07 s |
| Vecteur : p50 / p99 | 0,20 / 0,46 ms | 0,52 / 0,83 ms |
| Vecteur : rappel@10 | 0,931 | 0,930 |
| Filtre 20 % : p50 / rappel | 0,34 ms / 0,954 | 0,63 ms / 0,962 |
| Filtre 1 % : p50 / rappel | 0,11 ms / 0,994 | 0,72 ms / 0,994 |

### Vecteurs f32

| | VectixDB | Zvec |
| --- | --- | --- |
| Ingestion | 17 894 docs/s (3 030) | 14 525 docs/s |
| Taille sur disque | 172 Mio | 170 Mio |
| Réouverture | 0,13 s (0,67 s) | 0,07 s |
| Vecteur : p50 / p99 | 0,24 / 0,28 ms | 0,45 / 1,04 ms |
| Vecteur : rappel@10 | 0,994 | 0,997 |
| Filtre 20 % : p50 / rappel | 0,41 ms / 0,999 | 0,52 ms / 1,000 |
| Filtre 1 % : p50 / rappel | 0,13 ms / 1,000 | 0,60 ms / 1,000 |

### Routes propres à VectixDB (int8, 100 000 documents de 30 mots)

| Route | p50 | p99 |
| --- | --- | --- |
| Texte BM25 | 0,31 ms | 0,87 ms |
| Hybride (vecteur + BM25, RRF) | 0,45 ms | 1,04 ms |
| Hybride, filtre 20 % | 0,48 ms | 0,81 ms |
| Sous-chaîne exacte, filtre 1 % | 0,32 ms | 0,37 ms |

## Lecture honnête

- **Rappel : à égalité.** Les deux moteurs trouvent les mêmes voisins, à un millième près.
- **Latence : ne pas conclure que VectixDB est plus rapide.** Les temps de Zvec passent par Python (conversion du vecteur en liste, appel du binding), ce qui ajoute probablement 0,1 à 0,3 ms par requête ; ceux de VectixDB sont mesurés en Zig, sans binding. Seul l'écart sur le filtre à 1 % (0,11 ms contre 0,72 ms) dépasse nettement ce biais : VectixDB passe en recherche exacte sur les 1 000 documents retenus.
- **Ingestion : VectixDB est maintenant devant** (3 fois en int8, 1,2 fois en f32). Les nœuds d'un lot sont reliés au graphe sur plusieurs threads, avec un verrou par nœud ; le rappel est inchangé. Avec plusieurs threads le graphe dépend de l'ordonnancement (qualité égale, résultats pas identiques d'une construction à l'autre) ; `build_threads = 1` le rend déterministe.
- **Réouverture : à égalité en int8, presque en f32.** Le temps venait surtout du checksum (CRC32C logiciel de la bibliothèque standard, 391 Mo/s, remplacé par les instructions CRC du processeur) et du décodage élément par élément. VectixDB vérifie le checksum de tout l'instantané à l'ouverture, ce que le mmap n'éviterait pas : il ne ferait gagner que la copie (environ 40 ms sur 180 Mio). Le mmap reste utile pour réduire la mémoire, pas le temps d'ouverture.
- **Disque en int8 : 3,4 fois moins pour VectixDB**, mais pour une raison précise : Zvec garde aussi les vecteurs f32 d'origine, ce qui lui permet d'affiner les résultats (refine). VectixDB ne garde que les codes int8 et ne peut donc pas affiner.
- **Mémoire : pas comparable ici.** Les deux mesures incluent le jeu de données gardé par le script de mesure (numpy d'un côté, la copie f32 pour la vérité terrain de l'autre).

## Pistes

1. Instantanés en sections alignées et mmap, pour la mémoire.
2. Option « garder les vecteurs f32 » pour affiner les résultats int8.
3. Mesurer VectixDB à travers le binding Go pour une comparaison de latence à armes égales avec le binding Python de Zvec.
