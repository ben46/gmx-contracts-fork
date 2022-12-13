pragma solidity ^0.8.12;
import "../DataTypes.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

library TokenLogic { 
    using SafeMath for uint256;  
    using TokenLogic for DataTypes.FundingData;
    event UpdateFundingRate(address token, uint256 fundingRate);

    function updateCumulativeFundingRate(DataTypes.FundingData storage _data, 
                                        uint256 fundingInterval, 
                                        uint256 poolAmount, 
                                        uint256 stableFundingRateFactor,
                                        uint256 fundingRateFactor,
                                        uint256 reservedAmounts,
                                        bool stableTokens,
                                        address _token)  internal  {
        if (_data.lastFundingTimes == 0) {
            _data.lastFundingTimes = block.timestamp.div(fundingInterval).mul(fundingInterval);
            return;
        }

        if (_data.lastFundingTimes.add(fundingInterval) > block.timestamp) {
            return;
        }

        uint256 fundingRate = _data.getNextFundingRate(fundingInterval,   
                                                        poolAmount,
                                                        stableFundingRateFactor,
                                                        fundingRateFactor, 
                                                        reservedAmounts,
                                                        stableTokens);
        _data.cumulativeFundingRates = _data.cumulativeFundingRates.add(fundingRate);
        _data.lastFundingTimes = block.timestamp.div(fundingInterval).mul(fundingInterval);
        emit UpdateFundingRate(_token, _data.cumulativeFundingRates);

    }

    function getNextFundingRate(DataTypes.FundingData storage _data, 
                                uint256 fundingInterval, 
                                uint256 poolAmount, 
                                uint256 stableFundingRateFactor,
                                uint256 fundingRateFactor,
                                uint256 reservedAmounts,
                                bool stableTokens) 
                                internal view returns (uint256) {
        if (_data.lastFundingTimes.add( fundingInterval) > block.timestamp) { return 0; }
        uint256 intervals = block.timestamp.sub(_data.lastFundingTimes).div(fundingInterval);
        if (poolAmount == 0) { return 0; }
        uint256 _fundingRateFactor = stableTokens ? stableFundingRateFactor : fundingRateFactor;
        return _fundingRateFactor.mul(reservedAmounts).mul(intervals).div(poolAmount);
    }

}