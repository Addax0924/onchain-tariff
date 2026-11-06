// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "./EnvFile.sol";
import "../src/Market.sol";
import "../src/TradeExecutor.sol";
import "../src/Vault.sol";
import "../src/settlement/ERC20SettlementAsset.sol";
import "../src/RightsToken/ProportionalElection.sol";
import "../src/RightsToken/SeatTokenFactory.sol";
import "../src/RightsToken/GenesisSeatToken.sol";
import "../src/Governor/FinalGovernor.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

contract DeploySystem is EnvFile {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(deployerPrivateKey);
        address underlyingToken = vm.envOr("USDC_ADDRESS", address(0));

        vm.startBroadcast(deployerPrivateKey);

        // --- 1. 部署工厂 ---
        SeatTokenFactory buyerFactory = new SeatTokenFactory();
        SeatTokenFactory sellerFactory = new SeatTokenFactory();

        GenesisSeatToken buyerGenesisSeat = new GenesisSeatToken(
            "Council Seat 0",
            "CS",
            admin
        );
        GenesisSeatToken sellerGenesisSeat = new GenesisSeatToken(
            "Council Seat 0",
            "CS",
            admin
        );
        buyerGenesisSeat.mint(admin, 100 * 1e18);
        sellerGenesisSeat.mint(admin, 100 * 1e18);
        // --- 2. 部署选举合约 (使用作用域 {} 减少栈压力) ---
        ProportionalElection buyerElection;
        ProportionalElection sellerElection;
        {
            buyerElection = ProportionalElection(
                address(
                    new ERC1967Proxy(
                        address(new ProportionalElection()),
                        abi.encodeWithSelector(
                            ProportionalElection.initialize.selector,
                            address(buyerFactory),
                            admin,
                            address(buyerGenesisSeat)
                        )
                    )
                )
            );

            sellerElection = ProportionalElection(
                address(
                    new ERC1967Proxy(
                        address(new ProportionalElection()),
                        abi.encodeWithSelector(
                            ProportionalElection.initialize.selector,
                            address(sellerFactory),
                            admin,
                            address(sellerGenesisSeat)
                        )
                    )
                )
            );
        }

        buyerGenesisSeat.setMinter(address(buyerElection));
        sellerGenesisSeat.setMinter(address(sellerElection));

        // 绑定工厂
        buyerFactory.setElectionContract(address(buyerElection));
        sellerFactory.setElectionContract(address(sellerElection));

        ERC20SettlementAsset settlementAsset;
        {
            address settlementImpl = address(new ERC20SettlementAsset());
            bytes memory settlementInit = abi.encodeWithSelector(
                ERC20SettlementAsset.initialize.selector,
                underlyingToken,
                admin
            );
            settlementAsset = ERC20SettlementAsset(
                address(new ERC1967Proxy(settlementImpl, settlementInit))
            );
        }

        // --- 3. 部署 Timelock ---
        TimelockController timelock;
        {
            // The deployer configures roles but never receives direct proposal authority.
            address[] memory proposers = new address[](0);
            address[] memory executors = new address[](1);
            executors[0] = address(0);
            timelock = new TimelockController(0, proposers, executors, admin);
        }

        // --- 4. 部署 Market ---
        Market market;
        {
            address marketImpl = address(new Market());
            bytes memory marketInit = abi.encodeWithSelector(
                Market.initialize.selector,
                address(settlementAsset),
                address(buyerElection),
                address(sellerElection),
                address(timelock),
                address(0)
            );
            market = Market(address(new ERC1967Proxy(marketImpl, marketInit)));
        }

        Vault vault = new Vault(address(market));
        uint256 vaultInitialTier = vm.envOr("VAULT_INITIAL_TIER", uint256(40000));
        market.setVault(address(vault), vaultInitialTier);

        // --- 5. 部署执行器与 FinalGovernor ---
        TradeExecutor executor = new TradeExecutor(
            address(market),
            address(settlementAsset)
        );
        market.setExecutor(address(executor));
        settlementAsset.setController(address(market), true);
        settlementAsset.setController(address(executor), true);

        // 授权权限
        buyerElection.setMinter(address(market));
        sellerElection.setMinter(address(market));

        FinalGovernor governor;
        {
            address govImpl = address(new FinalGovernor());
            bytes memory govInit = abi.encodeWithSelector(
                FinalGovernor.initialize.selector,
                address(buyerElection),
                address(sellerElection),
                timelock
            );
            governor = FinalGovernor(
                payable(address(new ERC1967Proxy(govImpl, govInit)))
            );
        }

        // --- 6. 权限移交 ---
        market.transferOwnership(address(timelock));
        settlementAsset.transferOwnership(address(timelock));
        buyerElection.transferOwnership(address(timelock));
        sellerElection.transferOwnership(address(timelock));
        buyerFactory.transferOwnership(address(timelock));
        sellerFactory.transferOwnership(address(timelock));

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), admin);

        vm.stopBroadcast();

        console.log("Deployment Successful. Market:", address(market));
        console.log("Trade Executor:", address(executor));
        console.log("Settlement Asset:", address(settlementAsset));
        console.log("Underlying Token:", address(underlyingToken));
        console.log("Buyer Election:", address(buyerElection));
        console.log("Seller Election:", address(sellerElection));
        console.log("Vault:", address(vault));
        console.log("Governor:", address(governor));
        console.log("Timelock:", address(timelock));
        _writeDeploymentEnv(
            address(market),
            address(executor),
            address(settlementAsset),
            underlyingToken,
            address(buyerElection),
            address(sellerElection),
            address(governor),
            address(timelock),
            address(vault)
        );
    }

    function _writeDeploymentEnv(
        address market,
        address executor,
        address settlementAsset,
        address underlyingToken,
        address buyerElection,
        address sellerElection,
        address governor,
        address timelock,
        address vault
    ) internal {
        string memory path = ".env";
        string memory env = vm.readFile(path);

        env = _upsertEnvAddress(env, "MARKET_ADDRESS", market);
        env = _upsertEnvAddress(env, "TRADE_EXECUTOR_ADDRESS", executor);
        env = _upsertEnvAddress(
            env,
            "SETTLEMENT_ASSET_ADDRESS",
            settlementAsset
        );
        env = _upsertEnvAddress(env, "USDC_ADDRESS", underlyingToken);
        env = _upsertEnvAddress(env, "BUYER_ELECTION_ADDRESS", buyerElection);
        env = _upsertEnvAddress(
            env,
            "SELLER_ELECTION_ADDRESS",
            sellerElection
        );
        env = _upsertEnvAddress(env, "GOVERNOR_ADDRESS", governor);
        env = _upsertEnvAddress(env, "TIMELOCK_ADDRESS", timelock);
        env = _upsertEnvAddress(env, "VAULT_ADDRESS", vault);

        vm.writeFile(path, env);
        console.log("Updated .env deployment addresses");
    }
}

/*
forge script script/Deploy.s.sol:DeploySystem \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --via-ir \
  -vv
*/
