import { spawn } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { tool } from "@opencode-ai/plugin";

/**
 * Plugin: opencode-purge
 *
 * Añade la herramienta `purge_history` que lanza un *watcher detached* que:
 *   1. espera a que OpenCode cierre (pgrep -x opencode == 0),
 *   2. ejecuta opencode-cleanup.sh (--dry-run en el log, luego --yes),
 *   3. avisa (y opcionalmente reabre) al terminar.
 *
 * `detached: true` ya crea una nueva sesión en POSIX (setsid), así que no
 * dependemos del binario `setsid`. El watcher sobrevive al cierre de OpenCode.
 */
export default async (ctx) => {
  const home = process.env.HOME || homedir() || ctx.directory;
  const launcher =
    process.env.OPENCODE_PURGE_LAUNCHER ||
    join(home, ".local", "bin", "opencode-purge-launcher.sh");
  const stateHome = process.env.XDG_STATE_HOME || join(home, ".local", "state");
  const log = process.env.OPENCODE_PURGE_LOG || join(stateHome, "opencode-purge", "purge.log");

  return {
    tool: {
      purge_history: tool({
        description:
          "Purge OpenCode conversations older than N months and compact the SQLite database. " +
          "Launches a detached watcher that waits for OpenCode to close, cleans the DB + storage, " +
          "and (optionally) reopens OpenCode. Use /purge N or say 'purge conversations older than N months'.",
        args: {
          months: tool.schema
            .number({ default: 2, min: 1, max: 60 })
            .describe("Retention in months (integer 1..60). Sessions older than this are purged (default: 2)."),
        },
        async execute(args) {
          // El zod de opencode no aplica min/default en runtime; validamos aquí.
          const raw = args.months;
          const months = raw === undefined ? 2 : Number(raw);
          if (!Number.isInteger(months) || months < 1 || months > 60) {
            return (
              `[opencode-purge] ❌ **months inválido** (recibido: ${JSON.stringify(raw)}). ` +
              "Debe ser un entero entre 1 y 60 (meses de retención). No se ha lanzado ninguna purga."
            );
          }
          if (process.platform !== "linux") {
            return (
              `[opencode-purge] ❌ **Plataforma no soportada** (${process.platform}). ` +
              "El watcher depende de bash/flock/pgrep (Linux). No se ha lanzado ninguna purga."
            );
          }

          // Comprobar ANTES del spawn: un fallo de spawn solo llegaría al
          // console.error de opencode (invisible) mientras la tool ya habría
          // respondido "purga programada" mintiendo.
          try {
            accessSync(launcher, constants.R_OK);
          } catch {
            return (
              `[opencode-purge] ❌ **No encuentro el launcher** (\`${launcher}\`).\n\n` +
              "Crea el symlink y reintenta:\n" +
              "```bash\n" +
              "ln -sf ~/Repos/cleanOpencodeDB/opencode-purge-launcher.sh ~/.local/bin/opencode-purge-launcher.sh\n" +
              "```\n\n" +
              "No se ha lanzado ninguna purga."
            );
          }

          // `detached: true` crea una sesión/grupo nuevos (setsid en POSIX);
          // stdio:"ignore" evita heredar los FDs de opencode y unref() impide
          // que el event loop del plugin espere al watcher.
          const child = spawn("bash", [launcher, "--months", String(months)], {
            detached: true,
            stdio: "ignore",
          });
          child.unref();
          child.on("error", (err) => {
            console.error(`[opencode-purge] spawn error: ${err.message}`);
          });

          const relaunchHint =
            "Para reabrir OpenCode automáticamente en una ventana de terminal, " +
            "define `OPENCODE_PURGE_RELAUNCH=1` antes de lanzar la purga (best-effort, requiere sesión gráfica).";

          return [
            `🧹 **Purga programada** (${months} mes(es))`,
            "",
            "Se lanzó el watcher detached. La secuencia es:",
            "",
            "1. **Cierra OpenCode** — escribe `/exit`, pulsa Ctrl+C, o cierra la ventana.",
            "2. **El watcher detecta el cierre** (timeout 300 s por defecto; configurable con `OPENCODE_PURGE_TIMEOUT`) y ejecuta:",
            `   - \`opencode-cleanup.sh --months ${months} --dry-run\`  → plan en el log`,
            `   - \`opencode-cleanup.sh --months ${months} --yes\` → borra sesiones antiguas + VACUUM`,
            "3. **Reabre OpenCode** a mano en tu terminal cuando termine.",
            "",
            `📋 **Log en vivo:** \`tail -f ${log}\``,
            "",
            "> " + relaunchHint,
          ].join("\n");
        },
      }),
    },
  };
};
