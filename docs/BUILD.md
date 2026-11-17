# 编译与发布

## 环境

macOS 15或以上、Swift 6.1或以上、可用的macOS SDK与Python 3。本次公开包在Apple芯片Mac上构建，未提供Intel二进制包。项目使用Swift Package Manager，没有第三方Swift包依赖。

```bash
git clone https://github.com/hotpotly/PocketTransfer.git
cd PocketTransfer
swift --version
swift test
./scripts/package_public.sh
open "dist/Pocket Transfer.app"
```

脚本在仓库`dist/`生成App、以版本和当前机器架构命名的ZIP、`SHA256SUMS.txt`。构建缓存位于`.build/`。二者都被Git忽略，不应提交到源码。

App使用本地ad-hoc签名和hardened runtime。脚本不会使用或上传任何Developer ID私钥，不做Apple公证。面向更多用户分发时，应另外完成正式签名和公证。

## 结构

- `Sources/OsmoticCore/`：协议、传输、数据保护和纯逻辑。
- `Sources/Osmotic/`：SwiftUI界面及系统服务；可执行文件仍名为Osmotic以保留上游结构。
- `Tests/OsmoticCoreTests/`：协议样本、模拟相机、HTTP故障和策略测试。
- `Resources/`：本地化、图标、隐私声明和签名权限。
- `scripts/package_public.sh`：可移植公开包；不会嵌入开发者工作目录。

## 数据路径

公开包不设置`PocketTransferWorkspaceRoot`，使用用户Downloads和Application Support目录。开发时如主动设置该Info.plist键，则启用工作区隔离路径；不要将带有私人路径的构建分发给别人。

## 发布检查

1. `swift test`及Release构建通过。
2. 检查ZIP只包含App，不包含日志、媒体、配对记录、密码或工作区路径。
3. 检查许可证、来源署名、兼容性和未验证事项。
4. 核对`Resources/Info.plist`版本，发布Git标签及GitHub Release，上传ZIP与校验文件。
5. 真实相机测试结果与模拟测试分开记录，不把单台设备的速度写成保证。

本次公开仓库以隐私筛选的源码快照起步。上游来源：[smithplus/Osmotic](https://github.com/smithplus/Osmotic)，本地定制起点为其提交`e5c1498`。协议及第三方归属见README和LICENSE。
