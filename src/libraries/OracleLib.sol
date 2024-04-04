//SPDX-License-Identifier:MIT

pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author Mudit Sarda
 * @notice This lib is used to check the Chainlink Oracle for stale prices. If the price is stale, the function will revert and
 * make the DSCEngine unusable.
 *
 * We want the DSCEngine to freeze if prices become stale.
 *
 * So if a Chainlink network explodes and you have too much money stored in it...too bad.
 */
library OracleLib {
    error OracleLib_StalePrice();

    uint256 private constant TIMEOUT = 3 hours;

    function StaleCheckLatestRoundData(
        AggregatorV3Interface priceFeed
    ) public view returns (uint80, int256, uint256, uint256, uint80) {
        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        uint256 secondsSinceLastUpdate = block.timestamp - updatedAt;

        if (secondsSinceLastUpdate >= TIMEOUT) {
            revert OracleLib_StalePrice();
        }

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
