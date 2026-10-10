import { SyncDirection } from './Enums';
import { ConflictStrategy } from './Enums';

export class SyncTask {
  id: string = '';
  connectionId: string = '';
  localDir: string = '';
  remoteDir: string = '';
  direction: SyncDirection = SyncDirection.Bidirectional;
  conflictStrategy: ConflictStrategy = ConflictStrategy.CreateCopy;
  watchEnabled: boolean = true;
  debounceMs: number = 1000;
  pollIntervalSec: number = 60;
  filterRules: string = '';
  concurrency: number = 2;
}