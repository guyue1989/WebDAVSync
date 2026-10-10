
import { ServiceContainer } from '../application/ServiceContainer';
import { AppContext } from '../application/AppContext';
import { FileEntry } from '../domain/FileEntry';
import { Theme } from '../application/Theme';

@Entry
@Component
struct LocalDirPickerPage {
  @State currentPath: string = '';
  @State entries: FileEntry[] = [];
  @StorageProp('themeMode') themeMode: string = 'light';
  private sandboxRoot: string = '';

  private isDark(): boolean {
    return this.themeMode === 'dark';
  }

  private showToast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg });
    } catch (e) {
    }
  }

  private goBack(): void {
    try {
      this.getUIContext().getRouter().back();
    } catch (e) {
    }
  }

  async aboutToAppear(): Promise<void> {
    await ServiceContainer.init();
    const ctx = AppContext.getContext();
    if (ctx !== null) {
      this.sandboxRoot = ctx.filesDir;
      this.currentPath = ctx.filesDir;
      await this.refresh();
    }
  }

  async refresh(): Promise<void> {
    const res = await ServiceContainer.localFileService.listDirectory(this.currentPath);
    if (res.success && res.data !== null) {
      const dirs: FileEntry[] = [];
      for (const e of res.data) {
        if (e.isDirectory) {
          dirs.push(e);
        }
      }
      this.entries = dirs;
    }
  }

  enter(name: string): void {
    this.currentPath = ServiceContainer.localFileService.joinPath(this.currentPath, name);
    this.refresh();
  }

  goUp(): void {
    if (this.sandboxRoot !== '' && this.currentPath === this.sandboxRoot) {
      this.showToast('已是应用沙箱根目录');
      return;
    }
    const idx = this.currentPath.lastIndexOf('/');
    if (idx > 0) {
      const parent = this.currentPath.substring(0, idx);
      if (this.sandboxRoot !== '' && parent.length < this.sandboxRoot.length) {
        this.showToast('不能超出应用沙箱范围');
        return;
      }
      this.currentPath = parent;
      this.refresh();
    }
  }

  selectDir(): void {
    AppStorage.setOrCreate('selectedLocalDir', this.currentPath);
    this.goBack();
  }

  build() {
    Column() {
      Row() {
        Button('‹ 返回').fontSize(14).onClick(() => { this.goBack(); })
        Text('本地目录').fontSize(20).fontWeight(FontWeight.Bold).fontColor(Theme.fg(this.isDark())).margin({ left: 8 })
      }
      .width('100%')
      .padding(16)
      .alignItems(VerticalAlign.Center)

      Row() {
        Button('上级').fontSize(14).onClick(() => { this.goUp(); })
        Text(this.currentPath).fontSize(13).fontColor(Theme.sub(this.isDark())).margin({ left: 8 }).layoutWeight(1)
        Button('刷新').fontSize(14).onClick(() => { this.refresh(); })
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 12 })

      List() {
        ForEach(this.entries, (entry: FileEntry) => {
          ListItem() {
            Row() {
              Text('📁 ' + entry.name).fontSize(15).fontColor(Theme.fg(this.isDark())).layoutWeight(1)
            }
            .width('100%')
            .padding(12)
          }
          .onClick(() => { this.enter(entry.name); })
        }, (entry: FileEntry) => this.currentPath + '/' + entry.name)
      }
      .width('100%')
      .layoutWeight(1)

      Button('选择当前目录：' + this.currentPath).width('90%').margin({ bottom: 16 }).onClick(() => {
        this.selectDir();
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark()))
  }
}
