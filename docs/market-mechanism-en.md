# Market mechanism

English · [中文](market-mechanism-zh.md)

This document follows the current `Market.sol`, buyer and seller elections, `FinalGovernor`, and `Vault.sol`. Amounts use the settlement token's smallest unit. “Surplus” means net sales on one Market Account, not all receipts of a Merchant address. Source code determines exact rounding and interface behavior.

## 1. One trade, four identities

`Market.trade(buyer, buyerAccountId, sellerAccountId, rechargeTarget, amount, data)` separates these roles:

| Role | Meaning |
| --- | --- |
| Account Owner | Registers the economic account, controls its deposit tier, and receives its rights seats. |
| Merchant | Operates the account and receives all sale proceeds after the rights fee. |
| `buyer` | Account Owner of the buyer account for this trade. |
| Payer | The actual caller, `msg.sender`, who funds the amount due; this may be a third party. |

The trade begins with:

```text
vaultFee   = floor(amount / 100)
tradeValue = amount - vaultFee
```

The Vault receives `vaultFee`. The buyer's net trade balance decreases by `tradeValue` and the seller's increases by it. Each side's Account Owner receives rights equal to `vaultFee`; the Payer cannot choose another recipient. The Vault's own `(vault, vault)` buyer account is the exception: it receives no buyer rights. Fees may round to zero for amounts below 100 smallest units.

The Payer funds the full `amount`. TradeExecutor transfers the entire `tradeValue` (`netAmount`) from SettlementAsset to the seller Merchant, then calls `tradeIn(rightsOwner, rechargeTarget, netAmount, data)` for a contract Merchant. An EOA has no callback. A failed transfer or callback reverts balances, rights, and transfers together. SettlementAsset keeps deposits, not sale proceeds.

## 2. Accounts, default buyers, and tiers

One numeric accountId binds one `(Account Owner, Merchant)` pair. It is not an NFT and cannot be transferred or approved. `accountIdOf[owner][merchant]` locates the current account. Deposit, multiplier, balance, and deferred surplus are separate per ID. One Merchant may serve many owners and one owner may use many Merchants. Only a trade between the same buyer and seller account ID is forbidden.

The owner calls `registerMerchant(merchant, deposit, multiplier)` to activate a seller account. Deposit must be positive and the multiplier at least 1000. Capacity is:

```text
capacity = floor(deposit × capacityMultiplier / 10000)
```

Positive balance plus deferred surplus must fit inside capacity. A smaller multiplier means a stricter tier and less surplus per unit of deposit. Anyone may fund a deposit increase. After covering unpaid holding fees, any remainder raises capacity and accelerates deferred-surplus release from that point forward. Only the owner can maintain or lower the multiplier. An existing deficit cannot be moved into a stricter tier, and a multiplier reduction must still cover current Effective Surplus.

`buyerAccountId = 0` is a Market instruction, not an actual account ID. Market finds or creates the `(buyer, buyer)` Default Buyer Account. If that pair is already active, ID zero reuses its deposit and tier. An inactive default account may pay, accumulate a deficit, and receive buyer rights, but cannot sell. Its first trade must be paid by the buyer, and that first seller's multiplier pins the buyer tier. Later purchases may go to the same or a stricter tier; a stricter purchase does not silently change the pinned tier. Active buyer accounts likewise require `sellerMultiplier <= buyerMultiplier`. An explicit buyerAccountId must belong to `buyer`. A seller account must always be active.

A third party may pay for an existing account and funds the full `amount`. The buyer account still records its balance, deferred surplus, and buyer rights. Paying from the buyer's Merchant or its owner also costs the full `amount`.

## 3. Effective Surplus and deposit-backed capacity

`netTradeBalance` is signed: positive for net sales, negative for net purchases. The public views are:

```text
effectiveSurplus(accountId) = max(netTradeBalance, 0) + deferredSurplus
capacityOf(accountId)       = floor(deposit × capacityMultiplier / 10000)
```

A sale may fill capacity exactly. If the resulting Effective Surplus exceeds capacity, the entire trade reverts with `Capacity exceeded`; there is no partial execution or automatic deposit increase. A purchase reduces the buyer's real balance, while the matched portion described below continues to occupy capacity as Deferred Surplus. Neither view is a token balance or a claim on sale proceeds.

### Surplus holding fee

Governance sets an annual rate between 0% and 100% through `setHoldingFeeRate`. The rate starts at 0%. Only ordinary positive surplus accrues fees. While collateral covers the fee, the calculation follows the continuously declining surplus. After the collateral is exhausted, the remaining positive surplus accrues unpaid fees at the configured rate. Unpaid fees do not themselves accrue fees.

Market pays the fee from the account's deposit to Vault and reduces the account's ordinary positive surplus by the amount paid, stopping at zero. `holdingFeeOf` previews the amount collectible now and the debt that would remain. `capacityOf` and `effectiveSurplus` include the projected deduction. Anyone can call `settleHoldingFee`. Deferred surplus release uses each recorded deposit until it changes at settlement or deposit increase.

Payment may put the account over capacity. The account can still buy, and sale validation uses the seller's post-fee capacity and surplus. Deposit increases pay outstanding fees first. Voluntary exit requires zero debt, a nonpositive net balance, and zero deferred surplus. A governance kick settles fees before the slash and records any debt written off.

## 4. Deferred surplus slows matched balance resolution

A purchase may reduce the buyer's positive surplus while also reducing the seller's deficit. Only the overlapping reduction becomes the buyer's deferred surplus:

```text
buyerSurplusReduced = max(oldBuyerBalance, 0) - max(newBuyerBalance, 0)
sellerDeficitReduced = max(-oldSellerBalance, 0) - max(-newSellerBalance, 0)
resolvedSurplus      = min(buyerSurplusReduced, sellerDeficitReduced)
```

This handles balances crossing zero: only the portion genuinely resolved on both sides is deferred. An ordinary reduction of buyer surplus without matching seller deficit is not deferred. The deferred amount remains part of Effective Surplus, so concentrated offset trades cannot immediately free deposit-backed capacity or unlock the deposit.

Deferred surplus declines linearly with deposit and time. Initially `resolutionRatio = 5000` and `RESOLUTION_PERIOD = 30 days`, giving a release capacity equal to 50% of effective deposit per 30 days. A cumulative index and remainder preserve fractional progress across frequent calls. Market settles elapsed time under the old parameters before a deposit increase or governance ratio change, so neither change rewrites past release.

## 5. Withdrawal, eviction, and the public Vault

After fees settle, the account owner may request withdrawal of the remaining deposit when real net balance is nonpositive and both deferred surplus and fee debt are zero. The request immediately freezes the account: it cannot buy, sell, add deposit, or change multiplier; pending principal no longer provides capacity. After exactly `180 days`, the owner claims the principal. The claim deletes the account and pair mapping; re-registration gets a new ID. There is currently no cancel or early-unfreeze entry point.

`kickMerchant(accountId)` is restricted to Market's `governance` address, which the deployment flow sets to the Timelock. It slashes `min(effectiveSurplus(accountId), deposit plus pending withdrawal principal)` from the deposit. The slash goes to the Vault; leftover deposit goes to the Account Owner. Then the account and pending claim are deleted. Sale proceeds already paid to the Merchant are not clawed back. Other owner accounts sharing the same Merchant remain separate.

The Vault receives rights fees and governance slashes, without booking a sale surplus for itself. It is a public buyer that cannot sell and uses an inactive, deposit-free `(vault, vault)` Default Buyer Account. Market pins its initial tier; governance sets a separate Vault limit that can only tighten. Governance queues immutable purchase orders, and anyone may execute them one by one. For each order, the Vault checks `sellerMultiplier <= capacityMultiplierLimit` and pays through `Market.trade`. The seller still receives seller rights, while the Vault's own buyer account receives no buyer rights.

## 6. Annual seats and dual consensus

Buyers and sellers have separate `ProportionalElection` contracts and annual `SeatToken` contracts. Each round lasts 365 days. Ordinary seats minted in the current round start voting at the next round boundary; each mint therefore waits only for the remainder of its round. Each active round with historical supply is normalized to `100 × 10^18` votes, and at most five active rounds are counted. Historical queries use the SeatToken's historical supply checkpoints.

Genesis seats belong to round 0. The current deployment script mints 100 × 10^18 genesis seats on each side to the deployer address. Initialization places the clock in round 2, so genesis seats are active at launch and leave the five-round window four full cycles later. They cannot be burned. Governance may partially burn ordinary seats during their minting round or first active round; from their second active year onward they cannot be burned. `batchBurn` takes a round ID per item, emits `SeatBurnSkipped` for ineligible rounds, missing tokens, or failed individual burns, and continues. Mismatched array lengths revert the whole call.

The Governor takes the smaller buyer/seller count separately for For, Against, and Abstain. A proposal succeeds only with positive effective For votes, at least twice effective Against votes, and quorum based on actual votes cast. Quorum sums the three choices on each side and takes the smaller participation total; uncast power is not participation. Quorum is 4% of historical buyer-side total voting weight. The initial proposal threshold is 100 × 10^18 votes and can be met on either side. Governor's initial voting delay is 7200 seconds and its voting period is 50400 seconds; these are separate from the next-round seat activation rule. Passage still requires overlap between sides. The deployment script transfers administration of Market, elections, settlement asset, and factories to the Timelock and grants proposal/cancellation roles only to the Governor. Its Timelock minimum delay is currently configured as zero; this is a deployment setting, separate from seat activation.

## 7. Code and tests

- `src/Market.sol` and `src/interfaces/IMarket.sol`: accounts, trades, capacity, withdrawal, eviction.
- `src/settlement/ERC20SettlementAsset.sol` and `src/TradeExecutor.sol`: custody and Merchant callback boundary.
- `src/RightsToken/`, `src/Governor/`, and `src/Vault.sol`: issuance, dual governance, public purchasing.
- `test/MarketTest.t.sol`, `test/DepositWithdrawalTest.t.sol`, `test/VaultTest.t.sol`, and governance/election tests: behavior regressions.
- `test/SettlementConservationTest.t.sol`: full funding and net settlement, fee rounding, exact capacity, and callback rollback.
- [MerchantBase integration](merchantbase-integration-en.md): contract Merchant payment and release interfaces.

The current code is an independent, single-token Market.
