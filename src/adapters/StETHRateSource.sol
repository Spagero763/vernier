// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRateSource} from "../interfaces/IRateSource.sol";

interface IStETHMinimal {
    function getPooledEthByShares(uint256 shares) external view returns (uint256);
}

contract StETHRateSource is IRateSource {
    IStETHMinimal public immutable steth;

    constructor(address steth_) {
        steth = IStETHMinimal(steth_);
    }

    function getRate() external view returns (uint256) {
        return steth.getPooledEthByShares(1e18);
    }
}
