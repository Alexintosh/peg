// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.4;
interface IOracle {
    function getData() external view returns (uint256, bool);
}
interface IChainlinkAggregator {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/**
 * @title Chainlink Oracle
 *
 * @notice Provides a value onchain from a chainlink oracle aggregator
 */
contract RaiUSDChainlinkOracle is IOracle {
    // The address of the Chainlink Aggregator contract
    IChainlinkAggregator constant oracle = IChainlinkAggregator(0x483d36F6a1d063d580c7a24F9A42B346f3a69fbb);
    uint256 constant stalenessThresholdSecs = 86400;

    /**
     * @notice Fetches the latest market price from chainlink
     * @return Value: Latest market price as an 8 decimal fixed point number.
     *         valid: Boolean indicating an value was fetched successfully.
     */
    function getData() external view override returns (uint256, bool) {
        (, int256 answer, , uint256 updatedAt, ) = oracle.latestRoundData();
        uint256 diff = block.timestamp - updatedAt;
        return (uint256(answer), diff <= stalenessThresholdSecs);
    }
}