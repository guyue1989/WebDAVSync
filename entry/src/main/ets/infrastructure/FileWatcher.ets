import { ILocalFileService } from './LocalFileService';
import { FileEntry } from '../domain/FileEntry';
import { ChangeType } from '../domain/Enums';
import { Result } from '../domain/Result';

const POLL_INTERVAL_MS = 2000;

export class FileEvent {
  relPath: string = '';
  type: ChangeType = ChangeType.Modify;
}

export interface IFileWatcher {
  watch(dir: string, debounceMs: number, onEvent: (events: FileEvent[]) => void): Promise<Result<boolean>>;
  pause(): void;
  resume(): Promise<void>;
  stop(): Promise<void>;
}

export class FileWatcher implements IFileWatcher {
  private localFileService: ILocalFileService;
  private dir: string = '';
  private lastSnapshot: Map<string, FileEntry> | null = null;
  private pending: FileEvent[] = [];
  private pollTimer: number = -1;
  private debounceTimer: number = -1;
  private paused: boolean = false;
  private callback: ((events: FileEvent[]) => void) | null = null;
  private debounceMs: number = 1000;

  constructor(localFileService: ILocalFileService) {
    this.localFileService = localFileService;
  }

  async watch(dir: string, debounceMs: number, onEvent: (events: FileEvent[]) => void): Promise<Result<boolean>> {
    this.dir = dir;
    this.debounceMs = debounceMs;
    this.callback = onEvent;
    const snapshot = await this.localFileService.readSnapshot(dir);
    if (!snapshot.success || snapshot.data === null) {
      return Result.fail(-1, '无法读取目录快照');
    }
    this.lastSnapshot = snapshot.data;
    this.pollTimer = setInterval(() => {
      this.poll();
    }, POLL_INTERVAL_MS);
    return Result.ok(true);
  }

  private poll(): void {
    if (this.paused) {
      return;
    }
    this.localFileService.readSnapshot(this.dir).then((res: Result<Map<string, FileEntry>>) => {
      if (res.success && res.data !== null && this.lastSnapshot !== null) {
        const events = this.diff(this.lastSnapshot, res.data);
        if (events.length > 0) {
          this.mergeEvents(events);
          this.lastSnapshot = res.data;
          this.scheduleDebounce();
        } else {
          this.lastSnapshot = res.data;
        }
      }
    });
  }

  private diff(oldSnap: Map<string, FileEntry>, newSnap: Map<string, FileEntry>): FileEvent[] {
    const events: FileEvent[] = [];
    newSnap.forEach((entry: FileEntry, path: string) => {
      const old = oldSnap.get(path);
      if (old === undefined) {
        const e = new FileEvent();
        e.relPath = path;
        e.type = ChangeType.Add;
        events.push(e);
      } else if (old.mtime !== entry.mtime || old.size !== entry.size) {
        const e = new FileEvent();
        e.relPath = path;
        e.type = ChangeType.Modify;
        events.push(e);
      }
    });
    oldSnap.forEach((old: FileEntry, path: string) => {
      if (!newSnap.has(path)) {
        const e = new FileEvent();
        e.relPath = path;
        e.type = ChangeType.Delete;
        events.push(e);
      }
    });
    return events;
  }

  private mergeEvents(events: FileEvent[]): void {
    for (const e of events) {
      const idx = this.pending.findIndex((x: FileEvent) => x.relPath === e.relPath);
      if (idx >= 0) {
        this.pending[idx].type = e.type;
      } else {
        this.pending.push(e);
      }
    }
  }

  private scheduleDebounce(): void {
    if (this.debounceTimer !== -1) {
      clearTimeout(this.debounceTimer);
    }
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = -1;
      const events = this.pending;
      this.pending = [];
      if (this.callback !== null && events.length > 0) {
        this.callback(events);
      }
    }, this.debounceMs);
  }

  pause(): void {
    this.paused = true;
  }

  async resume(): Promise<void> {
    this.paused = false;
    this.pending = [];
    const snapshot = await this.localFileService.readSnapshot(this.dir);
    if (snapshot.success && snapshot.data !== null) {
      this.lastSnapshot = snapshot.data;
    }
  }

  async stop(): Promise<void> {
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    if (this.debounceTimer !== -1) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }
    this.lastSnapshot = null;
    this.pending = [];
    this.callback = null;
  }
}