# MerchantBase 接入与交互

[English](merchantbase-integration-en.md) · 中文

本文对应当前 `src/Merchant/MerchantBaseUpgradeable.sol`、`IMarket` 和 `TradeExecutor`。文件名含 `Upgradeable`，合约名是抽象基类 `MerchantBase`。它为**多 owner、多层级的合约 Merchant** 接入一个 Market 提供收款身份校验和出款额度账本；平台币、消费权益、创作者分账仍由派生合约或业务系统实现。EOA Merchant 可以直接参与 Market，但不会获得这里的回调、白名单和分桶约束。

## 1. 先区分四类身份

| 名称 | 在此基类中的作用 |
| --- | --- |
| 合约管理员 `owner()` | 维护白名单、`business`、Executor，并授权基类代理升级；不会因此自动获得 `tradeOut` 权限。 |
| Account Owner | 注册 `(owner, 平台代理)` Market 账户，控制乘数，接收该账户的买卖权利。 |
| Merchant | 此处是 **MerchantBase 代理地址**，接收销售实际到款，并作为买方调用 Market 以使用本账户可退关税。 |
| `business()` | 平台业务执行地址，可使用 business 释放桶；不是目标收款人，也不是所有账户的 owner。 |

一份平台代理可服务多个 Account Owner。每个 `(owner, proxy)` 配对都有独立的 Market accountId、押金、净余额和关税；同一乘数的业务流量则可以在 business 桶汇总。`rechargeTarget` 是由目标 Merchant 解释的 `uint160` 业务标识，基类不会按它建立持久销售桶。

## 2. 初始化并注册 Market 账户

派生合约通过代理部署，并在自己的 `initializer` 中调用：

```solidity
__MerchantBase_init(
    marketAddress,
    underlyingAddress,
    initialAccountOwner,
    tradeExecutorAddress,
    businessAddress,
    ownerShareBps,
    businessShareBps
);
```

`initialAccountOwner` 必须非零，初始化时先加入支持名单；**不会**自动在 Market 注册账户。两份释放比例均以 10000 为分母，相加必须为 10000，例如 `2000 / 8000`；允许一侧为零。当前接口没有比例修改函数，因为改变比例会重新分配历史收入。`owner()` 是代理初始化的调用者 `msg.sender`，并不必然是 `initialAccountOwner`。基类从 Market 读取 `settlementAsset()`，但不会完整验证所有地址组合；部署时要核对 Market、underlying、SettlementAsset 和 Executor 指向同一结算路径。

每位 Account Owner 先获得平台支持，再从本人地址注册：

```solidity
platform.setAccountOwnerSupport(accountOwner, true); // 由平台管理员执行；初始 owner 已支持
// accountOwner 先向 Market 的 SettlementAsset 授权押金
uint256 accountId = market.registerMerchant(address(platformProxy), deposit, multiplier);
```

注册调用者必须就是 Account Owner；押金大于零，乘数至少 1000。`market.accountIdOf(accountOwner, address(platformProxy))` 可查 accountId，`market.accounts(accountId)` 可查 owner、merchant、押金、乘数与激活状态。Market 注册和 MerchantBase 支持名单是两层条件：账户已激活但 owner 未受支持，平台收款回调仍会回滚。

任何人可调用 `Market.addDeposit(accountId, amount)` 为已激活账户全额增押；这不增加 MerchantBase 的 `received`，也不会即时退还关税。只有 Account Owner 可通过 `setCapacityMultiplier` 保持或降低乘数。基类按当前乘数入桶，**不会**迁移旧乘数桶；接入方应在业务上协调乘数变化。

## 3. 用户向平台付款：调用 Market.trade

付款人先向 SettlementAsset 授权，再调用：

```solidity
market.trade(
    buyer,                   // 买方账户的 Account Owner
    buyerAccountId,          // 0 表示 Market 默认买方账户
    platformSellerAccountId, // 已激活的 (owner, 平台代理) 卖方账户
    rechargeTarget,
    amount,
    data
);
```

`buyer` 可以与实际 Payer 不同。`buyerAccountId = 0` 只让 Market 查找或创建 `(buyer, buyer)` 默认买方账户，**不会**自动选择买方在平台上的账户。首次使用未激活默认账户时须由买方本人付款；显式买方 ID 必须属于 `buyer`。卖方 ID 始终必须已激活，并决定本笔收入归哪个平台账户、卖方权利铸给哪个 owner。

Market 先计算 `vaultFee = floor(amount / 100)`、`netAmount = amount - vaultFee`，再按卖方关税确定 `deltaW`。对 MerchantBase 而言：

| 金额 | 含义 |
| --- | --- |
| `amount` | 含权利费用的完整订单额。 |
| `netAmount` | 扣权利费用后的交易值，基类 `received` 桶增加此数。 |
| `deltaW` | 实际转到平台代理的结算代币；可能小于 `netAmount`。 |

所有金额均为 underlying 的最小单位；不能假定每种代币都是 6 位小数。Market 当前使用单一结算代币。第三方代付仍给买方账户记余额与权利，但不能动用该账户已收关税。

执行顺序是：

```text
Market 记余额、关税和权利
  → SettlementAsset 把 deltaW 转给平台代理
  → TradeExecutor 调用平台代理 tradeIn
  → 基类校验 owner 和账户、记录流量
  → 派生合约 _tradeIn 处理业务数据
```

合约收款人无论 `data` 是否为空都会收到回调；EOA 收款人没有回调。Executor 先转账再回调，平台不需要从 Executor `transferFrom`。回调中可以只读查询 Market，但不能重入同一 Market 的 `trade`；回调失败会回滚整笔交易。

## 4. tradeIn：白名单、账户和业务钩子

Executor 调用的外部接口为：

```solidity
function tradeIn(
    address registeredRightsOwner,
    uint160 rechargeTarget,
    uint256 netAmount,
    uint256 deltaW,
    bytes calldata data
) external;
```

基类只接受配置的 `tradeExecutor`，要求 `registeredRightsOwner` 在支持名单中，并通过 `(registeredRightsOwner, address(this))` 找到**已激活**的平台 Market 账户。它读取当前 `capacityMultiplier`，把同一笔 `netAmount` 同时记入 owner 和 business 两个原始收入视角，再调用派生钩子：

```solidity
function _tradeIn(
    uint160 rechargeTarget,
    uint256 capacityMultiplier,
    uint256 netAmount,
    uint256 deltaW,
    bytes calldata data
) internal override {
    // 在这里验证业务标识、订单资料与充值/分账规则。
}
```

外部 `tradeIn` 不接受乘数参数；乘数由基类从 Market 账户读取并传给内部钩子。基类不实现平台币发行、用户余额或创作者应得金额。支持名单关闭会阻止后续收款，但不删除 Market 账户和历史桶。

## 5. 两套流量桶与固定释放比例

| 桶 | 键 | `received` | `released` |
| --- | --- | --- | --- |
| owner 桶 | Account Owner + multiplier | 该 owner 在此乘数下的累计 `netAmount` | owner 路径累计支出的完整 `amount` |
| business 桶 | multiplier | 所有受支持 owner 在此乘数下的累计 `netAmount` | business 路径累计支出的完整 `amount` |

同一笔销售在两个 `received` 中各记一次，表示两种查看角度，**不是双倍收入**。初始化时固定的比例决定各自可释放份额：

```text
ownerAvailable =
    floor(ownerReceived × ownerShareBps / 10000) - ownerReleased
businessAvailable =
    floor(businessReceived × businessShareBps / 10000) - businessReleased
```

例如 `netAmount = 99` 个最小单位，比例为 `2000 / 8000`，owner 与 business 桶各记 `received = 99`，但两条路径最多分别释放 19 和 79 个单位；向下取整的余数会留到以后累计收入中。每个乘数桶分开计算，owner 不能用另一个 owner 的额度，business 可汇总同乘数的收入。`received` 不是平台代理的实时 ERC20 余额：部分 `netAmount` 可能仍作为关税留在 SettlementAsset；有额度也不保证立即有足够现金付款。

查询 `accountOwnerFlow(owner, multiplier)`、`businessFlow(multiplier)` 得到原始累计值，再用 `releaseShares()` 计算可用额。

## 6. 平台向上游付款：tradeOut

平台为 Account Owner 或 business 执行采购、上游付款或创作者分成时，调用：

```solidity
platform.tradeOut(
    buyer,           // 源 Market 账户的 Account Owner
    buyerAccountId,  // 必须是已激活的 (buyer, 平台代理) 账户
    sellerAccountId, // 目标收款人的已激活卖方账户
    rechargeTarget,
    amount,
    data
);
```

这里平台作为**买方 Merchant**，上游或创作者作为**目标卖方账户**。`MerchantBase.tradeOut` 不使用 ID 0 默认买方路径：它先读取源账户，要求已激活、merchant 是平台代理、owner 等于 `buyer`，且 owner 仍获支持。目标卖方在 Market 中也必须已激活；相同 ID 自交易、冻结账户或层级不合规都会回滚。Market 的默认买方功能仍可用于其他直接调用 `Market.trade` 的场景。

调用者若等于 `business()`，优先消耗 business 桶；否则必须等于该源账户的 Account Owner，消耗该 owner 桶。合约管理员没有额外的 `tradeOut` 特权。business 可以选择任意受支持的平台源账户，但业务层必须自行核实创作者身份、应得金额和提现授权；基类只管聚合额度。

基类先增加对应桶的 `released`，再用平台代理持有的 underlying 向 SettlementAsset 授权完整 `amount`，并以平台地址调用 `Market.trade`。这使 `msg.sender` 等于买方账户的 Merchant，故本账户若有符合条件的可退关税，可自动抵扣本次付款；退款不会单独打给外部调用者。`released` 总是记完整 `amount`，而非 `amount - refund` 或目标的 `deltaW`。Market 或目标回调失败时，授权、转账与桶记录都随交易回滚。

## 7. 生命周期、管理与索引

仅合约管理员可调用 `setAccountOwnerSupport`、`setBusiness` 和 `setTradeExecutor`。改变 business 地址会把既有 business 额度交给新地址，不会清空桶。Executor 是收款回调的信任入口，修改时须与 Market 配置协调。基类 UUPS 升级遵循 `onlyOwner`；升级旧代理前需单独审查存储布局和历史桶。

Account Owner 可在 Market 中申请退押。申请后账户立即冻结，180 天后领取押金；残余关税归 Merchant，账户和配对映射删除。治理也可按账户 ID 踢出。**MerchantBase 的流量桶独立于 Market 生命周期**：退出或踢出不会清零桶；同一 owner–Merchant 配对重新注册取得新 ID 后，若仍使用相同乘数，会继续命中旧桶。业务系统须决定如何管理这份历史额度。

链下索引可关注 `SaleRecorded`、`AccountOwnerReleaseRecorded`、`BusinessReleaseRecorded`、`AccountOwnerSupportUpdated`、`ReleaseSharesConfigured`、`BusinessUpdated` 与 `TradeExecutorUpdated`。基类没有枚举所有 owner/乘数的接口；可从事件建立索引，再调用 getter 核对。Market 净余额、退税和权利票需结合 Market 与选举事件，不能仅由 `SaleRecorded` 推出。

对应测试见 `test/MerchantBaseTest.t.sol`、`test/MerchantAccountingRegression.t.sol` 和 `test/DepositWithdrawalTest.t.sol`；整体关税与治理见 [Market 机制说明](market-mechanism-zh.md)。