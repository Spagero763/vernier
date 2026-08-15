// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRateSource} from "../../src/interfaces/IRateSource.sol";

contract ToggleRateSource is IRateSource {
    uint256 public rate = 1e18;
    bool public reverting;

    function setRate(uint256 value) external {
        rate = value;
    }

    function setReverting(bool value) external {
        reverting = value;
    }

    function getRate() external view returns (uint256) {
        require(!reverting, "rate unavailable");
        return rate;
    }
}
