import { FileEntry } from './FileEntry';
import { FileState } from './FileState';

const MTIME_WINDOW = 2;

export class ChangeDetector {
  static isSameFile(local: FileEntry | undefined, remote: FileEntry | undefined): boolean {
    if (local === undefined || remote === undefined) {
      return false;
    }
    return local.size === remote.size;
  }

  static isLocalChanged(localEntry: FileEntry | undefined, prev: FileState | undefined): boolean {
    if (localEntry !== undefined) {
      if (prev === undefined) {
        return true;
      }
      return Math.abs(localEntry.mtime - prev.localMtime) > MTIME_WINDOW;
    }
    return prev !== undefined;
  }

  static isRemoteChanged(remoteEntry: FileEntry | undefined, prev: FileState | undefined): boolean {
    if (remoteEntry !== undefined) {
      if (prev === undefined) {
        return true;
      }
      if (prev.remoteEtag !== '' && remoteEntry.etag !== '') {
        return remoteEntry.etag !== prev.remoteEtag;
      }
      if (prev.remoteEtag === '' && prev.remoteMtime <= 0) {
        return false;
      }
      return Math.abs(remoteEntry.mtime - prev.remoteMtime) > MTIME_WINDOW;
    }
    return prev !== undefined;
  }
}