import { SecureStore } from '../infrastructure/SecureStore';
import { LocalFileService } from '../infrastructure/LocalFileService';
import { WebDavClient } from '../infrastructure/WebDavClient';
import { SyncStore } from '../infrastructure/SyncStore';
import { ConnectionManager } from './ConnectionManager';
import { SyncEngine } from './SyncEngine';
import { SyncScheduler } from './SyncScheduler';
import { NotificationService } from './NotificationService';
import { TaskManager } from './TaskManager';
import { BackgroundTaskService } from './BackgroundTaskService';

export class ServiceContainer {
  static syncStore: SyncStore = new SyncStore();
  static secureStore: SecureStore = new SecureStore();
  static localFileService: LocalFileService = new LocalFileService();
  static webDavClient: WebDavClient = new WebDavClient(ServiceContainer.secureStore, ServiceContainer.localFileService);
  static connectionManager: ConnectionManager = new ConnectionManager(ServiceContainer.secureStore, ServiceContainer.webDavClient);
  static syncEngine: SyncEngine = new SyncEngine(ServiceContainer.webDavClient, ServiceContainer.localFileService, ServiceContainer.syncStore, ServiceContainer.connectionManager);
  static notificationService: NotificationService = new NotificationService();
  static backgroundTaskService: BackgroundTaskService = new BackgroundTaskService();
  static syncScheduler: SyncScheduler = new SyncScheduler(ServiceContainer.localFileService, ServiceContainer.syncEngine, ServiceContainer.notificationService, ServiceContainer.backgroundTaskService);
  static taskManager: TaskManager = new TaskManager();
  static initialized: boolean = false;

  static async init(): Promise<void> {
    if (ServiceContainer.initialized) {
      return;
    }
    await ServiceContainer.syncStore.init();
    await ServiceContainer.connectionManager.init();
    await ServiceContainer.taskManager.init();
    ServiceContainer.initialized = true;
  }

  static async startupSync(): Promise<void> {
    const tasks = await ServiceContainer.taskManager.list();
    if (!tasks.success || tasks.data === null) {
      return;
    }
    for (const task of tasks.data) {
      await ServiceContainer.syncEngine.startSync(task);
      if (task.watchEnabled) {
        await ServiceContainer.syncScheduler.startWatch(task);
      }
      await ServiceContainer.syncScheduler.startPolling(task);
    }
  }
}