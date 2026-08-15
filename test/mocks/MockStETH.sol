// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockStETH {
    uint256 public pooledEthPerShare = 1e18;

    function getPooledEthByShares(uint256 shares) external view returns (uint256) {
        return (shares * pooledEthPerShare) / 1e18;
    }

    function setPooledEthPerShare(uint256 value) external {
        pooledEthPerShare = value;
    }
}
