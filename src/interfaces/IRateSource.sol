// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IRateSource {
    function getRate() external view returns (uint256);
}
