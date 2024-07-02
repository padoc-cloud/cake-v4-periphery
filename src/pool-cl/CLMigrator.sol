// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {BaseMigrator, IV3NonfungiblePositionManager} from "../base/BaseMigrator.sol";
import {ICLMigrator, PoolKey} from "./interfaces/ICLMigrator.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";

contract CLMigrator is ICLMigrator, BaseMigrator {
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    constructor(address _WETH9, address _nonfungiblePositionManager) BaseMigrator(_WETH9) {
        nonfungiblePositionManager = INonfungiblePositionManager(_nonfungiblePositionManager);
    }

    function migrateFromV2(
        V2PoolParams calldata v2PoolParams,
        INonfungiblePositionManager.MintParams calldata v4MintParams,
        uint256 extraAmount0,
        uint256 extraAmount1
    ) external payable override {
        (uint256 amount0Received, uint256 amount1Received) =
            withdrawLiquidityFromV2(v2PoolParams.pair, v2PoolParams.migrateAmount);

        /// @notice if user mannually specify the price range, they might need to send extra token
        batchAndNormalizeTokens(
            v4MintParams.poolKey.currency0, v4MintParams.poolKey.currency1, extraAmount0, extraAmount1
        );

        (,, uint256 amount0Consumed, uint256 amount1Consumed) = _addLiquidityToTargetPool(v4MintParams);

        // refund if necessary, ETH is supported by CurrencyLib
        unchecked {
            if (amount0Received > amount0Consumed) {
                v4MintParams.poolKey.currency0.transfer(v4MintParams.recipient, amount0Received - amount0Consumed);
            }
            if (amount1Received > amount1Consumed) {
                v4MintParams.poolKey.currency1.transfer(v4MintParams.recipient, amount1Received - amount1Consumed);
            }
        }
    }

    function migrateFromV3(
        V3PoolParams calldata v3PoolParams,
        INonfungiblePositionManager.MintParams calldata v4MintParams,
        uint256 extraAmount0,
        uint256 extraAmount1
    ) external payable override {
        IV3NonfungiblePositionManager.DecreaseLiquidityParams memory decreaseLiquidityParams =
        IV3NonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: v3PoolParams.tokenId,
            liquidity: v3PoolParams.liquidity,
            amount0Min: v3PoolParams.amount0Min,
            amount1Min: v3PoolParams.amount1Min,
            deadline: v4MintParams.deadline
        });
        (uint256 amount0Received, uint256 amount1Received) =
            withdrawLiquidityFromV3(v3PoolParams.nfp, decreaseLiquidityParams, v3PoolParams.collectFee);

        /// @notice if user mannually specify the price range, they need to send extra token
        batchAndNormalizeTokens(
            v4MintParams.poolKey.currency0, v4MintParams.poolKey.currency1, extraAmount0, extraAmount1
        );

        (,, uint256 amount0Consumed, uint256 amount1Consumed) = _addLiquidityToTargetPool(v4MintParams);

        // refund if necessary, ETH is supported by CurrencyLib
        unchecked {
            if (amount0Received > amount0Consumed) {
                v4MintParams.poolKey.currency0.transfer(v4MintParams.recipient, amount0Received - amount0Consumed);
            }
            if (amount1Received > amount1Consumed) {
                v4MintParams.poolKey.currency1.transfer(v4MintParams.recipient, amount1Received - amount1Consumed);
            }
        }
    }

    function _addLiquidityToTargetPool(INonfungiblePositionManager.MintParams calldata params)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0Consumed, uint256 amount1Consumed)
    {
        /// @dev currency1 cant be NATIVE
        bool nativePair = params.poolKey.currency0.isNative();
        if (!nativePair) {
            approveMax(params.poolKey.currency0, address(nonfungiblePositionManager));
        }
        approveMax(params.poolKey.currency1, address(nonfungiblePositionManager));

        // TODO: compare the gas cost of multicall and two separate call
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(nonfungiblePositionManager.mint.selector, params);
        data[1] = abi.encodeWithSelector(nonfungiblePositionManager.refundETH.selector);
        bytes[] memory ret = nonfungiblePositionManager.multicall{value: nativePair ? params.amount0Desired : 0}(data);
        (tokenId, liquidity, amount0Consumed, amount1Consumed) =
            abi.decode(ret[0], (uint256, uint128, uint256, uint256));
    }

    /// @notice Planned to be batched with migration operations through multicall to save gas
    function initialize(PoolKey memory poolKey, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        payable
        override
        returns (int24 tick)
    {
        return nonfungiblePositionManager.initialize(poolKey, sqrtPriceX96, hookData);
    }
}
