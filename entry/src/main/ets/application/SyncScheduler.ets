import { SyncTask } from '../domain/SyncTask';
import { Result } from '../domain/Result';
import { ISyncEngine } from './SyncEngine';
import { ILocalFileService } from '../infrastructure/LocalFileService';
import { FileWatcher } from '../infrastructure/FileWatcher';
import { IFileWatcher } from '../infrastructure/FileWatcher';
import { FileEvent } from '../infrastructure/FileWatcher';
import { INotificationService } from './NotificationService';
import { IBackgroundTaskService } from './BackgroundTaskService';

export interface ISyncScheduler {
  startWatch(task: SyncTask): Promise<Result<boolean>>;
  stopWatch(taskId: string): Promise<void>;
  startPolling(task: SyncTask): Promise<Result<boolean>>;
  stopPolling(taskId: string): Promise<void>;
  stopAll(): Promise<void>;
}

export class SyncScheduler implements ISyncScheduler {
  private localFileService: ILocalFileService;
  private syncEngine: ISyncEngine;
  private notificationService: INotificationService | null;
  private backgroundTaskService: IBackgroundTaskService | null;
  private watchers: Map<string, IFileWatcher> = new Map<string, IFileWatcher>();
  private pollTimers: Map<string, number> = new Map<string, number>();

  constructor(localFileService: ILocalFileService, syncEngine: ISyncEngine, notificationService: INotificationService | null, backgroundTaskService: IBackgroundTaskService | null) {
    this.localFileService = localFileService;
    this.syncEngine = syncEngine;
    this.notificationService = notificationService;
    this.backgroundTaskService = backgroundTaskService;
  }

  async startWatch(task: SyncTask): Promise<Result<boolean>> {
    if (this.watchers.has(task.id)) {
      return Result.ok(true);
    }
    if (!task.watchEnabled) {
      return Result.ok(false);
    }
    const watcher = new FileWatcher(this.localFileService);
    const res = await watcher.watch(task.localDir, task.debounceMs, (events: FileEvent[]) => {
      watcher.pause();
      this.syncEngine.onLocalChange(task, events).then((r) => {
        watcher.resume().then(() => {
          if (this.notificationService !== null) {
            this.notificationService.notifySyncResult(r);
          }
        });
      });
    });
    if (res.success) {
      this.watchers.set(task.id, watcher);
      if (this.backgroundTaskService !== null) {
        this.backgroundTaskService.start();
      }
    }
    return res;
  }

  async stopWatch(taskId: string): Promise<void> {
    const watcher = this.watchers.get(taskId);
    if (watcher !== undefined) {
      await watcher.stop();
      this.watchers.delete(taskId);
    }
  }

  private pauseWatcher(taskId: string): void {
    const watcher = this.watchers.get(taskId);
    if (watcher !== undefined) {
      watcher.pause();
    }
  }

  private async resumeWatcher(taskId: string): Promise<void> {
    const watcher = this.watchers.get(taskId);
    if (watcher !== undefined) {
      await watcher.resume();
    }
  }

  async startPolling(task: SyncTask): Promise<Result<boolean>> {
    if (this.pollTimers.has(task.id)) {
      return Result.ok(true);
    }
    const timer = setInterval(() => {
      this.syncEngine.pullRemoteChanges(task).then((r) => {
        if (this.notificationService !== null) {
          this.notificationService.notifySyncResult(r);
        }
      });
    }, task.pollIntervalSec * 1000);
    this.pollTimers.set(task.id, timer);
    if (this.backgroundTaskService !== null) {
      this.backgroundTaskService.start();
    }
    return Result.ok(true);
  }

  async stopPolling(taskId: string): Promise<void> {
    const timer = this.pollTimers.get(taskId);
    if (timer !== undefined) {
      clearInterval(timer);
      this.pollTimers.delete(taskId);
    }
  }

  async stopAll(): Promise<void> {
    const watchIds: string[] = [];
    this.watchers.forEach((v: IFileWatcher, k: string) => {
      watchIds.push(k);
    });
    for (const id of watchIds) {
      await this.stopWatch(id);
    }
    const pollIds: string[] = [];
    this.pollTimers.forEach((v: number, k: string) => {
      pollIds.push(k);
    });
    for (const id of pollIds) {
      await this.stopPolling(id);
    }
    if (this.backgroundTaskService !== null) {
      await this.backgroundTaskService.stop();
    }
  }
}