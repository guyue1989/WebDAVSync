# WebDAV 同步

HarmonyOS NEXT 上的 WebDAV 文件同步工具，面向 Synology NAS 等 WebDAV 服务器，支持本地目录与远程目录之间的双向/单向同步。

## 功能特性

- **连接管理** — 支持配置多个 WebDAV 服务器，LAN/WAN 双地址自动探测，凭证 AES-256-CBC 加密存储
- **同步方向** — 双向同步、仅上传、仅下载三种模式
- **冲突处理** — 保留本地 / 保留远程 / 生成副本 / 手动处理四种策略，双向同步时自动检测冲突
- **实时监听** — 基于本地文件监听的增量同步，支持防抖
- **定时轮询** — 可配置的远端轮询间隔，检测远端变更
- **文件过滤** — 通配符规则过滤，跳过不需要同步的文件
- **并发传输** — 可配置并发数，大文件分块下载（4 MB/chunk）
- **断点续传** — 下载通过 Range 请求分块拼接，原子落盘
- **深色模式** — 全局浅色/深色主题切换
- **响应式布局** — GridRow 栅格适配手机、平板、2in1 设备

## 技术栈

| 项 | 说明 |
|---|---|
| 平台 | HarmonyOS NEXT (API 13 / SDK 6.1.0) |
| 语言 | ArkTS |
| 构建 | hvigor |
| 网络 | `@ohos.net.http`（PROPFIND / GET Range / PUT / MKCOL / DELETE） |
| 加密 | `@ohos.security.cryptoFramework`（AES256-CBC-PKCS7） |
| 持久化 | `@ohos.data.preferences`（凭证 & 连接配置） |

## 项目结构

```
AppScope/                        # 应用级配置
entry/src/main/ets/
├── application/                 # 应用服务层
│   ├── AppContext.ets           # 全局 Context 持有
│   ├── ServiceContainer.ets     # 依赖组装（手动 DI 容器）
│   ├── ConnectionManager.ets    # 连接 CRUD
│   ├── SyncEngine.ets           # 同步核心：快照对比 → 计划生成 → 执行
│   ├── SyncScheduler.ets        # 文件监听 + 定时轮询调度
│   ├── TaskManager.ets          # 同步任务管理
│   ├── SyncProgressTracker.ets  # 进度追踪
│   ├── BackgroundTaskService.ets
│   ├── NotificationService.ets  # 同步结果通知
│   ├── Theme.ets                # 主题色定义
│   └── LogService.ets
├── domain/                      # 领域模型
│   ├── Connection.ets           # 连接模型
│   ├── SyncTask.ets             # 同步任务模型
│   ├── FileEntry.ets            # 文件条目
│   ├── FileState.ets            # 文件同步状态（快照）
│   ├── SyncResult.ets           # 同步结果
│   ├── Conflict.ets             # 冲突模型
│   ├── ChangeSet.ets / ChangeDetector.ets  # 变更检测
│   ├── FileFilter.ets           # 通配符过滤
│   ├── TransferCursor.ets
│   ├── Enums.ets                # 枚举定义
│   └── Result.ets               # 通用 Result<T>
├── infrastructure/              # 基础设施
│   ├── WebDavClient.ets         # WebDAV 协议实现
│   ├── LocalFileService.ets     # 本地文件读写
│   ├── SyncStore.ets            # 同步状态持久化
│   ├── SecureStore.ets          # 凭证加密存储
│   └── FileWatcher.ets          # 本地文件变更监听
├── pages/                       # UI 页面
│   ├── Index.ets                # 主页（四宫格入口）
│   ├── ConnectionListPage.ets   # 连接列表
│   ├── ConnectionEditPage.ets   # 连接编辑
│   ├── FileBrowserPage.ets      # 远端文件浏览
│   ├── SyncSettingsPage.ets     # 同步设置
│   ├── SyncStatusPage.ets       # 同步状态
│   └── LocalDirPickerPage.ets   # 本地目录选择
└── entryability/
    └── EntryAbility.ets         # 应用入口 Ability
```

## 架构设计

采用分层架构 + 手动依赖注入：

- **domain** — 纯数据模型与业务规则，不依赖框架 API
- **infrastructure** — 文件系统、WebDAV 协议、持久化等具体实现，均定义接口（`IWebDavClient`、`ILocalFileService` 等）
- **application** — 业务编排层，`SyncEngine` 通过接口调用基础设施，`ServiceContainer` 在启动时组装依赖图

同步引擎核心流程：

1. 扫描本地目录快照 + 递归 PROPFIND 构建远端快照
2. 与上次同步保存的 `FileState` 对比，通过 `ChangeDetector` 判定本地/远端是否变更
3. `computePlan` 生成同步计划（上传/下载/删除/建目录/冲突）
4. 按依赖顺序执行：先建目录 → 再传文件 → 最后处理删除
5. 执行完毕后重建 `FileState` 快照

## 构建与运行

1. 复制签名模板：`cp build-profile.json5.template build-profile.json5`
2. 将 `build-profile.json5` 中的占位值替换为实际的签名证书路径和密码（该文件已在 `.gitignore` 中，不会被提交）
3. 使用 DevEco Studio 5.0+ 打开项目根目录
4. 等待 hvigor 同步完成、依赖下载
5. 选择目标设备（手机/平板/2in1），点击 Run 即可

## 权限

| 权限 | 用途 |
|---|---|
| `ohos.permission.INTERNET` | WebDAV 网络通信 |
| `ohos.permission.GET_NETWORK_INFO` | 检测网络状态 |

## 兼容性

- 最低 API 版本：6.1.0 (23)
- 编译 SDK：6.1.0 (23)
- 运行时：HarmonyOS NEXT
- 设备类型：phone / tablet / 2in1
