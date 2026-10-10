import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import hilog from '@ohos.hilog';
import { AppContext } from '../application/AppContext';
import { ServiceContainer } from '../application/ServiceContainer';

const TAG = 'WebDAVSync';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppContext.setContext(this.context);
    PersistentStorage.persistProp('themeMode', 'light');
    ServiceContainer.init().then(() => {
      hilog.info(0x0000, TAG, 'ServiceContainer initialized');
      ServiceContainer.startupSync().then(() => {
        hilog.info(0x0000, TAG, 'startup sync finished');
      });
    });
    hilog.info(0x0000, TAG, 'EntryAbility onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, TAG, 'Failed to load content: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(0x0000, TAG, 'Succeeded in loading content');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, TAG, 'EntryAbility onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(0x0000, TAG, 'EntryAbility onForeground');
  }

  onBackground(): void {
    hilog.info(0x0000, TAG, 'EntryAbility onBackground');
  }
}