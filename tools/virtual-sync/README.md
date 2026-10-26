# 离线同步验证流程

先用虚构数据复现问题，再修改，再跑相同场景。全部测试不使用真实账号、Token 或健康数据，不调用真实小米 API、Keychain 或 HealthKit。

## 本次调整

- 保留首轮 AppModel 同步入口互斥、部分健康权限不阻断其他类型的修复。
- HealthKit 查重窗口覆盖云端查询的完整日期，并包含被选中睡眠会话的完整分段；同一类型批次内部也按 external UUID 消重。
- 查重和删除限定本应用来源；不把官方小米 App 数据作为本应用的已导入记录。
- 睡眠、心率等普通样本回填：捕获旧对象 → 保存新样本 → 删除捕获的旧对象。保存失败不会先删旧数据，清理失败会报错、不返回成功游标。
- 压力回填只替换实际查询范围，独立 SwiftData 上下文关闭自动保存后一次提交；保存失败向上抛出，不推进游标。

仍然存在的边界：

- HealthKit 的保存与删除不是原子事务。保存后清理失败或进程中断可能暂留重复；需要重新回填相同范围以清理，不能依赖普通增量完成清理。
- 运动记录走独立的 WorkoutBuilder 流程，本轮未修改其删除后重建顺序。
- 其他来源数据保留，不实现官方小米与 HealthMi 的跨 App 自动合并。
- 普通样本无有效映射分组时保留旧历史，不把空响应自动解释为删除指令。
- 日汇总增量更新、账号隔离、分页无进展及其他审计项未在本轮全部解决。

## 运行

需要 Python 3，以及 Swift 6 或已准备镜像的 Docker。在仓库根目录执行：

```sh
python3 tools/virtual-sync/run.py --suite app
python3 tools/virtual-sync/run.py --suite engine
python3 tools/virtual-sync/run.py --suite stress
```

本机没有 Swift 时使用 Docker；首次拉镜像需要网络，测试运行时禁用网络：

```sh
docker pull swift:6.0.3@sha256:f19aea3f9a889df5884e1186e60be74869613477d99656b598c115a4b91af8a1
python3 tools/virtual-sync/run.py --docker --suite app
python3 tools/virtual-sync/run.py --docker --suite engine
python3 tools/virtual-sync/run.py --docker --suite stress
```

任何场景失败以非零退出码结束；产物位于临时目录，正常结束后清理。Docker 只读挂载临时源码，不挂载个人数据或仓库写目录。

可分别对照旧 AppModel 或旧 SyncEngine；其余依赖仍使用当前测试夹具和当前源码，不表示完整旧版本复现：

```sh
python3 tools/virtual-sync/run.py --suite app --model /absolute/path/to/old/AppModel.swift
python3 tools/virtual-sync/run.py --suite engine --engine /absolute/path/to/old/SyncEngine.swift
```

## 测试覆盖与边界

### app：12 个场景

原样编译生产 AppModel 方法体，只去除 HealthKit/SwiftData import。测试权限拒绝、前后台入口竞争、连接失败后重试、不可用设备、回填参数传递，以及压力回填保留范围外数据、失败不推进游标。

引擎、权限、存储和通知均为内存替身；这里不验证真实 HealthKit 授权或 SwiftData 行为。

### engine：13 个场景

原样编译 SyncEngine、MiParser、MiModels 和 HealthWriter 的查重/普通样本替换方法；API、样本映射、查询及存储使用替身。场景包括首日日界、完全位于查询日前的睡眠片段、同批重复记录、跨来源相同 ID、保存失败、清理失败重试、范围外历史与其他来源保留、空响应和网络失败。

只模拟这些场景需要的样本；不验证原生查询分页、所有 TypeMapper 映射或 WorkoutBuilder。

### stress：6 个场景

执行生产 StressStore.replace 方法，模拟持久化上下文的待提交修改与一次保存。验证首尾边界、范围外输入、批内去重、查询失败、提交失败和有效空范围替换。

Linux Swift 6.0 的 Foundation 在测试模型上进行 Predicate key path 检查时崩溃，因此此夹具只将 `#Predicate { ... }` 适配为相同内容的闭包。**不验证 SwiftData 宏、SQL 翻译、事务实现或界面上下文刷新。** 两个原生 SwiftData 回归用例补在 SyncStateStoreTests 中，需 Xcode 执行。

## 实际结果

基于 main `a9c4de4dcc04f0fec021485946c9aa64a4075757`，Swift 6.0.3、Swift 6 模式、完整严格并发检查：

- 首轮修改前：app 6/10；修改后 10/10。
- 本轮生产修改前：扩展 app 10/12；初始 engine 4/9，复现压力越界删除、时间窗口不一致与先删后写风险。
- 本轮修改后：app **12/12**、扩展 engine **13/13**、stress **6/6**，共 **31/31**。
- 新增的两个原生 SwiftData XCTest **未运行**；环境没有 Xcode/iOS SDK。

上线前仍需 Xcode 构建、现有及新增 XCTest、原生 HealthKit 保存/删除失败场景，以及 SwiftData 跨上下文显示更新验证。模拟通过不能等同于真机通过。
