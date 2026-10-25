# Market 机制说明

[English](market-mechanism-en.md) · 中文

本文按当前 `Market.sol`、两侧选举合约、`FinalGovernor` 和 `Vault.sol` 说明经济与治理流程。所有金额均以结算代币的最小单位计；“顺差”表示账户的净卖出，不代表 Merchant 地址的全部收入。合约接口和舍入结果以源码为准。

## 1. 从一笔交易看协议

`Market.trade(buyer, buyerAccountId, sellerAccountId, rechargeTarget, amount, data)` 中有四个不同身份：

| 身份 | 作用 |
| --- | --- |
| Account Owner | 经济账户的 owner，注册并控制押金层级，接收该账户的权利票。 |
| Merchant | 账户的经营/收款地址。卖出时接收实际结算款；作为买方付款时才可能使用本账户已收关税。 |
| `buyer` | 本次买方账户的 Account Owner。 |
| Payer | 实际调用 `trade` 的 `msg.sender`，支付应付额，可以是第三方。 |

一笔交易先计算：

```text
vaultFee  = floor(amount / 100)
tradeValue = amount - vaultFee
```

`vaultFee` 转给 Vault，买方净余额减少 `tradeValue`，卖方净余额增加 `tradeValue`。权利票各按 `vaultFee` 铸给买卖账户各自的 Account Owner；付款人不能改写归属。若买方正好是 Vault 的 `(vault, vault)` 账户，则不铸买方权利。金额不足 100 个最小单位时，向下取整的权利费用可能为零。

卖方本次新增关税 `deltaS` 留在 SettlementAsset 的资金中，实际收入 `deltaW = tradeValue - deltaS` 经 TradeExecutor 转给卖方 Merchant。收款地址是合约时，Executor 还调用 `tradeIn`；EOA 没有回调。交易、回调或代币转账失败会使整笔交易回滚。

## 2. 经济账户、默认买方与层级

一个 accountId 只对应一组 `(Account Owner, Merchant)`，没有 NFT 转让或授权功能。`accountIdOf[owner][merchant]` 指向当前账户。押金、乘数、净余额、已收关税和延迟顺差按 ID 独立；同一个 Merchant 可以服务多个 owner，同一个 owner 也能使用多个 Merchant。仅同一 accountId 自买自卖被禁止。

由 owner 本人调用 `registerMerchant(merchant, deposit, multiplier)` 激活卖方账户。押金须大于零，乘数至少 1000。容量为：

```text
capacity = floor(deposit × capacityMultiplier / 10000)
```

正净余额与延迟顺差之和不能超过容量。乘数越小，单位押金支持的顺差越少，层级越严格。任何人可以为活跃账户全额增押；增押不会直接减少已收关税，而且只从增押时起加速延迟顺差释放。只有账户 owner 能保持或调低乘数，不能调高。存在逆差时不能把历史逆差迁入更严格层级；降低乘数还须满足当前应税顺差的容量要求。

`buyerAccountId = 0` 不是链上的真实 ID 0。Market 会查找或创建 `(buyer, buyer)` 默认买方账户；若这个配对已激活，传 0 仍复用其押金和层级。未激活账户可以支付、记录逆差和接收买方权利，却不能作为卖方。首次交易必须由买方本人付款，首次卖方乘数固定它的买方层级；之后只能向相同或更严格层级购买，买更严格层不会自动调低原层级。已激活买方账户同样要求 `sellerMultiplier <= buyerMultiplier`。显式 buyerAccountId 必须属于 `buyer`；卖方 ID 在任何情形下都必须已激活。

第三方可以替已有账户付款，完整支付本次应付额。买方余额、延迟顺差和买方权利仍归该账户。只有 `msg.sender == buyerAccount.merchant` 且账户 owner 等于 `buyer`，才可以在这笔交易中使用本账户可退关税；单纯是 owner 本人但不是 Merchant，也不能动用另一个 Merchant 账户的关税。

## 3. 曲线关税：理论税与实际留存

`netTradeBalance` 是有符号账本：正值为净卖出顺差，负值为净买入逆差。`sellerPoints[accountId]` 虽沿用旧变量名，但现在表示该账户**实际已留存、尚未退还的关税**，不是顺差积分，也不是理论税。`claimed` 记录已退关税。

应税顺差和曲线容量：

```text
taxableSurplus = max(netTradeBalance, 0) + deferredSurplus
capacity       = deposit × capacityMultiplier / 10000
```

对正的应税顺差 `P`，曲线以 `P / capacity` 为利用率，叠加基础税与幂次变量税。初始化参数是 `baseTaxRate = 900`（9%）、`curveExponent = 2`；治理可改这两个参数。概念上，累计目标税约为：

```text
P × baseTaxRate / 10000
+ P × (10000 - baseTaxRate) / 10000
    × (P / capacity) ^ curveExponent / (curveExponent + 1)
```

链上使用定点数与向上取整，并把结果封顶在 `P`；上式用于理解曲线，不能代替精确报价。`curveTax` 和 `calculateAMM` 可用于查询。容量不足会使相应交易回滚。

卖出后按新的应税顺差算一次目标累计税。若目标税高于 `sellerPoints`，本笔最多留存 `tradeValue`：

```text
deltaS = min(max(newTargetTax - collectedTariff, 0), tradeValue)
deltaW = tradeValue - deltaS
```

差额大于本笔收入时，不会因为“补税不足”回滚；未补足的部分留待未来卖出。押金变化也不会把新的理论税误当成已经扣留的现金。

买入后同样按新的应税顺差算目标税。若已留存关税高于目标税，且付款人具备上述 Merchant 身份，则：

```text
buyerRefund = min(collectedTariff - newTargetTax, tradeValue)
payerPays   = amount - buyerRefund
```

实际扣减还受已留存关税限制。退款是本次付款抵扣，不是随时可领取的独立补贴；`vaultFee` 始终由本次付款覆盖。第三方代付即使使余额下降，也不会消耗买方账户的已收关税。

## 4. 延迟顺差：给余额互相填平留出时间

若买方原有正顺差、卖方原有逆差，一笔交易可能同时减少两边的绝对值。两者真正重叠的部分暂记为买方的延迟顺差：

```text
buyerSurplusReduced = max(oldBuyerBalance, 0) - max(newBuyerBalance, 0)
sellerDeficitReduced = max(-oldSellerBalance, 0) - max(-newSellerBalance, 0)
resolvedSurplus      = min(buyerSurplusReduced, sellerDeficitReduced)
```

跨过零点时只取真正被双方互相填平的部分。没有对应卖方逆差的普通买方顺差减少不进入延迟顺差。税曲线对 `max(realBalance, 0) + currentDeferred` 合并计算一次，避免大量账户用相反余额集中交易并立即释放关税。

延迟顺差按押金和时间线性下降。默认 `resolutionRatio = 5000`、`RESOLUTION_PERIOD = 30 days`，即每 30 天释放能力相当于有效押金的 50%。合约用累计指标和余数处理频繁调用的舍入；增押、治理更改释放比例之前会先按旧参数结算，之后才采用新参数。没有押金的默认买方账户不能依靠时间释放延迟顺差。

## 5. 退押、治理踢出与公共 Vault

账户 owner 可在普通净余额不为正、延迟顺差为零时申请退回全部押金。申请后立即冻结账户：不能买、卖、增押或调乘数，待退资金也不再提供容量。等待固定 `180 days` 后，owner 领取本金；剩余 `sellerPoints` 同时直接退给 Merchant。领取删除该 ID 与配对映射，重新注册会得到新 ID。申请不要求 `sellerPoints == 0`；当前没有取消申请或提前解冻接口。

`kickMerchant(accountId)` 由 Market 的 `governance` 调用。在部署流程中该地址是 Timelock。最多罚没 `min(taxableSurplus, 押金及已收关税总额)`，先扣押金（包括待退本金），不足再扣已收关税；罚没额入 Vault。剩余押金归 owner，剩余关税归 Merchant，然后删除该账户。共享 Merchant 的其他 owner 账户不受影响。

Vault 从交易权利费用和治理罚没获取资金，不靠给自己记销售顺差。它是不能卖出的公共买家，使用未激活、无需押金的 `(vault, vault)` 默认买方账户。Market 设置 Vault 时固定其初始层级；治理另行设置只能收紧的 Vault 本地乘数上限。治理提交不可由执行者修改的采购订单，任何人可逐项执行；Vault 每笔核查 `sellerMultiplier <= capacityMultiplierLimit`，通过 `Market.trade` 支付。卖方仍收取权利票，Vault 自己的默认账户不收买方权利票。

## 6. 年度席位与双侧共识

买方、卖方各有一套 `ProportionalElection` 和年度 `SeatToken`。一轮固定 365 天。本轮铸造的普通席位从下一轮边界起参与投票，因而实际等待时间取决于本轮剩余时长。每个有历史供应量的活跃轮次归一化为 `100 × 10^18` 票，最多统计最近五个活跃轮次；历史查询使用 SeatToken 的历史供应量检查点。

创世席位是第 0 轮。当前部署脚本在买卖两侧各向部署地址铸造 100 × 10^18 个创世席位。初始化把轮次时钟放在第 2 轮，故创世席位启动时已活跃，并在四个完整周期后移出五轮窗口。创世席位不能销毁。普通席位可在铸造轮和生效的第一轮由选举合约 owner 部分销毁，第二个活跃年度起不能再销毁。`batchBurn` 为每项指定轮次；不合规轮次、缺失 token 或该项销毁失败会发出 `SeatBurnSkipped` 并继续，只有数组长度不匹配会整笔回滚。

Governor 对赞成、反对、弃权分别取买卖两侧票数的较小值。提案通过需有效赞成非零且至少是有效反对的两倍；quorum 用两侧各自实际投出的三类票合计再取较小值，未投票不算参与。quorum 门槛是买方历史总票权的 4%；初始提案门槛为 100 × 10^18 票，买方或卖方任一侧满足即可发起。Governor 的初始投票延迟为 7200 秒、投票期为 50400 秒，和席位的下一轮生效时间是两套规则。投票通过仍须两侧形成重叠。部署脚本把 Market、选举、结算资产和工厂的管理权交给 Timelock，并只授予 Governor 提案/取消角色。当前脚本将 Timelock 最短延迟设为 0；这属于部署配置，不是席位生效等待期。

## 7. 代码与测试入口

- `src/Market.sol`、`src/interfaces/IMarket.sol`：账户、交易、关税、退押与踢出。
- `src/settlement/ERC20SettlementAsset.sol`、`src/TradeExecutor.sol`：代币托管与商家回调边界。
- `src/RightsToken/`、`src/Governor/`、`src/Vault.sol`：权利发行、双侧治理和公共采购。
- `test/MarketTest.t.sol`、`test/DepositWithdrawalTest.t.sol`、`test/VaultTest.t.sol` 及治理/选举测试：对应行为回归。
- [MerchantBase 接入文档](merchantbase-integration-zh.md)：合约商家的具体收款与出款接口。

当前代码只支持单一结算代币的独立 Market；没有顺差持有税、旧积分对冲领取接口或多币种路由。