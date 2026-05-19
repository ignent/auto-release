# Auto Release

通过 GitHub Actions 每天自动拉取 `sources.json` 里定义的软件，并按 `APK` 与 `模块` 分开下载到 `releases/` 目录。

## 自定义方式

直接编辑 `sources.json`：

- `groups[].items` 里每一项就是一个下载源
- `github_apk` 用于 GitHub Release APK 自动择优
- `github_asset` 用于 GitHub Release 指定扩展名资源
- `direct` 用于直链下载
- `mt_manager_t28` 用于 MT 管理器 TargetSdk28 页面解析
- `telegram_lsposed` 用于 LSPosed Telegram 页面解析

## APK 下载

<!-- APK_TABLE_START -->
| 序号 | 软件名 | 版本 | 更新时间 | 下载链接 |
| --- | --- | --- | --- | --- |
<!-- APK_TABLE_END -->

## 模块下载

<!-- MODULE_TABLE_START -->
| 序号 | 软件名 | 版本 | 更新时间 | 下载链接 |
| --- | --- | --- | --- | --- |
<!-- MODULE_TABLE_END -->
