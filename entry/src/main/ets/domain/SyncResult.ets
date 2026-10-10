import { SyncStatus } from './Enums';
import { Conflict } from './Conflict';

export class SyncResult {
  taskId: string = '';
  status: SyncStatus = SyncStatus.Idle;
  transferred: number = 0;
  failedCount: number = 0;
  failedPaths: string[] = [];
  conflicts: Conflict[] = [];
  message: string = '';
}