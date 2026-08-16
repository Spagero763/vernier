// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/// Second opinion on whether a pool's rate source can still be believed.
///
/// The rate itself is read straight from the yield token, so nothing off-chain is needed
/// to price accrual. What an operator set can add is judgement the hook cannot form
/// alone: whether a share price moved because yield accrued or because someone donated
/// into the vault to inflate it. This interface is that judgement and nothing more, so a
/// failure here can only stop the correction, never change the price.
interface IRateAttestor {
    function isSound(PoolId id) external view returns (bool);
}
