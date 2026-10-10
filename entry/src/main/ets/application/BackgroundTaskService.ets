import backgroundTaskManager from '@ohos.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { AppContext } from './AppContext';
import { Result } from '../domain/Result';

const BUNDLE_NAME = 'com.example.webdavsync';

export interface IBackgroundTaskService {
  start(): Promise<Result<boolean>>;
  stop(): Promise<Result<boolean>>;
}

export class BackgroundTaskService implements IBackgroundTaskService {
  async start(): Promise<Result<boolean>> {
    const ctx = AppContext.getContext();
    if (ctx === null) {
      return Result.fail(-1, 'context 为空');
    }
    try {
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: BUNDLE_NAME,
          abilityName: 'EntryAbility'
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(wantAgentInfo);
      await backgroundTaskManager.startBackgroundRunning(ctx, backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      return Result.ok(true);
    } catch (e) {
      return Result.fail(-1, '后台任务申请失败');
    }
  }

  async stop(): Promise<Result<boolean>> {
    const ctx = AppContext.getContext();
    if (ctx === null) {
      return Result.fail(-1, 'context 为空');
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(ctx);
      return Result.ok(true);
    } catch (e) {
      return Result.fail(-1, '后台任务停止失败');
    }
  }
}