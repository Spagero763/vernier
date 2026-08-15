// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRateSource} from "../interfaces/IRateSource.sol";

interface IERC4626Minimal {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

contract ERC4626RateSource is IRateSource {
    IERC4626Minimal public immutable vault;

    constructor(address vault_) {
        vault = IERC4626Minimal(vault_);
    }

    function getRate() external view returns (uint256) {
        return vault.convertToAssets(1e18);
    }
}
