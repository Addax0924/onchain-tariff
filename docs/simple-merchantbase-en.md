# SimpleMerchantBase: one-account Merchant integration

English · [中文](simple-merchantbase-zh.md)

`SimpleMerchantBase` is a separate abstract UUPS base contract for a contract Merchant that uses **one Market, one Account Owner, and one fixed deposit multiplier tier**. It keeps fixed owner/business release shares while removing the multiple-owner allowlist and multiplier-keyed flow buckets. The existing `MerchantBase` is unchanged.

## 1. What becomes simpler

| Topic | SimpleMerchantBase rule |
| --- | --- |
| Market account | Accepts only `(accountOwner, this proxy)`. The first successful receipt pins its accountId. |
| Tier | `capacityMultiplier` is fixed at initialization; each receipt and payout checks the live Market account against it. |
| Receipts | One cumulative `received` value records each sale's `netAmount` after the rights fee. |
| Payouts | `ownerReleased` and `businessReleased` are separate, but their limits are fixed shares of the same `received` total. |
| Business callback | The derived contract implements `_tradeIn(rechargeTarget, netAmount, deltaW, data)` without a multiplier parameter. |

Account Owner means the owner of the Market economic account. `owner()` is the upgradeable proxy administrator and initially equals the Account Owner. Administration may later be transferred, but that does not change the fixed economic owner or its payout role.

## 2. Deployment and registration

Deploy a derived contract through `ERC1967Proxy` and call the base initializer from the derived `initializer`:

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

The base reads the underlying token from Market's SettlementAsset, so there is no token-address parameter. `capacityMultiplier` must be at least 1000. The two shares must sum to 10000. If both shares are positive, `businessAddress` must be nonzero and distinct from Account Owner. No ordinary interface changes the shares after initialization.

After deploying the proxy, the **Account Owner** approves SettlementAsset for the deposit and registers the proxy:

```solidity
market.registerMerchant(address(simpleMerchantProxy), deposit, capacityMultiplier);
```

Deposit must be positive and the registration multiplier must match the proxy's fixed value. `accountId()` is zero before the first successful receipt. On the first `tradeIn`, the base reads `market.accountIdOf(accountOwner, address(this))` and pins the active account. If that account is later withdrawn or evicted, re-registering the same pair under a new ID cannot carry old release allowance into the new account; deploy a new proxy. Changing the Market account's multiplier also makes receipts and payouts fail, as required by the fixed-tier model.

## 3. Receipts and the derived hook

Customers still call `Market.trade` directly. The seller account ID must be this proxy's active Market account. `buyerAccountId = 0` is only the customer's Default Buyer Account path in Market. After SettlementAsset transfers `deltaW` to the proxy, TradeExecutor calls the base `tradeIn`.

The base checks the configured Executor, the rights recipient, an active and unfrozen Market account, the pinned account ID, and the fixed tier. It increments `received` and calls:

```solidity
function _tradeIn(
    uint160 rechargeTarget,
    uint256 netAmount,
    uint256 deltaW,
    bytes calldata data
) internal override {
    // Validate the order and record customer credits or other business state here.
}
```

`netAmount = amount - floor(amount / 100)` is the sale's trade value. `deltaW` is the token amount actually received by the proxy and may be smaller because of seller tariff. A failed hook reverts the whole Market trade. The base does not keep buckets by `rechargeTarget` or track customers and creator entitlements.

## 4. Fixed-share payouts

Both paths draw on one cumulative receipt base:

```text
ownerAvailable    = floor(received × ownerShareBps / 10000) - ownerReleased
businessAvailable = floor(received × businessShareBps / 10000) - businessReleased
```

For `received = 99` smallest units and `4000 / 6000` shares, the current owner and business limits are 39 and 59 units. Rounding remainder cannot be spent twice. Allowance decreases by the full payout `amount`, not the amount paid after a tariff refund or the destination Merchant's `deltaW`.

Account Owner or the configured business address calls:

```solidity
simpleMerchant.tradeOut(
    sellerAccountId, // active upstream or creator seller account
    rechargeTarget,
    amount,
    data
);
```

The base supplies its fixed `accountOwner` and pinned buyer account ID. The caller does not repeat `buyer` or `buyerAccountId`. **There is no ID-zero source-account path here**: the platform is the buyer Merchant and must use an active source account. The destination seller must also be active and satisfy Market's tier-flow rule.

Only the fixed Account Owner spends the owner share; only the current `business()` address spends the business share. The base approves SettlementAsset for the full `amount` from the proxy's underlying balance, then calls Market. Because the proxy is the buyer account's Merchant, eligible held tariff may offset this payment, while the 1% rights fee remains payable. Approval is cleared afterward. A Market or destination failure also reverts the `released` update.

`received` is an economic allowance, not the proxy's live ERC20 balance: some trade value may still be held as tariff in SettlementAsset. The business layer should check immediate liquidity and the upstream party's entitlement before paying.

## 5. Administration and lifecycle

- `releaseAvailable()` returns the two current allowances. `received()`, `ownerReleased()`, and `businessReleased()` expose cumulative values.
- `setBusiness` and `setTradeExecutor` are restricted to `owner()`. Changing business transfers its unused historical allowance to the new address. Coordinate Executor changes with Market.
- `owner()` initially equals the fixed Account Owner, but transferring proxy administration does not change `accountOwner()` or the owner's payout right.
- `owner()` authorizes proxy upgrades. The pinned account ID, multiplier, and release ledger are long-lived proxy state; review storage layout and historical allowance before an upgrade.
- The base does not manage Market deposits, withdrawal, or governance eviction. A frozen Market account cannot receive or pay through it. A new Market account after exit needs a new proxy.

The implementation is `src/Merchant/SimpleMerchantBaseUpgradeable.sol`. `test/SimpleMerchantBaseTest.t.sol` uses real Market, SettlementAsset, and Executor contracts to cover receipts, both shares, tier changes, account replacement, and rollback. Merchants serving several owners or tiers can keep using the [MerchantBase integration guide](merchantbase-integration-en.md).