# Market 机制说明

[English](market-mechanism-en.md) · 中文

本文按当前 `Market.sol`、两侧选举合约、`FinalGovernor` 和 `Vault.sol` 说明经济与治理流程。所有金额均以结算代币的最小单位计；“顺差”表示账户的净卖出，不代表 Merchant 地址的全部收入。合约接口和舍入结果以源码为准。

## 1. 从一笔交易看协议

`Market.trade(buyer, buyerAccountId, sellerAccountId, rechargeTarget, amount, data)` 中有四个不同身份：

| 身份 | 作用 |
| --- | --- |
| Account Owner | 经济账户的 owner，注册并控制押金层级，接收该账户的权利票。 |
| Merchant | 账户的经营/收款地址，卖出时接收扣除权利费用后的全部结算款。 |
| `buyer` | 本次买方账户的 Account Owner。 |
| Payer | 实际调用 `trade` 的 `msg.sender`，支付应付额，可以是第三方。 |

一笔交易先计算：

```text
vaultFee  = floor(amount / 100)
tradeValue = amount - vaultFee
```

`vaultFee` 转给 Vault，买方净余额减少 `tradeValue`，卖方净余额增加 `tradeValue`。权利票各按 `vaultFee` 铸给买卖账户各自的 Account Owner；付款人不能改写归属。若买方正好是 Vault 的 `(vault, vault)` 账户，则不铸买方权利。金额不足 100 个最小单位时，向下取整的权利费用可能为零。

付款人完整支付 `amount`。TradeExecutor 经 SettlementAsset 把全部 `tradeValue`（`netAmount`）转给卖方 Merchant，再向合约 Merchant 调用 `tradeIn(rightsOwner, rechargeTarget, netAmount, data)`；EOA 没有回调。转账或回调失败会使账本、权利和资金转移一起回滚。SettlementAsset 留存的是押金，不是销售收入。

## 2. 经济账户、默认买方与层级

一个 accountId 只对应一组 `(Account Owner, Merchant)`，没有 NFT 转让或授权功能。`accountIdOf[owner][merchant]` 指向当前账户。押金、乘数、净余额和延迟顺差按 ID 独立；同一个 Merchant 可以服务多个 owner，同一个 owner 也能使用多个 Merchant。仅同一 accountId 自买自卖被禁止。

由 owner 本人调用 `registerMerchant(merchant, deposit, multiplier)` 激活卖方账户。押金须大于零，乘数至少 1000。容量为：

```text
capacity = floor(deposit × capacityMultiplier / 10000)
```

正净余额与延迟顺差之和不能超过容量。乘数越小，单位押金支持的顺差越少，层级越严格。任何人可以为活跃账户增押，补上欠费后的剩余金额提高容量，并从增押时起加速延迟顺差释放。只有账户 owner 能保持或调低乘数，不能调高。存在逆差时不能把历史逆差迁入更严格层级；降低乘数还须满足当前有效顺差的容量要求。

`buyerAccountId = 0` 不是链上的真实 ID 0。Market 会查找或创建 `(buyer, buyer)` 默认买方账户；若这个配对已激活，传 0 仍复用其押金和层级。未激活账户可以支付、记录逆差和接收买方权利，却不能作为卖方。首次交易必须由买方本人付款，首次卖方乘数固定它的买方层级；之后只能向相同或更严格层级购买，买更严格层不会自动调低原层级。已激活买方账户同样要求 `sellerMultiplier <= buyerMultiplier`。显式 buyerAccountId 必须属于 `buyer`；卖方 ID 在任何情形下都必须已激活。

第三方可以替已有账户付款，完整支付本次 `amount`。买方余额、延迟顺差和买方权利仍归该账户。由买方 Merchant 或 owner 本人付款时，也完整支付 `amount`。

## 3. 有效顺差与押金额度

`netTradeBalance` 是有符号账本：正值为净卖出顺差，负值为净买入逆差。可通过两个公开查询读取：

```text
effectiveSurplus(accountId) = max(netTradeBalance, 0) + deferredSurplus
capacityOf(accountId)       = floor(deposit × capacityMultiplier / 10000)
```

卖出后的有效顺差可以恰好等于容量；超过则整笔交易以 `Capacity exceeded` 回滚，不会部分成交或自动增押。买入会减少买方普通净余额，但下面说明的匹配部分会作为延迟顺差继续占用额度。两个查询值都不是代币余额，也不是对销售收入的领取权。

### 顺差持有费

治理通过 `setHoldingFeeRate` 设置 0% 到 100% 的年费率，初始为 0%。只有普通正顺差计费。押金足以支付时，计算基数随实缴费用连续下降。押金耗尽后，剩余普通正顺差继续产生欠费，欠费本身不计费。

Market 从账户押金扣费给 Vault，并按实付额冲减普通正顺差，最低减至零。`holdingFeeOf` 可查询当前可扣金额和扣后剩余欠费，`capacityOf` 和 `effectiveSurplus` 反映预计扣费后的结果。任何人都可调用 `settleHoldingFee`。延迟顺差按账面押金释放，扣费或增押落账后才采用新押金。

扣费后超额度的账户仍可买入。卖出按卖方扣费后的有效顺差和额度检查。补押先抵欠费，剩余金额计入可用押金。主动退押须结清欠费、普通净余额不为正且延迟顺差为零。治理踢出先结算持有费再罚没，并记录核销的剩余欠费。

## 4. 延迟顺差：给余额互相填平留出时间

若买方原有正顺差、卖方原有逆差，一笔交易可能同时减少两边的绝对值。两者真正重叠的部分暂记为买方的延迟顺差：

```text
buyerSurplusReduced = max(oldBuyerBalance, 0) - max(newBuyerBalance, 0)
sellerDeficitReduced = max(-oldSellerBalance, 0) - max(-newSellerBalance, 0)
resolvedSurplus      = min(buyerSurplusReduced, sellerDeficitReduced)
```

跨过零点时只取真正被双方互相填平的部分。没有对应卖方逆差的普通买方顺差减少不进入延迟顺差。延迟部分仍计入有效顺差，避免大量账户用相反余额集中交易后立即释放容量或押金。

延迟顺差按押金和时间线性下降。默认 `resolutionRatio = 5000`、`RESOLUTION_PERIOD = 30 days`，即每 30 天释放能力相当于有效押金的 50%。合约用累计指标和余数处理频繁调用的舍入；增押、治理更改释放比例之前会先按旧参数结算，之后才采用新参数。没有押金的默认买方账户不能依靠时间释放延迟顺差。

## 5. 退押、治理踢出与公共 Vault

结算费用后，普通净余额不为正、延迟顺差和欠费均为零时，账户 owner 可申请退回剩余押金。申请后立即冻结账户：不能买、卖、增押或调乘数，待退资金也不再提供容量。等待固定 `180 days` 后，owner 领取本金。领取删除该 ID 与配对映射，重新注册会得到新 ID；当前没有取消申请或提前解冻接口。

`kickMerchant(accountId)` 由 Market 的 `governance` 调用，在部署流程中该地址是 Timelock。从押金中罚没 `min(effectiveSurplus(accountId), 押金与待退本金之和)` 给 Vault，剩余押金退给 Account Owner，然后删除账户与待退记录。已支付给 Merchant 的销售收入不会被追扣；共享 Merchant 的其他 owner 账户不受影响。

Vault 从交易权利费用和治理罚没获取资金，不靠给自己记销售顺差。它是不能卖出的公共买家，使用未激活、无需押金的 `(vault, vault)` 默认买方账户。Market 设置 Vault 时固定其初始层级；治理另行设置只能收紧的 Vault 本地乘数上限。治理提交不可由执行者修改的采购订单，任何人可逐项执行；Vault 每笔核查 `sellerMultiplier <= capacityMultiplierLimit`，通过 `Market.trade` 支付。卖方仍收取权利票，Vault 自己的默认账户不收买方权利票。

## 6. 年度席位与双侧共识

买方、卖方各有一套 `ProportionalElection` 和年度 `SeatToken`。一轮固定 365 天。本轮铸造的普通席位从下一轮边界起参与投票，因而实际等待时间取决于本轮剩余时长。每个有历史供应量的活跃轮次归一化为 `100 × 10^18` 票，最多统计最近五个活跃轮次；历史查询使用 SeatToken 的历史供应量检查点。

创世席位是第 0 轮。当前部署脚本在买卖两侧各向部署地址铸造 100 × 10^18 个创世席位。初始化把轮次时钟放在第 2 轮，故创世席位启动时已活跃，并在四个完整周期后移出五轮窗口。创世席位不能销毁。普通席位可在铸造轮和生效的第一轮由选举合约 owner 部分销毁，第二个活跃年度起不能再销毁。`batchBurn` 为每项指定轮次；不合规轮次、缺失 token 或该项销毁失败会发出 `SeatBurnSkipped` 并继续，只有数组长度不匹配会整笔回滚。

Governor 对赞成、反对、弃权分别取买卖两侧票数的较小值。提案通过需有效赞成非零且至少是有效反对的两倍；quorum 用两侧各自实际投出的三类票合计再取较小值，未投票不算参与。quorum 门槛是买方历史总票权的 4%；初始提案门槛为 100 × 10^18 票，买方或卖方任一侧满足即可发起。Governor 的初始投票延迟为 7200 秒、投票期为 50400 秒，和席位的下一轮生效时间是两套规则。投票通过仍须两侧形成重叠。部署脚本把 Market、选举、结算资产和工厂的管理权交给 Timelock，并只授予 Governor 提案/取消角色。当前脚本将 Timelock 最短延迟设为 0；这属于部署配置，不是席位生效等待期。

## 7. 代码与测试入口

- `src/Market.sol`、`src/interfaces/IMarket.sol`：账户、交易、额度、退押与踢出。
- `src/settlement/ERC20SettlementAsset.sol`、`src/TradeExecutor.sol`：代币托管与商家回调边界。
- `src/RightsToken/`、`src/Governor/`、`src/Vault.sol`：权利发行、双侧治理和公共采购。
- `test/MarketTest.t.sol`、`test/DepositWithdrawalTest.t.sol`、`test/VaultTest.t.sol` 及治理/选举测试：对应行为回归。
- `test/SettlementConservationTest.t.sol`：全额付款、净额到账、费用舍入、额度边界与回调回滚。
- [MerchantBase 接入文档](merchantbase-integration-zh.md)：合约商家的具体收款与出款接口。

当前代码只支持单一结算代币的独立 Market。
