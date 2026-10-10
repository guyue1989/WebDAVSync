import { Connection } from '../domain/Connection';
import { SyncTask } from '../domain/SyncTask';
import { SyncResult } from '../domain/SyncResult';
import { FileState } from '../domain/FileState';
import { FileEntry } from '../domain/FileEntry';
import { Conflict } from '../domain/Conflict';
import { SyncStatus } from '../domain/Enums';
import { ConflictStrategy } from '../domain/Enums';
import { SyncDirection } from '../domain/Enums';
import { Result } from '../domain/Result';
import { IWebDavClient, FileMeta } from '../infrastructure/WebDavClient';
import { ILocalFileService } from '../infrastructure/LocalFileService';
import { ISyncStore } from '../infrastructure/SyncStore';
import { IConnectionManager } from './ConnectionManager';
import { AppContext } from './AppContext';
import { FileEvent } from '../infrastructure/FileWatcher';
import { ChangeDetector } from '../domain/ChangeDetector';
import { SyncProgressTracker } from './SyncProgressTracker';
import { FileFilter } from '../domain/FileFilter';
import hilog from '@ohos.hilog';

const LWW_EPSILON = 2;

enum ActionType {
  Upload = 0,
  Download = 1,
  DeleteLocal = 2,
  DeleteRemote = 3,
  MkdirLocal = 4,
  MkdirRemote = 5
}

class SyncAction {
  relPath: string = '';
  type: ActionType = ActionType.Upload;
  isDirectory: boolean = false;
}

class SyncPlan {
  actions: SyncAction[] = [];
  conflicts: Conflict[] = [];
}

export interface ISyncEngine {
  startSync(task: SyncTask): Promise<SyncResult>;
  onLocalChange(task: SyncTask, events: FileEvent[]): Promise<SyncResult>;
  pullRemoteChanges(task: SyncTask): Promise<SyncResult>;
  resolveConflict(task: SyncTask, conflict: Conflict, strategy: ConflictStrategy): Promise<Result<boolean>>;
  stopSync(taskId: string): Promise<void>;
}

export class SyncEngine implements ISyncEngine {
  private webDavClient: IWebDavClient;
  private localFileService: ILocalFileService;
  private syncStore: ISyncStore;
  private connectionManager: IConnectionManager;
  private cancelled: Set<string> = new Set<string>();
  private running: Set<string> = new Set<string>();

  constructor(webDavClient: IWebDavClient, localFileService: ILocalFileService, syncStore: ISyncStore, connectionManager: IConnectionManager) {
    this.webDavClient = webDavClient;
    this.localFileService = localFileService;
    this.syncStore = syncStore;
    this.connectionManager = connectionManager;
  }

  async startSync(task: SyncTask): Promise<SyncResult> {
    return this.synchronize(task);
  }

  async onLocalChange(task: SyncTask, events: FileEvent[]): Promise<SyncResult> {
    return this.synchronize(task);
  }

  async pullRemoteChanges(task: SyncTask): Promise<SyncResult> {
    return this.synchronize(task);
  }

  async stopSync(taskId: string): Promise<void> {
    this.cancelled.add(taskId);
  }

  private remoteRelPath(task: SyncTask, relPath: string): string {
    const root = task.remoteDir.replace(/\/+$/, '');
    return root + '/' + relPath;
  }

  private async synchronize(task: SyncTask): Promise<SyncResult> {
    if (this.running.has(task.id)) {
      const busy = new SyncResult();
      busy.taskId = task.id;
      busy.status = SyncStatus.Error;
      busy.message = '该任务正在同步中';
      return busy;
    }
    this.running.add(task.id);
    try {
      return await this.doSynchronize(task);
    } finally {
      this.running.delete(task.id);
    }
  }

  private async doSynchronize(task: SyncTask): Promise<SyncResult> {
    const result = new SyncResult();
    result.taskId = task.id;
    result.status = SyncStatus.Comparing;
    this.cancelled.delete(task.id);

    const connRes = await this.connectionManager.getById(task.connectionId);
    if (!connRes.success || connRes.data === null) {
      result.status = SyncStatus.Error;
      result.message = '连接不存在';
      return result;
    }
    const conn = connRes.data;

    await this.webDavClient.resolveAddress(conn);

    if (!task.localDir.startsWith('/')) {
      const ctx = AppContext.getContext();
      if (ctx !== null) {
        task.localDir = ctx.filesDir + '/sync';
      }
    }

    await this.localFileService.ensureDir(task.localDir);

    const localRes = await this.localFileService.readSnapshot(task.localDir);
    if (!localRes.success || localRes.data === null) {
      result.status = SyncStatus.Error;
      result.message = '读取本地目录失败';
      return result;
    }
    const localSnap = localRes.data;

    const remoteSnap = await this.buildRemoteSnapshot(conn, task.remoteDir);

    const statesRes = await this.syncStore.listFileStates(task.id);
    const fileStates = statesRes.success && statesRes.data !== null ? statesRes.data : new Map<string, FileState>();

    const plan = this.computePlan(task, localSnap, remoteSnap, fileStates);

    if (plan.actions.length === 0 && plan.conflicts.length === 0) {
      await this.rebuildFileStates(task, localSnap, remoteSnap);
      result.status = SyncStatus.Completed;
      result.message = '无变化';
      return result;
    }

    SyncProgressTracker.begin(task.id, plan.actions.length + plan.conflicts.length);

    result.status = SyncStatus.Transferring;
    result.conflicts = plan.conflicts;
    await this.executeRemoteMkdirs(task, conn, plan, result, localSnap, remoteSnap);
    await this.executeUploads(task, conn, plan, result, localSnap, remoteSnap);
    await this.executeLocalMkdirs(task, plan, result, localSnap, remoteSnap);
    await this.executeDownloads(task, conn, plan, result, localSnap, remoteSnap);
    await this.executeRemoteDeletes(task, conn, plan, result, localSnap, remoteSnap);
    await this.executeLocalDeletes(task, plan, result, localSnap, remoteSnap);

    if (plan.conflicts.length > 0) {
      result.status = SyncStatus.Resolving;
      for (const c of plan.conflicts) {
        await this.applyConflictStrategy(task, conn, c, task.conflictStrategy, result);
        SyncProgressTracker.step(task.id, c.relPath);
      }
    }

    await this.rebuildFileStates(task, localSnap, remoteSnap);

    SyncProgressTracker.finish(task.id);

    result.status = SyncStatus.Completed;
    result.message = result.failedCount > 0 ? '同步完成（' + result.failedCount.toString() + ' 项失败）' : '同步完成';
    return result;
  }

  private async buildRemoteSnapshot(conn: Connection, remoteRoot: string): Promise<Map<string, FileEntry>> {
    const map = new Map<string, FileEntry>();
    await this.walkRemote(conn, remoteRoot, '', map);
    return map;
  }

  private async walkRemote(conn: Connection, remoteDir: string, relPrefix: string, map: Map<string, FileEntry>): Promise<void> {
    const res = await this.webDavClient.listDirectory(conn, remoteDir);
    if (!res.success || res.data === null) {
      return;
    }
    for (const entry of res.data) {
      const rel = relPrefix === '' ? entry.name : relPrefix + '/' + entry.name;
      map.set(rel, entry);
      if (entry.isDirectory) {
        const childRemote = remoteDir.replace(/\/+$/, '') + '/' + entry.name;
        await this.walkRemote(conn, childRemote, rel, map);
      }
    }
  }

  private computePlan(task: SyncTask, localSnap: Map<string, FileEntry>, remoteSnap: Map<string, FileEntry>, fileStates: Map<string, FileState>): SyncPlan {
    const plan = new SyncPlan();
    const filter = new FileFilter(task.filterRules);
    const keys = new Set<string>();
    localSnap.forEach((v: FileEntry, k: string) => keys.add(k));
    remoteSnap.forEach((v: FileEntry, k: string) => keys.add(k));
    fileStates.forEach((v: FileState, k: string) => keys.add(k));

    keys.forEach((path: string) => {
      if (this.isFiltered(filter, path)) {
        return;
      }
      const localEntry = localSnap.get(path);
      const remoteEntry = remoteSnap.get(path);
      const prev = fileStates.get(path);

      const localExists = localEntry !== undefined;
      const remoteExists = remoteEntry !== undefined;
      const isDir = (localEntry !== undefined && localEntry.isDirectory) || (remoteEntry !== undefined && remoteEntry.isDirectory);

      if (isDir && localExists && remoteExists) {
        return;
      }

      if (!localExists && !remoteExists) {
        return;
      }

      if (prev === undefined && localExists && remoteExists) {

        return;
      }

      const localChanged = ChangeDetector.isLocalChanged(localEntry, prev);
      const remoteChanged = ChangeDetector.isRemoteChanged(remoteEntry, prev);

      if (isDir) {
        hilog.info(0x0000, 'WebDAVSync', 'dir path=%{public}s local=%{public}d remote=%{public}d localChg=%{public}d remoteChg=%{public}d prev=%{public}d',
          path, localExists ? 1 : 0, remoteExists ? 1 : 0, localChanged ? 1 : 0, remoteChanged ? 1 : 0, prev !== undefined ? 1 : 0);
      }

      if (localChanged && remoteChanged) {
        const c = new Conflict();
        c.taskId = task.id;
        c.relPath = path;
        c.localMtime = localEntry !== undefined ? localEntry.mtime : 0;
        c.remoteMtime = remoteEntry !== undefined ? remoteEntry.mtime : 0;
        c.strategy = task.conflictStrategy;
        c.resolved = false;
        plan.conflicts.push(c);
        return;
      }

      if (localChanged && !remoteChanged) {
        if (localExists) {
          if (isDir) {
            plan.actions.push(this.makeAction(path, ActionType.MkdirRemote, true));
          } else if (task.direction === SyncDirection.Bidirectional || task.direction === SyncDirection.UploadOnly) {
            plan.actions.push(this.makeAction(path, ActionType.Upload, false));
          }
        } else if (task.direction === SyncDirection.Bidirectional) {
          plan.actions.push(this.makeAction(path, ActionType.DeleteRemote, isDir));
        }
        return;
      }

      if (!localChanged && remoteChanged) {
        if (remoteExists) {
          if (isDir) {
            plan.actions.push(this.makeAction(path, ActionType.MkdirLocal, true));
          } else if (task.direction === SyncDirection.Bidirectional || task.direction === SyncDirection.DownloadOnly) {
            plan.actions.push(this.makeAction(path, ActionType.Download, false));
          }
        } else if (task.direction === SyncDirection.Bidirectional) {
          plan.actions.push(this.makeAction(path, ActionType.DeleteLocal, isDir));
        }
      }
    });
    return plan;
  }

  private makeAction(relPath: string, type: ActionType, isDirectory: boolean): SyncAction {
    const a = new SyncAction();
    a.relPath = relPath;
    a.type = type;
    a.isDirectory = isDirectory;
    return a;
  }

  private isFiltered(filter: FileFilter, path: string): boolean {
    if (filter.isEmpty()) {
      return false;
    }
    const segs = path.split('/');
    for (const seg of segs) {
      if (seg !== '' && filter.matches(seg)) {
        return true;
      }
    }
    return false;
  }

  private async runConcurrent<T>(items: T[], limit: number, worker: (item: T) => Promise<void>): Promise<void> {
    if (items.length === 0) {
      return;
    }
    const n = Math.max(1, Math.min(limit, items.length));
    const batches: T[][] = [];
    for (let i = 0; i < n; i++) {
      batches.push([]);
    }
    for (let i = 0; i < items.length; i++) {
      batches[i % n].push(items[i]);
    }
    const runners: Promise<void>[] = [];
    for (const batch of batches) {
      runners.push(this.runBatch(batch, worker));
    }
    await Promise.all(runners);
  }

  private async runBatch<T>(batch: T[], worker: (item: T) => Promise<void>): Promise<void> {
    for (const item of batch) {
      await worker(item);
    }
  }


  private async executeRemoteMkdirs(task: SyncTask, conn: Connection, plan: SyncPlan, result: SyncResult, localSnap: Map<string, FileEntry>, remoteSnap: Map<string, FileEntry>): Promise<void> {
    for (const a of plan.actions) {
      if (this.cancelled.has(task.id)) {
        break;
      }
      if (a.type !== ActionType.MkdirRemote) {
        continue;
      }
      const res = await this.webDavClient.mkdir(conn, this.remoteRelPath(task, a.relPath));
      if (res.success) {
        const localEntry = localSnap.get(a.relPath);
        if (localEntry !== undefined) {
          remoteSnap.set(a.relPath, localEntry);
        }
      }
      SyncProgressTracker.step(task.id, a.relPath);
    }
  }

  private async executeLocalMkdirs(task: SyncTask, plan: SyncPlan, result: SyncResult, localSnap: Map<string, FileEntry>, remoteSnap: Map<string, FileEntry>): Promise<void> {
    for (const a of plan.actions) {
      if (a.type !== ActionType.MkdirLocal) {
        continue;
      }
      const res = await this.localFileService.ensureDir(this.localFileService.joinPath(task.localDir, a.relPath));
      if (res.success) {
        const remoteEntry = remoteSnap.get(a.relPath);
        if (remoteEntry !== undefined) {
          localSnap.set(a.relPath, remoteEntry);
        }
      }
      SyncProgressTracker.step(task.id, a.relPath);
    }
  }

  private async executeUploads(task: SyncTask, conn: Connection, plan: SyncPlan, result: SyncResult, localSnap: Map<string, FileEntry>, remoteSnap: Map<string, FileEntry>): Promise<void> {
    const actions: SyncAction[] = [];
    for (const a of plan.actions) {
      if (a.type === ActionType.Upload) {
        actions.push(a);
      }
    }
    await this.runConcurrent<SyncAction>(actions, task.concurrency, async (a: SyncAction) => {
      if (this.cancelled.has(task.id)) {
        return;
      }
      const localPath = this.localFileService.joinPath(task.localDir, a.relPath);
      const res = await this.webDavClient.uploadFile(conn, localPath, this.remoteRelPath(task, a.relPath), () => {});
      if (res.success) {
        result.transferred += 1;
        const localEntry = localSnap.get(a.relPath);
        if (localEntry !== undefined) {
          const metaRes = await this.webDavClient.getFileMeta(conn, this.remoteRelPath(task, a.relPath));
          const meta = metaRes.success && metaRes.data !== null ? metaRes.data : new FileMeta();
          const remoteEntry = new FileEntry(localEntry.name, false, localEntry.size, meta.mtime > 0 ? meta.mtime : localEntry.mtime, meta.etag);
          remoteSnap.set(a.relPath, remoteEntry);
        }
      } else {
        hilog.info(0x0000, 'WebDAVSync', 'upload FAIL relPath=%{public}s err=%{public}s', a.relPath, res.errorMessage);
        result.failedCount += 1;
        result.failedPaths.push(a.relPath);
      }
      SyncProgressTracker.step(task.id, a.relPath);
    });
  }

  private async executeDownloads(task: SyncTask, conn: Connection, plan: SyncPlan, result: SyncResult, localSnap: Map<string, FileEntry>, remoteSnap: Map<string, FileEntry>): Promise<void> {
    const actions: SyncAction[] = [];
    for (const a of plan.actions) {
      if (a.type === ActionType.Download) {
        actions.push(a);
      }
    }
    await this.runConcurrent<SyncAction>(actions, task.concurrency, async (a: SyncAction) => {
      if (this.cancelled.has(task.id)) {
        return;
      }
      const localPath = this.localFileService.joinPath(task.localDir, a.relPath);
      const res = await this.webDavClient.downloadFile(conn, this.remoteRelPath(task, a.relPath), localPath, 0, () => {});
      if (res.success) {
        result.transferred += 1;
        const remoteEntry = remoteSnap.get(a.relPath);
        if (remoteEntry !== undefined) {
          await this.localFileService.setMTime(localPath, remoteEntry.mtime);
          localSnap.set(a.relPath, new FileEntry(remoteEntry.name, false, remoteEntry.size, remoteEntry.mtime, ''));
        }
      } else {
        hilog.info(0x0000, 'WebDAVSync', 'download FAIL relPath=%{public}s err=%{public}s', a.relPath, res.errorMessage);
        result.failedCount += 1;
        result.failedPaths.push(a.relPath);
      }
      SyncProgressTracker.step(task.id, a.relPath);
    });
  }

  private async executeRemoteDeletes(task: SyncTask, conn: Connection, plan: SyncPlan, result: SyncResult, localSnap: Map<string, FileEntry>, remoteSnap: Map<string, FileEntry>): Promise<void> {
    const dirs = plan.actions.filter((a: SyncAction) => a.type === ActionType.DeleteRemote && a.isDirectory);
    const files = plan.actions.filter((a: SyncAction) => a.type === ActionType.DeleteRemote && !a.isDirectory);
    for (const a of files) {
      if (this.cancelled.has(task.id)) {
        break;
      }
      const res = await this.webDavClient.deleteItem(conn, this.remoteRelPath(task, a.relPath));
      if (res.success) {
        remoteSnap.delete(a.relPath);
      } else {
        result.failedCount += 1;
        result.failedPaths.push(a.relPath);
      }
      SyncProgressTracker.step(task.id, a.relPath);
    }
    for (const a of dirs) {
      if (this.cancelled.has(task.id)) {
        break;
      }
      const res = await this.webDavClient.deleteItem(conn, this.remoteRelPath(task, a.relPath));
      if (res.success) {
        remoteSnap.delete(a.relPath);
      } else {
        result.failedCount += 1;
        result.failedPaths.push(a.relPath);
      }
      SyncProgressTracker.step(task.id, a.relPath);
    }
  }

  private async executeLocalDeletes(task: SyncTask, plan: SyncPlan, result: SyncResult, localSnap: Map<string, FileEntry>, remoteSnap: Map<string, FileEntry>): Promise<void> {
    const dirs = plan.actions.filter((a: SyncAction) => a.type === ActionType.DeleteLocal && a.isDirectory);
    const files = plan.actions.filter((a: SyncAction) => a.type === ActionType.DeleteLocal && !a.isDirectory);
    for (const a of files) {
      const res = await this.localFileService.removePath(this.localFileService.joinPath(task.localDir, a.relPath));
      if (res.success) {
        localSnap.delete(a.relPath);
      } else {
        result.failedCount += 1;
        result.failedPaths.push(a.relPath);
      }
      SyncProgressTracker.step(task.id, a.relPath);
    }
    for (const a of dirs) {
      hilog.info(0x0000, 'WebDAVSync', 'deleteLocalDir relPath=%{public}s', a.relPath);
      const res = await this.localFileService.removePath(this.localFileService.joinPath(task.localDir, a.relPath));
      hilog.info(0x0000, 'WebDAVSync', 'deleteLocalDir result=%{public}d relPath=%{public}s', res.success ? 1 : 0, a.relPath);
      if (res.success) {
        localSnap.delete(a.relPath);
      } else {
        result.failedCount += 1;
        result.failedPaths.push(a.relPath);
      }
      SyncProgressTracker.step(task.id, a.relPath);
    }
  }

  async resolveConflict(task: SyncTask, conflict: Conflict, strategy: ConflictStrategy): Promise<Result<boolean>> {
    const connRes = await this.connectionManager.getById(task.connectionId);
    if (!connRes.success || connRes.data === null) {
      return Result.fail(-1, '连接不存在');
    }
    await this.applyConflictStrategy(task, connRes.data, conflict, strategy, new SyncResult());
    await this.syncStore.deleteConflict(task.id, conflict.relPath);
    return Result.ok(true);
  }

  private async applyConflictStrategy(task: SyncTask, conn: Connection, conflict: Conflict, strategy: ConflictStrategy, result: SyncResult): Promise<void> {
    const localPath = this.localFileService.joinPath(task.localDir, conflict.relPath);
    const remoteRel = this.remoteRelPath(task, conflict.relPath);
    if (strategy === ConflictStrategy.KeepLocal) {
      await this.webDavClient.uploadFile(conn, localPath, remoteRel, () => {});
    } else if (strategy === ConflictStrategy.KeepRemote) {
      await this.webDavClient.downloadFile(conn, remoteRel, localPath, 0, () => {});
    } else {
      const diff = Math.abs(conflict.localMtime - conflict.remoteMtime);
      if (diff <= LWW_EPSILON) {
        const copyPath = localPath + '.conflict.' + Date.now();
        const statRes = await this.localFileService.stat(localPath);
        if (statRes.success && statRes.data !== null) {
          const data = await this.localFileService.readFileRange(localPath, 0, statRes.data.size);
          if (data.success && data.data !== null) {
            await this.localFileService.writeFile(copyPath, data.data);
          }
        }
        await this.webDavClient.downloadFile(conn, remoteRel, localPath, 0, () => {});
      } else if (conflict.localMtime > conflict.remoteMtime) {
        await this.webDavClient.uploadFile(conn, localPath, remoteRel, () => {});
      } else {
        await this.webDavClient.downloadFile(conn, remoteRel, localPath, 0, () => {});
      }
    }
    await this.syncStore.deleteConflict(task.id, conflict.relPath);
  }

  private async rebuildFileStates(task: SyncTask, localSnap: Map<string, FileEntry>, remoteSnap: Map<string, FileEntry>): Promise<void> {
    await this.syncStore.clearTaskStates(task.id);
    const keys = new Set<string>();
    localSnap.forEach((v: FileEntry, k: string) => keys.add(k));
    remoteSnap.forEach((v: FileEntry, k: string) => keys.add(k));
    for (const path of keys) {
      const localEntry = localSnap.get(path);
      const remoteEntry = remoteSnap.get(path);
      const state = new FileState();
      state.taskId = task.id;
      state.relPath = path;
      state.localMtime = localEntry !== undefined ? localEntry.mtime : 0;
      state.remoteEtag = remoteEntry !== undefined ? remoteEntry.etag : '';
      state.remoteMtime = remoteEntry !== undefined ? remoteEntry.mtime : 0;
      state.conflict = false;
      await this.syncStore.upsertFileState(state);
    }
  }
}