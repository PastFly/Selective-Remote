import { open, mkdir, unlink, lstat } from "node:fs/promises";
import { constants } from "node:fs";
import { dirname, isAbsolute } from "node:path";
const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
function validate(record) {
  if (
    !record ||
    Object.keys(record).sort().join(",") !==
      "attemptID,manifestHash,schemaFloor,teamID,vaultID" ||
    !["teamID", "vaultID", "attemptID"].every((k) => uuid.test(record[k])) ||
    ![19, 20].includes(record.schemaFloor) ||
    !/^[a-f0-9]{64}$/.test(record.manifestHash)
  )
    throw Error("invalid_deployment_fence");
  return record;
}
function verifySchemaFloor(schemaVersion, records) {
  // Publication tables first exist at19, even if no intent has been recorded.
  if (
    !Number.isSafeInteger(schemaVersion) ||
    schemaVersion < 19 ||
    records.some((record) => schemaVersion < record.schemaFloor)
  )
    throw Error("deployment_schema_floor");
  return true;
}
export class MigrationFence {
  constructor(path, { openFile = open } = {}) {
    if (!isAbsolute(path)) throw Error("invalid_deployment_fence_path");
    this.path = path;
    this.openFile = openFile;
  }
  async records(file) {
    const text = await file.readFile("utf8");
    if (text.length > 4 * 1024 * 1024 || (text && !text.endsWith("\n")))
      throw Error("corrupt_deployment_fence");
    const seen = new Set();
    return text.trim()
      ? text
          .trim()
          .split("\n")
          .map((line) => {
            const r = validate(JSON.parse(line));
            if (seen.has(r.vaultID)) throw Error("corrupt_deployment_fence");
            seen.add(r.vaultID);
            return r;
          })
      : [];
  }
  async intent(record) {
    validate(record);
    const directory = dirname(this.path);
    const stat = await lstat(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink())
      throw Error("invalid_deployment_fence_directory");
    const lock = this.path + ".lock";
    let acquired = false;
    // The lock directory is fail-closed after a crash; operator recovery must explicitly remove it.
    for (let n = 0; n < 100; n++) {
      try {
        await mkdir(lock, { mode: 0o700 });
        acquired = true;
        break;
      } catch (e) {
        if (e.code !== "EEXIST") throw e;
        await new Promise((r) => setTimeout(r, 10));
      }
    }
    if (!acquired) throw Error("deployment_fence_locked");
    let file;
    try {
      file = await this.openFile(
        this.path,
        constants.O_RDWR | constants.O_CREAT | constants.O_NOFOLLOW,
        0o600,
      );
      const records = await this.records(file),
        old = records.find((r) => r.vaultID === record.vaultID);
      if (old) {
        if (JSON.stringify(old) !== JSON.stringify(record))
          throw Error("deployment_fence_conflict");
      } else {
        const line = Buffer.from(JSON.stringify(record) + "\n"), size = (await file.stat()).size;
        for (let offset = 0; offset < line.length;) {
          const { bytesWritten } = await file.write(line, offset, line.length - offset, size + offset);
          if (bytesWritten <= 0) throw Error("deployment_fence_short_write");
          offset += bytesWritten;
        }
      }
      // Visible bytes after an earlier failure do not prove durability.
      // Exact replays must confirm both barriers before allowing DB cutover.
      await file.sync();
      const dir = await this.openFile(directory, constants.O_RDONLY);
      try {
        await dir.sync();
      } finally {
        await dir.close();
      }
    } finally {
      await file?.close();
      await unlink(lock).catch(async () => {
        const { rmdir } = await import("node:fs/promises");
        await rmdir(lock);
      });
    }
  }
  async readRecords() {
    const file = await this.openFile(
      this.path,
      constants.O_RDONLY | constants.O_NOFOLLOW,
    );
    try {
      return await this.records(file);
    } finally {
      await file.close();
    }
  }
  async verifySchemaFloor(schemaVersion) {
    return verifySchemaFloor(schemaVersion, await this.readRecords());
  }
  async verify({ schemaVersion, publications }) {
    const records = await this.readRecords();
    verifySchemaFloor(schemaVersion, records);
    for (const r of records) {
      if (
        !publications.some(
          (p) =>
            p.teamID === r.teamID &&
            p.vaultID === r.vaultID &&
            p.attemptID === r.attemptID &&
            p.manifestHash === r.manifestHash,
        )
      )
        throw Error("deployment_fence_mismatch");
    }
    return true;
  }
}
