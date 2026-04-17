import { spawn } from "node:child_process";
import { createReadStream } from "node:fs";
import { sql } from "drizzle-orm";
import { db } from "@/drizzle/db";
import { logger } from "@/lib/logger";
import { getDatabaseConfig } from "./db-config";

export type ExportMode = "full" | "excludeLogs" | "ledgerOnly";

function parseCommand(command?: string): string[] | null {
  if (!command) return null;
  const parsed = command.split(/\s+/).filter(Boolean);
  return parsed.length > 0 ? parsed : null;
}

/**
 * Parse PG_CONTAINER_EXEC into a command array.
 *
 * Example:
 *   podman exec cch-dev-postgres
 */
export function getContainerExecCommand(): string[] | null {
  return parseCommand(process.env.PG_CONTAINER_EXEC);
}

/**
 * Temporary compatibility layer for the old docker compose based variable.
 */
function getLegacyComposeExecCommand(): string[] | null {
  return parseCommand(process.env.PG_COMPOSE_EXEC);
}

function spawnWithContainerExec(
  containerExec: string[],
  command: string,
  args: string[],
  env: Record<string, string>,
  options?: { stdin?: boolean }
) {
  const [runtime, ...execArgsWithContainer] = containerExec;
  const containerName = execArgsWithContainer.at(-1);
  const baseExecArgs = execArgsWithContainer.slice(0, -1);

  if (!runtime || !containerName) {
    throw new Error("PG_CONTAINER_EXEC must include both the runtime and container name.");
  }

  const execFlags: string[] = [];
  if (options?.stdin) execFlags.push("-i");
  if (env.PGPASSWORD) {
    execFlags.push("-e", `PGPASSWORD=${env.PGPASSWORD}`);
  }

  return spawn(runtime, [...baseExecArgs, ...execFlags, containerName, command, ...args], {
    env: { ...process.env },
  });
}

function spawnWithLegacyComposeExec(
  composeExec: string[],
  command: string,
  args: string[],
  env: Record<string, string>,
  options?: { stdin?: boolean }
) {
  const execFlags = ["-T"];
  if (options?.stdin) execFlags.push("-i");
  if (env.PGPASSWORD) {
    execFlags.push("-e", `PGPASSWORD=${env.PGPASSWORD}`);
  }

  return spawn(
    composeExec[0],
    [...composeExec.slice(1), "exec", ...execFlags, "postgres", command, ...args],
    { env: { ...process.env } }
  );
}

/**
 * Spawn a PostgreSQL CLI tool either directly on the host or by routing the
 * execution through a container runtime command.
 */
export function spawnPgTool(
  command: string,
  args: string[],
  env: Record<string, string>,
  options?: { stdin?: boolean }
) {
  const containerExec = getContainerExecCommand();
  if (containerExec) {
    return spawnWithContainerExec(containerExec, command, args, env, options);
  }

  const legacyComposeExec = getLegacyComposeExecCommand();
  if (legacyComposeExec) {
    return spawnWithLegacyComposeExec(legacyComposeExec, command, args, env, options);
  }

  return spawn(command, args, {
    env: { ...process.env, ...env },
  });
}

/**
 * 执行 pg_dump 导出数据库
 *
 * @param mode 导出模式:
 *   - 'full': 完整备份（默认）
 *   - 'excludeLogs': 排除日志数据（保留表结构但不导出 message_request 数据）
 *   - 'ledgerOnly': 仅导出账单数据（完全排除 message_request 表的结构和数据）
 * @returns ReadableStream 数据流
 */
export function executePgDump(mode: ExportMode = "full"): ReadableStream<Uint8Array> {
  const dbConfig = getDatabaseConfig();

  const args = [
    "-h",
    dbConfig.host,
    "-p",
    dbConfig.port.toString(),
    "-U",
    dbConfig.user,
    "-d",
    dbConfig.database,
    "-Fc",
    "-v",
  ];

  if (mode === "excludeLogs") {
    args.push("--exclude-table-data=message_request");
  } else if (mode === "ledgerOnly") {
    args.push("--exclude-table=message_request");
  }

  const pgProcess = spawnPgTool("pg_dump", args, {
    PGPASSWORD: dbConfig.password,
  });

  logger.info({
    action: "pg_dump_start",
    host: dbConfig.host,
    port: dbConfig.port,
    database: dbConfig.database,
    mode,
  });

  return new ReadableStream({
    start(controller) {
      pgProcess.stdout.on("data", (chunk: Buffer) => {
        controller.enqueue(new Uint8Array(chunk));
      });

      pgProcess.stderr.on("data", (chunk: Buffer) => {
        logger.info(`[pg_dump] ${chunk.toString().trim()}`);
      });

      pgProcess.on("close", (code: number | null) => {
        if (code === 0) {
          logger.info({
            action: "pg_dump_complete",
            database: dbConfig.database,
          });
          controller.close();
        } else {
          const error = `pg_dump 失败，退出代码: ${code}`;
          logger.error({
            action: "pg_dump_error",
            database: dbConfig.database,
            exitCode: code,
          });
          controller.error(new Error(error));
        }
      });

      pgProcess.on("error", (err: Error) => {
        logger.error({
          action: "pg_dump_spawn_error",
          error: err.message,
        });
        controller.error(err);
      });
    },

    cancel() {
      pgProcess.kill();
      logger.warn({
        action: "pg_dump_cancelled",
        database: dbConfig.database,
      });
    },
  });
}

function analyzeRestoreErrors(errors: string[]): {
  hasFatalErrors: boolean;
  ignorableCount: number;
  fatalCount: number;
  summary: string;
} {
  const ignorablePatterns = [
    /already exists/i,
    /multiple primary keys/i,
    /duplicate key value/i,
    /role .* does not exist/i,
  ];

  const fatalPatterns = [
    /could not connect/i,
    /authentication failed/i,
    /permission denied/i,
    /database .* does not exist/i,
    /out of memory/i,
    /disk full/i,
  ];

  let ignorableCount = 0;
  let fatalCount = 0;
  const fatalErrors: string[] = [];

  for (const error of errors) {
    const isIgnorable = ignorablePatterns.some((pattern) => pattern.test(error));
    const isFatal = fatalPatterns.some((pattern) => pattern.test(error));

    if (isFatal) {
      fatalCount++;
      fatalErrors.push(error);
    } else if (isIgnorable) {
      ignorableCount++;
    } else {
      fatalCount++;
      fatalErrors.push(error);
    }
  }

  let summary = "";
  if (fatalCount > 0) {
    summary = `发现 ${fatalCount} 个致命错误`;
    if (fatalErrors.length > 0) {
      summary += `：${fatalErrors[0]}`;
    }
  } else if (ignorableCount > 0) {
    summary = `数据导入完成，跳过了 ${ignorableCount} 个已存在的对象`;
  }

  return {
    hasFatalErrors: fatalCount > 0,
    ignorableCount,
    fatalCount,
    summary,
  };
}

export function executePgRestore(
  filePath: string,
  cleanFirst: boolean,
  skipLogs = false
): ReadableStream<Uint8Array> {
  const dbConfig = getDatabaseConfig();

  const args = [
    "-h",
    dbConfig.host,
    "-p",
    dbConfig.port.toString(),
    "-U",
    dbConfig.user,
    "-d",
    dbConfig.database,
    "-v",
  ];

  if (cleanFirst) {
    args.push("--clean", "--if-exists", "--no-owner");
  }

  if (skipLogs) {
    args.push("--exclude-table-data=message_request");
  }

  const isContainerExec = !!getContainerExecCommand() || !!getLegacyComposeExecCommand();
  if (!isContainerExec) {
    args.push(filePath);
  }

  const pgProcess = spawnPgTool(
    "pg_restore",
    args,
    { PGPASSWORD: dbConfig.password },
    { stdin: isContainerExec }
  );

  if (isContainerExec) {
    const fileStream = createReadStream(filePath);
    fileStream.pipe(pgProcess.stdin!);
    fileStream.on("error", (err) => {
      logger.error({
        action: "pg_restore_file_read_error",
        error: err.message,
        filePath,
      });
      pgProcess.kill();
    });
  }

  logger.info({
    action: "pg_restore_start",
    host: dbConfig.host,
    port: dbConfig.port,
    database: dbConfig.database,
    cleanFirst,
    skipLogs,
    filePath,
  });

  const encoder = new TextEncoder();
  const errorLines: string[] = [];

  return new ReadableStream({
    start(controller) {
      pgProcess.stderr.on("data", (chunk: Buffer) => {
        const message = chunk.toString().trim();
        logger.info(`[pg_restore] ${message}`);

        if (message.toLowerCase().includes("error:")) {
          errorLines.push(message);
        }

        const sseMessage = `data: ${JSON.stringify({ type: "progress", message })}\n\n`;
        controller.enqueue(encoder.encode(sseMessage));
      });

      pgProcess.stdout.on("data", (chunk: Buffer) => {
        const message = chunk.toString().trim();
        if (message) {
          logger.info(`[pg_restore stdout] ${message}`);
        }
      });

      pgProcess.on("close", async (code: number | null) => {
        const analysis = analyzeRestoreErrors(errorLines);
        const shouldRunMigrations =
          code === 0 || (code === 1 && !analysis.hasFatalErrors && analysis.ignorableCount > 0);

        if (code === 0) {
          logger.info({
            action: "pg_restore_complete",
            database: dbConfig.database,
          });

          const progressMessage = `data: ${JSON.stringify({
            type: "progress",
            message: "数据导入成功！",
          })}\n\n`;
          controller.enqueue(encoder.encode(progressMessage));
        } else if (code === 1 && !analysis.hasFatalErrors && analysis.ignorableCount > 0) {
          logger.warn({
            action: "pg_restore_complete_with_warnings",
            database: dbConfig.database,
            exitCode: code,
            ignorableErrors: analysis.ignorableCount,
            analysis: analysis.summary,
          });

          const progressMessage = `data: ${JSON.stringify({
            type: "progress",
            message: analysis.summary,
          })}\n\n`;
          controller.enqueue(encoder.encode(progressMessage));
        } else {
          logger.error({
            action: "pg_restore_error",
            database: dbConfig.database,
            exitCode: code,
            fatalErrors: analysis.fatalCount,
            analysis: analysis.summary,
          });

          const errorMessage = `data: ${JSON.stringify({
            type: "error",
            message: analysis.summary || `数据导入失败，退出代码: ${code}`,
            exitCode: code,
            errorCount: analysis.fatalCount || errorLines.length,
          })}\n\n`;
          controller.enqueue(encoder.encode(errorMessage));
          controller.close();
          return;
        }

        if (shouldRunMigrations) {
          try {
            logger.info({
              action: "pg_restore_running_migrations",
              database: dbConfig.database,
            });

            const migrationsMessage = `data: ${JSON.stringify({
              type: "progress",
              message: "正在执行数据库迁移以同步 schema...",
            })}\n\n`;
            controller.enqueue(encoder.encode(migrationsMessage));

            const { runMigrations } = await import("@/lib/migrate");
            await runMigrations();

            logger.info({
              action: "pg_restore_migrations_complete",
              database: dbConfig.database,
            });

            const migrationSuccessMessage = `data: ${JSON.stringify({
              type: "progress",
              message: "数据库迁移完成！",
            })}\n\n`;
            controller.enqueue(encoder.encode(migrationSuccessMessage));

            const completeMessage = `data: ${JSON.stringify({
              type: "complete",
              message: "数据导入和迁移全部完成！",
              exitCode: code,
              warningCount: analysis.ignorableCount || undefined,
            })}\n\n`;
            controller.enqueue(encoder.encode(completeMessage));
          } catch (migrationError) {
            logger.error({
              action: "pg_restore_migrations_error",
              database: dbConfig.database,
              error:
                migrationError instanceof Error ? migrationError.message : String(migrationError),
            });

            const errorMessage = `data: ${JSON.stringify({
              type: "error",
              message: `数据库迁移失败: ${
                migrationError instanceof Error ? migrationError.message : String(migrationError)
              }`,
            })}\n\n`;
            controller.enqueue(encoder.encode(errorMessage));
          }
        }

        controller.close();
      });

      pgProcess.on("error", (err: Error) => {
        logger.error({
          action: "pg_restore_spawn_error",
          error: err.message,
        });

        const errorMessage = `data: ${JSON.stringify({
          type: "error",
          message: `执行 pg_restore 失败: ${err.message}`,
        })}\n\n`;
        controller.enqueue(encoder.encode(errorMessage));
        controller.close();
      });
    },

    cancel() {
      pgProcess.kill();
      logger.warn({
        action: "pg_restore_cancelled",
        database: dbConfig.database,
      });
    },
  });
}

export async function getDatabaseInfo(): Promise<{
  size: string;
  tableCount: number;
  version: string;
}> {
  const result = await db.execute(sql`
    SELECT
      pg_size_pretty(pg_database_size(current_database())) as size,
      (SELECT count(*) FROM information_schema.tables
       WHERE table_schema = 'public' AND table_type = 'BASE TABLE') as table_count,
      version() as version
  `);
  const row = result[0];
  return {
    size: String(row?.size ?? "Unknown"),
    tableCount: Number(row?.table_count ?? 0),
    version: String(row?.version ?? "Unknown").split(" ")[0] || "Unknown",
  };
}

export async function checkDatabaseConnection(): Promise<boolean> {
  try {
    await db.execute(sql`SELECT 1`);
    return true;
  } catch {
    return false;
  }
}
