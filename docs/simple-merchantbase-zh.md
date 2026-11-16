# SimpleMerchantBase：单账户商家接入

[English](simple-merchantbase-en.md) · 中文

`SimpleMerchantBase` 是独立于现有 `MerchantBase` 的抽象 UUPS 基类，适合只经营**一个 Market、一个 Account Owner、一个固定押金乘数层级**的合约商家。它保留 owner/business 固定比例出款，但删去了多 owner 白名单和按乘数分桶。多账户、多层级商家可使用 `MerchantBase`。

## 1. 它简化了什么

| 项目 | SimpleMerchantBase 的规则 |
| --- | --- |
| Market 账户 | 只接受 `(accountOwner, 本代理)` 这一组配对；第一次成功收款自动绑定 accountId。 |
| 层级 | 初始化时固定 `capacityMultiplier`；每次收款和出款都核对 Market 中的实际乘数。 |
| 收入 | 只有一个累计 `received`，记录每笔扣除权利费用后的 `netAmount`。 |
| 出款 | `ownerReleased` 和 `businessReleased` 分开累计，但都从同一 `received` 按固定比例计算额度。 |
| 收款业务 | 派生合约实现简化的 `_tradeIn(rechargeTarget, netAmount, data)`。 |

这里的 Account Owner 是 Market 经济账户 owner；`owner()` 是可升级代理的管理员，初始化时也设为 Account Owner。管理员以后可以转移，但不会改变固定的经济账户 owner 或它的出款身份。

## 2. 部署与注册

派生合约通过 `ERC1967Proxy` 部署，并在自己的 `initializer` 中调用：

```solidity
__SimpleMerchantBase_init(
    marketAddress,
    accountOwner,
    tradeExecutorAddress,
    businessAddress,
    capacityMultiplier,
    ownerShareBps,
    businessShareBps
);
```

基类从 Market 的 SettlementAsset 读取 underlying，因此不用再传代币地址。`capacityMultiplier` 至少为 1000；两份比例必须相加等于 10000。如果两份比例都大于零，`businessAddress` 必须非零且不同于 Account Owner。比例初始化后没有普通修改入口。

部署代理后，由 **Account Owner 本人** 向 SettlementAsset 授权押金，再注册本代理：

```solidity
market.registerMerchant(address(simpleMerchantProxy), deposit, capacityMultiplier);
```

押金必须大于零；注册时的乘数要与代理初始化时设置的乘数一致。基类的 `accountId()` 在第一次成功收款前为 0；第一次 `tradeIn` 会从 `market.accountIdOf(accountOwner, address(this))` 读取并绑定已激活账户。之后如原账户退押或被踢出，即使同一配对重新注册为新 ID，旧代理也不会把历史额度带到新账户；这时需部署新的代理。若 Market 账户的乘数发生变化，收款与出款都会拒绝，符合固定层级的约定。

## 3. 收款与派生钩子

客户仍然直接调用 `Market.trade`。卖方 accountId 必须是该代理已激活的 Market 账户；`buyerAccountId = 0` 只属于客户在 Market 的默认买方路径。Market 经 SettlementAsset 转入全部 `netAmount` 后，TradeExecutor 调用基类的 `tradeIn`。

基类检查调用者是配置的 Executor、权利接收 owner 正确、账户已激活且未冻结、accountId 未更换、乘数未变化，然后增加 `received` 并调用派生钩子：

```solidity
function _tradeIn(
    uint160 rechargeTarget,
    uint256 netAmount,
    bytes calldata data
) internal override {
    // 这里实现订单校验、充值或业务记账。
}
```

`netAmount = amount - floor(amount / 100)` 是本次销售的交易值；该金额在钩子调用前全部转入代理。业务钩子失败会回滚整笔 Market 交易。基类不按 `rechargeTarget` 记账，也不维护客户或创作者余额。

## 4. 固定比例出款

两条出款路径共享一个累计收入基数：

```text
ownerAvailable    = floor(received × ownerShareBps / 10000) - ownerReleased
businessAvailable = floor(received × businessShareBps / 10000) - businessReleased
```

例如 `received = 99` 个最小单位、比例为 `4000 / 6000`，两侧当前上限分别是 39 和 59 个单位。向下取整的余数不会被双方重复花费。额度按包含权利费用的完整出款 `amount` 扣减。

Account Owner 或配置的 business 调用：

```solidity
simpleMerchant.tradeOut(
    sellerAccountId, // 上游或创作者的已激活卖方账户
    rechargeTarget,
    amount,
    data
);
```

基类固定使用自己的 `accountOwner` 和绑定的买方 accountId，不要求调用者重复传 `buyer` 和 `buyerAccountId`。**这里没有 ID 0 源账户路径**：平台作为买方 Merchant，必须使用已激活的源账户；目标卖方也必须已激活，并满足 Market 的乘数流向规则。

只有固定 Account Owner 可花 owner 份额，只有当前 `business()` 地址可花 business 份额。基类用平台代理的 underlying 向 SettlementAsset 授权完整 `amount`，再调用 Market。Market 拉取全部金额，并支付对应的权利费用和净收入。调用结束后清除授权。若 Market 或目标 Merchant 回滚，`released` 更新也回滚。

`received` 是累计收入，不等于代理当前的 ERC20 余额。全部净收入在钩子前到账；出款、使用 owner 份额增押和派生业务转账可能减少可用现金。业务方仍须核实流动性与上游应得金额。

## 5. 使用 owner 份额增押

固定 Account Owner 可在代理已有可用 owner 份额后调用 `addDepositFromOwnerShare(amount)`。它按完整 `amount` 增加 `ownerReleased`，授权 SettlementAsset，并用代理持有的代币调用 `Market.addDeposit`。business 额度和 `received` 不变，成功后清除授权；增加的押金属于 Account Owner。

金额必须大于零且不超过 owner 剩余额度，绑定账户必须已激活、未冻结且保持固定层级。实际余额不足或 Market 失败时整笔回滚。该入口不能代替首次注册，也不能给其他账户增押；成功发出 `OwnerShareDeposited`。

## 6. 管理与生命周期

- `releaseAvailable()` 返回 owner/business 当前可释放额度；`received()`、`ownerReleased()`、`businessReleased()` 返回原始累计值。
- `setBusiness` 和 `setTradeExecutor` 只允许 `owner()` 调用。更换 business 会把其尚未用完的历史份额交给新地址；更换 Executor 需与 Market 配置协调。
- `owner()` 初始是固定 Account Owner，但转移代理管理权不会改变 `accountOwner()` 或 owner 出款权限。
- 代理升级由 `owner()` 授权。固定 accountId、乘数和释放账本属于该代理。
- 基类支持上述 owner 份额增押；首次注册和 Market 退押由 Account Owner 直接办理，踢出由治理控制。Market 冻结账户时收款和出款都会失败；退出后新账户应使用新代理。

`src/Merchant/SimpleMerchantBaseUpgradeable.sol` 是实现；`test/SimpleMerchantBaseTest.t.sol` 用真实 Market、SettlementAsset 和 Executor 验证收款、两侧出款、错误层级、账户更换与回滚。多账户、多层级商家继续使用 [MerchantBase 接入说明](merchantbase-integration-zh.md)。
