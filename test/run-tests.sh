#!/usr/bin/env bash
#
# test/run-tests.sh — Tests end-to-end de opencode-cleanup.sh (y validación
# del launcher/plugin) contra un fixture hermético en /tmp.
#
# Uso:  bash test/run-tests.sh     (desde cualquier directorio)
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLEANUP="$REPO/opencode-cleanup.sh"
LAUNCHER="$REPO/opencode-purge-launcher.sh"
PLUGIN="$REPO/plugin/index.js"

command -v sqlite3 >/dev/null 2>&1 || { echo "ERROR: falta sqlite3"; exit 1; }
command -v node  >/dev/null 2>&1 || { echo "ERROR: falta node";    exit 1; }
command -v flock >/dev/null 2>&1 || { echo "ERROR: falta flock";   exit 1; }

WORK="$(mktemp -d /tmp/opencode-cleanup-tests.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
ORIG_PATH="$PATH"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_eq() { # desc esperado actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (esperado: '$2', actual: '$3')"; fi
}
assert_rc() { # desc rc-esperado rc-real
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (esperado rc=$2, actual rc=$3)"; fi
}
assert_exists()  { if [[ -e "$2" ]]; then ok "$1"; else bad "$1 (no existe: $2)"; fi; }
assert_missing() { if [[ ! -e "$2" ]]; then ok "$1"; else bad "$1 (debería haberse borrado: $2)"; fi; }
assert_grep() { # desc fichero patrón
  if grep -q -- "$3" "$2"; then ok "$1"; else bad "$1 (patrón '$3' no encontrado en $2)"; fi
}

# ---- Stubs: pgrep/fuser controlados ---------------------------------------
mkdir -p "$WORK/bin-clean" "$WORK/bin-busy" "$WORK/bin-fuser"
for c in pgrep fuser; do
  printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin-clean/$c"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin-busy/pgrep"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin-busy/fuser"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin-fuser/pgrep"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin-fuser/fuser"
chmod +x "$WORK/bin-clean"/* "$WORK/bin-busy"/* "$WORK/bin-fuser"/*

FIX=""
q() { sqlite3 "$FIX/opencode.db" "$1"; }

new_fixture() {
  FIX="$WORK/$1"
  rm -rf "$FIX"
  mkdir -p "$FIX/storage"/{message,part,session_diff,todo,agent-usage-reminder,directory-readme,rules-injector,project,session,plugin/dcp}

  local now_ms old_ms
  now_ms=$(( $(date +%s) * 1000 ))
  old_ms=$(( now_ms - 200*24*3600*1000 ))   # ~6.5 meses de antigüedad

  sqlite3 -bail "$FIX/opencode.db" >/dev/null <<SQL || { echo "ERROR creando fixture $1"; exit 1; }
PRAGMA journal_mode=WAL;
CREATE TABLE project(id TEXT PRIMARY KEY, name TEXT);
CREATE TABLE session(
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
  parent_id TEXT,
  title TEXT, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL);
CREATE TABLE message(
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
CREATE TABLE part(
  id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
CREATE TABLE event_sequence(aggregate_id TEXT PRIMARY KEY, seq INTEGER NOT NULL);
CREATE TABLE event(
  id TEXT PRIMARY KEY,
  aggregate_id TEXT NOT NULL REFERENCES event_sequence(aggregate_id) ON DELETE CASCADE,
  seq INTEGER NOT NULL, type TEXT, data TEXT);
CREATE TABLE todo(
  session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  content TEXT, status TEXT, priority TEXT, position INTEGER NOT NULL,
  time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
  PRIMARY KEY(session_id, position));
INSERT INTO project VALUES('0abc000000000000000000000000000000000001','proyecto vivo');
INSERT INTO project VALUES('0abc000000000000000000000000000000000002','proyecto dos');
INSERT INTO session VALUES('ses_old','0abc000000000000000000000000000000000001',NULL,'vieja',$old_ms,$old_ms);
INSERT INTO session VALUES('ses_new','0abc000000000000000000000000000000000001',NULL,'nueva',$now_ms,$now_ms);
INSERT INTO session VALUES('ses_child','0abc000000000000000000000000000000000001','ses_old','hija',$now_ms,$now_ms);
INSERT INTO session VALUES('ses_touched','0abc000000000000000000000000000000000001',NULL,'tocada',$old_ms,$now_ms);
INSERT INTO session VALUES('ses_old2','0abc000000000000000000000000000000000002',NULL,'vieja2',$old_ms,$old_ms);
INSERT INTO message VALUES('msg_oldm','ses_old',$old_ms,$old_ms,'{}');
INSERT INTO message VALUES('msg_newm','ses_new',$now_ms,$now_ms,'{}');
INSERT INTO message VALUES('msg_new2','ses_new',$now_ms,$now_ms,'{}');
INSERT INTO message VALUES('msg_child','ses_child',$now_ms,$now_ms,'{}');
INSERT INTO message VALUES('msg_touched','ses_touched',$old_ms,$old_ms,'{}');
INSERT INTO message VALUES('msg_old2','ses_old2',$old_ms,$old_ms,'{}');
INSERT INTO part VALUES('prt_old','msg_oldm','ses_old',$old_ms,$old_ms,'{"type":"reasoning","text":"pensamiento viejo"}');
INSERT INTO part VALUES('prt_new','msg_newm','ses_new',$now_ms,$now_ms,'{"type":"text","text":"hola"}');
INSERT INTO part VALUES('prt_r','msg_new2','ses_new',$now_ms,$now_ms,'{"type":"reasoning","text":"pensamiento nuevo"}');
INSERT INTO part VALUES('prt_tool','msg_new2','ses_new',$now_ms,$now_ms,'{"type":"tool","state":{"status":"completed","output":"salida grande","metadata":{"a":1},"input":{"b":2}}}');
INSERT INTO part VALUES('prt_bad','msg_new2','ses_new',$now_ms,$now_ms,'not json');
INSERT INTO part VALUES('prt_child','msg_child','ses_child',$now_ms,$now_ms,'{"type":"text","text":"hija"}');
INSERT INTO part VALUES('prt_touched','msg_touched','ses_touched',$old_ms,$old_ms,'{"type":"reasoning","text":"pensamiento tocado"}');
INSERT INTO part VALUES('prt_old2','msg_old2','ses_old2',$old_ms,$old_ms,'{"type":"text","text":"vieja2"}');
INSERT INTO event_sequence VALUES('ses_old',1);
INSERT INTO event_sequence VALUES('ses_new',1);
INSERT INTO event_sequence VALUES('ses_child',1);
INSERT INTO event_sequence VALUES('ses_touched',1);
INSERT INTO event_sequence VALUES('ses_old2',1);
INSERT INTO event VALUES('ev_old','ses_old',1,'message.updated.1','{"x":1}');
INSERT INTO event VALUES('ev_new','ses_new',1,'message.updated.1','{"x":2}');
INSERT INTO event VALUES('ev_child','ses_child',1,'message.updated.1','{"x":3}');
INSERT INTO event VALUES('ev_touched','ses_touched',1,'message.updated.1','{"x":4}');
INSERT INTO event VALUES('ev_old2','ses_old2',1,'message.updated.1','{"x":5}');
INSERT INTO todo VALUES('ses_old','tarea','pending','low',0,$old_ms,$old_ms);
INSERT INTO todo VALUES('ses_new','tarea','pending','low',0,$now_ms,$now_ms);
SQL

  # storage: sesiones vieja/nueva/hija/tocada/old2/huérfana
  mkdir -p "$FIX/storage/message/ses_old" "$FIX/storage/message/ses_new" \
           "$FIX/storage/message/ses_child" "$FIX/storage/message/ses_touched" \
           "$FIX/storage/message/ses_old2" "$FIX/storage/message/ses_orphan"
  touch "$FIX/storage/message/ses_old/f.json" "$FIX/storage/message/ses_new/f.json"
  touch "$FIX/storage/session_diff/ses_old.json" "$FIX/storage/session_diff/ses_new.json" \
        "$FIX/storage/session_diff/ses_child.json" "$FIX/storage/session_diff/ses_touched.json" \
        "$FIX/storage/session_diff/ses_old2.json" "$FIX/storage/session_diff/ses_orphan.json"
  touch "$FIX/storage/todo/ses_old.json" "$FIX/storage/todo/ses_child.json"
  touch "$FIX/storage/agent-usage-reminder/ses_old.json"
  touch "$FIX/storage/directory-readme/ses_orphan_dr.json" "$FIX/storage/directory-readme/ses_new.json"
  touch "$FIX/storage/rules-injector/ses_orphan_ri.json"
  mkdir -p "$FIX/storage/part/msg_oldm" "$FIX/storage/part/msg_newm" \
           "$FIX/storage/part/msg_child" "$FIX/storage/part/msg_touched" \
           "$FIX/storage/part/msg_old2" "$FIX/storage/part/msg_orphan"
  touch "$FIX/storage/part/msg_oldm/p.json"
  # plugins que guardan datos por sesión
  touch "$FIX/storage/plugin/dcp/ses_old.json" "$FIX/storage/plugin/dcp/ses_new.json" \
        "$FIX/storage/plugin/dcp/ses_child.json" "$FIX/storage/plugin/dcp/ses_orphan.json"
  # anidado por proyecto: proyecto vivo + proyecto huérfano
  mkdir -p "$FIX/storage/session/0abc000000000000000000000000000000000001" \
           "$FIX/storage/session/0abc000000000000000000000000000000000002" \
           "$FIX/storage/session/dead00000000000000000000000000000000000be"
  touch "$FIX/storage/session/0abc000000000000000000000000000000000001/ses_old.json" \
        "$FIX/storage/session/0abc000000000000000000000000000000000001/ses_new.json" \
        "$FIX/storage/session/0abc000000000000000000000000000000000001/ses_child.json"
  touch "$FIX/storage/session/0abc000000000000000000000000000000000002/ses_old2.json"
  touch "$FIX/storage/session/dead00000000000000000000000000000000000be/ses_z.json"
  touch "$FIX/storage/project/0abc000000000000000000000000000000000001.json" \
        "$FIX/storage/project/0abc000000000000000000000000000000000002.json" \
        "$FIX/storage/project/dead00000000000000000000000000000000000be.json"
}

new_fixture_no_project() {
  FIX="$WORK/$1"
  rm -rf "$FIX"
  mkdir -p "$FIX/storage"/{message,part,session_diff}
  local now_ms old_ms
  now_ms=$(( $(date +%s) * 1000 ))
  old_ms=$(( now_ms - 200*24*3600*1000 ))
  sqlite3 -bail "$FIX/opencode.db" >/dev/null <<SQL || { echo "ERROR creando fixture sin project $1"; exit 1; }
CREATE TABLE session(
  id TEXT PRIMARY KEY, title TEXT,
  time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL);
CREATE TABLE message(
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
CREATE TABLE part(
  id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
CREATE TABLE event_sequence(aggregate_id TEXT PRIMARY KEY, seq INTEGER NOT NULL);
CREATE TABLE event(
  id TEXT PRIMARY KEY,
  aggregate_id TEXT NOT NULL REFERENCES event_sequence(aggregate_id) ON DELETE CASCADE,
  seq INTEGER NOT NULL, type TEXT, data TEXT);
INSERT INTO session VALUES('ses_old','vieja',$old_ms,$old_ms);
INSERT INTO session VALUES('ses_new','nueva',$now_ms,$now_ms);
INSERT INTO message VALUES('msg_oldm','ses_old',$old_ms,$old_ms,'{}');
INSERT INTO message VALUES('msg_newm','ses_new',$now_ms,$now_ms,'{}');
INSERT INTO part VALUES('prt_old','msg_oldm','ses_old',$old_ms,$old_ms,'{"type":"text"}');
INSERT INTO part VALUES('prt_new','msg_newm','ses_new',$now_ms,$now_ms,'{"type":"text"}');
INSERT INTO event_sequence VALUES('ses_old',1);
INSERT INTO event_sequence VALUES('ses_new',1);
SQL
  mkdir -p "$FIX/storage/message/ses_old" "$FIX/storage/message/ses_new" "$FIX/storage/message/ses_orphan"
  mkdir -p "$FIX/storage/part/msg_oldm" "$FIX/storage/part/msg_newm"
  touch "$FIX/storage/session_diff/ses_old.json"
}

run_cleanup() { # stubs "clean" en PATH
  env PATH="$WORK/bin-clean:$ORIG_PATH" OPENCODE_DIR="$FIX" \
      OPENCODE_CLEANUP_LOCK="$FIX/.cleanup.lock" bash "$CLEANUP" "$@"
}

echo "== 1. Limpieza completa (happy path) =="
new_fixture t1
OUT="$WORK/t1.out"
run_cleanup --months 2 --yes >"$OUT" 2>&1
assert_rc "exit 0" 0 $?
assert_eq  "ses_old borrada de la BD"          0 "$(q "SELECT count(*) FROM session WHERE id='ses_old';")"
assert_eq  "ses_child (reciente, hija de vieja) borrada con su padre" 0 "$(q "SELECT count(*) FROM session WHERE id='ses_child';")"
assert_eq  "ses_touched (creada hace 6 meses) borrada por defecto"   0 "$(q "SELECT count(*) FROM session WHERE id='ses_touched';")"
assert_eq  "ses_old2 borrada"                   0 "$(q "SELECT count(*) FROM session WHERE id='ses_old2';")"
assert_eq  "ses_new conservada"                 1 "$(q "SELECT count(*) FROM session WHERE id='ses_new';")"
assert_eq  "msg_oldm borrado en cascada"        0 "$(q "SELECT count(*) FROM message WHERE id='msg_oldm';")"
assert_eq  "prt_old borrado en cascada"         0 "$(q "SELECT count(*) FROM part WHERE id='prt_old';")"
assert_eq  "ev_old borrado en cascada"          0 "$(q "SELECT count(*) FROM event WHERE id='ev_old';")"
assert_eq  "event_sequence ses_old borrado"     0 "$(q "SELECT count(*) FROM event_sequence WHERE aggregate_id='ses_old';")"
assert_eq  "todo de ses_old borrado"            0 "$(q "SELECT count(*) FROM todo WHERE session_id='ses_old';")"
assert_eq  "quick_check ok"                "ok" "$(q "PRAGMA quick_check;")"
# storage: directorios planos
assert_missing "storage/message/ses_old"        "$FIX/storage/message/ses_old"
assert_missing "storage/message/ses_child"      "$FIX/storage/message/ses_child"
assert_missing "storage/message/ses_touched"    "$FIX/storage/message/ses_touched"
assert_missing "storage/message/ses_old2"       "$FIX/storage/message/ses_old2"
assert_missing "storage/message/ses_orphan"     "$FIX/storage/message/ses_orphan"
assert_exists  "storage/message/ses_new"        "$FIX/storage/message/ses_new"
assert_missing "storage/session_diff/ses_old"   "$FIX/storage/session_diff/ses_old.json"
assert_missing "storage/session_diff huérfano"  "$FIX/storage/session_diff/ses_orphan.json"
assert_exists  "storage/session_diff/ses_new"   "$FIX/storage/session_diff/ses_new.json"
assert_missing "storage/directory-readme huérfano" "$FIX/storage/directory-readme/ses_orphan_dr.json"
assert_exists  "storage/directory-readme/ses_new"  "$FIX/storage/directory-readme/ses_new.json"
assert_missing "storage/rules-injector huérfano"   "$FIX/storage/rules-injector/ses_orphan_ri.json"
# storage/part
assert_missing "storage/part/msg_oldm"              "$FIX/storage/part/msg_oldm"
assert_missing "storage/part/msg_child"             "$FIX/storage/part/msg_child"
assert_missing "storage/part/msg_touched"           "$FIX/storage/part/msg_touched"
assert_missing "storage/part/msg_old2"              "$FIX/storage/part/msg_old2"
assert_missing "storage/part/msg_orphan"            "$FIX/storage/part/msg_orphan"
assert_exists  "storage/part/msg_newm"              "$FIX/storage/part/msg_newm"
# plugins por sesión
assert_missing "storage/plugin/dcp/ses_old"         "$FIX/storage/plugin/dcp/ses_old.json"
assert_missing "storage/plugin/dcp/ses_child"       "$FIX/storage/plugin/dcp/ses_child.json"
assert_missing "storage/plugin/dcp/ses_orphan"      "$FIX/storage/plugin/dcp/ses_orphan.json"
assert_exists  "storage/plugin/dcp/ses_new"         "$FIX/storage/plugin/dcp/ses_new.json"
# anidado por proyecto
assert_missing "session/proj_ok/ses_old.json"     "$FIX/storage/session/0abc000000000000000000000000000000000001/ses_old.json"
assert_missing "session/proj_ok/ses_child.json"   "$FIX/storage/session/0abc000000000000000000000000000000000001/ses_child.json"
assert_exists  "session/proj_ok/ses_new.json"     "$FIX/storage/session/0abc000000000000000000000000000000000001/ses_new.json"
assert_missing "session/proj2/ses_old2.json"      "$FIX/storage/session/0abc000000000000000000000000000000000002/ses_old2.json"
assert_missing "proyecto huérfano storage/session" "$FIX/storage/session/dead00000000000000000000000000000000000be"
assert_missing "proyecto huérfano storage/project" "$FIX/storage/project/dead00000000000000000000000000000000be.json"
assert_exists  "proyecto vivo storage/project"     "$FIX/storage/project/0abc000000000000000000000000000000000001.json"
# recuentos honestos
assert_grep "conteo honesto directory-readme" "$OUT" "storage/directory-readme: 1 entradas borradas"
assert_grep "conteo honesto part (5)" "$OUT" "storage/part: 5 entradas borradas"
assert_grep "conteo honesto message (5)" "$OUT" "storage/message: 5 entradas borradas"
assert_grep "conteo plugin/dcp (3)" "$OUT" "storage/plugin/dcp: 3 entradas borradas"
assert_grep "conteo nested session (3)" "$OUT" "storage/session/<proyecto>/: 3 ficheros de sesión borrados"
assert_grep "plan: 4 sesiones a borrar (incl. hija)" "$OUT" "Sesiones a borrar de la BD (creadas antes de 2 meses; incluye descendientes): 4"
assert_grep "plan: 4 mensajes de sesiones borradas" "$OUT" "Mensajes de esas sesiones (cascada; sus parts de storage/ se borran también): 4"

echo "== 2. Segunda ejecución sin nada que borrar (regresión: set -e mataba el script) =="
OUT="$WORK/t2.out"
run_cleanup --months 2 --yes >"$OUT" 2>&1
assert_rc "exit 0 (antes: crash por pipefail en línea de ALL_SESS)" 0 $?
assert_exists "storage/message/ses_new sigue" "$FIX/storage/message/ses_new"
assert_eq "ses_new sigue en BD" 1 "$(q "SELECT count(*) FROM session WHERE id='ses_new';")"

echo "== 3. --dry-run no toca nada =="
new_fixture t3
run_cleanup --months 2 --dry-run >"$WORK/t3.out" 2>&1
assert_rc "exit 0" 0 $?
assert_eq "ses_old sigue en BD" 1 "$(q "SELECT count(*) FROM session WHERE id='ses_old';")"
assert_eq "ses_child sigue en BD" 1 "$(q "SELECT count(*) FROM session WHERE id='ses_child';")"
assert_exists "storage: ses_old sigue" "$FIX/storage/message/ses_old"
assert_exists "storage: huérfanos siguen" "$FIX/storage/directory-readme/ses_orphan_dr.json"
assert_exists "storage: part huérfano sigue" "$FIX/storage/part/msg_orphan"
assert_exists "storage: plugin huérfano sigue" "$FIX/storage/plugin/dcp/ses_orphan.json"
assert_grep "avisa de modo dry-run" "$WORK/t3.out" "no se ha hecho nada"

echo "== 4. --vacuum-only no borra nada =="
new_fixture t4
run_cleanup --vacuum-only --yes >"$WORK/t4.out" 2>&1
assert_rc "exit 0" 0 $?
assert_eq "ses_old sigue en BD" 1 "$(q "SELECT count(*) FROM session WHERE id='ses_old';")"
assert_exists "storage intacto (message)" "$FIX/storage/message/ses_old"
assert_exists "storage intacto (directory-readme)" "$FIX/storage/directory-readme/ses_orphan_dr.json"
assert_exists "storage intacto (part)" "$FIX/storage/part/msg_orphan"

echo "== 5. Validación de argumentos =="
new_fixture t5
for bad_args in "abc" "0"; do
  run_cleanup --months "$bad_args" --yes >"$WORK/t5.out" 2>&1
  assert_rc "--months '$bad_args' rechazado" 1 $?
done
run_cleanup --months >"$WORK/t5.out" 2>&1
assert_rc "--months sin valor rechazado" 1 $?
assert_grep "mensaje claro para --months sin valor" "$WORK/t5.out" "necesita un valor"
run_cleanup --events-older-than 0 --yes >"$WORK/t5.out" 2>&1
assert_rc "--events-older-than 0 rechazado" 1 $?
run_cleanup --backup-keep abc --yes >"$WORK/t5.out" 2>&1
assert_rc "--backup-keep abc rechazado" 1 $?
run_cleanup --keep-session '../evil' --yes >"$WORK/t5.out" 2>&1
assert_rc "--keep-session con ID inseguro rechazado" 1 $?
run_cleanup --vacuum-only --strip-tool-output --yes >"$WORK/t5.out" 2>&1
assert_rc "--strip-tool-output incompatible con --vacuum-only" 1 $?
run_cleanup --vacuum-only --events-older-than 5 --yes >"$WORK/t5.out" 2>&1
assert_rc "--events-older-than incompatible con --vacuum-only" 1 $?

echo "== 6. Guardia de BD en uso: --yes NO la desactiva; --force sí =="
new_fixture t6
env PATH="$WORK/bin-busy:$ORIG_PATH" OPENCODE_DIR="$FIX" \
    OPENCODE_CLEANUP_LOCK="$FIX/.cleanup.lock" bash "$CLEANUP" >"$WORK/t6.out" 2>&1
assert_rc "exit 1 con BD en uso (sin --yes)" 1 $?
assert_grep "mensaje de BD en uso" "$WORK/t6.out" "está en uso"
assert_eq "nada borrado de la BD" 1 "$(q "SELECT count(*) FROM session WHERE id='ses_old';")"
env PATH="$WORK/bin-busy:$ORIG_PATH" OPENCODE_DIR="$FIX" \
    OPENCODE_CLEANUP_LOCK="$FIX/.cleanup.lock" bash "$CLEANUP" --yes >"$WORK/t6b.out" 2>&1
assert_rc "--yes sigue respetando la guardia" 1 $?
assert_grep "aviso de --force en el error" "$WORK/t6b.out" "usa --force"
env PATH="$WORK/bin-busy:$ORIG_PATH" OPENCODE_DIR="$FIX" \
    OPENCODE_CLEANUP_LOCK="$FIX/.cleanup.lock" bash "$CLEANUP" --force --yes >"$WORK/t6c.out" 2>&1
assert_rc "--force --yes continúa" 0 $?
assert_eq "--force borra la sesión vieja" 0 "$(q "SELECT count(*) FROM session WHERE id='ses_old';")"
new_fixture t6f
env PATH="$WORK/bin-fuser:$ORIG_PATH" OPENCODE_DIR="$FIX" \
    OPENCODE_CLEANUP_LOCK="$FIX/.cleanup.lock" bash "$CLEANUP" --yes >"$WORK/t6f.out" 2>&1
assert_rc "fuser detecta la BD/WAL en uso" 1 $?

echo "== 7. --strip-reasoning vacía el texto sin borrar filas (JSON inválido incluido) =="
new_fixture t7
run_cleanup --strip-reasoning --yes >"$WORK/t7.out" 2>&1
assert_rc "exit 0 pese a part.data inválido" 0 $?
assert_eq "prt_r sigue existiendo"        1 "$(q "SELECT count(*) FROM part WHERE id='prt_r';")"
assert_eq "texto de prt_r vaciado"       "" "$(q "SELECT json_extract(data,'\$.text') FROM part WHERE id='prt_r';")"
assert_eq "prt_new (text) intacto"    "hola" "$(q "SELECT json_extract(data,'\$.text') FROM part WHERE id='prt_new';")"
assert_eq "prt_bad (JSON inválido) intacto" "not json" "$(q "SELECT data FROM part WHERE id='prt_bad';")"
assert_eq "prt_tool.output intacto sin --strip-tool-output" "salida grande" "$(q "SELECT json_extract(data,'\$.state.output') FROM part WHERE id='prt_tool';")"

echo "== 8. --backup crea snapshot consistente y respeta --backup-keep =="
new_fixture t8
run_cleanup --backup --backup-keep 1 --yes >"$WORK/t8.out" 2>&1
assert_rc "exit 0" 0 $?
BAK=$(ls -d "$FIX"/opencode.db.backup-* 2>/dev/null | head -1)
if [[ -n "$BAK" && -f "$BAK/opencode.db" ]]; then ok "backup creado: $(basename "$BAK")"; else bad "backup no creado"; fi
if [[ -n "$BAK" ]]; then
  assert_eq "backup legible (integrity ok)" "ok" "$(sqlite3 "$BAK/opencode.db" "PRAGMA integrity_check;")"
fi
run_cleanup --backup --backup-keep 1 --yes >"$WORK/t8b.out" 2>&1
assert_rc "segundo backup exit 0" 0 $?
NBACKUPS=$(find "$FIX" -maxdepth 1 -type d -name 'opencode.db.backup-*' | wc -l)
assert_eq "--backup-keep 1 deja una sola copia" 1 "$NBACKUPS"

echo "== 9. Launcher: validación de argumentos =="
bash "$LAUNCHER" --months 0   >/dev/null 2>&1; assert_rc "--months 0 rechazado" 1 $?
bash "$LAUNCHER" --months abc >/dev/null 2>&1; assert_rc "--months abc rechazado" 1 $?
bash "$LAUNCHER" --months 61  >/dev/null 2>&1; assert_rc "--months 61 rechazado" 1 $?
bash "$LAUNCHER" --months     >/dev/null 2>&1; assert_rc "--months sin valor rechazado" 1 $?
bash "$LAUNCHER" --bogus      >/dev/null 2>&1; assert_rc "opción desconocida rechazada" 1 $?
OPENCODE_PURGE_TIMEOUT=abc bash "$LAUNCHER" >/dev/null 2>&1; assert_rc "timeout inválido rechazado" 1 $?

echo "== 10. Sintaxis, plugin y artefactos =="
bash -n "$CLEANUP"  && ok "bash -n cleanup"   || bad "bash -n cleanup"
bash -n "$LAUNCHER" && ok "bash -n launcher"   || bad "bash -n launcher"
node --check "$PLUGIN" && ok "node --check plugin" || bad "node --check plugin"
assert_exists "commands/purge.md existe" "$REPO/commands/purge.md"
assert_exists "opencode.json.example existe" "$REPO/opencode.json.example"
assert_exists "LICENSE existe" "$REPO/LICENSE"

echo "== 11. --by-updated y listas de protección =="
new_fixture t11
run_cleanup --by-updated --months 2 --yes >"$WORK/t11.out" 2>&1
assert_rc "by-updated exit 0" 0 $?
assert_eq "ses_touched conservada (time_updated reciente)" 1 "$(q "SELECT count(*) FROM session WHERE id='ses_touched';")"
assert_exists "storage de ses_touched conservado" "$FIX/storage/message/ses_touched"
assert_eq "ses_old sigue borrándose" 0 "$(q "SELECT count(*) FROM session WHERE id='ses_old';")"
assert_eq "ses_child sigue borrándose con su padre" 0 "$(q "SELECT count(*) FROM session WHERE id='ses_child';")"

new_fixture t11b
run_cleanup --keep-session ses_old --yes >"$WORK/t11b.out" 2>&1
assert_rc "keep-session exit 0" 0 $?
assert_eq "ses_old conservada por --keep-session" 1 "$(q "SELECT count(*) FROM session WHERE id='ses_old';")"
assert_eq "ses_child conservada (madre protegida)" 1 "$(q "SELECT count(*) FROM session WHERE id='ses_child';")"
assert_exists "storage ses_old conservado" "$FIX/storage/message/ses_old"
assert_eq "ses_touched sigue borrándose" 0 "$(q "SELECT count(*) FROM session WHERE id='ses_touched';")"

new_fixture t11c
run_cleanup --keep-project 0abc000000000000000000000000000000000002 --yes >"$WORK/t11c.out" 2>&1
assert_rc "keep-project exit 0" 0 $?
assert_eq "ses_old2 conservada por --keep-project" 1 "$(q "SELECT count(*) FROM session WHERE id='ses_old2';")"
assert_exists "storage p2 conservado" "$FIX/storage/session/0abc000000000000000000000000000000000002/ses_old2.json"
assert_eq "ses_old sigue borrándose" 0 "$(q "SELECT count(*) FROM session WHERE id='ses_old';")"

new_fixture t11d
run_cleanup --keep-session ses_child --yes >"$WORK/t11d.out" 2>&1
assert_rc "keep-child exit 0" 0 $?
assert_eq "ses_child protegida" 1 "$(q "SELECT count(*) FROM session WHERE id='ses_child';")"
assert_eq "ses_child reparentada a NULL" 1 "$(q "SELECT count(*) FROM session WHERE id='ses_child' AND parent_id IS NULL;")"

echo "== 12. --events-older-than poda eventos y conserva event_sequence =="
new_fixture t12
run_cleanup --months 12 --events-older-than 30 --yes >"$WORK/t12.out" 2>&1
assert_rc "events exit 0" 0 $?
assert_eq "ses_old conservada con --months 12" 1 "$(q "SELECT count(*) FROM session WHERE id='ses_old';")"
assert_eq "ev_old podado"               0 "$(q "SELECT count(*) FROM event WHERE id='ev_old';")"
assert_eq "ev_old2 podado"              0 "$(q "SELECT count(*) FROM event WHERE id='ev_old2';")"
assert_eq "ev_new conservado"           1 "$(q "SELECT count(*) FROM event WHERE id='ev_new';")"
assert_eq "ev_touched conservado"       1 "$(q "SELECT count(*) FROM event WHERE id='ev_touched';")"
assert_eq "event_sequence de ses_old conservado" 1 "$(q "SELECT count(*) FROM event_sequence WHERE aggregate_id='ses_old';")"

echo "== 13. --strip-tool-output =="
new_fixture t13
run_cleanup --strip-tool-output --yes >"$WORK/t13.out" 2>&1
assert_rc "tool strip exit 0" 0 $?
assert_eq "tool sigue existiendo" 1 "$(q "SELECT count(*) FROM part WHERE id='prt_tool';")"
assert_eq "state.output vaciado" "" "$(q "SELECT json_extract(data,'\$.state.output') FROM part WHERE id='prt_tool';")"
assert_eq "state.metadata vaciado a {}" "{}" "$(q "SELECT json_extract(data,'\$.state.metadata') FROM part WHERE id='prt_tool';")"
assert_eq "state.input intacto" 2 "$(q "SELECT json_extract(data,'\$.state.input.b') FROM part WHERE id='prt_tool';")"
assert_eq "prt_bad intacto" "not json" "$(q "SELECT data FROM part WHERE id='prt_bad';")"
assert_eq "prt_r (reasoning) intacto" "pensamiento nuevo" "$(q "SELECT json_extract(data,'\$.text') FROM part WHERE id='prt_r';")"

echo "== 14. Fixture sin tabla project (versión antigua del esquema) =="
new_fixture_no_project t14
run_cleanup --months 2 --yes >"$WORK/t14.out" 2>&1
assert_rc "sin project: exit 0" 0 $?
assert_eq "sin project: ses_old borrada" 0 "$(q "SELECT count(*) FROM session WHERE id='ses_old';")"
assert_eq "sin project: ses_new conservada" 1 "$(q "SELECT count(*) FROM session WHERE id='ses_new';")"
assert_missing "sin project: storage message old" "$FIX/storage/message/ses_old"
assert_missing "sin project: storage message orphan" "$FIX/storage/message/ses_orphan"
assert_exists "sin project: storage message new" "$FIX/storage/message/ses_new"
assert_missing "sin project: part old" "$FIX/storage/part/msg_oldm"
assert_exists "sin project: part new" "$FIX/storage/part/msg_newm"

echo "== 15. OPENCODE_DIR con espacios =="
new_fixture "t15 con espacios"
run_cleanup --months 2 --yes >"$WORK/t15.out" 2>&1
assert_rc "ruta con espacios: exit 0" 0 $?
assert_eq "ruta con espacios: ses_old borrada" 0 "$(q "SELECT count(*) FROM session WHERE id='ses_old';")"
assert_missing "ruta con espacios: storage limpio" "$FIX/storage/message/ses_old"

echo "== 16. Lock: dos limpiezas concurrentes =="
new_fixture t16
flock -x "$FIX/.cleanup.lock" -c "sleep 3" &
LOCK_PID=$!
sleep 0.2
run_cleanup --yes >"$WORK/t16.out" 2>&1
assert_rc "segunda limpieza rechazada por flock" 1 $?
assert_grep "mensaje de lock" "$WORK/t16.out" "otra limpieza en marcha"
wait "$LOCK_PID" 2>/dev/null || true

echo "== 17. Launcher end-to-end con stubs =="
mkdir -p "$WORK/bin-launcher"
cat > "$WORK/bin-launcher/pgrep" <<STUB
#!/usr/bin/env bash
f="$WORK/pgrep.count"
n=0; [[ -f "\$f" ]] && n=\$(cat "\$f")
if (( n < 2 )); then echo \$((n+1)) > "\$f"; exit 0; else exit 1; fi
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin-launcher/sleep"
chmod +x "$WORK/bin-launcher"/*
cat > "$WORK/cleanup-stub.sh" <<'STUB'
#!/usr/bin/env bash
echo "CLEANUP_STUB $*"
exit "${STUB_RC:-0}"
STUB

rm -f "$WORK/pgrep.count" "$WORK/launcher.log" "$WORK/launcher.lock"
env PATH="$WORK/bin-launcher:$ORIG_PATH" \
    CLEANUP_SCRIPT="$WORK/cleanup-stub.sh" \
    OPENCODE_PURGE_LOG="$WORK/launcher.log" \
    OPENCODE_PURGE_LOCK="$WORK/launcher.lock" \
    OPENCODE_PURGE_TIMEOUT=10 \
    bash "$LAUNCHER" --months 3
assert_rc "launcher E2E exit 0" 0 $?
assert_grep "launcher esperó y detectó cierre" "$WORK/launcher.log" "OpenCode cerrado tras 4s"
assert_grep "launcher ejecutó dry-run" "$WORK/launcher.log" "CLEANUP_STUB --months 3 --dry-run"
assert_grep "launcher ejecutó cleanup real con --yes" "$WORK/launcher.log" "CLEANUP_STUB --months 3 --yes"
assert_grep "launcher anuncia éxito" "$WORK/launcher.log" "Cleanup completado con éxito"

rm -f "$WORK/pgrep.count" "$WORK/launcher.log"
env PATH="$WORK/bin-launcher:$ORIG_PATH" \
    CLEANUP_SCRIPT="$WORK/cleanup-stub.sh" \
    OPENCODE_PURGE_LOG="$WORK/launcher.log" \
    OPENCODE_PURGE_LOCK="$WORK/launcher.lock" \
    OPENCODE_PURGE_TIMEOUT=10 STUB_RC=3 \
    bash "$LAUNCHER" --months 3
assert_rc "launcher propaga el fallo del cleanup" 1 $?
assert_grep "launcher registra el fallo" "$WORK/launcher.log" "La purga FALLÓ"

# Timeout: pgrep siempre activo, sleep no-op, timeout 2s.
cat > "$WORK/bin-launcher/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$WORK/bin-launcher/pgrep"
rm -f "$WORK/launcher.log"
env PATH="$WORK/bin-launcher:$ORIG_PATH" \
    CLEANUP_SCRIPT="$WORK/cleanup-stub.sh" \
    OPENCODE_PURGE_LOG="$WORK/launcher.log" \
    OPENCODE_PURGE_LOCK="$WORK/launcher.lock" \
    OPENCODE_PURGE_TIMEOUT=2 \
    bash "$LAUNCHER" --months 3
assert_rc "launcher aborta por timeout" 1 $?
assert_grep "launcher registra timeout" "$WORK/launcher.log" "TIMEOUT"

echo ""
echo "== Resultado: $PASS ok, $FAIL FAIL =="
(( FAIL == 0 ))
