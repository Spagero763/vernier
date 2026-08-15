// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library Retention {
    uint256 internal constant ACC_SCALE = 1e18;

    struct Pool {
        uint256 accPerLiquidity;
        uint256 totalLiquidity;
        uint256 totalRetained;
    }

    struct Position {
        uint128 liquidity;
        uint256 rewardDebt;
        uint256 accrued;
    }

    function accrue(Pool storage p, uint256 amount) internal {
        if (p.totalLiquidity == 0 || amount == 0) return;
        p.accPerLiquidity += (amount * ACC_SCALE) / p.totalLiquidity;
        p.totalRetained += amount;
    }

    function pending(Pool storage p, Position storage pos) internal view returns (uint256) {
        return pos.accrued + (uint256(pos.liquidity) * (p.accPerLiquidity - pos.rewardDebt)) / ACC_SCALE;
    }

    function addLiquidity(Pool storage p, Position storage pos, uint128 amount) internal {
        settle(p, pos);
        pos.liquidity += amount;
        p.totalLiquidity += amount;
    }

    function removeLiquidity(Pool storage p, Position storage pos, uint128 amount) internal {
        settle(p, pos);
        pos.liquidity -= amount;
        p.totalLiquidity -= amount;
    }

    function settle(Pool storage p, Position storage pos) internal {
        if (pos.liquidity > 0) {
            pos.accrued += (uint256(pos.liquidity) * (p.accPerLiquidity - pos.rewardDebt)) / ACC_SCALE;
        }
        pos.rewardDebt = p.accPerLiquidity;
    }
}
