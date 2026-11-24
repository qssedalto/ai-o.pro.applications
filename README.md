# AI-O Studio

原生 macOS 14+ 商城只读客户端（SwiftUI / Swift Package Manager）。使用本机钥匙串保存商户 ID 和密钥，固定 HTTPS 站点，不使用登录 Cookie，不执行余额采购。

## 构建

在 Mac 安装 Xcode Command Line Tools 后运行：

    swift test
    bash scripts/package.sh
    open "dist/AI-O Studio.app"

GitHub Actions 在 macOS 上执行测试并生成 ad-hoc 签名 ZIP，未进行 Apple 公证。正式签名由所有者本地完成。CI 不读取商户密钥。

## 第一版

商品目录、搜索、账户余额、商品详情、类别规格、总报价、规格库存、库存校验、零售价参考毛利、历史快照和 CSV。历史记录保存在本地 Application Support JSON；仅记录成功的手动查询。目录库存和规格库存不同；不把供应商库存或销量视为本店资产。动态多维 SKU 和预选卡未实现。任何交易、自动采购、账户凭证交付均未实现。

供应商商品说明仅作参考；不将第三方描述视作品牌授权。网页详情禁用脚本和外部资源。首次启动在账户设置填写重置后的密钥，不要提交凭证或真实响应到仓库。
