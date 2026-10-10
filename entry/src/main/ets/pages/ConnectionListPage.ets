import router from '@ohos.router';
import { ServiceContainer } from '../application/ServiceContainer';
import { Connection } from '../domain/Connection';
import { Theme } from '../application/Theme';

@Entry
@Component
struct ConnectionListPage {
  @State connections: Connection[] = [];
  @State activeId: string = '';
  @StorageProp('themeMode') themeMode: string = 'light';

  private isDark(): boolean {
    return this.themeMode === 'dark';
  }

  async aboutToAppear(): Promise<void> {
    await this.load();
  }

  async load(): Promise<void> {
    await ServiceContainer.init();
    const list = await ServiceContainer.connectionManager.list();
    if (list.success && list.data !== null) {
      this.connections = list.data;
    }
    const active = await ServiceContainer.connectionManager.getActive();
    if (active.success && active.data !== null) {
      this.activeId = active.data.id;
    }
  }

  async setActive(id: string): Promise<void> {
    await ServiceContainer.connectionManager.setActive(id);
    await this.load();
  }

  async remove(id: string): Promise<void> {
    await ServiceContainer.connectionManager.remove(id);
    await this.load();
  }

  build() {
    Column() {
      Row() {
        Button('‹ 返回').fontSize(14).onClick(() => { router.back(); })
        Text('连接管理').fontSize(20).fontWeight(FontWeight.Bold).fontColor(Theme.fg(this.isDark())).margin({ left: 8 })
      }
      .width('100%')
      .padding(16)
      .alignItems(VerticalAlign.Center)

      List() {
        ForEach(this.connections, (conn: Connection) => {
          ListItem() {
            Row() {
              Column() {
                Text(conn.name !== '' ? conn.name : conn.baseUrl).fontSize(16).fontColor(Theme.fg(this.isDark()))
                Text(conn.username + ' @ ' + conn.rootPath).fontSize(12).fontColor(Theme.sub(this.isDark()))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              if (conn.id === this.activeId) {
                Text('当前').fontSize(12).fontColor(Theme.primary(this.isDark())).margin({ right: 8 })
              }
              Button('编辑').fontSize(12).height(32).onClick(() => {
                AppStorage.setOrCreate('editingConnId', conn.id);
                router.pushUrl({ url: 'pages/ConnectionEditPage', params: { id: conn.id } });
              })
              Button('设为当前').fontSize(12).height(32).margin({ left: 8 }).onClick(() => {
                this.setActive(conn.id);
              })
              Button('删除').fontSize(12).height(32).margin({ left: 8 }).onClick(() => {
                this.remove(conn.id);
              })
            }
            .width('100%')
            .padding(12)
          }
        }, (conn: Connection) => conn.id)
      }
      .layoutWeight(1)

      Button('新增连接').width('90%').margin({ bottom: 16 }).onClick(() => {
        AppStorage.setOrCreate('editingConnId', '');
        router.pushUrl({ url: 'pages/ConnectionEditPage', params: { id: '' } });
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg(this.isDark()))
  }
}