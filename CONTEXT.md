# Onchain Tariff Market

This context names the economic and governance identities used by the market so
their responsibilities remain distinct across settlement and voting code.

## Language

**Market Account**:
A lightweight, non-transferable numeric ID for one immutable Account
Owner–Merchant pair. Its deposit, capacity multiplier, net trade balance,
deferred surplus, and active state are tracked independently.
_Avoid_: Merchant ID, NFT

**Account Owner**:
The address that creates a Market Account, controls its capacity multiplier,
receives that account's rights tokens, and receives the deposit back on
withdrawal or kick.
_Avoid_: Beneficiary, delegatee

**Merchant**:
The address that receives the account's trade settlement in full (the 1%
rights fee aside), followed by a `tradeIn` callback when it is a contract.
One Merchant may participate in multiple Market Accounts with different Account
Owners and may reject unsupported owners during its trade callback.
_Avoid_: Account Owner, seller account

**Default Buyer Account**:
The lazily created Market Account where Account Owner and Merchant both equal
the external buyer. It starts inactive, with no deposit or capacity multiplier,
and records that buyer's deficit. Its first seller pins its capacity multiplier;
later purchases must use that tier or a stricter one. The first trade must be
self-paid. Its ID and pinned tier are reused if the same pair is later activated
as a Merchant; an outstanding deficit prevents choosing a stricter tier then.
_Avoid_: Unregistered merchant

**Payer**:
The `msg.sender` funding a trade. A Payer may fund either a Default Buyer Account
or an explicitly selected Market Account. Paying does not change who owns the
buyer account or who receives its rights.
_Avoid_: Buyer

**Deposit Increase**:
A permissionless, fully funded increase to a Market Account's deposit. It
raises capacity immediately and accelerates deferred-surplus release only from
the time of the increase onward. The whole deposit returns to the Account Owner.
_Avoid_: Deposit credit

**Deferred Surplus**:
The buyer-side amount of surplus that disappeared while the seller's deficit
was reduced in the same trade. It still counts toward capacity and still blocks
deposit withdrawal, and it declines linearly over time at a deposit-based rate.
This prevents balance-resolution bots from netting many accounts' surpluses and
deficits against each other and freeing their deposits at once.
_Avoid_: Refund quota

**Effective Surplus**:
The positive part of a Market Account's real net trade balance plus its current
Deferred Surplus (`effectiveSurplus`). A sale that would raise it above the
account's capacity, `deposit * capacityMultiplier / 10000` (`capacityOf`),
reverts. A kick slashes at most this amount.
_Avoid_: Taxable surplus, retainable surplus

**Capacity Multiplier**:
A per-account capacity parameter expressed in basis points. It may only move
down while the Market Account exists, and cannot be below 1,000. Funds booked
to an active buyer account may only flow to a seller account with an equal or
lower multiplier. Inactive Default Buyer Accounts follow their first seller's
pinned tier and may subsequently buy only at that tier or a stricter one.
_Avoid_: Global capacity

**Merchant Release Shares**:
The MerchantBase instance fixes Account Owner and Business shares at
initialization, in basis points adding to 10,000. Both flow views retain raw
received amounts. Each release is capped by floor(cumulative received * its
share / 10,000) minus cumulative released. Fixed shares prevent reallocating
already-spent historical receipts. These limits account for economic flows;
they do not attach a multiplier label to each ERC20 unit after settlement.

**Governance Participation**:
Quorum counts only explicitly cast For, Against, and Abstain votes. Participation
is summed separately on buyer and seller sides, then the smaller side is used.
Uncast voting power contributes nothing. The proposal success ratio remains
effective For >= twice effective Against, with positive effective For required.
Only Active proposals accept votes. Timelock proposal and cancellation roles
belong to the Governor after deployment; the deployer has no direct such role.

**Election Round Activation And Burn Window**:
Each round lasts 365 days. Seats minted in the current round start voting at the
next round boundary; this is not a fixed 365-day wait for each mint. Governance
may partially burn ordinary seats in the current minting round or their first
active round by specifying the round ID. Older active rounds and genesis round 0
cannot be burned. A single burn rejects an invalid round. Batch burns take one
round ID per item, skip ineligible rounds, missing tokens, or token burn failures,
and emit SeatBurnSkipped for each skipped item. Mismatched array lengths revert
the whole call.

**Historical Total Voting Weight**:
Each active annual SeatToken with nonzero supply at the queried past timestamp
contributes 100 normalized votes. ProportionalElection reads the SeatToken's
existing ERC20Votes total-supply checkpoints; later creation, burning, or
reminting cannot rewrite that timestamp's weight. At most five rounds are read.

**Deposit Withdrawal**:
Only the Account Owner may request withdrawal of the entire effective deposit.
The real net trade balance must be nonpositive and current Deferred Surplus must
be zero. The request moves all deposit into a pending withdrawal with a
fixed 180-day delay; it immediately stops providing capacity or deferred release.
The account retains its registered/active identity, multiplier and deficit,
but isAccountFrozen becomes true immediately. Frozen accounts cannot participate
on either side of a trade, including third-party payments and ID-zero default
account resolution. Deposit increases and multiplier changes are also blocked.
The freeze persists until the pending withdrawal is claimed. Only the Account
Owner may claim, and the principal is paid to that Owner, not Merchant,
including amounts previously contributed by third parties. A governance kick
deletes the pending claim and frozen flag along with the account, and slashes
from the effective deposit (including a pending withdrawal) at most the
account's current Effective Surplus. The rest is paid immediately to the
Account Owner. There is currently no
unfreeze/cancellation entry point. Successful
withdrawal deletes the Market Account and its pair mapping, returning the pair
to an unregistered state. Re-registration creates a fresh ID; MerchantBase flow
buckets are external to Market and are not reset by this deletion.
