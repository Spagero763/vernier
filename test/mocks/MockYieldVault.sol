// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockYieldVault {
    uint256 public rate = 1e18;

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * rate) / 1e18;
    }

    function setRate(uint256 newRate) external {
        rate = newRate;
    }

    function accrue(uint256 pips) external {
        rate = rate + (rate * pips) / 1_000_000;
    }
}
