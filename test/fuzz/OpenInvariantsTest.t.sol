// SPDX-License-Identifier: MIT

// Have our invariant aka properties

// What are our invariant:
// 1. The total supply of DSC should be less than the total value of collateral
// 2. Getter view functions should never revert <- evergreen invariant

pragma solidity ^0.8.19;

// import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {ERC20Mock} from "../mocks/ERC20Mock.sol";

// contract OpenInvariantsTest is StdInvariant, Test {
//     DeployDSC deployer;
//     DSCEngine dsce;
//     DecentralizedStableCoin dsc;
//     HelperConfig config;

//     address public ethUsdPriceFeed;
//     address public btcUsdPriceFeed;
//     address public weth;
//     address public wbtc;

//     function setUp() public {
//         deployer = new DeployDSC();
//         (dsc, dsce, config) = deployer.run();
//         (,, weth, wbtc,) = config.activeNetworkConfig();
//         targetContract(address(dsce));
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
//         // Get the all value of collateral in the protocol compare it to all the debt (DSC)
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = ERC20Mock(weth).balanceOf(address(dsc));
//         uint256 totalWbtcDeposited = ERC20Mock(wbtc).balanceOf(address(dsc));

//         uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
//         uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

//         console.log("wethValue: %s", wethValue);
//         console.log("wbtcValue: %s", wbtcValue);

//         assert(wethValue + wbtcValue >= totalSupply);
//     }
//     function invariant_gettersCantRevert() public view {
//     dsce.getAdditionalFeedPrecision();
//     dsce.getCollateralTokens();
//     dsce.getLiquidationBonus();
//     dsce.getLiquidationBonus();
//     dsce.getLiquidationThreshold();
//     dsce.getMinHealthFactor();
//     dsce.getPrecision();
//     dsce.getDsc();
//     // dsce.getTokenAmountFromUsd();
//     // dsce.getCollateralTokenPriceFeed();
//     // dsce.getCollateralBalanceOfUser();
//     // getAccountCollateralValue();
// }
// }
