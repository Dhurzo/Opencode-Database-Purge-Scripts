#!/usr/bin/env bash
#
# opencode-purge-launcher.sh — *detached* watcher that:
#   1. Waits for OpenCode to close (pgrep -x opencode)
#   2. Runs opencode-cleanup.sh (--dry-run for the plan, then --yes to delete)
#   3. (Optional) Reopens OpenCode in a GUI terminal emulator — requires
#      OPENCODE_PURGE_RELAUNCH=1. By default it does NOT reopen: the TUI needs
#      a TTY that a detached process cannot provide.
#
# It is launched by the purge_history plugin. It can also be started manually:
#   nohup opencode-purge-launcher.sh --months 3 >/dev/null 2>&1 &
#
# It does not use set -e because we want to continue to the relaunch step even
# if cleanup fails.
#
# Environment variables:
#   CLEANUP_SCRIPT          path to opencode-cleanup.sh (default: $HOME/.local/bin/opencode-cleanup.sh)
#   OPENCODE_PURGE_RELAUNCH if set and non-empty, try to reopen OpenCode
#                           in a GUI terminal emulator when done.
#   OPENCODE_PURGE_TERM     emulator to use for the GUI relaunch (autodetected).
#   OPENCODE_PURGE_LOCK     single-instance lock file
#   OPENCODE_PURGE_LOG      log file (default: $XDG_STATE_HOME/opencode-purge/purge.log)
#   OPENCODE_PURGE_LOG_MAX  max log size before rotation (bytes; default: 5242880)
#   OPENCODE_PURGE_TIMEOUT  seconds to wait for OpenCode to close (default: 300)
set -uo pipefail

MONTHS=2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --months)
      if [[ $# -lt 2 ]]; then
        echo "[$(date '+%F %T')] ERROR: --months necesita un valor (entero 1..60)" >&2
        exit 1
      fi
      MONTHS="$2"; shift 2 ;;
    -h|--help) awk 'NR==1{next} /^#/{gsub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) echo "[$(date '+%F %T')] opción desconocida: $1" >&2; exit 1 ;;
  esac
done

if [[ ! "$MONTHS" =~ ^[0-9]+$ ]]; then
  echo "[$(date '+%F %T')] ERROR: --months debe ser un entero 1..60 (recibido: '$MONTHS')" >&2
  exit 1
fi
if (( MONTHS < 1 || MONTHS > 60 )); then
  echo "[$(date '+%F %T')] ERROR: --months debe ser un entero 1..60 (recibido: $MONTHS)" >&2
  exit 1
fi

TIMEOUT="${OPENCODE_PURGE_TIMEOUT:-300}"
if [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]] || (( TIMEOUT < 1 )); then
  echo "[$(date '+%F %T')] ERROR: OPENCODE_PURGE_TIMEOUT debe ser un entero >= 1 (recibido: '$TIMEOUT')" >&2
  exit 1
fi
LOG_MAX="${OPENCODE_PURGE_LOG_MAX:-5242880}"
if [[ ! "$LOG_MAX" =~ ^[0-9]+$ ]]; then
  echo "[$(date '+%F %T')] ERROR: OPENCODE_PURGE_LOG_MAX debe ser un entero (recibido: '$LOG_MAX')" >&2
  exit 1
fi

CLEANUP="${CLEANUP_SCRIPT:-$HOME/.local/bin/opencode-cleanup.sh}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/opencode-purge"
LOG="${OPENCODE_PURGE_LOG:-$STATE_DIR/purge.log}"
if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
  RUNTIME_DIR="$XDG_RUNTIME_DIR/opencode-purge"
else
  RUNTIME_DIR="/tmp/opencode-purge-$UID"
fi
LOCK="${OPENCODE_PURGE_LOCK:-$RUNTIME_DIR/launcher.lock}"
TS() { date '+%F %T'; }

umask 077
mkdir -p "$(dirname "$LOG")" || { echo "[$(TS)] ERROR: no puedo crear $(dirname "$LOG")" >&2; exit 1; }
[[ -O "$(dirname "$LOG")" ]] || { echo "[$(TS)] ERROR: $(dirname "$LOG") no es propiedad del usuario" >&2; exit 1; }
mkdir -p "$RUNTIME_DIR" || { echo "[$(TS)] ERROR: no puedo crear $RUNTIME_DIR" >&2; exit 1; }
[[ -O "$RUNTIME_DIR" ]] || { echo "[$(TS)] ERROR: $RUNTIME_DIR no es propiedad del usuario" >&2; exit 1; }
chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
chmod 700 "$(dirname "$LOG")" 2>/dev/null || true

# Rotación simple del log antes de abrirlo en modo append.
if [[ -f "$LOG" ]] && (( $(stat -c %s "$LOG" 2>/dev/null || echo 0) > LOG_MAX )); then
  mv -f "$LOG" "$LOG.1" 2>/dev/null || true
fi
touch "$LOG" 2>/dev/null || { echo "[$(TS)] ERROR: no puedo crear $LOG" >&2; exit 1; }
chmod 600 "$LOG" 2>/dev/null || true

# Todo lo escrito a continuación va al log (STDERR también)
exec >>"$LOG" 2>&1

notify() {
  if command -v notify-send >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    notify-send "opencode-purge" "$1" >/dev/null 2>&1 || true
  fi
}

# --- 0. Lock de instancia única ----------------------------------------------
command -v flock >/dev/null 2>&1 || { echo "[$(TS)] ERROR: falta 'flock' (util-linux)."; exit 1; }
command -v pgrep >/dev/null 2>&1 || { echo "[$(TS)] ERROR: falta 'pgrep' (procps); no puedo esperar a que OpenCode cierre."; exit 1; }
exec 9>"$LOCK" || { echo "[$(TS)] ERROR: no puedo abrir el lock $LOCK"; exit 1; }
if ! flock -n 9; then
  echo "[$(TS)] ERROR: ya hay otro watcher de purga en marcha (lock: $LOCK). Saliendo sin hacer nada."
  exit 1
fi

# --- 0b. El script de limpieza debe existir (fallar ANTES de esperar) --------
if [[ ! -f "$CLEANUP" ]]; then
  echo "[$(TS)] ERROR: no encuentro el script de limpieza: $CLEANUP"
  echo "[$(TS)]   Crea el symlink (ln -sf <repo>/opencode-cleanup.sh ~/.local/bin/opencode-cleanup.sh)"
  echo "[$(TS)]   o define CLEANUP_SCRIPT con la ruta correcta."
  exit 1
fi

echo ""
echo "========================================================"
echo "[$(TS)] opencode-purge-launcher iniciado (months=${MONTHS}, timeout=${TIMEOUT}s)"
echo "[$(TS)] Script de limpieza: $CLEANUP"
echo "[$(TS)] Log: $LOG"
echo "[$(TS)] Esperando a que OpenCode cierre..."

# --- 1. Esperar a que OpenCode cierre ---------------------------------------
waited=0
while pgrep -x opencode >/dev/null 2>&1; do
  sleep 2
  waited=$((waited + 2))
  if [[ $waited -ge $TIMEOUT ]]; then
    echo "[$(TS)] TIMEOUT: OpenCode no cerró en ${TIMEOUT}s. Abortando."
    notify "Purga cancelada: OpenCode no se cerró en ${TIMEOUT}s."
    exit 1
  fi
  if [[ $(( waited % 30 )) -eq 0 ]]; then
    echo "[$(TS)]   ...sigue esperando (${waited}s)"
  fi
done
echo "[$(TS)] OpenCode cerrado tras ${waited}s. Procediendo a la limpieza."

# --- 2. Dry-run (registrar el plan en el log) -------------------------------
echo ""
echo "[$(TS)] === DRY-RUN (plan de borrado) ==="
if ! bash "$CLEANUP" --months "$MONTHS" --dry-run 2>&1; then
  echo "[$(TS)] AVISO: el dry-run falló (continuamos con el cleanup real)."
fi

# --- 3. Cleanup real (--yes salta la confirmación; la guardia de BD en uso sigue activa) ---
echo ""
echo "[$(TS)] === CLEANUP (ejecución real) ==="
CLEANUP_RC=0
bash "$CLEANUP" --months "$MONTHS" --yes 2>&1 || CLEANUP_RC=$?
if [[ $CLEANUP_RC -ne 0 ]]; then
  echo "[$(TS)] ERROR: cleanup terminó con código $CLEANUP_RC. Revisa arriba el motivo."
  notify "Purga fallida (código $CLEANUP_RC). Revisa $LOG."
else
  echo "[$(TS)] Cleanup completado con éxito."
fi

# --- 4. Reapertura de OpenCode ----------------------------------------------
echo ""
echo "[$(TS)] === REOPEN ==="
if [[ $CLEANUP_RC -ne 0 ]]; then
  echo "[$(TS)] La purga FALLÓ (código $CLEANUP_RC) — revisa este log antes de reabrir OpenCode."
  echo "[$(TS)] Log completo: $LOG"
  echo "========================================================"
  exit 1
fi
if [[ -n "${OPENCODE_PURGE_RELAUNCH:-}" ]]; then
  pick_term() {
    local override="${OPENCODE_PURGE_TERM:-}"
    if [[ -n "$override" ]] && command -v "$override" >/dev/null 2>&1; then
      echo "$override"; return
    fi
    for t in x-terminal-emulator xterm gnome-terminal konsole alacritty kitty wezterm; do
      command -v "$t" >/dev/null 2>&1 && { echo "$t"; return; }
    done
    echo ""
  }
  TERM_BIN=$(pick_term)
  if [[ -z "$TERM_BIN" ]]; then
    echo "[$(TS)] AVISO: no hay emulador de terminal GUI. Reabre OpenCode a mano."
  elif [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    echo "[$(TS)] AVISO: ni DISPLAY ni WAYLAND_DISPLAY definidos (sin sesión gráfica). Reabre OpenCode a mano."
  else
    echo "[$(TS)] Intentando reabrir OpenCode en '$TERM_BIN'..."
    case "$TERM_BIN" in
      gnome-terminal) setsid "$TERM_BIN" --      opencode </dev/null >>"$LOG" 2>&1 & ;;
      wezterm)        setsid "$TERM_BIN" start -- opencode </dev/null >>"$LOG" 2>&1 & ;;
      kitty)          setsid "$TERM_BIN"            opencode </dev/null >>"$LOG" 2>&1 & ;;
      *)              setsid "$TERM_BIN" -e         opencode </dev/null >>"$LOG" 2>&1 & ;;
    esac
    echo "[$(TS)] Lanzado (best-effort). Si no aparece una ventana, abre OpenCode a mano."
  fi
else
  echo "[$(TS)] Limpieza completada. REABRE OpenCode cuando quieras:"
  echo "[$(TS)]   • teclea \`opencode\` en tu terminal, o"
  echo "[$(TS)]   • (opcional) define OPENCODE_PURGE_RELAUNCH=1 para reabrirlo en una GUI automáticamente."
fi
notify "Purga completada. Reabre OpenCode cuando quieras."
echo "[$(TS)] Log completo: $LOG"
echo "========================================================"
