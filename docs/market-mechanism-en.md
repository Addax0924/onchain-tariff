# Market mechanism

English · [中文](market-mechanism-zh.md)

This document follows the current `Market.sol`, buyer and seller elections, `FinalGovernor`, and `Vault.sol`. Amounts use the settlement token's smallest unit. “Surplus” means net sales on one Market Account, not all receipts of a Merchant address. Source code determines exact rounding and interface behavior.

## 1. One trade, four identities

`Market.trade(buyer, buyerAccountId, sellerAccountId, rechargeTarget, amount, data)` separates these roles:

| Role | Meaning |
| --- | --- |
| Account Owner | Registers the economic account, controls its deposit tier, and receives its rights seats. |
| Merchant | Operates the account and receives sale proceeds. When buying, only this address may use that account's collected tariff. |
| `buyer` | Account Owner of the buyer account for this trade. |
| Payer | The actual caller, `msg.sender`, who funds the amount due; this may be a third party. |

The trade begins with:

```text
vaultFee   = floor(amount / 100)
tradeValue = amount - vaultFee
```

The Vault receives `vaultFee`. The buyer's net trade balance decreases by `tradeValue` and the seller's increases by it. Each side's Account Owner receives rights equal to `vaultFee`; the Payer cannot choose another recipient. The Vault's own `(vault, vault)` buyer account is the exception: it receives no buyer rights. Fees may round to zero for amounts below 100 smallest units.

New seller tariff `deltaS` remains in the SettlementAsset's custody. Actual proceeds `deltaW = tradeValue - deltaS` go through TradeExecutor to the seller Merchant. A contract Merchant also receives a `tradeIn` callback; an EOA does not. A failed transfer or callback reverts the entire trade.

## 2. Accounts, default buyers, and tiers

One numeric accountId binds one `(Account Owner, Merchant)` pair. It is not an NFT and cannot be transferred or approved. `accountIdOf[owner][merchant]` locates the current account. Deposit, multiplier, balance, collected tariff, and deferred surplus are separate per ID. One Merchant may serve many owners and one owner may use many Merchants. Only a trade between the same buyer and seller account ID is forbidden.

The owner calls `registerMerchant(merchant, deposit, multiplier)` to activate a seller account. Deposit must be positive and the multiplier at least 1000. Capacity is:

```text
capacity = floor(deposit × capacityMultiplier / 10000)
```

Positive balance plus deferred surplus must fit inside capacity. A smaller multiplier means a stricter tier and less surplus per unit of deposit. Anyone may pay the full amount of a deposit increase; it does not directly reduce collected tariff and accelerates deferred-surplus release only from that point forward. Only the owner can maintain or lower the multiplier. An existing deficit cannot be moved into a stricter tier, and a multiplier reduction must still cover current taxable surplus.

`buyerAccountId = 0` is a Market instruction, not an actual account ID. Market finds or creates the `(buyer, buyer)` Default Buyer Account. If that pair is already active, ID zero reuses its deposit and tier. An inactive default account may pay, accumulate a deficit, and receive buyer rights, but cannot sell. Its first trade must be paid by the buyer, and that first seller's multiplier pins the buyer tier. Later purchases may go to the same or a stricter tier; a stricter purchase does not silently change the pinned tier. Active buyer accounts likewise require `sellerMultiplier <= buyerMultiplier`. An explicit buyerAccountId must belong to `buyer`. A seller account must always be active.

A third party may pay for an existing account and funds the full amount due. The buyer account still records its balance, deferred surplus, and buyer rights. An immediate tariff offset is allowed only when `msg.sender == buyerAccount.merchant` and the account's owner equals `buyer`. An owner paying personally cannot spend tariff held for that owner's different Merchant account.

## 3. Tariff curve: target versus money held

`netTradeBalance` is signed: positive for net sales, negative for net purchases. Despite its historical name, `sellerPoints[accountId]` is **tariff actually collected and still held** for that account. It is neither a surplus point balance nor a theoretical amount. `claimed` records refunded tariff.

The curve uses:

```text
taxableSurplus = max(netTradeBalance, 0) + deferredSurplus
capacity       = deposit × capacityMultiplier / 10000
```

For positive taxable surplus `P`, the curve combines a base rate with a power term based on capacity utilization `P / capacity`. Initial values are `baseTaxRate = 900` (9%) and `curveExponent = 2`; governance may change both. Conceptually, target cumulative tariff is approximately:

```text
P × baseTaxRate / 10000
+ P × (10000 - baseTaxRate) / 10000
    × (P / capacity) ^ curveExponent / (curveExponent + 1)
```

On-chain fixed-point operations round upward and cap the result at `P`. Use `curveTax` or `calculateAMM` for a quote; the expression above explains the shape, not exact integer results. A trade that exceeds capacity reverts.

After a sale, Market evaluates the new target once. If the target exceeds tariff already held, it retains no more than this sale's `tradeValue`:

```text
deltaS = min(max(newTargetTax - collectedTariff, 0), tradeValue)
deltaW = tradeValue - deltaS
```

A small sale does not revert merely because its proceeds cannot cover the full shortfall. Later sales can collect the remainder. A deposit change likewise does not turn theoretical tariff into money already collected.

After a purchase, Market evaluates the buyer account's new target. If held tariff exceeds that target and the Payer meets the Merchant identity condition above:

```text
buyerRefund = min(collectedTariff - newTargetTax, tradeValue)
payerPays   = amount - buyerRefund
```

The actual deduction is also bounded by tariff held. This is an offset against the current payment, not an independent claim function. It cannot pay the `vaultFee`. Third-party payment may reduce the buyer's balance, but does not consume that account's tariff.

## 4. Deferred surplus slows matched balance resolution

A purchase may reduce the buyer's positive surplus while also reducing the seller's deficit. Only the overlapping reduction becomes the buyer's deferred surplus:

```text
buyerSurplusReduced = max(oldBuyerBalance, 0) - max(newBuyerBalance, 0)
sellerDeficitReduced = max(-oldSellerBalance, 0) - max(-newSellerBalance, 0)
resolvedSurplus      = min(buyerSurplusReduced, sellerDeficitReduced)
```

This handles balances crossing zero: only the portion genuinely resolved on both sides is deferred. An ordinary reduction of buyer surplus without matching seller deficit is not deferred. Market evaluates the curve once on `max(realBalance, 0) + currentDeferred`, making concentrated offset trades less able to unlock collected tariff immediately.

Deferred surplus declines linearly with deposit and time. Initially `resolutionRatio = 5000` and `RESOLUTION_PERIOD = 30 days`, giving a release capacity equal to 50% of effective deposit per 30 days. A cumulative index and remainder preserve fractional progress across frequent calls. Market settles elapsed time under the old parameters before a deposit increase or governance ratio change, so neither change rewrites past release.

## 5. Withdrawal, eviction, and the public Vault

The account owner may request withdrawal of the entire deposit when real net balance is nonpositive and deferred surplus is zero. The request immediately freezes the account: it cannot buy, sell, add deposit, or change multiplier; pending principal no longer provides capacity. After exactly `180 days`, the owner claims the principal and any remaining `sellerPoints` goes directly to the Merchant. The claim deletes the account and pair mapping; re-registration gets a new ID. The request does not require `sellerPoints == 0`. There is currently no cancel or early-unfreeze entry point.

`kickMerchant(accountId)` is restricted to Market's `governance` address, which the deployment flow sets to the Timelock. It slashes at most `min(taxableSurplus, deposit plus collected tariff)`, consuming deposit (including pending withdrawal principal) before collected tariff. The slash goes to the Vault; leftover deposit goes to the owner and leftover tariff to the Merchant. Then the account is deleted. Other owner accounts sharing the same Merchant remain separate.

The Vault receives rights fees and governance slashes, without booking a sale surplus for itself. It is a public buyer that cannot sell and uses an inactive, deposit-free `(vault, vault)` Default Buyer Account. Market pins its initial tier; governance sets a separate Vault limit that can only tighten. Governance queues immutable purchase orders, and anyone may execute them one by one. For each order, the Vault checks `sellerMultiplier <= capacityMultiplierLimit` and pays through `Market.trade`. The seller still receives seller rights, while the Vault's own buyer account receives no buyer rights.

## 6. Annual seats and dual consensus

Buyers and sellers have separate `ProportionalElection` contracts and annual `SeatToken` contracts. Each round lasts 365 days. Ordinary seats minted in the current round start voting at the next round boundary; each mint therefore waits only for the remainder of its round. Each active round with historical supply is normalized to `100 × 10^18` votes, and at most five active rounds are counted. Historical queries use the SeatToken's historical supply checkpoints.

Genesis seats belong to round 0. The current deployment script mints 100 × 10^18 genesis seats on each side to the deployer address. Initialization places the clock in round 2, so genesis seats are active at launch and leave the five-round window four full cycles later. They cannot be burned. Governance may partially burn ordinary seats during their minting round or first active round; from their second active year onward they cannot be burned. `batchBurn` takes a round ID per item, emits `SeatBurnSkipped` for ineligible rounds, missing tokens, or failed individual burns, and continues. Mismatched array lengths revert the whole call.

The Governor takes the smaller buyer/seller count separately for For, Against, and Abstain. A proposal succeeds only with positive effective For votes, at least twice effective Against votes, and quorum based on actual votes cast. Quorum sums the three choices on each side and takes the smaller participation total; uncast power is not participation. Quorum is 4% of historical buyer-side total voting weight. The initial proposal threshold is 100 × 10^18 votes and can be met on either side. Governor's initial voting delay is 7200 seconds and its voting period is 50400 seconds; these are separate from the next-round seat activation rule. Passage still requires overlap between sides. The deployment script transfers administration of Market, elections, settlement asset, and factories to the Timelock and grants proposal/cancellation roles only to the Governor. Its Timelock minimum delay is currently configured as zero; this is a deployment setting, separate from seat activation.

## 7. Code and tests

- `src/Market.sol` and `src/interfaces/IMarket.sol`: accounts, trades, tariff, withdrawal, eviction.
- `src/settlement/ERC20SettlementAsset.sol` and `src/TradeExecutor.sol`: custody and Merchant callback boundary.
- `src/RightsToken/`, `src/Governor/`, and `src/Vault.sol`: issuance, dual governance, public purchasing.
- `test/MarketTest.t.sol`, `test/DepositWithdrawalTest.t.sol`, `test/VaultTest.t.sol`, and governance/election tests: behavior regressions.
- [MerchantBase integration](merchantbase-integration-en.md): contract Merchant payment and release interfaces.

The current code is a single-token, independent Market. It has no surplus holding tax, old point-offset claim function, or multi-token router.