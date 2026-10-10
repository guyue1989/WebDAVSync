import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { ServiceContainer } from '../application/ServiceContainer';
import { SyncTask } from '../domain/SyncTask';
import { Conflict } from '../domain/Conflict';
import { SyncProgressTracker } from '../application/SyncProgressTracker';
import { Theme } from '../application/Theme';


@Entry
@Component
struct SyncStatusPage {
  @State tasks: SyncTask[] = [];
  @State conflicts: Conflict[] = [];
  @State lastMessage: string = '';
  @State progressText: string = '';
  @State progressVisible: boolean = false;
  @State displayRows: string[] = ['', '', '', '', ''];
  @StorageProp('themeMode') themeMode: string = 'light';
  private timerId: number = -1;

  private isDark(): boolean {
    return this.themeMode === 'dark';
  }

  async aboutToAppear(): Promise<void> {
    await ServiceContainer.init();
    await this.load();
  }

  onPageShow(): void {
    this.timerId = setInterval(() => {
      const snap = SyncProgressTracker.snapshot();
      this.progressVisible = snap.running;
      if (snap.running) {
        this.lastMessage = '';
        this.progressText = '同步中 ' + snap.done.toString() + '/' + snap.total.toString() + '  ' + snap.currentFile;
        const rows: string[] = [];
        const recent = snap.recentFiles;
        for (let i = 0; i < 5; i++) {
          if (i < recent.length) {
            rows.push(recent[recent.length - 1 - i]);
          } else {
            rows.push('');
          }
        }
        this.displayRows = rows;
      }
    }, 500);
  }

  onPageHide(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  async load(): Promise<void> {
    const res = await ServiceContainer.taskManager.list();
    if (res.success && res.data !== null) {
      this.tasks = res.data;
    }
    const allConflicts: Conflict[] = [];
    for (const t of this.tasks) {
      const cr = await ServiceContainer.syncStore.listConflicts(t.id);
      if (cr.success && cr.data !== null) {
        for (const c of cr.data) {
          allConflicts.push(c);
        }
      }
    }
    this.conflicts = allConflicts;
  }

  async runAll(): Promise<void> {
    this.lastMessage = '';
    let msg = '';
    for (const t of this.tasks) {
      const result = await ServiceContainer.syncEngine.startSync(t);
      if (msg === '') {
        msg = result.message;
      }
    }
    this.lastMessage = msg;
    await this.load();
    promptAction.showToast({ message: this.lastMessage });
  }

  build() {
    Column() {
      Row() {
        Button('‹ 返回').fontSize(14).onClick(() => { router.back(); })
        Text('同步状态').fontSize(20).fontWeight(FontWeight.Bold).fontColor(Theme.fg(this.isDark())).margin({ left: 8 })
      }
      .width('100%')
      .padding(16)
      .alignItems(VerticalAlign.Center)

      Button('立即同步全部').width('90%').margin({ bottom: 12 }).onClick(() => { this.runAll(); })

      if (this.progressVisible) {
        Column() {
          Row() {
            LoadingProgress().width(20).height(20).margin({ right: 8 })
            Text(this.progressText).fontSize(13).fontColor(Theme.primary(this.isDark())).layoutWeight(1)
          }
          .width('100%')
          .margin({ bottom: 8 })

          ForEach(this.displayRows, (row: string, idx: number) => {
            Row() {
              Text(row === '' ? '—' : row).fontSize(12).fontColor(idx === 0 ? Theme.primary(this.isDark()) : Theme.sub(this.isDark())).layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
          }, (row: string, idx: number) => idx.toString())
        }
        .width('90%')
        .margin({ bottom: 12 })
        .alignItems(HorizontalAlign.Start)
      }

      if (this.lastMessage !== '') {
        Text(this.lastMessage).fontSize(14).fontColor(Theme.primary(this.isDark())).margin({ bottom: 12 })
      }
      Text('冲突列表').fontSize(16).fontWeight(FontWeight.Medium).fontColor(Theme.fg(this.isDark())).width('90%').margin({ bottom: 8 })
      List() {
        ForEach(this.conflicts, (c: Conflict) => {
          ListItem() {
            Text(c.relPath + '（' + c.strategy + '）').fontSize(14).fontColor(Theme.fg(this.isDark())).padding(12)
          }
        }, (c: Conflict) => c.taskId + '/' + c.relPath)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark()))
  }

}
