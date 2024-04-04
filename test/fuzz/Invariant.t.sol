//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// what are out invariants?

// 1. The total supply of DSC should be less than the total value of collateral
// 2. getter view functions should never revert <- EVERGREEN

import {Test, console} from "forge-std/Test.sol";
// import "forge-std/console.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentalizedStableCoin} from "../../src/DecentalizedStableCoin.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dsce;
    DecentalizedStableCoin dsc;
    HelperConfig config;
    Handler handler;
    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (, , weth, wbtc, ) = config.activeNetworkConfig();
        handler = new Handler(dsce, dsc);
        targetContract(address(handler));
        // targetContract(address(dsce));
    }

    function invariant_protocolMusthaveMoreCollateralThanDebt() public view {
        //get value of all the collateral
        uint256 totalWethDeposited = ERC20Mock(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = ERC20Mock(wbtc).balanceOf(address(dsce));

        //get value of all the dsc
        uint256 totalDSC = dsc.totalSupply();

        // value in $
        uint256 totalWethValue = dsce.getUsdValue(weth, totalWethDeposited);
        uint256 totalWbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("weth value: ", totalWethValue);
        console.log("wbtc value: ", totalWbtcValue);
        console.log("total supply: ", totalDSC);
        console.log("times mint is called: ", handler.timesMintIsCalled());

        assert(totalWethValue + totalWbtcValue >= totalDSC);
    }

    function invariant_gettersShouldNeverRevert() public view {
        dsce.getCollateralTokens();
        dsce.getPrecision();
        dsce.getAdditionalPrecision();
    }
}
