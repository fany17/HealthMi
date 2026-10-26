# 更新日志

本文件记录 HealthMi 的版本变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

## [1.2.0] - 2026-10-27

- 增加区域时区的自选回填起止日期，包含两端，拒绝反向/未来日期，保留 7/30/90/全部选项。
- 历史回填不建立、推进或回退日常游标；超限错误展示类型和日期，保留 200 页与游标循环保护。
- 增加默认关闭的自动增量开关，以一小时为目标交给 iOS 调度；后台跳过首次同步，老游标分轮追赶并保留回看。
- 后台取消传播到请求、分页等待与 HealthKit 查询，完成回调仅一次；不刷新界面统计，不重复请求相同失败的睡眠窗口。
- 运动回填改为先保存后清理；扩大睡眠窗口不删除相邻日期的无关记录。压力/游标保存失败向上传递。
- 增加本机 50 轮非敏感运行指标和对应回归测试，CI 交付未签名 IPA、entitlements、提交号及测试结果。
- 保持 SwiftData schema、Keychain service 和 Bundle ID 兼容；覆盖安装步骤见 docs/MAC_HANDOFF.md。

## [1.1.0] - 2026-08-16

### 新增

- **多区域支持**：支持中国大陆/俄罗斯/欧洲/国际/新加坡/美国六个区域，自动适配 API 域名和时区，Dashboard 区域选择器
- **Swift Charts 趋势图**：7 天步数/心率/睡眠/HRV 趋势可视化（`HKStatisticsCollectionQuery` 按天查询）
- **每日详情页**：点击趋势图中任一天查看当日全部数据 + 压力记录明细
- **同步历史日志**：持久化每次类型同步的结果（成功/失败/拉取数/新增数），`SyncHistoryView` 列表展示，自动裁剪 200 条
- **同步失败通知**：后台同步失败时发送本地通知，`NotificationManager` 管理授权与发送
- **数据导出**：一键导出最近 7 天每日数据为 CSV，通过系统分享面板发送
- **App Intents / 快捷指令**：通过 Siri 或快捷指令触发同步（"同步 HealthMi 健康数据"）
- **压力数据同步**：新增 `SyncDataType.stress`，从云端拉取压力数据存入 SwiftData，Dashboard 展示 7 天平均压力
- **身体指标补全**：新增写入 BMI（`bodyMassIndex`）、肌肉量（`leanBodyMass`）、基础代谢（`basalEnergyBurned`）
- **运动记录心率**：运动记录关联平均/最大心率样本（`HKWorkoutBuilder` + `store.add(_:to:)`）
- **同步进度文字**：显示"正在同步 3/9"
- **HealthKit 授权实时检测**：每次同步前检查权限状态，被撤销时提示用户
- **统一日志**：`AppLog` 枚举集中管理所有 `os.Logger` 实例
- **SwiftData 迁移策略**：`SchemaV1` + `MigrationPlan`，为未来 schema 变更建立基础设施
- **测试覆盖**：新增 `SyncEngineTests`（窗口计算）、`SyncStateStoreTests`（游标+区域配置）

### 修复

- **后台同步失效**：Info.plist 添加 `BGTaskSchedulerPermittedIdentifiers`，统一 BG Task ID 为 `com.healthmi.HealthMi.sync`，`try?` 改为 do/catch + 日志
- **Sleep 数据重复下载**：SyncEngine 内缓存，sleep/呼吸频率/HRV 共享同一份睡眠原始数据（从 3 次降为 1 次）
- **退出登录不重置游标**：`disconnect()` 清除所有 `SyncState` 游标和压力记录
- **API 无重试/限流**：网络错误指数退避重试（最多 3 次），分页间 200ms 间隔，认证错误不重试，新增 HTTP 状态码检查
- **try? 静默吞错**：`SyncStateStore` 和 `BackgroundSync` 的 save/submit 错误改为 do/catch + Logger
- **睡眠去重边界漏洞**：`HealthWriter` 从 `.strictStartDate/.strictEndDate` 改为软边界
- **Keychain service 迁移**：从旧 `com.example.HealthMi` 一次性迁移到新 `com.healthmi.HealthMi`
- **后台同步任务取消**：存储 sync Task 引用，`expirationHandler` 中 `cancel()`，`syncAll` 检查 `Task.isCancelled`

### 优化

- **HealthKitReader 并行查询**：4 个独立统计查询用 `async let` 并行执行
- **标识符统一**：`project.yml` 的 `bundleIdPrefix` 和测试 bundle ID 从 `com.example` 改为 `com.healthmi`
- **MCP 工具 SQLite 性能**：连接复用 + WAL 模式 + `executemany` 批量插入
- **MCP 工具 0 值修正**：`_optional_float`/`_optional_int` 不再把 0 当 None
- **MCP 工具请求限流**：`iter_*` 方法间 200ms 间隔，可配置 `min_request_interval_seconds`
- **MCP 工具清理死配置**：删除未引用的 `auto_sync_on_start`/`stale_after_minutes`/`store_raw_payloads`

## [1.0.0] - 2026-08-14

### 首次开源发布

- Swift 移植 `mi-fitness-mcp-cn` 取数逻辑
- 8 类数据同步：日常活动、心率、睡眠、血氧、体重/体脂、运动记录
- WebView 登录小米账号 + 手动 Cookie 输入
- 增量同步 + 7/30/90/全部 回填
- 幂等写入（`HKMetadataKeyExternalUUID` 去重）
- Keychain 凭据存储
- `BGAppRefreshTask` 后台同步
- 加密向量单测（RC4/SHA256/SHA1 预言机测试）
