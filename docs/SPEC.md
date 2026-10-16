# VectixDB — spécification v0 (phase 0)

VectixDB est une base de recherche embarquée : une bibliothèque Zig sans dépendance, exposée par une API C stable, qui combine vecteurs, plein texte, recherche exacte et filtres sur métadonnées dans un seul moteur. Elle tourne dans le processus de l'application ; il n'y a pas de serveur.

Le moteur est **générique** : il ne connaît ni les agents, ni les problèmes, ni les solutions. Lorag (l'application) construit sa mémoire au-dessus, avec les primitives décrites ici.

Statut : phase 1 implémentée (moteur, journal, instantanés, API C, binding Go). Le format disque et l'API C restent modifiables jusqu'à la version 1.0 ; ensuite, tout changement passe par un numéro de version.

---

## 1. Principes

1. **Une écriture acquittée survit à un plantage du processus et, en mode `sync`, à une coupure de courant.** Aucune exception, aucun réglage caché.
2. **La reprise ne supprime jamais une donnée qu'elle n'a pas prouvée obsolète.** Un fichier n'est effacé que si un manifeste plus récent, validé par checksum, le rend inutile.
3. **Une erreur ne laisse jamais un état à moitié appliqué.** Chaque opération se prépare d'abord, puis se valide en une étape qui ne peut pas échouer.
4. **Une ouverture en lecture seule n'écrit aucun octet.**
5. **Zéro dépendance.** Pas de RocksDB, Arrow, Parquet ni générateur de parseur : chaque format est spécifié ici et lisible par un autre programme.
6. **Déterministe.** Mêmes écritures dans le même ordre, mêmes résultats, égalités départagées par slot.
7. **Valeurs typées de bout en bout.** Un filtre sur un flottant reste un `f64` binaire du client jusqu'au moteur, jamais une chaîne.

## 2. Ce que nous retenons de Zvec, et ce que nous évitons

Lecture du code de `alibaba/zvec` (branche main, octobre 2026) et de ses issues.

| Constat chez Zvec | Référence | Décision VectixDB |
| --- | --- | --- |
| Le WAL n'est jamais fsyncé avant l'acquittement : l'intervalle `max_docs_wal_flush` vaut toujours 0 et n'est pas exposé | #789 point 4, `local_wal_file.cc` | Trois modes explicites (`sync` par défaut, `batch`, `none`) ; en `sync`, l'appel ne rend la main qu'après fsync (et `F_FULLFSYNC` sur macOS) |
| Un fsync en échec est seulement journalisé | #789 | Un fsync en échec empoisonne la base : toutes les écritures suivantes échouent jusqu'à réouverture (on ne réessaie jamais un fsync) |
| Le checkpoint supprime le WAL avant que les données de remplacement soient sur disque | #789 point 1 | Ordre strict : écrire les instantanés, fsync, écrire le manifeste, fsync, rename, fsync du dossier, *puis* seulement supprimer les WAL couverts |
| Manifeste écrit sur place, sans checksum ; un manifeste tronqué se décode comme valide, puis le nettoyage efface tous les segments | #789 point 2 | Manifeste écrit dans un fichier temporaire puis renommé, avec CRC ; un manifeste invalide fait repartir sur le précédent, et un manifeste invalide n'autorise jamais un nettoyage |
| Un WAL créé sans son en-tête rend la collection impossible à ouvrir | #800 | Un WAL naît par fichier temporaire + rename ; un WAL plus court que son en-tête est traité comme vide |
| Un enregistrement corrompu au milieu du WAL arrête la relecture en silence, et les écritures suivantes s'ajoutent après les octets illisibles | `local_wal_file.cc` | La fin déchirée est tronquée avant toute nouvelle écriture ; une corruption *au milieu* (suivie d'enregistrements valides) est une erreur explicite, jamais un saut silencieux |
| Une écriture de plus de 4 Mio est acceptée mais refusée à la relecture, ce qui perd tout ce qui suit | `MAX_RECORD_SIZE` lu, jamais vérifié à l'écriture | Les mêmes limites sont vérifiées à l'écriture et à la lecture |
| Le CRC du WAL ne couvre que le contenu, pas la longueur | `local_wal_file.cc` | Le CRC couvre l'en-tête de l'enregistrement et son contenu |
| Un manque de descripteurs pendant le changement de segment duplique des documents et bloque les écritures | #811 | Préparer puis valider : la nouvelle structure est entièrement créée avant que l'ancienne soit retirée |
| Un plantage pendant le scellement d'un segment détruit une famille de colonnes RocksDB | #798, #783, #784, #806 | Pas de RocksDB ; nos fichiers sont immuables une fois écrits |
| Un document sans vecteur relit un faux vecteur nul | #691 | Champs annulables avec bitmap de présence ; « absent » n'est jamais une valeur |
| Les bornes exclusives des filtres flottants sont fausses après conversion en texte | #817 | Filtres construits par un AST typé, pas par une chaîne SQL |
| Fermer une collection ouverte en lecture seule modifie un fichier d'index | #815 | Test systématique : hash de tous les fichiers avant et après une session en lecture seule |
| Un seul processus écrivain ; une demande ouverte pour plusieurs lecteurs | #586 | Même choix, annoncé dès le départ : verrou exclusif sur le dossier ; l'application (le démon Lorag) est le seul accès |
| Agrégation int8 lente sur ARM, accumulation FP16 qui perd du rappel | #719, #786 | Produit scalaire int8 accumulé en i32 ; benchmarks sur ARM64 et x86-64 dans la CI |

Ce que nous reprenons comme idées : moteur dans le processus, collections avec schéma, vecteurs denses et épars, recherche hybride avec filtres, fusion RRF, mmap pour les données froides.

## 3. Modèle de données

### Base
Un dossier sur disque. Il contient des collections, un WAL partagé et un manifeste. Verrou sur `LOCK` : exclusif pour une ouverture en écriture, partagé pour une ouverture en lecture seule. Un conflit renvoie `VTX_E_LOCKED` (un lecteur ne voit donc jamais un écrivain supprimer des fichiers sous ses pieds).

### Collection
Une collection a un nom (`[a-z0-9_-]{1,64}`) et un schéma fixé à la création :

| Élément | Contenu |
| --- | --- |
| `vector` | facultatif : dimension (1 à 4096), métrique (`cosine`, `l2`, `dot`), quantification (`none`, `int8`), paramètres HNSW (`m`, `ef_construction`), étiquette libre (par exemple le nom du modèle d'embedding) |
| `text` | zéro ou plusieurs champs texte indexés en BM25, chacun avec son analyseur |
| `fields` | champs de métadonnées typés : `keyword` (chaîne exacte), `keywords` (liste), `int` (i64), `float` (f64), `bool`, `time` (i64, ms Unix) ; chacun peut être indexé pour les filtres |
| `payload` | bloc d'octets opaque, stocké et renvoyé, jamais interprété |

Changer de modèle d'embedding revient à créer une nouvelle collection : le moteur ne mélange pas deux espaces vectoriels.

### Document
- `id` : identifiant externe, de 1 à 512 octets.
- `vector`, champs texte et champs de métadonnées : tous facultatifs, avec la présence notée dans un bitmap.
- `payload` : facultatif.

En interne, chaque document vivant occupe un **slot** `u32`. Vecteurs, BM25, colonnes et payloads partagent le même espace de slots. Un `upsert` sur un id existant libère l'ancien slot (tombstone) et en prend un nouveau. Le compactage renumérote les slots.

## 4. Écriture

Toute écriture est un **lot** atomique : une suite de `put` et de `delete`, sur une ou plusieurs collections. Le lot reçoit un numéro de séquence `seq` (u64, strictement croissant) et il est entièrement appliqué ou pas du tout.

Étapes :
1. Valider le lot (schéma, dimensions, limites, et effet des opérations précédentes du même lot). En cas d'échec, rien n'est écrit.
2. Encoder puis ajouter au WAL.
3. En mode `sync`, fsync (`F_FULLFSYNC` sur macOS). Le group commit (les lots arrivés pendant un fsync partagent le suivant) est prévu.
4. Appliquer en mémoire. Un manque de mémoire à cette étape empoisonne la poignée : le lot est déjà dans le WAL, une réouverture le rejoue.
5. Rendre la main avec `seq`.

Si l'étape 2 échoue (disque plein), le fichier est tronqué à la dernière position valide et la base reste utilisable. Si un fsync échoue, la base est empoisonnée.

Limites vérifiées à l'écriture *et* à la relecture : lot ≤ 64 Mio encodé, id ≤ 512 o, texte ≤ 16 Mio par champ, payload ≤ 16 Mio.

## 5. Format sur disque

```
<base>/
  LOCK
  MANIFEST-<gen>                 manifeste courant (seul gardé après un checkpoint réussi)
  wal-<premier seq>.log          WAL, numéros sur 20 chiffres
  snap-<gen>-<collection>.vtx    instantané d'une collection, écrit au checkpoint <gen>
```
Tout est dans un seul dossier, si bien qu'un seul fsync de dossier rend durables toutes les créations, renommages et suppressions.

Entiers en petit-boutiste. CRC32C partout, calculé avec les instructions du processeur (ARMv8 CRC, SSE4.2) quand la cible les a.

### WAL
```
en-tête (24 o): "VTXW" | version u16 | 0 u16 | premier_seq u64 | crc32c u32 | 0 u32
enregistrement: longueur u32 | seq u64 | synced u64 | crc32c u32 (couvre les 20 octets précédents et le contenu) | contenu
```
`synced` est le dernier numéro de séquence dont le fsync avait abouti quand l'enregistrement a été écrit. Un fichier naît sous un nom temporaire et n'est renommé qu'une fois son en-tête durable.

Relecture : lire jusqu'au premier enregistrement invalide, de numéro s.
- Si aucun enregistrement valide situé après ne déclare `synced >= s`, alors s n'a jamais été acquitté comme durable : s et la suite sont une fin non synchronisée (éventuellement persistée dans le désordre par le système de fichiers). On tronque avant de réécrire.
- Sinon, des données durables sont abîmées : l'ouverture échoue avec `VTX_E_CORRUPT`, sauf option `repair` explicite.
- Limite connue : les derniers enregistrements synchronisés en bloc ne sont attestés que par l'écriture suivante. Une corruption de ces octets-là, entre un plantage et la réouverture, serait prise pour une fin non synchronisée.

Les fichiers entièrement couverts par le checkpoint sont ignorés à la relecture (leurs voisins peuvent déjà être supprimés) et effacés. Les lots dont `seq` est inférieur ou égal au `checkpoint_seq` du manifeste sont ignorés, ce qui rend la relecture idempotente.

### Manifeste
`"VTXM" | version u32 | gen u64 | checkpoint_seq u64 | n u32 | (nom de collection, fichier d'instantané)* | crc32c`.
Écrit en `MANIFEST-n.tmp`, fsync, rename, fsync du dossier. À l'ouverture, on prend le plus grand `n` dont le CRC est bon et dont tous les instantanés se chargent ; sinon on essaie le précédent. Si le journal ne couvre plus l'écart entre ce manifeste plus ancien et le présent, la relecture le détecte (trou de numéros) et l'ouverture échoue, sans rien perdre ni supprimer.

### Instantané de collection
Fichier immuable `"VTXC" | version | corps | crc32c`. Le corps contient le nom, le schéma, les documents vivants renumérotés de façon dense (id, payload), les colonnes champ par champ (texte avec son index BM25, mots-clés, numériques avec présence) et le graphe HNSW (les nœuds supprimés restent pour le routage, jusqu'au compactage).

En v1, le fichier est lu en mémoire. La v1.1 le découpera en sections alignées sur 64 octets, avec une table des sections, pour mapper (mmap) les vecteurs et les payloads sans copie.

### Checkpoint
1. Pour chaque collection modifiée : écrire `snap-<n>-<nom>.vtx.tmp`, fsync, rename ; puis fsync du dossier.
2. Écrire `MANIFEST-n` (étapes ci-dessus).
3. Seulement ensuite : fermer le WAL courant, supprimer les WAL couverts par `checkpoint_seq`, les instantanés remplacés ou des collections supprimées, et l'ancien manifeste.

Un plantage à n'importe quelle étape laisse soit l'ancien état complet, soit le nouveau. Le checkpoint se déclenche quand le WAL dépasse un seuil (64 Mio par défaut), à la demande et à la fermeture.

À l'ouverture en écriture, les fichiers orphelins (temporaires, instantanés non référencés, anciens manifestes) ne sont supprimés que si le manifeste chargé est le plus récent présent : un manifeste abîmé ne déclenche jamais de suppression.

Le compactage d'une collection renumérote les slots sans changer aucun document : il n'est pas journalisé, et un plantage avant le checkpoint suivant rejoue simplement sur l'instantané précédent.

## 6. Recherche

Une requête porte sur une collection et combine les routes demandées :

| Route | Entrée | Exhaustive |
| --- | --- | --- |
| `vector` | vecteur | non (HNSW) ; oui en force brute si le filtre retient peu de documents |
| `text` | chaîne, analysée comme les documents | oui sur les documents qui contiennent un terme |
| `exact` | sous-chaîne littérale dans un champ texte | oui |
| `hybrid` | vecteur + chaîne | fusion RRF (k=60) ou pondérée |

Paramètres communs :
- `k` : nombre de résultats ;
- `filter` : AST typé ;
- `ef` : taille de la liste HNSW ;
- `candidates` : candidats par route avant la fusion ;
- `fields` : champs à renvoyer ;
- `payload` : oui ou non.

### Filtres
AST construit par l'API : `eq`, `ne`, `in`, `range` (bornes incluses ou exclues), `exists`, `and`, `or`, `not`. Il est évalué en bitmap sur les slots grâce aux index des champs.
- Si moins de `max(1000, 2 % du total)` documents passent, la route vectorielle fait une force brute exacte sur ces slots.
- Sinon, HNSW parcourt le graphe normalement mais n'admet que les slots qui passent, en élargissant `ef`.

### Résultat
Chaque résultat contient :
- `id` et `score` final ;
- le rang et le score de chaque route (pour expliquer le classement) ;
- les champs demandés et le payload.

## 7. Primitives génériques pour la mémoire d'agents (phase 2)

Ces options de requête restent neutres : elles ne connaissent que des champs.
- **Modulation du score** par un champ numérique : `score × (1 + w·log1p(champ))`, ou décroissance temporelle sur un champ `time` avec une demi-vie.
- **Diversité (MMR)** : éviter les résultats quasi identiques, avec un paramètre λ.
- **Budget** : renvoyer le meilleur ensemble dont la somme d'un champ `int` (par exemple un nombre de tokens) ne dépasse pas N.
- **Prédicats de validité** : un filtre `range` sur deux champs (`v_min ≤ x ≤ v_max`) exprime « valide pour cette version ».

Lorag assemble ces primitives pour sa mémoire problème-solution ; le moteur n'en sait rien.

## 8. Concurrence

- Thread-safe : un écrivain à la fois (mutex), des lecteurs parallèles.
- v1 : verrou lecteurs-rédacteur par collection ; une recherche voit un état cohérent.
- v2 : lectures sur instantanés par `seq` (sans bloquer l'écrivain).
- La bibliothèque ne crée des threads que pour insérer les vecteurs d'un lot (`build_threads`, par défaut le nombre de cœurs, au plus 8), le temps de l'écriture. Avec un seul thread, le graphe est déterministe ; avec plusieurs, il dépend de l'ordonnancement, à qualité égale. Le checkpoint et le compactage sont des appels explicites.
- Les entrées-sorties passent par une instance `std.Io` propre à la bibliothèque, qui n'installe aucun gestionnaire de signal (compatibilité avec le runtime Go).

## 9. API C

Principes :
- poignées opaques ;
- code d'erreur `int` en retour, avec `vtx_last_error()` (message propre au thread) ;
- constructeurs plutôt que structures publiques, pour que l'ABI puisse évoluer ;
- toute mémoire rendue se libère avec la fonction `*_free` correspondante.

```c
int  vtx_open(const char *path, const vtx_options *opt, vtx_db **out);
int  vtx_close(vtx_db *db);
int  vtx_checkpoint(vtx_db *db);

int  vtx_collection_create(vtx_db *db, const char *name, const vtx_schema *s);
int  vtx_collection_drop(vtx_db *db, const char *name);
int  vtx_collection_compact(vtx_db *db, const char *name);

vtx_batch *vtx_batch_new(void);
int  vtx_batch_put(vtx_batch *b, const char *coll, const void *id, size_t id_len);
int  vtx_batch_vector(vtx_batch *b, const float *v, size_t dim);
int  vtx_batch_text(vtx_batch *b, const char *field, const char *s, size_t len);
int  vtx_batch_int / _float / _keyword / _bool / _time(...);
int  vtx_batch_payload(vtx_batch *b, const void *p, size_t len);
int  vtx_batch_delete(vtx_batch *b, const char *coll, const void *id, size_t id_len);
int  vtx_write(vtx_db *db, vtx_batch *b, uint64_t *seq_out);
void vtx_batch_free(vtx_batch *b);

vtx_filter *vtx_filter_eq_keyword(const char *field, const char *v, size_t len);
vtx_filter *vtx_filter_range_float(const char *field, double lo, int lo_incl, double hi, int hi_incl);
vtx_filter *vtx_filter_and(vtx_filter *a, vtx_filter *b);   /* prend possession */

vtx_query *vtx_query_new(const char *coll, uint32_t k);
int  vtx_query_vector(vtx_query *q, const float *v, size_t dim);
int  vtx_query_text(vtx_query *q, const char *s, size_t len);
int  vtx_query_filter(vtx_query *q, vtx_filter *f);         /* prend possession */
int  vtx_search(vtx_db *db, const vtx_query *q, vtx_results **out);
size_t vtx_results_len(const vtx_results *r);
/* accesseurs : id, score, rangs par route, champs, payload */
void vtx_results_free(vtx_results *r);
```

Les bindings (Go en premier, Python ensuite) enveloppent ces fonctions sans logique propre.

## 10. Analyseur de texte

- Découpage Unicode : lettres et chiffres forment des tokens ; `_`, `.` et `-` à l'intérieur d'un identifiant donnent à la fois le token complet et ses parties (`ERR_MODULE_NOT_FOUND` → `err_module_not_found`, `err`, `module`, `not`, `found`).
- Repli : minuscules ; accents latins retirés ; pour l'arabe, retrait du tashkeel et du tatweel, et unification de أ/إ/آ en ا, de ى en ي et de ة en ه.
- Pas de racinisation en v1, par souci de prévisibilité.
- Les langues sans espaces (chinois, japonais) attendent une v2, avec des bigrammes.

## 11. Tests et preuves

- **Couche système de fichiers interne** (`Fs`) : une implémentation réelle sur `std.Io` et une implémentation simulée en mémoire. Le simulateur garde, de ce qui n'est pas synchronisé, soit un préfixe, soit un sous-ensemble arbitraire (les vrais systèmes de fichiers réordonnent), avec des écritures déchirées et des renommages atomiques. Il injecte aussi `ENOSPC` et des fsync en échec, qui perdent les données en attente comme sous Linux.
- **Plantage à chaque point** : la charge de travail (création, écritures, suppressions, checkpoints automatiques) est rejouée en plantant à chaque appel système, avec plusieurs tirages par point, et parfois un second plantage pendant la reprise. Le test vérifie que l'état relu est exactement celui d'un préfixe des lots, et que ce préfixe contient tous les lots acquittés.
- **Tests de mutation** : retirer un fsync ou avancer une suppression dans le code de checkpoint doit faire échouer ces tests. C'est vérifié pour le fsync du WAL, le fsync des instantanés, le fsync du dossier avant le manifeste et la suppression du WAL avant le manifeste.
- **Lecture seule** : hash de tous les fichiers inchangé après ouverture, recherches et fermeture.
- **Fuzzing** des décodeurs (WAL, manifeste, instantanés) : jamais de plantage, seulement `VTX_E_CORRUPT`.
- **Rappel** : HNSW contre force brute (rappel@10 ≥ 0,95 en f32, ≥ 0,90 en int8) ; filtres contre une évaluation naïve.
- **Benchmarks reproductibles** (`zig build bench`) : ingestion, latence p50/p99 par route, rappel, taille disque, temps d'ouverture, mémoire. Jeux : synthétique, plus un corpus public avec embeddings multilingues. Comparaison avec Zvec (via son package Python) avant toute affirmation publique.

## 12. Organisation du dépôt

```
vectixdb/
  build.zig, build.zig.zon
  include/vectixdb.h
  src/        distance, codec, topk, analyzer, hnsw, bm25, filter, fs (réel + simulé),
              wal, manifest, snapshot, collection, query, db, c_api
  bindings/go/
  bench/
  docs/SPEC.md
```

Lorag dépend de VectixDB par `build.zig.zon` pour le moteur et par le module Go `bindings/go`.

## 13. Phase 1 : ordre de construction

1. Couche `Fs` réelle et simulée.
2. WAL avec relecture et tests de plantage à chaque point.
3. Collection : schéma, table id↔slot, colonnes, payloads, bitmaps de présence.
4. HNSW et BM25 indexés par slot (adaptation du code actuel), analyseur Unicode.
5. Filtres et requêtes : routes vectorielle, texte, exacte et hybride.
6. Instantanés, manifeste, checkpoint, compactage.
7. API C, en-tête, binding Go.
8. Outil en ligne de commande `vectix` (inspect, verify, search, bench).
9. Benchmarks.

Critère de sortie : tous les tests de plantage passent, rappel@10 et latence mesurés sur 100 000 documents.

## 14. Questions ouvertes

- Licence : Apache-2.0 (clause de brevets, comme Zvec).
- Retenu par défaut : un seul champ vecteur par collection en v1, vecteurs épars en v1.1.
