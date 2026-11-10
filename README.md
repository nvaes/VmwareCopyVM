# VmwareCopyVM

`esxi-vm-move.sh` arrête une VM sur un hôte ESXi et copie **tous** ses fichiers vers un autre hôte ESXi via SSH, sans vCenter.

- Dossier de la VM : vmx, nvram, vmsd, vmsn, logs et disques locaux.
- Disques situés sur **d'autres datastores** (lus dans le `.vmx`).
- Extents (`-flat`, `-delta`, `-sesparse`) et **chaîne de snapshots** complète.
- Tout est regroupé dans un seul dossier à destination ; les chemins du `.vmx` et des descripteurs VMDK sont réécrits.
- Barre de progression par fichier : débit instantané, débit moyen, temps restant et avancement global.

## Prérequis

- Shell ESXi (busybox `ash`) : bash **non** requis.
- Service SSH démarré sur l'hôte **de destination**.
- Règle de pare-feu `sshClient` sur l'hôte source : ouverte temporairement par le script, puis refermée.
- Clé SSH conseillée (`/etc/ssh/keys-root/authorized_keys` sur la destination). Sans clé, le mot de passe est demandé une seule fois (connexion multiplexée).

## Utilisation

À lancer sur l'ESXi **source** :

```sh
scp esxi-vm-move.sh root@esx-src:/tmp/
ssh root@esx-src
chmod +x /tmp/esxi-vm-move.sh

# Simulation : vérifications + liste des fichiers, sans arrêt ni copie
/tmp/esxi-vm-move.sh -n -d root@esx-dst -p /vmfs/volumes/DATASTORE MaVM

# Copie réelle
/tmp/esxi-vm-move.sh -z -r -d root@esx-dst -p /vmfs/volumes/DATASTORE MaVM
```

Sans nom de VM, le script affiche la liste des VM de l'hôte (Vmid, nom, état, fichier) et demande laquelle migrer.

| Option | Rôle |
|---|---|
| `-d user@hôte` | ESXi de destination |
| `-p chemin` | Datastore (ou dossier) de destination ; la VM est copiée dans `<chemin>/<dossier de la VM>` |
| `-z` | Compression gzip à la volée (conseillé pour les disques thin ou un lien partagé) |
| `-t` | Re-thin des disques à l'arrivée (`vmkfstools -i -d thin`) ; ignoré si snapshots |
| `-r` | Enregistre la VM sur l'hôte de destination |
| `-T s` | Délai d'arrêt propre avant proposition d'arrêt forcé (défaut 300 s) |
| `-i s` | Intervalle de rafraîchissement de la progression (défaut 2 s, 30 s hors terminal) |
| `-y` | Répond « oui » à tout, **arrêt forcé inclus** |
| `-n` | Simulation |

### Copie longue (survivre à une coupure SSH)

```sh
nohup /tmp/esxi-vm-move.sh -y -z -r -d root@esx-dst -p /vmfs/volumes/DATASTORE MaVM > /tmp/vmmove.log 2>&1 &
tail -f /tmp/vmmove.log
```

## Déroulement

1. Inventaire des disques et de leurs chaînes. Arrêt si un RDM est trouvé ou si deux fichiers portent le même nom.
2. Contrôles : connexion SSH, dossier de destination encore inexistant, espace libre (`vmkfstools -P`) avec 5 % de marge.
3. Arrêt propre via les VMware Tools, puis arrêt forcé sur confirmation.
4. Copie fichier par fichier, avec vérification de la taille à l'arrivée.
5. Options : re-thin (`-t`), enregistrement (`-r`).

## Fichiers exclus

`*.vswp`, verrous `.lck` et fichiers CBT `*-ctk.vmdk` (la ligne `changeTrackPath` est retirée des descripteurs). Les lignes `sched.swap.derivedName`, `sched.swap.dir` et `workingDir` sont retirées du `.vmx`.

## Limites connues

- **Débit** : la copie SSH sur ESXi est limitée par le processeur, souvent bien en dessous du débit du lien. À mesurer sur une VM pilote.
- **Disques thin** : sans `-z`, ils transitent à leur taille complète et arrivent en thick (utiliser `-t` pour les remettre en thin).
- **Avec `-z`** : le débit affiché est celui des données écrites à destination, pas celui du réseau.
- **ISO** montées depuis un datastore : non copiées (un avertissement est affiché).
- **RDM** : non pris en charge.
- **vSAN** (source ou destination, ex. VxRail) : non pris en charge. Sur vSAN, un disque n'est pas un fichier `-flat.vmdk` : le descripteur pointe vers un objet (`vsan://…`), que la copie de fichiers ne peut ni lire ni écrire. Le script s'arrête avant d'éteindre la VM si une source ou une destination vSAN est détectée.
- **VM source** : elle reste enregistrée et arrêtée, ce qui permet un retour arrière. Au premier démarrage à destination, répondre « I Moved It » (conserve UUID et MAC). Ne jamais démarrer les deux copies en même temps.
- **Pas de conversion** de format : copie ESXi → ESXi uniquement.

## Alternative pour vSAN : ovftool d'hôte à hôte

`ovftool` (VMware OVF Tool) lit et écrit les disques par l'API de l'hôte, y compris sur vSAN. Il s'exécute depuis un poste ou une VM d'administration, et les données transitent par cette machine. La VM doit être arrêtée.

```sh
ovftool --noSSLVerify --diskMode=thin --datastore=vsanDatastore --network="VM Network" \
  "vi://root@hote-source/NomDeLaVM" "vi://root@hote-destination"
```

Le nom du datastore et du réseau de destination sont ceux vus par l'hôte de destination.

## Tests hors ESXi

```sh
./esxi-vm-move.sh --selftest-vmx  exemple.vmx    # réécriture du .vmx
./esxi-vm-move.sh --selftest-desc exemple.vmdk   # réécriture d'un descripteur
```
