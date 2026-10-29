# Onchain Tariff Market

English · [中文](README.zh.md)

## Protocol summary

Onchain Tariff Market is a decentralized on-chain marketplace that uses dynamic tariffs and governance by both buyers and sellers to keep funds circulating.

The protocol applies a dynamic tariff to net selling surplus. As a seller's surplus rises, it retains part of new sale proceeds. Later purchases by the same participant reduce that historical surplus and return held funds as the taxable surplus falls. Once both ordinary and deferred surplus reach zero, no tariff remains due: eligible purchases offset payments, and any held balance not yet refunded is returned in full to the Merchant when the account completes withdrawal.

Each trade pays a rights fee of about 1% to the public Vault and mints non-transferable governance seats for the buyer and seller sides. Seats become active in the next round; both sides vote on market entry rules, account eviction, and the use of shared funds.

### Design strengths

- **Atomic, account-level accounting:** Each economic account keeps its own deposit, net surplus, and tariff actually retained. A trade settles both sides' records, funds, and rights together; a failure reverts the whole trade.
- **A path for funds to circulate:** Growing sale surplus triggers dynamic retention, while later purchases release held funds. This gives sale proceeds a route back into trade and reduces long-lived accumulation from one-way surpluses.
- **Dual-sided governance and decentralization:** Trades generate rights on both sides. Market rules, account eviction, and public Vault purchases are executed through on-chain governance, reducing reliance on centralized operation for market access and the allocation of shared funds.

## 1. System overview

Onchain Tariff Market records commerce in one settlement token. Each economic account binds an immutable Account Owner–Merchant pair. Selling creates a surplus; buying reduces a surplus or creates a deficit. Positive surplus is constrained by a deposit-backed capacity and a dynamic tariff. When that account later buys, collected tariff can offset its payment within the protocol's rules.

Each trade also pays a rights fee of about 1% to the public Vault. The trade mints annual seats for the Account Owners on the buyer and seller sides. Seats begin voting in the next round, and both sides must participate in governing the Market. The design makes sustained surplus bear a stronger capital requirement while rotating governance weight toward recent participants.

“Tariff” names an internal settlement rule; it is not a claim about legal taxation. Rights are minted from protocol trade amounts, which are not a measure of national GDP.

## 2. Core architecture

| Layer | Contracts | Responsibility |
| --- | --- | --- |
| Settlement | `ERC20SettlementAsset`, `Market`, `TradeExecutor` | Hold one settlement token, track account balances and tariff, deliver actual proceeds to Merchants. |
| Merchant | `MerchantBase`, `SimpleMerchantBase` | Contract Merchant callbacks and release allowances for multiple accounts or one fixed account. EOAs use neither base contract. |
| Rights | Buyer and seller `ProportionalElection` contracts, annual `SeatToken` contracts | Mint non-transferable seats and normalize voting power by round. |
| Decisions | `FinalGovernor`, Timelock, `Vault` | Count both sides, execute governance decisions, and purchase from an approved public-funds list. |

The main path of a trade is:

```text
Payer → Market.trade → SettlementAsset pulls funds
                     ├─ about 1% rights fee → Vault
                     ├─ new seller tariff → retained for possible refund
                     └─ actual proceeds deltaW → seller Merchant
                                                    └─ tradeIn callback for a contract Merchant
```

### Accounts and trades

The Account Owner registers an `(owner, merchant)` pair with a deposit and receives a numeric accountId. The account cannot be transferred. One Merchant can serve multiple owners; each account has separate deposit, balance, and tariff records. The Account Owner controls its multiplier and receives rights; the Merchant receives trade proceeds. A third party may be the Payer (`msg.sender`), but payment does not grant access to the buyer account's tariff refund.

`buyerAccountId = 0` is a Market-only default buyer path: it creates or reuses the `(buyer, buyer)` account. An inactive default account can pay and record a deficit, but cannot receive as a seller. A contract Merchant's `tradeOut` requires both an active source account and an active destination seller account.

### Tariff and deposit

A trade first computes `vaultFee = floor(amount / 100)` and `tradeValue = amount - vaultFee`. The buyer's net balance decreases by `tradeValue`, and the seller's increases by the same amount. The seller's target cumulative tariff uses positive net balance plus unreleased deferred surplus. `sellerPoints` is the tariff actually retained and not yet refunded. If a small sale cannot collect the full shortfall, it retains at most that sale's `tradeValue` and collects the rest from later sales.

Deposit-backed capacity is `deposit × capacityMultiplier / 10000`. A lower multiplier is a stricter tier. An active buyer account may pay only a seller at the same or a stricter tier. Its owner may lower the multiplier but cannot raise it; anyone may fully fund a deposit increase.

If a purchase simultaneously reduces the buyer's surplus and the seller's deficit, the overlapping amount becomes deferred surplus on the buyer account. It releases over time at a deposit-based rate. A qualifying later purchase may use collected tariff to reduce the amount pulled from the Merchant, up to that purchase's `tradeValue`. The 1% rights fee remains payable.

### Seats and governance

A round lasts 365 days. Ordinary seats minted in a round begin voting at the next round boundary. Each active round with supply is normalized to 100 votes, with at most five rounds counted. Governance may partially burn ordinary seats in their minting round or first active round, but not later. Genesis seats are active at launch, remain in the active window for four more years under the current round initialization, and have no burn entry point.

`FinalGovernor` records For, Against, and Abstain votes separately for buyers and sellers. The effective count for each choice is the smaller of the two sides. Success requires positive effective For votes, at least twice the effective Against votes, and quorum: the smaller side's actual participation must reach 4% of historical buyer-side total voting weight. The deployment flow transfers administration of the Market, elections, and settlement asset to the Timelock.

The Vault receives rights fees and governance slashes. It buys through individually approved orders, never sells, and does not mint buyer rights for its own `(vault, vault)` account.

## 3. Reading guide

- [Market mechanism](docs/market-mechanism-en.md): accounts, tariff curve, deferred surplus, exit, Vault, and governance.
- [MerchantBase integration](docs/merchantbase-integration-en.md): multiple owners and multiplier buckets.
- [SimpleMerchantBase integration](docs/simple-merchantbase-en.md): one account, one fixed tier, and two fixed release shares.
- [Domain language](CONTEXT.md): boundaries between Account Owner, Merchant, Payer, and other identities.
- [中文 README](README.zh.md), [中文机制说明](docs/market-mechanism-zh.md), and [中文商家接入说明](docs/merchantbase-integration-zh.md).

## 4. Development and testing

The project uses Foundry, Solidity `^0.8.20`, OpenZeppelin, and Solady. `foundry.toml` enables `via_ir`. Market uses a transient-storage reentrancy guard, so the target chain must support the relevant Cancun EVM features.

```sh
forge build
forge test
```

`script/Deploy.s.sol` shows the full proxy, dual-election, Timelock, Governor, Market, Vault, executor, and permission-transfer path. `script/DeployMock.s.sol` deploys a local six-decimal test token. The deployment script reads a private key and settlement-token address and writes contract addresses to `.env`; review the target chain and environment before running it. `script/Interact.s.sol` is currently a commented-out legacy example and is not an interface guide.

Source, interfaces, and tests define the behavior; this README is a starting point. The current implementation is an independent, single-token Market without a multi-token router or surplus holding tax.
