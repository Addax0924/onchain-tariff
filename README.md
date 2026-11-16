# Onchain Tariff Market

English · [中文](README.zh.md)

## Protocol summary

Onchain Tariff Market is a decentralized on-chain marketplace that uses deposit-backed surplus limits and governance by both buyers and sellers to keep funds circulating.

Every seller account posts a deposit. Its net selling surplus may grow only up to a capacity proportional to that deposit, and the deposit can be withdrawn only after the surplus has been spent back to zero. The seller receives all proceeds after the rights fee; the deposit carries the commitment to keep funds moving.

Each trade pays a rights fee of about 1% to the public Vault and mints non-transferable governance seats for the buyer and seller sides. Seats become active in the next round; both sides vote on market entry rules, account eviction, and the use of shared funds.

### Design strengths

- **Atomic, account-level accounting:** Each economic account keeps its own deposit, net balance, and deferred surplus. A trade settles both sides' records, funds, and rights together; a failure reverts the whole trade.
- **A path for funds to circulate:** Surplus is capped by the deposit, and the deposit stays locked until the surplus returns to zero. Sellers therefore have a standing reason to spend proceeds back into the market instead of accumulating one-way surpluses.
- **Dual-sided governance and decentralization:** Trades generate rights on both sides. Market rules, account eviction, and public Vault purchases are executed through on-chain governance, reducing reliance on centralized operation for market access and the allocation of shared funds.

## 1. System overview

Onchain Tariff Market records commerce in one settlement token. Each economic account binds an immutable Account Owner–Merchant pair. Selling creates a surplus; buying reduces a surplus or creates a deficit. Positive surplus is limited by a deposit-backed capacity, and the deposit is released only after the surplus is gone.

Each trade also pays a rights fee of about 1% to the public Vault. The trade mints annual seats for the Account Owners on the buyer and seller sides. Seats begin voting in the next round, and both sides must participate in governing the Market. The design makes sustained surplus bear a capital requirement while rotating governance weight toward recent participants.

"Tariff" in the project name is a brand, not a description of a tax. The protocol takes no cut of sale proceeds other than the 1% rights fee. Rights are minted in proportion to protocol trading volume.

## 2. Core architecture

| Layer | Contracts | Responsibility |
| --- | --- | --- |
| Settlement | `ERC20SettlementAsset`, `Market`, `TradeExecutor` | Hold one settlement token and deposits, track account balances and capacity, deliver proceeds to Merchants. |
| Merchant | `MerchantBase`, `SimpleMerchantBase` | Contract Merchant callbacks and release allowances for multiple accounts or one fixed account. EOAs use neither base contract. |
| Rights | Buyer and seller `ProportionalElection` contracts, annual `SeatToken` contracts | Mint non-transferable seats and normalize voting power by round. |
| Decisions | `FinalGovernor`, Timelock, `Vault` | Count both sides, execute governance decisions, and purchase from an approved public-funds list. |

The main path of a trade is:

```text
Payer → Market.trade → SettlementAsset pulls funds
                     ├─ about 1% rights fee → Vault
                     └─ netAmount (the rest) → seller Merchant
                                                  └─ tradeIn callback for a contract Merchant
```

### Accounts and trades

The Account Owner registers an `(owner, merchant)` pair with a deposit and receives a numeric accountId. The account cannot be transferred. One Merchant can serve multiple owners; each account has separate deposit, balance, and deferred-surplus records. The Account Owner controls its multiplier, receives rights, and gets the deposit back; the Merchant receives trade proceeds. A third party may be the Payer (`msg.sender`) for any buyer account.

`buyerAccountId = 0` is a Market-only default buyer path: it creates or reuses the `(buyer, buyer)` account. An inactive default account can pay and record a deficit, but cannot receive as a seller. Its first trade must be self-paid and pins the first seller's tier; later purchases must use that tier or a stricter one. A contract Merchant's `tradeOut` requires both an active source account and an active destination seller account.

### Capacity and deposit

A trade computes `vaultFee = floor(amount / 100)` and `netAmount = amount - vaultFee`. The buyer's net balance decreases by `netAmount`, the seller's increases by the same amount, and the seller Merchant receives `netAmount` immediately.

The Effective Surplus of an account is its positive net balance plus its current deferred surplus. A sale reverts with `Capacity exceeded` if it would push the seller's Effective Surplus above its capacity, `deposit × capacityMultiplier / 10000` (`capacityOf`). A lower multiplier is a stricter tier. An active buyer account may pay only a seller at the same or a stricter tier. Its owner may lower the multiplier but cannot raise it; anyone may fully fund a deposit increase, which raises capacity immediately.

If a purchase simultaneously reduces the buyer's surplus and the seller's deficit, the overlapping amount becomes deferred surplus on the buyer account. It still counts toward capacity and still blocks deposit withdrawal, and it releases linearly over time at a deposit-based rate. This keeps bots from netting many accounts' surpluses and deficits against each other to free deposits at once.

The deposit is withdrawn in two steps. The Account Owner requests withdrawal when net balance is at most zero and deferred surplus is zero; the account freezes immediately, and the principal can be claimed after 180 days. Governance may kick an account instead, slashing at most its Effective Surplus from the deposit to the Vault and returning the rest to the Account Owner.

### Seats and governance

A round lasts 365 days. Ordinary seats minted in a round begin voting at the next round boundary. Each active round with supply is normalized to 100 votes, with at most five rounds counted. Governance may partially burn ordinary seats in their minting round or first active round, but not later. Genesis seats are active at launch, remain in the active window for four more years under the current round initialization, and have no burn entry point.

`FinalGovernor` records For, Against, and Abstain votes separately for buyers and sellers. The effective count for each choice is the smaller of the two sides. Success requires positive effective For votes, at least twice the effective Against votes, and quorum: the smaller side's actual participation must reach 4% of historical buyer-side total voting weight. The deployment flow transfers administration of the Market, elections, and settlement asset to the Timelock.

The Vault receives rights fees and governance slashes. It buys through individually approved orders, never sells, and does not mint buyer rights for its own `(vault, vault)` account.

## 3. Reading guide

- [Market mechanism](docs/market-mechanism-en.md): accounts, capacity, deferred surplus, exit, Vault, and governance.
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

`script/Deploy.s.sol` shows the full proxy, dual-election, Timelock, Governor, Market, Vault, executor, and permission-transfer path. `script/DeployMock.s.sol` deploys a local six-decimal test token. The deployment script reads a private key and settlement-token address and writes contract addresses to `.env`; review the target chain and environment before running it. When `DEPLOYMENT_OUTPUT` is set to a prefix under `deployments/` (for example `deployments/local`), both scripts instead write `<prefix>.mock.json` and `<prefix>.json` and neither read nor write `.env`. `script/Interact.s.sol` is currently a commented-out legacy example and is not an interface guide.

Source, interfaces, and tests define the behavior; this README is a starting point. The current implementation is an independent, single-token Market without a multi-token router or surplus holding fee.

## 5. Disclaimer

This code has not been audited. It is experimental software provided "as is", without warranty of any kind, as stated in the [MIT License](LICENSE). The authors and contributors accept no liability for any loss, damage, or other consequence arising from deploying, operating, or interacting with these contracts, including loss of funds, contract vulnerabilities, misconfiguration, or governance actions. Anyone who deploys or uses this code does so at their own risk and is responsible for independent security review, testing, and compliance with the laws and regulations that apply to them. Nothing in this repository is financial, legal, or investment advice.
