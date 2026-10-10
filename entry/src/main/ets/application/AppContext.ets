import common from '@ohos.app.ability.common';

export class AppContext {
  private static context: common.UIAbilityContext | null = null;

  static setContext(ctx: common.UIAbilityContext): void {
    AppContext.context = ctx;
  }

  static getContext(): common.UIAbilityContext | null {
    return AppContext.context;
  }
}