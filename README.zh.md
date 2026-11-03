# Onchain Tariff Market

[English](README.md) · 中文

## 协议摘要

Onchain Tariff Market 是一个以可退还的动态暂扣和买卖双侧治理促进资金持续流通的去中心化链上市场。

收入时暂扣一部分，支出时全部退回。协议对净卖出顺差实行动态暂扣。卖方顺差上升时，协议从新销售收入中暂扣一部分；同一参与者随后买入、顺差下降时，已暂扣款随之退回。顺差归零，暂扣全部退回。

协议从每笔交易收取约 1% 的权利费用，划入公共 Vault，并为买卖双方铸造不可转让的治理席位。席位从下一轮起生效；双方共同表决市场准入规则、账户踢出及公共资金使用。

### 设计特点

- **原子化账户核算**：每个经济账户独立记录押金、净顺差和实际暂扣的金额；一笔交易中的买卖双方账本、资金与权利同时结算，失败则整体回滚。
- **资金回流机制**：卖出顺差带来动态暂扣，再采购使历史暂扣款逐步退回，为销售收入重新进入市场提供明确路径，减轻长期单向顺差造成的资金滞留。
- **双侧共治与去中心化**：交易产生的权利分别归买卖双方，市场规则、账户踢出与公共 Vault 的采购通过链上治理执行，降低市场准入与公共资金分配对中心化运营的依赖。

## 1. 系统概览

Onchain Tariff Market 用一种结算代币记录链上交易。每个经济账户绑定一组不可转让的 Account Owner–Merchant 身份。账户卖出形成顺差，买入减少顺差或形成逆差；正顺差受到押金容量和动态暂扣约束。账户之后作为买方消费时，已暂扣款可以在规则允许的范围内抵扣付款。

每笔交易另收约 1% 的权利费用，进入公共 Vault，并分别为买卖双方的 Account Owner 铸造年度席位。席位在下一轮生效，买方与卖方两侧共同决定市场规则。持续顺差因此承担更高资金约束，治理权也随近期交易参与而轮换。

项目名中的 “Tariff” 只是品牌名，不描述任何税。该机制是协议内对销售收入的临时、可退还的暂扣，不是法律意义上的税，也不是协议收入。治理权按协议交易量产生。

部分代码标识符沿用旧名：`taxableSurplus` 即应暂扣顺差，`curveTax` / `accountCurveTax` 报出暂扣曲线的值，`baseTaxRate` 是基础暂扣率，`sellerPoints` 记录已暂扣款，`TaxRefunded` 事件表示暂扣款退回。

## 2. 核心结构

| 层 | 合约 | 职责 |
| --- | --- | --- |
| 结算 | `ERC20SettlementAsset`、`Market`、`TradeExecutor` | 保管单一结算代币，记账户余额和暂扣款，把实际收入交给商家。 |
| 商家 | `MerchantBase`、`SimpleMerchantBase` | 分别服务多账户/多层级商家与单账户/固定层级商家。EOA 商家无需这两个基类。 |
| 权利 | 买卖两侧 `ProportionalElection`、年度 `SeatToken` | 铸造不可转让席位，按轮次归一化投票权。 |
| 决策 | `FinalGovernor`、Timelock、`Vault` | 双侧计票，执行治理决议，并按已批准清单使用公共资金采购。 |

一笔交易的主要路径：

```text
付款人 → Market.trade → SettlementAsset 收款
                    ├─ 约 1% 权利费用 → Vault
                    ├─ 本次卖方新增暂扣 → 留作可退暂扣款
                    └─ 实际结算额 deltaW → 卖方 Merchant
                                              └─ 合约商家收到 tradeIn 回调
```

### 经济账户与交易

Account Owner 注册 `(owner, merchant)` 配对账户并缴押金，获得数字 accountId。账户不可转让；同一 Merchant 可以对应多个 owner，各账户的押金、净余额和暂扣款独立。Account Owner 控制乘数并接收权利票，Merchant 接收交易收入。付款人 `msg.sender` 可以是第三方，但不会因此取得买方账户的暂扣款退回权益。

`buyerAccountId = 0` 只用于 Market 的默认买方路径：创建或复用 `(buyer, buyer)` 账户。未激活的默认账户可记逆差并支付，不能作为卖方收款。合约商家的 `tradeOut` 则必须使用已激活的源账户和已激活的目标卖方账户。

### 暂扣与押金

每笔金额 `amount` 先计算 `vaultFee = floor(amount / 100)`，余款 `tradeValue = amount - vaultFee`。买方净余额减少 `tradeValue`，卖方净余额增加 `tradeValue`。卖方的目标累计暂扣额按“正净余额 + 未释放的延迟顺差”计算；`sellerPoints` 记录真正已经暂扣、尚未退还的金额。小额交易若不足以补足目标暂扣额，本次最多暂扣全部 `tradeValue`，差额留待后续销售。

押金容量为 `deposit × capacityMultiplier / 10000`。乘数越小，层级越严格。已激活买方账户只能向相同或更严格层级的卖方账户付款。账户 owner 可以调低乘数，不能调高；任何人都可以全额付款增押。

当一笔买入同时减少买方顺差和卖方逆差，两者重叠的部分进入买方的延迟顺差，按押金和时间逐步释放。可退暂扣款只在合格的后续买入中抵扣，最多抵扣本次 `tradeValue`；1% 权利费用仍须支付。

### 席位与治理

一轮是 365 天。本轮铸造的普通席位从下一轮开始投票；每个有供应量的活跃轮次归一化为 100 票，最多统计五轮。普通席位可在铸造轮和生效第一轮被治理部分销毁，此后不能销毁。创世席位启动时已活跃，按当前轮次设置再活跃四年，且没有销毁入口。

`FinalGovernor` 分别统计买卖双方的赞成、反对和弃权。每种票的有效值取两侧较小者；通过需有效赞成票大于零，且至少为有效反对票的两倍，并达到 quorum：实际投出的双侧参与票须达到买方历史总票权的 4%。Market、选举和结算资产的管理权在部署流程中交给 Timelock。

Vault 收取权利费用和治理罚没，作为公共买家执行治理批准的逐项采购。它不卖出，不为自己的 `(vault, vault)` 买方账户铸造买方权利。

## 3. 阅读路线

- [Market 机制说明](docs/market-mechanism-zh.md)：账户、暂扣曲线、延迟顺差、退出、Vault 和双侧治理。
- [MerchantBase 接入与交互](docs/merchantbase-integration-zh.md)：多 owner 与多乘数分桶。
- [SimpleMerchantBase 接入](docs/simple-merchantbase-zh.md)：单账户、固定层级和两侧固定比例出款。
- [设计术语](CONTEXT.md)：Account Owner、Merchant、Payer 等身份的边界。
- [英文版 README](README.md)、[英文机制说明](docs/market-mechanism-en.md)、[英文商家接入说明](docs/merchantbase-integration-en.md)。

## 4. 开发与测试

项目使用 Foundry、Solidity `^0.8.20`、OpenZeppelin 和 Solady。`foundry.toml` 启用了 `via_ir`；Market 使用 Cancun 的瞬态存储重入锁，目标链须支持相应 EVM 功能。

```sh
forge build
forge test
```

`script/Deploy.s.sol` 展示代理、两侧选举、Timelock、Governor、Market、Vault 与执行器的完整部署和权限移交。`script/DeployMock.s.sol` 用于本地 6 位小数测试代币。部署脚本会读取私钥与结算代币地址，并写回 `.env` 中的合约地址；运行前应审查目标链和环境变量。`script/Interact.s.sol` 当前是注释掉的旧示例，不能当作现行交互接口。

源码、接口和测试是行为依据；本文是阅读入口。当前实现是单一结算代币的独立 Market，没有多币种路由或顺差持有费。

## 5. 免责声明

本代码未经审计，属于实验性软件，按 [MIT 许可证](LICENSE) 以"现状"提供，不附带任何形式的担保。因部署、运行或与这些合约交互而产生的任何损失、损害或其他后果，包括资金损失、合约漏洞、配置错误或治理行为所致后果，作者与贡献者均不承担责任。任何部署或使用本代码的人自行承担风险，并负责独立的安全审查、测试，以及遵守其适用的法律法规。本仓库中的任何内容均不构成金融、法律或投资建议。
