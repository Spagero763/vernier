// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRateAttestor} from "../../src/interfaces/IRateAttestor.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

contract MockRateAttestor is IRateAttestor {
    bool public sound = true;
    bool public broken;

    function setSound(bool value) external {
        sound = value;
    }

    function setBroken(bool value) external {
        broken = value;
    }

    function isSound(PoolId) external view returns (bool) {
        require(!broken, "attestor down");
        return sound;
    }
}
