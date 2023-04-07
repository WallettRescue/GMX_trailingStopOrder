// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IOrderBook2 {

    function getTrailingStopOrder(address _account, uint256 _orderIndex) external view returns (
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionFee,
        uint256 trailingBPS
    );

    function executeTrailingStopOrder(address, uint256, address payable) external;
}
