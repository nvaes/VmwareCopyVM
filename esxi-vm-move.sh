#!/bin/sh
# =============================================================================
# esxi-vm-move.sh
# Arrête une VM et copie TOUS ses fichiers vers un autre hôte ESXi via SSH :
#   - le dossier de la VM (vmx, nvram, vmsd, vmsn, logs, disques locaux...)
#   - les disques situés sur d'AUTRES datastores (référencés dans le .vmx)
#   - les extents (-flat, -delta, -sesparse) et toute la chaîne de snapshots
# Tout est regroupé dans un seul dossier à destination ; les chemins du .vmx
# et des descripteurs VMDK sont réécrits en conséquence.
#
# À exécuter dans le shell de l'ESXi SOURCE (busybox ash : bash non requis).
#
# Usage :
#   ./esxi-vm-move.sh -d root@esx-dst -p /vmfs/volumes/DATASTORE [options] [VM]
#
#   VM              nom exact ou Vmid ; sans argument -> menu interactif
#   -d user@hote    ESXi de destination (service SSH démarré)
#   -p chemin       datastore (ou dossier) de destination ; la VM est copiée
#                   dans <chemin>/<nom du dossier de la VM source>
#   -z              compression gzip à la volée (conseillé : disques thin,
#                   lien partagé type BLES — les zéros ne transitent plus)
#   -t              re-thin des disques à l'arrivée (vmkfstools -i -d thin) ;
#                   ignoré si la VM a des snapshots
#   -r              enregistre la VM sur l'hôte de destination
#   -T secondes     délai d'arrêt propre avant arrêt forcé (défaut : 300)
#   -y              répond « oui » à toutes les questions (arrêt forcé inclus)
#   -n              simulation : vérifications + liste des fichiers, sans
#                   arrêt ni copie
#   -i secondes     intervalle de rafraîchissement de la progression (défaut : 2 ;
#                   30 si la sortie n'est pas un terminal, ex. nohup)
#
# Copie longue : lancer détaché pour survivre à une coupure SSH, par ex.
#   nohup ./esxi-vm-move.sh -y -d ... -p ... VM > /tmp/vmmove.log 2>&1 &
#   tail -f /tmp/vmmove.log
#
# Exemple :
#   ./esxi-vm-move.sh -d root@10.0.2.14 -p /vmfs/volumes/DS_DC2_01 -z -r RDRvMembers-DB2
# =============================================================================
set -u

DEST=""; DPATH=""; GZIP=0; THIN=0; REG=0; TMO=300; YES=0; DRY=0
HASSNAP=0; FW_ENABLED=0; PINT=""; PPID_MON=""
WORK="/tmp/vmmove.$$"
CTL="/tmp/.vmmove-cm-$$"
SSH="ssh -o ControlMaster=auto -o ControlPath=$CTL -o ControlPersist=3600 -o ServerAliveInterval=30"

log()   { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn()  { printf '%s  ATTENTION : %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()   { printf 'ERREUR : %s\n' "$*" >&2; exit 1; }
ask()   {
    [ "$YES" -eq 1 ] && return 0
    printf '%s [o/N] ' "$1"; read -r _a </dev/tty
    case "$_a" in o|O|oui|y|Y|yes) return 0 ;; esac
    return 1
}
# Protection d'un argument pour le shell distant
q()     { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
rsh()   { $SSH "$DEST" "$1"; }
human() { awk -v b="$1" 'BEGIN{split("o Ko Mo Go To",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++};printf "%.1f %s",b,u[i]}'; }
absof() { case "$2" in /*) printf '%s\n' "$2" ;; *) printf '%s/%s\n' "$1" "$2" ;; esac; }
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; }
pstate(){ vim-cmd vmsvc/power.getstate "$1" 2>/dev/null | tail -1; }

cleanup() {
    [ -n "$PPID_MON" ] && kill "$PPID_MON" 2>/dev/null
    [ -n "$DEST" ] && $SSH -O exit "$DEST" >/dev/null 2>&1
    [ "$FW_ENABLED" -eq 1 ] && esxcli network firewall ruleset set -e false -r sshClient >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- Réécriture du .vmx : chemins de disques ramenés au nom de fichier seul ---
rewrite_vmx() {
    awk '
    /^[A-Za-z]+[0-9]+:[0-9]+\.[Ff]ile[Nn]ame *= *".*\.vmdk" *$/ {
        k=$0; sub(/".*$/,"",k)
        v=$0; sub(/^[^"]*"/,"",v); sub(/" *$/,"",v)
        n=split(v,a,"/"); print k "\"" a[n] "\""; next }
    /^(sched\.swap\.derivedName|sched\.swap\.dir|workingDir) / { next }
    { print }' "$1"
}

# --- Réécriture d'un descripteur VMDK : parent et extents en nom seul, CBT retiré ---
rewrite_desc() {
    awk '
    /^parentFileNameHint=/ {
        v=$0; sub(/^parentFileNameHint="/,"",v); sub(/" *$/,"",v)
        n=split(v,a,"/"); print "parentFileNameHint=\"" a[n] "\""; next }
    /^changeTrackPath=/ { next }
    /^(RW|RDONLY|NOACCESS) [0-9]+ [A-Z]+ "/ {
        pre=$0; sub(/".*$/,"",pre)
        v=$0; sub(/^[^"]*"/,"",v); post=v; sub(/^[^"]*"/,"",post); sub(/".*$/,"",v)
        n=split(v,a,"/"); print pre "\"" a[n] "\"" post; next }
    { print }' "$1"
}

# --- Ligne de progression (calcul et rendu) ---------------------------------
# args : octets_fichier taille_fichier octets_précédents secondes_écoulées secondes_delta
#        octets_déjà_copiés(global) total(global) fin_de_ligne
progress_line() {
    awk -v c="$1" -v s="$2" -v p="$3" -v el="$4" -v dt="$5" -v done="$6" -v tot="$7" -v eol="$8" '
    function h(b,  u,i){split("o Ko Mo Go To",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++};return sprintf("%.1f %s",b,u[i])}
    function hms(x){x=int(x);return sprintf("%02d:%02d:%02d",x/3600,(x%3600)/60,x%60)}
    BEGIN{
      if (s<=0) s=1; if (dt<=0) dt=1; if (el<=0) el=1
      pct=c*100/s; if (pct>100) pct=100
      cur=(c-p)/dt; if (cur<0) cur=0; avg=c/el
      eta=(avg>0)? (s-c)/avg : 0
      w=25; f=int(pct*w/100); bar=""
      for(i=0;i<w;i++) bar=bar (i<f ? "#" : ".")
      g=(tot>0)? (done+c)*100/tot : 0
      printf "  [%s] %5.1f%%  %s / %s  débit %s/s  moy %s/s  reste %s  | global %4.1f%%%s",
             bar, pct, h(c), h(s), h(cur), h(avg), hms(eta), g, eol
    }'
}

# Surveillance en arrière-plan : taille du fichier distant à intervalle régulier
monitor() { # $1 chemin distant, $2 taille attendue, $3 octets déjà copiés (global)
    _prev=0; _t0=$(date +%s); _tp=$_t0
    while :; do
        sleep "$PINT"
        _c=$(rsh "stat -c %s $(q "$1") 2>/dev/null" </dev/null); [ -n "$_c" ] || _c=0
        _now=$(date +%s)
        progress_line "$_c" "$2" "$_prev" $((_now - _t0)) $((_now - _tp)) "$3" "$TOTAL" "$EOL" >&2
        _prev=$_c; _tp=$_now
    done
}

# Mode test (validation hors ESXi) : ./esxi-vm-move.sh --selftest-vmx|--selftest-desc fichier
case "${1:-}" in
    --selftest-vmx)  rewrite_vmx "$2";  exit 0 ;;
    --selftest-desc) rewrite_desc "$2"; exit 0 ;;
    --selftest-progress) shift; progress_line "$@"; echo; exit 0 ;;
esac

# --- Arguments ---------------------------------------------------------------
while getopts "d:p:ztrT:yni:" o; do
    case "$o" in
        d) DEST="$OPTARG" ;;  p) DPATH="${OPTARG%/}" ;;
        z) GZIP=1 ;;          t) THIN=1 ;;          r) REG=1 ;;
        T) TMO="$OPTARG" ;;   y) YES=1 ;;           n) DRY=1 ;;
        i) PINT="$OPTARG" ;;
        *) usage; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
VMARG="${1:-}"
[ -n "$DEST" ] && [ -n "$DPATH" ] || { usage; exit 2; }
# Terminal : ligne réécrite sur place ; sinon (nohup/log) : une ligne par mesure
if [ -t 2 ]; then EOL=$(printf '\r'); : "${PINT:=2}"; else EOL=$(printf '\n_'); EOL=${EOL%_}; : "${PINT:=30}"; fi
[ -n "$PINT" ] || PINT=2
command -v vim-cmd >/dev/null 2>&1 || die "vim-cmd introuvable : ce script doit tourner sur l'ESXi source"
mkdir -p "$WORK" || die "Impossible de créer $WORK"
: > "$WORK/descs"; : > "$WORK/data"; : > "$WORK/flat"

# --- Choix de la VM ----------------------------------------------------------
vim-cmd vmsvc/getallvms 2>/dev/null \
  | sed -nE 's/^([0-9]+) +([^[]*[^ []) +\[([^]]+)\] (.*\.vmx)( .*)?$/\1|\2|\3|\4/p' > "$WORK/vms"
[ -s "$WORK/vms" ] || die "Aucune VM enregistrée sur cet hôte"

if [ -z "$VMARG" ]; then
    printf '\n%6s  %-40s %-12s %s\n' "Vmid" "Nom" "État" "Fichier"
    while IFS='|' read -r id name ds rel <&3; do
        printf '%6s  %-40s %-12s [%s] %s\n' "$id" "$name" "$(pstate "$id")" "$ds" "$rel"
    done 3< "$WORK/vms"
    printf '\nVmid (ou nom) de la VM à migrer : '; read -r VMARG </dev/tty
fi
awk -F'|' -v a="$VMARG" '$1==a || $2==a' "$WORK/vms" > "$WORK/sel"
[ "$(wc -l < "$WORK/sel")" -eq 1 ] || die "VM « $VMARG » introuvable ou ambiguë"
IFS='|' read -r VMID VMNAME DS REL < "$WORK/sel"
VMX="/vmfs/volumes/$DS/$REL"
VMDIR=$(dirname "$VMX")
DDIR="$DPATH/$(basename "$VMDIR")"
[ -f "$VMX" ] || die "Fichier vmx introuvable : $VMX"
log "VM : $VMNAME (Vmid $VMID) — $VMX"

# --- Inventaire des disques (y compris hors dossier VM et chaînes de snapshots) ---
grep -iE '^[a-z]+[0-9]+:[0-9]+\.filename *= *".*\.vmdk"' "$VMX" \
  | sed -E 's/^[^"]*"(.*)"[^"]*$/\1/' > "$WORK/vmdks"

while IFS= read -r d <&4; do
    cur=$(absof "$VMDIR" "$d")
    while [ -n "$cur" ]; do
        grep -qxF "$cur" "$WORK/descs" && break
        [ -f "$cur" ] || die "Descripteur introuvable : $cur"
        head -c 2048 "$cur" | grep -q 'Disk DescriptorFile' \
            || die "$cur n'est pas un descripteur VMDK texte"
        printf '%s\n' "$cur" >> "$WORK/descs"
        cdir=$(dirname "$cur")
        sed -nE 's/^(RW|RDONLY|NOACCESS) [0-9]+ ([A-Z]+) "([^"]+)".*/\2|\3/p' "$cur" > "$WORK/ext"
        while IFS='|' read -r typ f <&5; do
            case "$typ" in
                VMFSRDM|VMFSRAW|VMFSPASSTHROUGHRAW)
                    die "RDM détecté ($cur) : non copiable, à traiter séparément" ;;
                VMFS) printf '%s\n' "$cur" >> "$WORK/flat" ;;
            esac
            e=$(absof "$cdir" "$f")
            [ -f "$e" ] || die "Extent introuvable : $e"
            printf '%s\n' "$e" >> "$WORK/data"
        done 5< "$WORK/ext"
        p=$(sed -nE 's/^parentFileNameHint="(.*)"/\1/p' "$cur")
        if [ -n "$p" ]; then HASSNAP=1; cur=$(absof "$cdir" "$p"); else cur=""; fi
    done
done 4< "$WORK/vmdks"

# Dossier de la VM (hors swap, verrous et fichiers CBT)
find "$VMDIR" -maxdepth 1 -type f ! -name '*.vswp' ! -name '*-ctk.vmdk' ! -name '*.lck' > "$WORK/dir"
cat "$WORK/dir" "$WORK/descs" "$WORK/data" | sort -u > "$WORK/all"
N=$(wc -l < "$WORK/all")

# Collisions de noms (deux disques homonymes sur deux datastores)
while IFS= read -r f; do basename "$f"; done < "$WORK/all" | sort | uniq -d > "$WORK/dup"
[ -s "$WORK/dup" ] && die "Noms de fichiers en double, renommer d'abord : $(tr '\n' ' ' < "$WORK/dup")"

TOTAL=$(while IFS= read -r f; do stat -c %s "$f"; done < "$WORK/all" | awk '{s+=$1} END{printf "%.0f", s}')
EXT=$(grep -cvF "$VMDIR/" "$WORK/all")
log "$N fichiers, $(human "$TOTAL") (taille logique), dont $EXT hors du dossier de la VM"
[ "$HASSNAP" -eq 1 ] && warn "la VM a des snapshots : chaîne copiée telle quelle (consolider avant est préférable)"
grep -iqE '^[a-z]+[0-9]+:[0-9]+\.filename *= *"/vmfs/.*\.iso"' "$VMX" \
    && warn "une ISO est montée depuis un datastore : elle ne sera pas copiée"
[ "$EXT" -gt 0 ] && grep -vF "$VMDIR/" "$WORK/all" | sed 's/^/      hors dossier : /'

# --- Pare-feu ESXi : client SSH sortant ---------------------------------------
if ! esxcli network firewall ruleset list -r sshClient 2>/dev/null | grep -q true; then
    log "Ouverture temporaire de la règle de pare-feu sshClient"
    esxcli network firewall ruleset set -e true -r sshClient || die "Impossible d'ouvrir sshClient"
    FW_ENABLED=1
fi

# --- Contrôles destination ---------------------------------------------------
log "Connexion à $DEST (mot de passe demandé une seule fois si pas de clé SSH)"
rsh "true" </dev/null || die "Connexion SSH impossible vers $DEST"
rsh "test -d $(q "$DPATH")" </dev/null || die "Chemin de destination inexistant : $DPATH"
rsh "test -e $(q "$DDIR")" </dev/null && die "La destination existe déjà : $DDIR"
DSROOT=$(printf '%s' "$DPATH" | cut -d/ -f1-4)
AVAIL=$(rsh "vmkfstools -Pv10 $(q "$DSROOT")" </dev/null 2>/dev/null \
        | sed -nE 's/.*, ([0-9]+) \([0-9]+ blocks\) avail.*/\1/p')
if [ -n "$AVAIL" ]; then
    log "Espace libre à destination : $(human "$AVAIL")"
    awk -v a="$AVAIL" -v t="$TOTAL" 'BEGIN{exit !(a < t*1.05)}' \
        && die "Espace insuffisant à destination ($(human "$AVAIL") < $(human "$TOTAL") + 5 %)"
else
    warn "espace libre à destination non vérifié"
fi

if [ "$DRY" -eq 1 ]; then
    log "Simulation — fichiers qui seraient copiés vers $DEST:$DDIR :"
    while IFS= read -r f; do printf '      %10s  %s\n' "$(human "$(stat -c %s "$f")")" "$f"; done < "$WORK/all"
    exit 0
fi

# --- Arrêt de la VM -----------------------------------------------------------
ST=$(pstate "$VMID")
case "$ST" in
    "Powered off") log "VM déjà arrêtée" ;;
    "Suspended")   ask "VM suspendue : la copier dans cet état ?" || die "Abandon" ;;
    *)
        ask "Arrêter la VM $VMNAME (Vmid $VMID) ?" || die "Abandon"
        if vim-cmd vmsvc/power.shutdown "$VMID" >/dev/null 2>&1; then
            log "Arrêt propre demandé (VMware Tools), attente ${TMO}s maximum"
            t=0
            while [ "$t" -lt "$TMO" ]; do
                sleep 5; t=$((t + 5))
                [ "$(pstate "$VMID")" = "Powered off" ] && break
            done
        else
            warn "arrêt propre impossible (VMware Tools absents ou arrêtés ?)"
        fi
        if [ "$(pstate "$VMID")" != "Powered off" ]; then
            ask "La VM tourne encore : forcer l'arrêt (power off) ?" || die "Abandon, VM toujours démarrée"
            vim-cmd vmsvc/power.off "$VMID" >/dev/null || die "Échec du power off"
        fi
        sleep 3
        log "VM arrêtée"
        ;;
esac

# --- Copie --------------------------------------------------------------------
rewrite_vmx "$VMX" > "$WORK/out.vmx"
rsh "mkdir -p $(q "$DDIR")" </dev/null || die "Création de $DDIR impossible"
log "Copie vers $DEST:$DDIR (compression : $([ "$GZIP" -eq 1 ] && echo oui || echo non))"
i=0; DONE=0; START=$(date +%s)
while IFS= read -r f <&3; do
    i=$((i + 1)); b=$(basename "$f"); src="$f"
    if [ "$f" = "$VMX" ]; then
        src="$WORK/out.vmx"
    elif grep -qxF "$f" "$WORK/descs"; then
        rewrite_desc "$f" > "$WORK/desc.$i"; src="$WORK/desc.$i"
    fi
    sz=$(stat -c %s "$src"); t0=$(date +%s)
    log "[$i/$N] $b ($(human "$sz"))"
    # Barre de progression pour les fichiers de plus de 64 Mo
    PPID_MON=""
    if awk -v s="$sz" 'BEGIN{exit !(s > 67108864)}'; then
        monitor "$DDIR/$b" "$sz" "$DONE" &
        PPID_MON=$!
    fi
    if [ "$GZIP" -eq 1 ] && [ "$sz" -gt 1048576 ]; then
        gzip -1 -c "$src" | rsh "gunzip -c > $(q "$DDIR/$b")"
    else
        rsh "cat > $(q "$DDIR/$b")" < "$src"
    fi
    if [ -n "$PPID_MON" ]; then
        kill "$PPID_MON" 2>/dev/null; wait "$PPID_MON" 2>/dev/null; PPID_MON=""
        [ -t 2 ] && printf '\r\033[K' >&2
    fi
    DONE=$(awk -v a="$DONE" -v b="$sz" 'BEGIN{printf "%.0f", a+b}')
    rs=$(rsh "stat -c %s $(q "$DDIR/$b")" </dev/null)
    [ "$rs" = "$sz" ] || die "Taille différente pour $b (source $sz / destination ${rs:-absent})"
    dt=$(( $(date +%s) - t0 )); [ "$dt" -eq 0 ] && dt=1
    log "      OK en ${dt}s — $(human "$(awk -v s="$sz" -v d="$dt" 'BEGIN{printf "%.0f", s/d}')")/s"
done 3< "$WORK/all"

# --- Re-thin optionnel --------------------------------------------------------
if [ "$THIN" -eq 1 ]; then
    if [ "$HASSNAP" -eq 1 ]; then
        warn "snapshots présents : re-thin ignoré (il casserait la chaîne)"
    else
        sort -u "$WORK/flat" | while IFS= read -r f; do
            b=$(basename "$f"); tb="${b%.vmdk}-thin.vmdk"
            log "Re-thin de $b"
            rsh "cd $(q "$DDIR") && vmkfstools -i $(q "$b") -d thin $(q "$tb") && vmkfstools -U $(q "$b") && vmkfstools -E $(q "$tb") $(q "$b")" </dev/null \
                || warn "re-thin échoué pour $b (le disque thick reste utilisable)"
        done
    fi
fi

# --- Enregistrement optionnel -------------------------------------------------
if [ "$REG" -eq 1 ]; then
    NEWID=$(rsh "vim-cmd solo/registervm $(q "$DDIR/$(basename "$VMX")")" </dev/null) \
        && log "VM enregistrée sur $DEST (Vmid $NEWID)" \
        || warn "enregistrement échoué : à faire à la main dans l'interface de l'hôte"
fi

DUR=$(( $(date +%s) - START )); [ "$DUR" -eq 0 ] && DUR=1
log "Terminé : $(human "$TOTAL") en $((DUR / 60)) min $((DUR % 60)) s — moyenne $(human "$(awk -v s="$TOTAL" -v d="$DUR" 'BEGIN{printf "%.0f", s/d}')")/s"
cat <<EOF

À faire ensuite :
  - La VM source reste enregistrée et ARRÊTÉE sur cet hôte (retour arrière possible).
    Ne jamais démarrer les deux copies en même temps.
  - Au premier démarrage à destination, répondre « I Moved It » (conserve UUID et MAC).
  - Le suivi CBT a été réinitialisé : prévoir une sauvegarde complète.
  - Après validation, désinscrire puis supprimer la VM source.
EOF
