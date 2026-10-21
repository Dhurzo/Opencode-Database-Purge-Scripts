#!/usr/bin/env bash
#
# opencode-cleanup.sh — keep only the last N months of conversations
# and compact the opencode database to reclaim space.
#
# It does 6 things:
#   1. Deletes sessions older than the cutoff from opencode.db (and their
#      descendants if parent_id exists), cascading to messages, parts,
#      events, todos, shares, and context epochs.
#   2. Deletes orphaned session, message, project, and plugin files from
#      ~/.local/share/opencode/storage (files no longer referenced by the DB).
#   3. (Optional) empties "reasoning" blocks (--strip-reasoning) and/or tool
#      output (--strip-tool-output).
#   4. (Optional) prunes the event log by age (--events-older-than).
#   5. Compacts the .db file: WAL checkpoint + auto_vacuum=INCREMENTAL
#      (full VACUUM the first time; incremental_vacuum afterwards).
#   6. Serializes concurrent runs with flock and verifies integrity
#      before/after (quick_check by default; --full-check for integrity_check).
#
# Usage:
#   opencode-cleanup.sh [--months N] [--yes] [--force] [--dry-run]
#                        [--vacuum-only] [--strip-reasoning] [--strip-tool-output]
#                        [--events-older-than DAYS] [--backup] [--backup-keep N]
#                        [--by-updated] [--keep-session ID] [--keep-project ID]
#                        [--full-check] [--skip-space-check]
#
#   --months N          retention in months, integer >= 1 (default: 2)
#   --yes               run without asking for confirmation (does NOT disable
#                       the in-use DB check)
#   --force             ignore the check for processes using the DB
#                       (dangerous; only if you know what you are doing)
#   --dry-run           only show what would be deleted, without touching anything
#   --vacuum-only       delete NOTHING: only compact the DB
#   --strip-reasoning   empty the text of "reasoning" blocks
#   --strip-tool-output empty state.output/state.metadata on tool blocks
#   --events-older-than DAYS  delete events for sessions inactive for
#                       DAYS days (keeps event_sequence)
#   --backup            consistent backup (.backup) before writing
#   --backup-keep N     keep the N most recent backups (0 = all; default: 3)
#   --by-updated        retention by time_updated instead of time_created
#   --keep-session ID   do not delete that session (repeatable)
#   --keep-project ID   do not delete sessions from that project (repeatable)
#   --full-check        use PRAGMA integrity_check instead of quick_check
#   --skip-space-check  skip the free-space check before VACUUM/backup
#
# Safety: quick_check/integrity_check before and after, detection of
# processes using the DB (pgrep + fuser on the file and the WAL), flock to
# prevent concurrent runs, and auto_vacuum=INCREMENTAL to keep the DB from
# bloating again after cleanup.
#
# Environment variables:
#   OPENCODE_DIR          path to ~/.local/share/opencode
#   OPENCODE_CLEANUP_LOCK path to the single-instance lock

set -euo pipefail
export LC_ALL=C

MONTHS=2
YES=0
FORCE=0
DRY_RUN=0
VACUUM_ONLY=0
STRIP=0
STRIP_TOOL=0
BACKUP=0
BACKUP_KEEP=3
BY_UPDATED=0
EVENTS_DAYS=""
FULL_CHECK=0
SKIP_SPACE_CHECK=0
KEEP_SESSIONS=()
KEEP_PROJECTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --months)
      [[ $# -ge 2 ]] || { printf 'ERROR: --months necesita un valor (entero >= 1)\n' >&2; exit 1; }
      MONTHS="$2"; shift 2 ;;
    --yes) YES=1; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --vacuum-only) VACUUM_ONLY=1; shift ;;
    --strip-reasoning) STRIP=1; shift ;;
    --strip-tool-output) STRIP_TOOL=1; shift ;;
    --events-older-than)
      [[ $# -ge 2 ]] || { printf 'ERROR: --events-older-than necesita un valor (días >= 1)\n' >&2; exit 1; }
      EVENTS_DAYS="$2"; shift 2 ;;
    --backup) BACKUP=1; shift ;;
    --backup-keep)
      [[ $# -ge 2 ]] || { printf 'ERROR: --backup-keep necesita un valor (entero >= 0)\n' >&2; exit 1; }
      BACKUP_KEEP="$2"; shift 2 ;;
    --by-updated) BY_UPDATED=1; shift ;;
    --keep-session)
      [[ $# -ge 2 ]] || { printf 'ERROR: --keep-session necesita un ID\n' >&2; exit 1; }
      KEEP_SESSIONS+=("$2"); shift 2 ;;
    --keep-project)
      [[ $# -ge 2 ]] || { printf 'ERROR: --keep-project necesita un ID\n' >&2; exit 1; }
      KEEP_PROJECTS+=("$2"); shift 2 ;;
    --full-check) FULL_CHECK=1; shift ;;
    --skip-space-check) SKIP_SPACE_CHECK=1; shift ;;
    -h|--help) awk 'NR==1{next} /^#/{gsub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) printf 'Opción desconocida: %s (--help para ayuda)\n' "$1" >&2; exit 1 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Defensa en profundidad: valores numéricos validados antes de usarlos.
[[ "$MONTHS" =~ ^[0-9]+$ ]] || die "--months debe ser un entero >= 1 (recibido: '$MONTHS')."
(( MONTHS >= 1 ))           || die "--months debe ser >= 1 (recibido: $MONTHS)."
[[ "$BACKUP_KEEP" =~ ^[0-9]+$ ]] || die "--backup-keep debe ser un entero >= 0 (recibido: '$BACKUP_KEEP')."
if [[ -n "$EVENTS_DAYS" ]]; then
  [[ "$EVENTS_DAYS" =~ ^[0-9]+$ ]] || die "--events-older-than debe ser un entero >= 1 (recibido: '$EVENTS_DAYS')."
  (( EVENTS_DAYS >= 1 ))           || die "--events-older-than debe ser >= 1 (recibido: $EVENTS_DAYS)."
fi
for id in "${KEEP_SESSIONS[@]}"; do
  [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || die "--keep-session contiene un ID inválido: '$id'."
done
for id in "${KEEP_PROJECTS[@]}"; do
  [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || die "--keep-project contiene un ID inválido: '$id'."
done

OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.local/share/opencode}"
DB="$OPENCODE_DIR/opencode.db"
STORAGE="$OPENCODE_DIR/storage"
CUTOFF_MS=$(date -d "$MONTHS months ago" +%s%3N) || die "no pude calcular la fecha de corte (se requiere GNU date)."
[[ "$CUTOFF_MS" =~ ^[0-9]+$ ]] || die "tu 'date' no soporta +%s%3N (se requiere GNU coreutils)."

# Directorio de runtime propiedad del usuario para locks (evita symlinks en /tmp).
if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
  RUNTIME_DIR="$XDG_RUNTIME_DIR/opencode-purge"
else
  RUNTIME_DIR="/tmp/opencode-purge-$UID"
fi
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
CLEANUP_LOCK="${OPENCODE_CLEANUP_LOCK:-$RUNTIME_DIR/cleanup.lock}"

# Directorios de storage indexados por sesión (claves ses_*); en todos ellos
# los ficheros/directorios cuelgan directamente del directorio.
SES_DIRS=(message session_diff todo agent-usage-reminder directory-readme rules-injector)

[[ -f "$DB" ]]                  || die "no encuentro $DB"
command -v sqlite3 >/dev/null   || die "sqlite3 no está instalado"
[[ $VACUUM_ONLY -eq 0 || $STRIP -eq 0 ]] || die "--strip-reasoning es incompatible con --vacuum-only."
[[ $VACUUM_ONLY -eq 0 || $STRIP_TOOL -eq 0 ]] || die "--strip-tool-output es incompatible con --vacuum-only."
[[ $VACUUM_ONLY -eq 0 || -z "$EVENTS_DAYS" ]] || die "--events-older-than es incompatible con --vacuum-only."

# Sanity check: que $DB parezca una BD de opencode.
N_CORE=$(sqlite3 "$DB" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('session','message','part','event_sequence');")
[[ "$N_CORE" == "4" ]] || die "$DB no parece una BD de opencode (faltan tablas core: session/message/part/event_sequence)."

# Tablas/columnas opcionales según versión de opencode.
HAS_PROJECT=1
sqlite3 "$DB" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='project' LIMIT 1;" | grep -q 1 || HAS_PROJECT=0
HAS_PARENT=1
sqlite3 "$DB" "SELECT 1 FROM pragma_table_info('session') WHERE name='parent_id' LIMIT 1;" | grep -q 1 || HAS_PARENT=0
HAS_UPDATED=1
sqlite3 "$DB" "SELECT 1 FROM pragma_table_info('session') WHERE name='time_updated' LIMIT 1;" | grep -q 1 || HAS_UPDATED=0
HAS_EVENT=1
sqlite3 "$DB" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='event' LIMIT 1;" | grep -q 1 || HAS_EVENT=0

[[ $BY_UPDATED -eq 0 || $HAS_UPDATED -eq 1 ]] || die "--by-updated requiere la columna session.time_updated."
[[ $HAS_PROJECT -eq 1 || ${#KEEP_PROJECTS[@]} -eq 0 ]] || die "--keep-project requiere la tabla project."
[[ $HAS_EVENT -eq 1 || -z "$EVENTS_DAYS" ]] || die "--events-older-than requiere la tabla event."

size_mb() { # Suma el fichero principal + sus sidecars WAL/SHM (modo WAL)
  local total=0
  for f in "$1" "$1-wal" "$1-shm"; do
    [[ -f "$f" ]] || continue
    local mb
    mb=$(du -sm "$f" 2>/dev/null | cut -f1)
    total=$(( total + ${mb:-0} ))
  done
  echo "$total"
}

# Número de líneas no vacías de un string multi-línea.
nlines() { printf '%s' "$1" | grep -c -v '^$' || true; }

# Escapa una lista de IDs ya validados como literales SQL.
sql_list() { local out="" x; for x in "$@"; do out+="${out:+,}'$x'"; done; printf '%s' "$out"; }

# Claves de un directorio (nombres), filtrando por regex y quitando .json.
list_keys() {
  find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null \
    | sed -E 's/\.json$//' | grep -E "$2" || true
}

DB_BEFORE=$(size_mb "$DB")
STORAGE_BEFORE=$(size_mb "$STORAGE")

say "== Limpieza de conversaciones de opencode =="
say "  BD:       $DB"
if [[ $VACUUM_ONLY -eq 1 ]]; then
  say "  Modo:     --vacuum-only (no se borra nada, solo compactar)"
else
  RETENTION_COL="time_created"
  [[ $BY_UPDATED -eq 1 ]] && RETENTION_COL="time_updated"
  say "  Cutoff:   $(date -d @$((CUTOFF_MS/1000)) '+%F %T')  (sesiones sin actividad desde entonces; columna: $RETENTION_COL)"
fi
say "  BD ahora:       ${DB_BEFORE} MB"
say "  Storage ahora:  ${STORAGE_BEFORE} MB"

# ---- 1/2. Sesiones antiguas (incl. descendientes) y huérfanos de storage ----
KEEP_SESS_SQL=""
(( ${#KEEP_SESSIONS[@]} > 0 )) && KEEP_SESS_SQL=$(sql_list "${KEEP_SESSIONS[@]}")
KEEP_PROJ_SQL=""
(( ${#KEEP_PROJECTS[@]} > 0 )) && KEEP_PROJ_SQL=$(sql_list "${KEEP_PROJECTS[@]}")

DOOMED=()
OLD_MESSAGES=()
N_SESS=0
N_OLD_MSGS=0
N_EVENTS=0
EV_BYTES=0
N_STRIP=0
STRIP_BYTES=0
N_TOOL=0
TOOL_BYTES=0

VALID_SESS=$(mktemp); VALID_MSG=$(mktemp); VALID_PROJ=$(mktemp)
SES_KEYS=$(mktemp);   MSG_KEYS=$(mktemp);  PROJ_KEYS=$(mktemp)
ALL_SESS=$(mktemp);   ALL_MSG=$(mktemp)
trap 'rm -f "$VALID_SESS" "$VALID_MSG" "$VALID_PROJ" "$SES_KEYS" "$MSG_KEYS" "$PROJ_KEYS" "$ALL_SESS" "$ALL_MSG"' EXIT

if [[ $VACUUM_ONLY -eq 0 ]]; then
  RETENTION_COL="time_created"
  [[ $BY_UPDATED -eq 1 ]] && RETENTION_COL="time_updated"
  ROOT_WHERE="$RETENTION_COL < $CUTOFF_MS"
  [[ -n "$KEEP_SESS_SQL" ]] && ROOT_WHERE+=" AND id NOT IN ($KEEP_SESS_SQL)"
  [[ -n "$KEEP_PROJ_SQL" ]] && ROOT_WHERE+=" AND project_id NOT IN ($KEEP_PROJ_SQL)"

  KEEP_CHILD_FILTER=""
  [[ -n "$KEEP_SESS_SQL" ]] && KEEP_CHILD_FILTER=" AND s.id NOT IN ($KEEP_SESS_SQL)"
  if [[ $HAS_PARENT -eq 1 ]]; then
    DOOM_CTE="WITH RECURSIVE doomed(id) AS (
      SELECT id FROM session WHERE $ROOT_WHERE
      UNION
      SELECT s.id FROM session s JOIN doomed d ON s.parent_id = d.id WHERE 1=1$KEEP_CHILD_FILTER
    )"
  else
    DOOM_CTE="WITH doomed(id) AS (SELECT id FROM session WHERE $ROOT_WHERE)"
  fi

  mapfile -t DOOMED < <(sqlite3 "$DB" "$DOOM_CTE SELECT id FROM doomed;")
  N_SESS=${#DOOMED[@]}
  DOOMED_SQL=""
  if (( N_SESS > 0 )); then
    for id in "${DOOMED[@]}"; do
      [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || die "ID de sesión inseguro en la BD: '$id'."
    done
    DOOMED_SQL=$(sql_list "${DOOMED[@]}")
    mapfile -t OLD_MESSAGES < <(sqlite3 "$DB" "$DOOM_CTE SELECT id FROM message WHERE session_id IN (SELECT id FROM doomed);")
    N_OLD_MSGS=${#OLD_MESSAGES[@]}
  fi

  # Huérfanos de storage: las claves ya llevan el prefijo (ses_*, msg_*).
  sqlite3 "$DB" "SELECT id FROM session" | sort > "$VALID_SESS"
  sqlite3 "$DB" "SELECT id FROM message" | sort > "$VALID_MSG"
  if [[ $HAS_PROJECT -eq 1 ]]; then
    sqlite3 "$DB" "SELECT id FROM project" | sort > "$VALID_PROJ"
  else
    : > "$VALID_PROJ"
  fi

  for dir in "${SES_DIRS[@]}"; do
    [[ -d "$STORAGE/$dir" ]] && list_keys "$STORAGE/$dir" '^ses_' >> "$SES_KEYS" || true
  done
  # Plugins que guardan ficheros por sesión: storage/plugin/<plugin>/ses_*.json
  if [[ -d "$STORAGE/plugin" ]]; then
    for pdir in "$STORAGE/plugin"/*/; do
      [[ -d "$pdir" ]] || continue
      list_keys "$pdir" '^ses_' >> "$SES_KEYS" || true
    done
  fi
  # Claves ses_* anidadas en storage/session/<proyecto>/ (proyectos válidos).
  if [[ $HAS_PROJECT -eq 1 && -d "$STORAGE/session" ]]; then
    for pdir in "$STORAGE/session"/*/; do
      [[ -d "$pdir" ]] || continue
      grep -qx "$(basename "$pdir")" "$VALID_PROJ" || continue
      list_keys "$pdir" '^ses_' >> "$SES_KEYS" || true
    done
  fi
  sort -u -o "$SES_KEYS" "$SES_KEYS"

  [[ -d "$STORAGE/part" ]] && list_keys "$STORAGE/part" '^msg_' | sort -u > "$MSG_KEYS" || true

  # Claves de proyecto: storage/project/* y storage/session/<id>/.
  if [[ $HAS_PROJECT -eq 1 ]]; then
    [[ -d "$STORAGE/project" ]] && list_keys "$STORAGE/project" '^([0-9a-f]{8,}|global)$' >> "$PROJ_KEYS" || true
    if [[ -d "$STORAGE/session" ]]; then
      for pdir in "$STORAGE/session"/*/; do
        [[ -d "$pdir" ]] && basename "$pdir" | grep -E '^([0-9a-f]{8,}|global)$' >> "$PROJ_KEYS" || true
      done
    fi
    sort -u -o "$PROJ_KEYS" "$PROJ_KEYS"
  fi

  ORPHAN_SESS=$(comm -23 "$SES_KEYS" "$VALID_SESS")
  ORPHAN_MSG=$(comm -23 "$MSG_KEYS" "$VALID_MSG")
  ORPHAN_PROJ=""
  [[ $HAS_PROJECT -eq 1 ]] && ORPHAN_PROJ=$(comm -23 "$PROJ_KEYS" "$VALID_PROJ")
  N_ORPH_SESS=$(nlines "$ORPHAN_SESS")
  N_ORPH_MSG=$(nlines "$ORPHAN_MSG")
  N_ORPH_PROJ=$(nlines "$ORPHAN_PROJ")

  { printf '%s\n' "$ORPHAN_SESS"; printf '%s\n' ${DOOMED[@]+"${DOOMED[@]}"}; } | sort -u > "$ALL_SESS"
  { printf '%s\n' "$ORPHAN_MSG";   printf '%s\n' ${OLD_MESSAGES[@]+"${OLD_MESSAGES[@]}"}; } | sort -u > "$ALL_MSG"

  say ""
  if [[ $BY_UPDATED -eq 1 ]]; then
    say "Sesiones a borrar de la BD (sin actividad desde hace $MONTHS meses; incluye descendientes): $N_SESS"
  else
    say "Sesiones a borrar de la BD (creadas antes de $MONTHS meses; incluye descendientes): $N_SESS"
  fi
  say "Mensajes de esas sesiones (cascada; sus parts de storage/ se borran también): $N_OLD_MSGS"
  say "Huérfanos en storage (ya no existen en la BD): $N_ORPH_SESS claves ses_*, $N_ORPH_MSG claves msg_*, $N_ORPH_PROJ proyectos"

  if [[ $STRIP -eq 1 ]]; then
    read -r N_STRIP STRIP_BYTES < <(
      sqlite3 -separator ' ' "$DB" "SELECT COUNT(*), COALESCE(SUM(length(json_extract(data,'\$.text'))),0)
                       FROM part WHERE json_valid(data) AND json_extract(data,'\$.type')='reasoning';"
    )
    say "Bloques 'reasoning' a vaciar (--strip-reasoning): ${N_STRIP:-0} ($(( ${STRIP_BYTES:-0} / 1048576 )) MB de texto)"
  fi
  if [[ $STRIP_TOOL -eq 1 ]]; then
    read -r N_TOOL TOOL_BYTES < <(
      sqlite3 -separator ' ' "$DB" "SELECT COUNT(*), COALESCE(SUM(length(json_extract(data,'\$.state.output'))),0)
                       FROM part WHERE json_valid(data) AND json_extract(data,'\$.type')='tool'
                         AND json_type(data,'\$.state')='object';"
    )
    say "Bloques 'tool' a vaciar (--strip-tool-output): ${N_TOOL:-0} ($(( ${TOOL_BYTES:-0} / 1048576 )) MB de output)"
  fi
  if [[ -n "$EVENTS_DAYS" ]]; then
    EVENTS_CUTOFF_MS=$(date -d "$EVENTS_DAYS days ago" +%s%3N) || die "no pude calcular el cutoff de eventos."
    EVENT_TIME_EXPR="time_created"
    [[ $HAS_UPDATED -eq 1 ]] && EVENT_TIME_EXPR="COALESCE(time_updated,time_created)"
    EVENT_KEEP_FILTER=""
    [[ -n "$KEEP_SESS_SQL" ]] && EVENT_KEEP_FILTER+=" AND id NOT IN ($KEEP_SESS_SQL)"
    [[ -n "$KEEP_PROJ_SQL" ]] && EVENT_KEEP_FILTER+=" AND project_id NOT IN ($KEEP_PROJ_SQL)"
    read -r N_EVENTS EV_BYTES < <(
      sqlite3 -separator ' ' "$DB" "SELECT COUNT(*), COALESCE(SUM(length(data)),0) FROM event
        WHERE aggregate_id IN (SELECT id FROM session WHERE $EVENT_TIME_EXPR < $EVENTS_CUTOFF_MS$EVENT_KEEP_FILTER);"
    )
    say "Eventos a podar (--events-older-than $EVENTS_DAYS): ${N_EVENTS:-0} ($(( ${EV_BYTES:-0} / 1048576 )) MB)"
  fi
fi

FREELIST_BEFORE=$(sqlite3 "$DB" "PRAGMA freelist_count;")
PAGE_SIZE=$(sqlite3 "$DB" "PRAGMA page_size;")
say "Páginas libres en la BD: $FREELIST_BEFORE ($(( FREELIST_BEFORE * PAGE_SIZE / 1048576 )) MB)"
say ""

if [[ $DRY_RUN -eq 1 ]]; then
  say "Modo --dry-run: no se ha hecho nada. Ejecuta sin --dry-run para limpiar."
  exit 0
fi

# ---- 3. Lock de instancia única --------------------------------------------
command -v flock >/dev/null 2>&1 || die "falta 'flock' (util-linux); necesario para evitar ejecuciones concurrentes."
exec 8>"$CLEANUP_LOCK" || die "no puedo abrir el lock $CLEANUP_LOCK"
if ! flock -n 8; then
  die "ya hay otra limpieza en marcha (lock: $CLEANUP_LOCK)."
fi

# ---- 4. Comprobar que nadie esté usando la BD ------------------------------
IN_USE=0
if command -v pgrep >/dev/null 2>&1; then
  pgrep -x opencode >/dev/null && IN_USE=1
else
  say "AVISO: pgrep no disponible; no puedo comprobar si opencode está en marcha."
fi
if command -v fuser >/dev/null 2>&1; then
  fuser -s "$DB" >/dev/null 2>&1 && IN_USE=1
  [[ -f "$DB-wal" ]] && fuser -s "$DB-wal" >/dev/null 2>&1 && IN_USE=1
fi
if [[ $IN_USE -eq 1 ]]; then
  if [[ $FORCE -eq 1 ]]; then
    say "AVISO: hay procesos usando la BD (--force dado, se continúa igualmente)."
  else
    die "La BD está en uso (opencode u otro proceso). Ciérralo antes de limpiar (o usa --force)."
  fi
fi

# ---- 5. Espacio libre antes de VACUUM/backup -------------------------------
DB_KB=$(du -sk "$DB" | cut -f1)
for f in "$DB-wal" "$DB-shm"; do
  [[ -f "$f" ]] && DB_KB=$(( DB_KB + $(du -sk "$f" | cut -f1) ))
done
if [[ $SKIP_SPACE_CHECK -eq 0 ]]; then
  NEED_KB=$DB_KB
  [[ $BACKUP -eq 1 ]] && NEED_KB=$(( NEED_KB * 2 ))
  AVAIL_KB=$(df -Pk "$(dirname "$DB")" | awk 'NR==2{print $4}')
  [[ "$AVAIL_KB" =~ ^[0-9]+$ ]] || die "no pude consultar el espacio libre en $(dirname "$DB")."
  if (( AVAIL_KB < NEED_KB )); then
    EXTRA=""
    [[ $BACKUP -eq 1 ]] && EXTRA=" (incluye backup)"
    die "espacio insuficiente en $(dirname "$DB"): libre $((AVAIL_KB/1024)) MB, necesario ~$((NEED_KB/1024)) MB$EXTRA. Usa --skip-space-check para omitir."
  fi
  say "  Espacio libre: $((AVAIL_KB/1024)) MB (necesario ~$((NEED_KB/1024)) MB)"
fi

# ---- 6. Confirmación -------------------------------------------------------
if [[ $YES -eq 0 ]]; then
  if [[ $VACUUM_ONLY -eq 1 ]]; then
    read -r -p "¿Compactar la BD (VACUUM)? [s/N] " ans
  elif [[ $STRIP -eq 1 || $STRIP_TOOL -eq 1 || -n "$EVENTS_DAYS" ]]; then
    read -r -p "¿Borrar sesiones, vaciar contenido y compactar? [s/N] " ans
  else
    read -r -p "¿Borrar y compactar? [s/N] " ans
  fi
  [[ "$ans" == "s" || "$ans" == "S" ]] || { say "Cancelado."; exit 1; }
fi

db_check() {
  if [[ $FULL_CHECK -eq 1 ]]; then
    sqlite3 "$DB" "PRAGMA integrity_check;"
  else
    sqlite3 "$DB" "PRAGMA quick_check;"
  fi
}

# ---- 7. Verificación de integridad + backup (antes de escribir) -----------
if [[ "$(db_check)" != "ok" ]]; then
  die "la comprobación de integridad no pasó antes de tocar la BD. No se modifica nada."
fi
say "  Integridad: OK ($([[ $FULL_CHECK -eq 1 ]] && echo integrity_check || echo quick_check))"

if [[ $BACKUP -eq 1 ]]; then
  BAK_DIR="$(dirname "$DB")/opencode.db.backup-$(date '+%Y%m%d-%H%M%S-%N')"
  mkdir -p "$BAK_DIR" || die "no se pudo crear $BAK_DIR"
  sqlite3 "$DB" ".backup '$BAK_DIR/opencode.db'" || die "falló el backup en $BAK_DIR"
  say "  Backup creado: $BAK_DIR/opencode.db"
  if (( BACKUP_KEEP > 0 )); then
    mapfile -t BAKS < <(find "$(dirname "$DB")" -maxdepth 1 -type d -name 'opencode.db.backup-*' -printf '%f\n' | sort)
    if (( ${#BAKS[@]} > BACKUP_KEEP )); then
      for ((i=0; i<${#BAKS[@]}-BACKUP_KEEP; i++)); do
        rm -rf -- "$(dirname "$DB")/${BAKS[$i]}" && say "  Backup antiguo borrado: ${BAKS[$i]}"
      done
    fi
  fi
fi

# ---- 8. Borrado en la BD (cascada + descendientes) ------------------------
if [[ $VACUUM_ONLY -eq 0 && $N_SESS -gt 0 ]]; then
  {
    printf 'PRAGMA foreign_keys=ON;\nBEGIN;\n'
    if [[ $HAS_PARENT -eq 1 && -n "$KEEP_SESS_SQL" ]]; then
      printf 'UPDATE session SET parent_id=NULL WHERE parent_id IN (%s) AND id IN (%s);\n' "$DOOMED_SQL" "$KEEP_SESS_SQL"
    fi
    printf 'DELETE FROM event_sequence WHERE aggregate_id IN (%s);\n' "$DOOMED_SQL"
    printf 'DELETE FROM session WHERE id IN (%s);\n' "$DOOMED_SQL"
    printf 'COMMIT;\n'
  } | sqlite3 "$DB"
  say "BD actualizada: $N_SESS sesiones borradas (mensajes, parts, events en cascada)."
elif [[ $VACUUM_ONLY -eq 0 ]]; then
  say "BD: no hay sesiones antiguas que borrar."
fi

# ---- 9. Podar el log de eventos (opcional) --------------------------------
# event_sequence se conserva para no reiniciar los números de secuencia.
if [[ $VACUUM_ONLY -eq 0 && -n "$EVENTS_DAYS" && ${N_EVENTS:-0} -gt 0 ]]; then
  EVENT_TIME_EXPR="time_created"
  [[ $HAS_UPDATED -eq 1 ]] && EVENT_TIME_EXPR="COALESCE(time_updated,time_created)"
  EVENT_KEEP_FILTER=""
  [[ -n "$KEEP_SESS_SQL" ]] && EVENT_KEEP_FILTER+=" AND id NOT IN ($KEEP_SESS_SQL)"
  [[ -n "$KEEP_PROJ_SQL" ]] && EVENT_KEEP_FILTER+=" AND project_id NOT IN ($KEEP_PROJ_SQL)"
  EVENT_DELETED=$(sqlite3 "$DB" <<SQL
BEGIN;
DELETE FROM event
 WHERE aggregate_id IN (SELECT id FROM session WHERE $EVENT_TIME_EXPR < $EVENTS_CUTOFF_MS$EVENT_KEEP_FILTER);
SELECT changes();
COMMIT;
SQL
  )
  say "  Eventos podados: ${EVENT_DELETED:-0} (event_sequence conservado)."
fi

# ---- 10. Vaciar bloques 'reasoning' / 'tool' (opcional) -------------------
if [[ $STRIP -eq 1 ]]; then
  STRIP_DONE=$(sqlite3 "$DB" <<SQL
PRAGMA foreign_keys=ON;
BEGIN;
UPDATE part
   SET data = json_set(data, '\$.text', '')
 WHERE json_valid(data) AND json_extract(data,'\$.type') = 'reasoning';
SELECT changes();
COMMIT;
SQL
  )
  say "  Razonamiento vaciado: ${STRIP_DONE:-0} bloques."
fi

if [[ $STRIP_TOOL -eq 1 ]]; then
  TOOL_DONE=$(sqlite3 "$DB" <<SQL
PRAGMA foreign_keys=ON;
BEGIN;
UPDATE part
   SET data = json_set(data, '\$.state.output', '', '\$.state.metadata', json('{}'))
 WHERE json_valid(data) AND json_extract(data,'\$.type') = 'tool'
   AND json_type(data,'\$.state') = 'object';
SELECT changes();
COMMIT;
SQL
  )
  say "  Salida de tools vaciada: ${TOOL_DONE:-0} bloques."
fi

# ---- 11. Borrado de storage ----------------------------------------------
if [[ $VACUUM_ONLY -eq 0 ]]; then
  del_keys() { # $1=dir relativo a storage  $2=fichero con ids
    local dir="$1" list="$2" id n=0
    local -a paths=()
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      if [[ ! "$id" =~ ^[A-Za-z0-9_-]+$ ]]; then
        say "    AVISO: clave insegura ignorada en storage/$dir: '$id'"
        continue
      fi
      if [[ -e "$STORAGE/$dir/$id" ]]; then
        paths+=("$STORAGE/$dir/$id"); n=$((n+1))
      elif [[ -e "$STORAGE/$dir/$id.json" ]]; then
        paths+=("$STORAGE/$dir/$id.json"); n=$((n+1))
      fi
    done < "$list"
    if (( ${#paths[@]} > 0 )); then
      printf '%s\0' "${paths[@]}" | xargs -0 -r rm -rf -- || say "    AVISO: rm falló parcialmente en storage/$dir"
    fi
    say "  storage/$dir: $n entradas borradas"
  }

  for dir in "${SES_DIRS[@]}"; do
    [[ -d "$STORAGE/$dir" ]] && del_keys "$dir" "$ALL_SESS"
  done
  if [[ -d "$STORAGE/plugin" ]]; then
    for pdir in "$STORAGE/plugin"/*/; do
      [[ -d "$pdir" ]] || continue
      del_keys "plugin/$(basename "$pdir")" "$ALL_SESS"
    done
  fi
  [[ -d "$STORAGE/part" ]] && del_keys "part" "$ALL_MSG"

  # Proyectos huérfanos: storage/project/<id>(.json) y storage/session/<id>/
  if [[ -n "$ORPHAN_PROJ" ]]; then
    n=0
    while IFS= read -r pkey; do
      [[ -z "$pkey" ]] && continue
      [[ "$pkey" =~ ^[A-Za-z0-9_-]+$ ]] || { say "    AVISO: proyecto inseguro ignorado: '$pkey'"; continue; }
      for p in "$STORAGE/project/$pkey" "$STORAGE/project/$pkey.json" "$STORAGE/session/$pkey"; do
        if [[ -e "$p" ]] && rm -rf "$p" 2>/dev/null; then n=$((n+1)); fi
      done
    done <<<"$ORPHAN_PROJ"
    say "  storage/project + storage/session (proyectos huérfanos): $n entradas borradas"
  fi

  # storage/session/<proyecto válido>/ses_*.json de sesiones borradas/huérfanas
  if [[ -d "$STORAGE/session" ]]; then
    declare -A del_ses=()
    while IFS= read -r k; do [[ -n "$k" ]] && del_ses["$k"]=1; done < "$ALL_SESS"
    n=0
    for pdir in "$STORAGE/session"/*/; do
      [[ -d "$pdir" ]] || continue
      for f in "$pdir"ses_*.json; do
        [[ -f "$f" ]] || continue
        key=$(basename "$f" .json)
        if [[ -n "${del_ses["$key"]:-}" ]] && rm -f "$f" 2>/dev/null; then n=$((n+1)); fi
      done
    done
    say "  storage/session/<proyecto>/: $n ficheros de sesión borrados"
  fi
fi

# ---- 12. Compactar la BD --------------------------------------------------
say "Compactando la BD (en BD grandes puede tardar varios minutos)..."
if ! sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1; then
  say "  AVISO: wal_checkpoint falló (¿otro proceso con la BD abierta?). La compactación puede fallar."
fi
AV=$(sqlite3 "$DB" "PRAGMA auto_vacuum;")
if [[ "$AV" == "2" ]]; then
  sqlite3 "$DB" "PRAGMA incremental_vacuum;"
  say "  Compactación: incremental_vacuum (auto_vacuum=INCREMENTAL activo)."
else
  sqlite3 "$DB" "PRAGMA auto_vacuum=INCREMENTAL; VACUUM;"
  say "  Compactación: auto_vacuum activado a INCREMENTAL + VACUUM completo."
fi
sqlite3 "$DB" "PRAGMA optimize;" >/dev/null 2>&1 || true

# ---- 13. Verificación final ------------------------------------------------
if [[ "$(db_check)" == "ok" ]]; then
  say "  Integridad tras compactación: OK"
else
  say "  ERROR: la comprobación de integridad falló tras la compactación. ¡Revisa la BD!"
fi

FREELIST_AFTER=$(sqlite3 "$DB" "PRAGMA freelist_count;")
DB_AFTER=$(size_mb "$DB")
STORAGE_AFTER=$(size_mb "$STORAGE")

say ""
say "== Resultado =="
say "  Páginas libres:  $FREELIST_BEFORE -> $FREELIST_AFTER"
say "  BD:       ${DB_BEFORE} MB -> ${DB_AFTER} MB"
say "  Storage:  ${STORAGE_BEFORE} MB -> ${STORAGE_AFTER} MB"
say "  Total liberado: $(( (DB_BEFORE-DB_AFTER) + (STORAGE_BEFORE-STORAGE_AFTER) )) MB"
