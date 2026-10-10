import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';

import { BusinessError } from '@ohos.base';
import { FileEntry } from '../domain/FileEntry';
import { Result } from '../domain/Result';

export interface ILocalFileService {
  exists(path: string): Promise<boolean>;
  ensureDir(dir: string): Promise<Result<boolean>>;
  stat(path: string): Promise<Result<FileEntry>>;
  readSnapshot(dir: string): Promise<Result<Map<string, FileEntry>>>;
  readFileRange(path: string, offset: number, length: number): Promise<Result<Uint8Array>>;
  appendFile(path: string, data: Uint8Array): Promise<Result<boolean>>;
  writeFile(path: string, data: Uint8Array): Promise<Result<boolean>>;
  atomicReplace(tmpPath: string, targetPath: string): Promise<Result<boolean>>;
  removePath(path: string): Promise<Result<boolean>>;
  listDirectory(dir: string): Promise<Result<FileEntry[]>>;
  setMTime(path: string, mtime: number): Promise<Result<boolean>>;

  joinPath(...parts: string[]): string;
}

export class LocalFileService implements ILocalFileService {
  joinPath(...parts: string[]): string {
    if (parts.length > 0 && parts[0].indexOf('://') >= 0) {
      let result = parts[0].replace(/\/+$/, '');
      for (let i = 1; i < parts.length; i++) {
        const p = parts[i];
        if (p === '' || p === '/' || p === '.') {
          continue;
        }
        result = result + '/' + p.replace(/^\/+/, '');
      }
      return result;
    }
    let result = '';
    for (let p of parts) {
      if (p === '' || p === '/' || p === '.') {
        continue;
      }
      if (result === '') {
        result = p;
      } else {
        result = result.replace(/\/+$/, '') + '/' + p.replace(/^\/+/, '');
      }
    }
    if (!result.startsWith('/')) {
      result = '/' + result;
    }
    return result;
  }

  private relativize(base: string, full: string): string {
    const b = base.replace(/\/+$/, '');
    if (full === b) {
      return '';
    }
    if (full.startsWith(b + '/')) {
      return full.substring(b.length + 1);
    }
    return full;
  }

  async exists(path: string): Promise<boolean> {
    try {
      await fs.access(path);
      return true;
    } catch (e) {
      return false;
    }
  }

  async ensureDir(dir: string): Promise<Result<boolean>> {
    try {
      await fs.mkdir(dir, true);
      return Result.ok(true);
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, err.message);
    }
  }

  async stat(path: string): Promise<Result<FileEntry>> {
    try {
      const st = await fs.stat(path);
      const name = path.substring(path.lastIndexOf('/') + 1);
      const isDir = st.isDirectory();
      const entry = new FileEntry(name, isDir, isDir ? 0 : st.size, st.mtime, '');
      return Result.ok(entry);
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, err.message);
    }
  }

  async listDirectory(dir: string): Promise<Result<FileEntry[]>> {
    try {
      const names = await fs.listFile(dir);
      const entries: FileEntry[] = [];
      for (const name of names) {
        const full = this.joinPath(dir, name);
        const st = await fs.stat(full);
        const isDir = st.isDirectory();
        entries.push(new FileEntry(name, isDir, isDir ? 0 : st.size, st.mtime, ''));
      }
      return Result.ok(entries);
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, err.message);
    }
  }

  async setMTime(path: string, mtime: number): Promise<Result<boolean>> {
    try {
      const before = await fs.stat(path);
      await fs.utimes(path, mtime * 1000);
      const after = await fs.stat(path);
      hilog.info(0x0000, 'WebDAVSync', 'setMTime input=%{public}d before.mtime=%{public}d after.mtime=%{public}d',
        Math.floor(mtime), Math.floor(before.mtime), Math.floor(after.mtime));
      return Result.ok(true);
    } catch (e) {
      const err = e as BusinessError;
      hilog.info(0x0000, 'WebDAVSync', 'setMTime FAIL input=%{public}d err=%{public}s', Math.floor(mtime), err.message);
      return Result.fail(err.code, err.message);
    }
  }


  async readSnapshot(dir: string): Promise<Result<Map<string, FileEntry>>> {
    const map = new Map<string, FileEntry>();
    try {
      await this.walk(dir, dir, map);
      return Result.ok(map);
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, err.message);
    }
  }

  private async walk(dir: string, base: string, result: Map<string, FileEntry>): Promise<void> {
    let names: string[] = [];
    try {
      names = await fs.listFile(dir);
    } catch (e) {
      return;
    }
    for (const name of names) {
      const full = this.joinPath(dir, name);
      let st: fs.Stat;
      try {
        st = await fs.stat(full);
      } catch (e) {
        continue;
      }
      const rel = this.relativize(base, full);
      if (st.isDirectory()) {
        result.set(rel, new FileEntry(name, true, 0, st.mtime, ''));
        await this.walk(full, base, result);
      } else {
        result.set(rel, new FileEntry(name, false, st.size, st.mtime, ''));
      }
    }
  }

  async readFileRange(path: string, offset: number, length: number): Promise<Result<Uint8Array>> {
    try {
      const file = await fs.open(path, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(length);
      const readLen = await fs.read(file.fd, buf, { offset: offset, length: length });
      await fs.close(file);
      const out = new Uint8Array(buf, 0, readLen);
      return Result.ok(out);
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, err.message);
    }
  }

  async writeFile(path: string, data: Uint8Array): Promise<Result<boolean>> {
    try {
      const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      await fs.write(file.fd, data.buffer as ArrayBuffer);
      await fs.close(file);
      return Result.ok(true);
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, err.message);
    }
  }

  async appendFile(path: string, data: Uint8Array): Promise<Result<boolean>> {
    try {
      const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND);
      await fs.write(file.fd, data.buffer as ArrayBuffer);
      await fs.close(file);
      return Result.ok(true);
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, err.message);
    }
  }

  async atomicReplace(tmpPath: string, targetPath: string): Promise<Result<boolean>> {
    try {
      await fs.rename(tmpPath, targetPath);
      return Result.ok(true);
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, err.message);
    }
  }

  async removePath(path: string): Promise<Result<boolean>> {
    try {
      const st = await fs.stat(path);
      if (st.isDirectory()) {
        const names = await fs.listFile(path);
        for (const n of names) {
          await this.removePath(this.joinPath(path, n));
        }
        await fs.rmdir(path);
      } else {
        await fs.unlink(path);
      }
      return Result.ok(true);
    } catch (e) {
      const err = e as BusinessError;
      return Result.fail(err.code, err.message);
    }
  }
}