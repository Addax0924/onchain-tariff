# MerchantBase integration and interactions

English · [中文](merchantbase-integration-zh.md)

This document follows the current `src/Merchant/MerchantBaseUpgradeable.sol`, `IMarket`, and `TradeExecutor`. The file is named `MerchantBaseUpgradeable.sol`; its abstract contract is `MerchantBase`. It helps a **multi-owner, multi-tier contract Merchant** connect to one Market: it checks who may receive a sale and tracks release allowances. A derived contract or business system still implements platform credits, consumption, and creator allocations. An EOA Merchant can use Market directly, but has none of this base contract's callback, allowlist, or bucket checks.

## 1. Keep the identities separate

| Name | Role in this base contract |
| --- | --- |
| Contract administrator `owner()` | Maintains supported owners, `business`, and the Executor; authorizes proxy upgrades. Administration alone gives no `tradeOut` authority. |
| Account Owner | Registers an `(owner, platform proxy)` Market account, controls its multiplier, and receives its buyer or seller rights. |
| Merchant | Here, the **MerchantBase proxy address**. It receives actual sale proceeds and calls Market as a buyer when using tariff held for an account. |
| `business()` | The platform's business executor, which can use the business release bucket. It is neither the destination nor the owner of every source account. |

One platform proxy may serve multiple Account Owners. Each `(owner, proxy)` pair has its own Market accountId, deposit, balance, and tariff. Business flow can aggregate receipts from multiple owners at the same multiplier. `rechargeTarget` is a `uint160` business identifier interpreted by the destination Merchant. The base contract does not keep a persistent bucket per recharge target.

## 2. Initialize and register accounts

Deploy a derived contract through a proxy and call the base initializer from the derived `initializer`:

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

`initialAccountOwner` must be nonzero and is added to the support list; this does **not** register a Market account. Release shares use a denominator of 10000 and must sum to 10000, for example `2000 / 8000`. Either share may be zero. There is no ordinary share setter: changing shares would reallocate historical receipts. `owner()` is the proxy initialization caller `msg.sender`, not necessarily `initialAccountOwner`. The base reads `settlementAsset()` from Market but does not fully validate all address combinations. Check that Market, underlying, SettlementAsset, and Executor belong to the same settlement path.

Each Account Owner needs platform support and registers from their own address:

```solidity
platform.setAccountOwnerSupport(accountOwner, true); // platform administrator; initial owner is already supported
// accountOwner first approves the Market's SettlementAsset for the deposit
uint256 accountId = market.registerMerchant(address(platformProxy), deposit, multiplier);
```

The caller of `registerMerchant` is the Account Owner. Deposit must be positive and multiplier at least 1000. Use `market.accountIdOf(accountOwner, address(platformProxy))` to find the ID and `market.accounts(accountId)` to inspect owner, merchant, deposit, multiplier, and active state. Market registration and MerchantBase support are separate: an active account whose owner is unsupported will still fail the platform's receipt callback.

Anyone may fully fund `Market.addDeposit(accountId, amount)` for an active account. This does not increase MerchantBase `received` or immediately refund tariff. Only the Account Owner may maintain or lower the multiplier through `setCapacityMultiplier`. The base books receipts under the **current** multiplier and does not migrate old multiplier buckets. The integration should coordinate multiplier changes at the business level.

## 3. Customer pays the platform through Market.trade

The Payer first approves SettlementAsset, then calls:

```solidity
market.trade(
    buyer,                   // Account Owner of the buyer account
    buyerAccountId,          // 0 means the Market Default Buyer Account
    platformSellerAccountId, // active (owner, platform proxy) seller account
    rechargeTarget,
    amount,
    data
);
```

`buyer` may differ from the actual Payer. `buyerAccountId = 0` asks Market to find or create `(buyer, buyer)`; it does **not** choose a buyer's platform account. The first payment from an inactive default account must be made by the buyer. An explicit buyer ID must belong to `buyer`. The seller ID must always be active; it determines which platform account records the sale and which owner receives seller rights.

Market computes `vaultFee = floor(amount / 100)`, `netAmount = amount - vaultFee`, then determines seller tariff and `deltaW`:

| Amount | Meaning |
| --- | --- |
| `amount` | Full order amount, including the rights fee. |
| `netAmount` | Trade value after the rights fee; the amount added to the base contract's `received` buckets. |
| `deltaW` | Settlement tokens actually delivered to the platform proxy; it may be less than `netAmount`. |

Amounts are in the underlying token's smallest unit; do not assume every token has six decimals. Market currently uses one settlement token. A third-party Payer still changes the buyer account's balance and rights, but cannot use its collected tariff.

The execution path is:

```text
Market records balance, tariff, and rights
  → SettlementAsset sends deltaW to the platform proxy
  → TradeExecutor calls the proxy's tradeIn
  → the base validates owner and account, then records flow
  → the derived _tradeIn handles business data
```

A contract recipient receives the callback whether `data` is empty or not; an EOA has no callback. Executor transfers first and calls afterward, so the platform does not `transferFrom` Executor. The callback may read Market view methods but cannot reenter the same Market's `trade`. A failed callback reverts the entire trade.

## 4. tradeIn: support list, account, and business hook

The external callback from Executor is:

```solidity
function tradeIn(
    address registeredRightsOwner,
    uint160 rechargeTarget,
    uint256 netAmount,
    uint256 deltaW,
    bytes calldata data
) external;
```

The base accepts only its configured `tradeExecutor`. It requires `registeredRightsOwner` to be supported, locates the **active** `(registeredRightsOwner, address(this))` Market account, and reads its current `capacityMultiplier`. It adds the same `netAmount` to the owner and business receipt views, then calls the derived hook:

```solidity
function _tradeIn(
    uint160 rechargeTarget,
    uint256 capacityMultiplier,
    uint256 netAmount,
    uint256 deltaW,
    bytes calldata data
) internal override {
    // Validate the business target, order data, and credit or allocation rules here.
}
```

The external `tradeIn` takes no multiplier parameter. The base reads it from Market and passes it to the internal hook. The base does not issue platform credits, track customer balances, or decide creator entitlements. Removing an owner from the support list blocks future receipts but does not delete their Market account or historical buckets.

## 5. Two flow views and fixed release shares

| Bucket | Key | `received` | `released` |
| --- | --- | --- | --- |
| Owner | Account Owner + multiplier | Cumulative `netAmount` for that owner's sales in this tier | Full `amount` spent by the owner path |
| Business | multiplier | Cumulative `netAmount` for all supported owners in this tier | Full `amount` spent by the business path |

A sale appears once in each `received` view. These are two views of the **same** receipt, not double revenue. The fixed initialization shares limit what each path may release:

```text
ownerAvailable =
    floor(ownerReceived × ownerShareBps / 10000) - ownerReleased
businessAvailable =
    floor(businessReceived × businessShareBps / 10000) - businessReleased
```

For `netAmount = 99` smallest units and `2000 / 8000` shares, each bucket records `received = 99`, but the owner and business paths can release at most 19 and 79 units respectively. Rounding remainder may become usable as cumulative receipts grow. Multiplier buckets do not mix. An owner cannot use another owner's allowance; business aggregates receipts at the same multiplier. `received` is not the proxy's live ERC20 balance: part of `netAmount` may remain as tariff in SettlementAsset. Having an allowance does not guarantee enough immediate cash to pay.

`accountOwnerFlow(owner, multiplier)` and `businessFlow(multiplier)` return raw cumulative values; combine them with `releaseShares()` to calculate availability.

## 6. The platform pays upstream through tradeOut

For procurement, upstream payments, or creator allocations, the platform calls:

```solidity
platform.tradeOut(
    buyer,           // Account Owner of the source Market account
    buyerAccountId,  // active (buyer, platform proxy) source account
    sellerAccountId, // active seller account receiving the payment
    rechargeTarget,
    amount,
    data
);
```

The platform is the **buyer Merchant**. The upstream party or creator is the **destination seller account**. `MerchantBase.tradeOut` does not use the ID-zero Default Buyer Account path: it first reads the source account and requires it to be active, owned by `buyer`, served by this proxy, and still supported. Market also requires an active destination seller. Same-ID self-trades, frozen accounts, and invalid tiers revert. Market's default buyer path remains available to other direct callers of `Market.trade`.

If the caller equals `business()`, the business bucket takes precedence. Otherwise the caller must be the source Account Owner and uses that owner's bucket. The contract administrator has no extra `tradeOut` privilege. Business may select any supported platform source account, but the business layer must verify the creator, entitlement, and withdrawal authorization. The base only checks its aggregate allowance.

The base first increments `released`, approves SettlementAsset for the full `amount` from the platform's underlying balance, and calls `Market.trade` as the platform. This makes `msg.sender` equal the buyer account's Merchant, allowing an eligible refund of that account's collected tariff to offset the current payment. No separate refund is sent to the external caller. `released` always records the full `amount`, not `amount - refund` or the destination's `deltaW`. A failure in Market or the destination callback reverts the allowance update and transfers.

## 7. Lifecycle, administration, and indexing

Only the contract administrator may call `setAccountOwnerSupport`, `setBusiness`, and `setTradeExecutor`. Changing business hands existing business allowance to the new address without resetting buckets. Executor is the trusted receipt callback caller; coordinate a change with Market's configuration. The base uses UUPS `onlyOwner` upgrades; review storage layout and historical buckets separately before upgrading an existing proxy.

An Account Owner can request a Market deposit withdrawal. The account freezes immediately, and after 180 days the owner claims principal while residual tariff goes to the Merchant; the Market account and pair mapping are deleted. Governance may also evict by account ID. **MerchantBase buckets have a separate lifecycle**: exit or eviction does not clear them. If the same pair registers again under a new ID and the same multiplier, it encounters the old bucket. The business system must decide how to handle that historical allowance.

Index `SaleRecorded`, `AccountOwnerReleaseRecorded`, `BusinessReleaseRecorded`, `AccountOwnerSupportUpdated`, `ReleaseSharesConfigured`, `BusinessUpdated`, and `TradeExecutorUpdated`. The base does not enumerate every owner and multiplier; an indexer can discover them from events and verify totals through getters. Market balances, refunds, and rights need Market and election events as well; `SaleRecorded` alone cannot reconstruct the whole economic state.

See `test/MerchantBaseTest.t.sol`, `test/MerchantAccountingRegression.t.sol`, and `test/DepositWithdrawalTest.t.sol` for regressions. The wider tariff and governance model is described in the [Market mechanism](market-mechanism-en.md).