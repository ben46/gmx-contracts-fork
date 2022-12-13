// SPDX-License-Identifier: MIT

pragma solidity ^0.8.12;
library DataTypes {
    struct Position {
        uint256 size;
        uint256 collateral;
        uint256 averagePrice;
        uint256 entryFundingRate;
        uint256 reserveAmount;
        int256 realisedPnl;
        uint256 lastIncreasedTime;
    }
    
    struct Slot0{
        bool   isInitialized; // 8
        bool   isSwapEnabled ; // 16
        bool   isLeverageEnabled ; // 24
        bool  includeAmmPrice ; // 32        
        uint8   taxBasisPoints; // 500 max
        uint8  stableTaxBasisPoints ; // 500 max
        uint8  mintBurnFeeBasisPoints ; // 
        
        uint16 whitelistedTokenCount;//
        uint32 totalTokenWeights;//
        uint32   maxLeverage ; // 50x    152
        
        uint112   liquidationFeeUsd; // 最大值 100 * 10 ** 30
    }

    struct Slot1{
        bool  useSwapPricing  ; // 40
        bool   inManagerMode  ; // 48
        bool   inPrivateLiquidationMode  ; // 56
        bool   hasDynamicFees; // 64
        uint32 marginFeeBasisPoints ; // 112
        uint32 swapFeeBasisPoints;//120        
        uint32 minProfitTime; // 248

        uint16 fundingRateFactor; // 最大值10000
        uint16 stableFundingRateFactor;// 最大值10000
        uint32   fundingInterval ; //     176

        uint32 maxGasPrice;//208
        uint32   stableSwapFeeBasisPoints; // 104
    }
    struct UpgradeVaultParams{
        address newVault;
        address token;
        uint256 amount;
        uint256 endTime;
    }

    struct AddrObj{
        bool isLiquidator;
        bool isManager;
        bool whitelistedTokens;
        bool stableTokens;
        bool shortableTokens;//40
        uint16 tokenWeights;
        uint16 tokenDecimals;
        uint16 minProfitBasisPoints;
        // feeReserves tracks the amount of fees per token跟踪每个令牌的费用金额
        uint128 feeReserves;
        // lastFundingTimes tracks the last time funding was updated for a token
        //跟踪上次更新代币资金的时间
    }

    struct FundingData{
        uint256  lastFundingTimes;
        uint256 cumulativeFundingRates;
        
    }

}