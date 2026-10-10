class ProgressSession {
  total: number = 0;
  done: number = 0;
  currentFile: string = '';
  recentFiles: string[] = [];
  running: boolean = false;
}

export class ProgressSnapshot {
  running: boolean = false;
  total: number = 0;
  done: number = 0;
  currentFile: string = '';
  recentFiles: string[] = [];
}

export class SyncProgressTracker {
  private static activeId: string = '';
  private static sessions: Map<string, ProgressSession> = new Map<string, ProgressSession>();
  private static readonly MAX_RECENT = 20;

  static begin(sessionId: string, total: number): void {
    let s = SyncProgressTracker.sessions.get(sessionId);
    if (s === undefined) {
      s = new ProgressSession();
      SyncProgressTracker.sessions.set(sessionId, s);
    }
    if (!s.running) {
      s.total = total;
      s.done = 0;
      s.currentFile = '';
      s.recentFiles = [];
      s.running = true;
    }
    SyncProgressTracker.activeId = sessionId;
  }

  static step(sessionId: string, currentFile: string): void {
    const s = SyncProgressTracker.sessions.get(sessionId);
    if (s === undefined) {
      return;
    }
    s.done += 1;
    s.currentFile = currentFile;
    s.recentFiles.push(currentFile);
    if (s.recentFiles.length > SyncProgressTracker.MAX_RECENT) {
      s.recentFiles.splice(0, s.recentFiles.length - SyncProgressTracker.MAX_RECENT);
    }
    SyncProgressTracker.activeId = sessionId;
  }

  static finish(sessionId: string): void {
    const s = SyncProgressTracker.sessions.get(sessionId);
    if (s !== undefined) {
      s.running = false;
    }
  }

  static snapshot(): ProgressSnapshot {
    const snap = new ProgressSnapshot();
    const s = SyncProgressTracker.sessions.get(SyncProgressTracker.activeId);
    if (s === undefined) {
      return snap;
    }
    snap.running = s.running;
    snap.total = s.total;
    snap.done = s.done;
    snap.currentFile = s.currentFile;
    snap.recentFiles = s.recentFiles.slice();
    return snap;
  }
}