import router from '@ohos.router';
import { Theme } from '../application/Theme';

@Entry
@Component
struct Index {
  @StorageProp('themeMode') themeMode: string = 'light';

  private isDark(): boolean {
    return this.themeMode === 'dark';
  }

  build() {
    Column() {
      Row() {
        Text('WebDAV 同步').fontSize(26).fontWeight(FontWeight.Bold).fontColor(Theme.fg(this.isDark()))
        Blank()
        Text(this.isDark() ? '深色' : '浅色').fontSize(13).fontColor(Theme.sub(this.isDark())).margin({ right: 8 })
        Toggle({ type: ToggleType.Switch, isOn: this.isDark() }).onChange((on: boolean) => {
          AppStorage.setOrCreate('themeMode', on ? 'dark' : 'light');
        })
      }
      .width('100%')
      .padding(16)
      .alignItems(VerticalAlign.Center)


      GridRow({
        columns: { sm: 4, md: 8, lg: 12 },
        breakpoints: { value: ['320vp', '600vp', '840vp'], reference: BreakpointsReference.WindowSize },
        gutter: 12
      }) {
        GridCol({ span: { sm: 4, md: 4, lg: 3 } }) {
          this.menuItem('连接管理', 'pages/ConnectionListPage')
        }
        GridCol({ span: { sm: 4, md: 4, lg: 3 } }) {
          this.menuItem('文件浏览', 'pages/FileBrowserPage')
        }
        GridCol({ span: { sm: 4, md: 4, lg: 3 } }) {
          this.menuItem('同步设置', 'pages/SyncSettingsPage')
        }
        GridCol({ span: { sm: 4, md: 4, lg: 3 } }) {
          this.menuItem('同步状态', 'pages/SyncStatusPage')
        }
      }
      .width('100%')
      .padding(16)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark()))
  }

  @Builder
  menuItem(label: string, target: string) {
    Column() {
      Text(label).fontSize(18).fontWeight(FontWeight.Medium).fontColor(Theme.fg(this.isDark()))
    }
    .width('100%')
    .padding(28)
    .backgroundColor(Theme.card(this.isDark()))
    .borderRadius(12)
    .margin({ bottom: 12 })
    .onClick(() => {
      router.pushUrl({ url: target });
    })
  }
}