//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*
 * @title DecentralizedStableCoin
 * @author Mudit Sarda
 * Collateral: Exogenous (ETH & BTC)
 * Minting: Algorithmic
 * Relative stability: Pegged to USD
 *
 * This is the contract meant to be governed by DSCEngine. This is just the ERC20 implementation of the stable coin.
 *
 */
contract DecentalizedStableCoin is ERC20Burnable, Ownable {
    error DecentalizedStableCoin__AmountMustBeGreaterThanZero();
    error DecentalizedStableCoin__BurnAmountExceedsBalance();
    error DecentalizedStableCoin__NotZeroAddress();

    constructor(address initialOwner) ERC20("DecentralizedStableCoin", "DSC") Ownable(initialOwner) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            // this line does not need any test because zero amount check has been tested in DSCEngine in burnDsc function
            revert DecentalizedStableCoin__AmountMustBeGreaterThanZero();
        }
        if (balance < _amount) {
            revert DecentalizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentalizedStableCoin__NotZeroAddress();
        }
        if (_amount <= 0) {
            // this line does not need any test because zero amount check has been tested in DSCEngine in mintDsc function
            revert DecentalizedStableCoin__AmountMustBeGreaterThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
