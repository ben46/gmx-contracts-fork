pragma solidity ^0.8.12;
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IVaultPriceFeed.sol";
import "./interfaces/IVaultManager.sol";
import "../tokens/interfaces/IUSDG.sol";
import "./ValidationLogic.sol";
import "./TokenLogic.sol";
import "./VaultStorage.sol";
import "./DataTypes.sol";
import "../libraries/math/SafeCast.sol";

contract VaultManager is ReentrancyGuard, VaultStorage, IVaultManager {
    using SafeMath for uint256;  
    using SafeCast for uint256;  
    using SafeMath128 for uint128;
    using SafeERC20 for IERC20;
    using TokenLogic for DataTypes.FundingData;
    
    function buyUSDG(address _token, address _receiver,uint256 tokenAmount) external    returns (uint256) {

        require(tokenAmount > 0, "17");
        fundingDatas[_token].updateCumulativeFundingRate(slot1.fundingInterval,
                                                        poolAmounts[_token],
                                                        slot1.stableFundingRateFactor,
                                                        slot1.fundingRateFactor,
                                                        reservedAmounts[_token],
                                                        addrObjs[_token].stableTokens,
                                                        _token
                                                        );

        uint256 price = IVaultPriceFeed(priceFeed).getPrice(_token, false, slot0.includeAmmPrice, true);

        uint256 usdgAmount = tokenAmount.mul(price).div(PRICE_PRECISION);
        usdgAmount = adjustForDecimals(usdgAmount, _token, usdg);
        require(usdgAmount > 0, "18");

        uint256 feeBasisPoints = getFeeBasisPoints(_token, usdgAmount, slot0.mintBurnFeeBasisPoints, slot0.taxBasisPoints, true);
        uint256 amountAfterFees = _collectSwapFees(_token, tokenAmount, feeBasisPoints);
        uint256 mintAmount = amountAfterFees.mul(price).div(PRICE_PRECISION);
        mintAmount = adjustForDecimals(mintAmount, _token, usdg);

        _increaseUsdgAmount(_token, mintAmount);
        _increasePoolAmount(_token, amountAfterFees);

        IUSDG(usdg).mint(_receiver, mintAmount);
 
        emit BuyUSDG(_receiver, _token, tokenAmount, mintAmount, feeBasisPoints); 
        
        return mintAmount;
    }

    function sellUSDG(address _token, address _receiver) external   nonReentrant returns (uint256) {
       
        slot1.useSwapPricing = true;

        uint256 usdgAmount = _transferIn(usdg);
        require(usdgAmount > 0, "20");
        fundingDatas[_token].updateCumulativeFundingRate(
            slot1.fundingInterval,
            poolAmounts[_token],
            slot1.stableFundingRateFactor,
            slot1.fundingRateFactor,
            reservedAmounts[_token],
            addrObjs[_token].stableTokens,                                                        _token

        );

        uint256 redemptionAmount = getRedemptionAmount(_token, usdgAmount);
        require(redemptionAmount > 0, "21");

        _decreaseUsdgAmount(_token, usdgAmount);
        _decreasePoolAmount(_token, redemptionAmount);

        IUSDG(usdg).burn(address(this), usdgAmount);

        // the _transferIn call increased the value of tokenBalances[usdg]
        // usually decreases in token balances are synced by calling mgr_transferOut
        // however, for usdg, the tokens are burnt, so _updateTokenBalance should
        // be manually called to record the decrease in tokens
        _updateTokenBalance(usdg);
 
        uint256 feeBasisPoints = getFeeBasisPoints(_token, usdgAmount, slot0.mintBurnFeeBasisPoints, slot0.taxBasisPoints, false);
        uint256 amountOut = _collectSwapFees(_token, redemptionAmount, feeBasisPoints);
        require(amountOut > 0, "22");

        _transferOut(_token, amountOut, _receiver);

        emit SellUSDG(_receiver, _token, usdgAmount, amountOut, feeBasisPoints);

        slot1.useSwapPricing = false;
        return amountOut;
    }

    function swap(address _tokenIn, 
                address _tokenOut, 
                address _receiver) external   nonReentrant returns (uint256) {

        require(slot0.isSwapEnabled, "23");
        require(addrObjs[_tokenIn].whitelistedTokens, "24");
        require(addrObjs[_tokenOut].whitelistedTokens, "25");
        require(_tokenIn != _tokenOut, "26");

        slot1.useSwapPricing = true;
        fundingDatas[_tokenIn].updateCumulativeFundingRate(
            slot1.fundingInterval,
            poolAmounts[_tokenIn],
            slot1.stableFundingRateFactor,
            slot1.fundingRateFactor,
            reservedAmounts[_tokenIn],
            addrObjs[_tokenIn].stableTokens,                                                        _tokenIn

        );
        fundingDatas[_tokenOut].updateCumulativeFundingRate(
            slot1.fundingInterval,
            poolAmounts[_tokenOut],
            slot1.stableFundingRateFactor,
            slot1.fundingRateFactor,
            reservedAmounts[_tokenOut],
            addrObjs[_tokenOut].stableTokens,                                                        _tokenOut

        ); 

        uint256 amountIn = _transferIn(_tokenIn);
        require(amountIn > 0, "27");

        uint256 priceIn = IVaultPriceFeed(priceFeed).getPrice(_tokenIn, false, slot0.includeAmmPrice, slot1.useSwapPricing);
        uint256 priceOut = IVaultPriceFeed(priceFeed).getPrice(_tokenOut, true, slot0.includeAmmPrice, slot1.useSwapPricing);

        uint256 amountOut = amountIn.mul(priceIn).div(priceOut);
        amountOut = adjustForDecimals(amountOut, _tokenIn, _tokenOut);

        // adjust usdgAmounts by the same usdgAmount as debt is shifted between the assets
        uint256 usdgAmount = amountIn.mul(priceIn).div(PRICE_PRECISION);
        usdgAmount = adjustForDecimals(usdgAmount, _tokenIn, usdg);

        bool isStableSwap = addrObjs[_tokenIn].stableTokens && addrObjs[_tokenOut].stableTokens;
        uint256 feeBasisPoints;
        {
            uint256 baseBps = isStableSwap ? slot1.stableSwapFeeBasisPoints : slot1.swapFeeBasisPoints;
            uint256 taxBps = isStableSwap ? slot0.stableTaxBasisPoints : slot0.taxBasisPoints;
            uint256 feesBasisPoints0 = getFeeBasisPoints(_tokenIn, usdgAmount, baseBps, taxBps, true);
            uint256 feesBasisPoints1 = getFeeBasisPoints(_tokenOut, usdgAmount, baseBps, taxBps, false);
            // use the higher of the two fee basis points
            feeBasisPoints = feesBasisPoints0 > feesBasisPoints1 ? feesBasisPoints0 : feesBasisPoints1;
        }
        uint256 amountOutAfterFees = _collectSwapFees(_tokenOut, amountOut, feeBasisPoints);

        _increaseUsdgAmount(_tokenIn, usdgAmount);
        _decreaseUsdgAmount(_tokenOut, usdgAmount);

        (bool suc,) = address(this).call(abi.encodeWithSignature(
            "swapCallback(address,uint256,address,uint256)", 
            _tokenIn,
            amountIn,
            _tokenOut,
            amountOut
        ));
        require(suc);

        _validateBufferAmount(_tokenOut);

        _transferOut(_tokenOut, amountOutAfterFees, _receiver);

        emit Swap(_receiver, _tokenIn, _tokenOut, amountIn, amountOut, amountOutAfterFees, feeBasisPoints);

        slot1.useSwapPricing = false;
        return amountOutAfterFees;
    } 

    /**

        // cases to consider
        // 1. initialAmount is far from targetAmount, action increases balance slightly => high rebate
        // 2. initialAmount is far from targetAmount, action increases balance largely => high rebate
        // 3. initialAmount is close to targetAmount, action increases balance slightly => low rebate
        // 4. initialAmount is far from targetAmount, action reduces balance slightly => high tax
        // 5. initialAmount is far from targetAmount, action reduces balance largely => high tax
        // 6. initialAmount is close to targetAmount, action reduces balance largely => low tax
        // 7. initialAmount is above targetAmount, nextAmount is below targetAmount and vice versa
        // 8. a large swap should have similar fees as the same trade split into multiple smaller swaps
        //    function getFeeBasisPoints(address _token, uint256 _usdgDelta, uint256 _feeBasisPoints, uint16 _taxBasisPoints, bool _increment) external pure returns (uint256);
    
    */  
    function getFeeBasisPoints(address _token, 
                            uint256 _usdgDelta, 
                            uint256 _feeBasisPoints, 
                            uint256 _taxBasisPoints, 
                            bool _increment) public  view returns (uint256) {
        if (!slot1.hasDynamicFees) { return _feeBasisPoints; }

        uint256 initialAmount = usdgAmounts[_token];
        uint256 nextAmount = initialAmount.add(_usdgDelta);
        if (!_increment) {
            nextAmount = _usdgDelta > initialAmount ? 0 : initialAmount.sub(_usdgDelta);
        }

        uint256 targetAmount = getTargetUsdgAmount(_token);
        if (targetAmount == 0) { return _feeBasisPoints; }

        uint256 initialDiff = initialAmount > targetAmount ? initialAmount.sub(targetAmount) : targetAmount.sub(initialAmount);
        uint256 nextDiff = nextAmount > targetAmount ? nextAmount.sub(targetAmount) : targetAmount.sub(nextAmount);

        // action improves relative asset balance
        if (nextDiff < initialDiff) {
            uint256 rebateBps = _taxBasisPoints.mul(initialDiff).div(targetAmount);
            return rebateBps > _feeBasisPoints ? 0 : _feeBasisPoints.sub(rebateBps);
        }

        uint256 averageDiff = initialDiff.add(nextDiff).div(2);
        if (averageDiff > targetAmount) {
            averageDiff = targetAmount;
        }
        uint256 taxBps = _taxBasisPoints.mul(averageDiff).div(targetAmount);
        return _feeBasisPoints.add(taxBps);
    }

    function _increaseUsdgAmount(address _token, uint256 _amount) private {
        uint256 _usdgAmounts = usdgAmounts[_token];
        _usdgAmounts = _usdgAmounts.add(_amount);
        uint256 maxUsdgAmount = maxUsdgAmounts[_token];
        if (maxUsdgAmount != 0) {
            require(_usdgAmounts <= maxUsdgAmount, "51");
        }
        usdgAmounts[_token] = _usdgAmounts;
        emit IncreaseUsdgAmount(_token, _amount);
    }
    
    function _decreaseUsdgAmount(address _token, uint256 _amount) private {
        uint256 value = usdgAmounts[_token];
        // since USDG can be minted using multiple assets
        // it is possible for the USDG debt for a single asset to be less than zero
        // the USDG debt is capped to zero for this case
        if (value <= _amount) {
            usdgAmounts[_token] = 0;
            emit DecreaseUsdgAmount(_token, value);
            return; 
        }
        usdgAmounts[_token] = value.sub(_amount);
        emit DecreaseUsdgAmount(_token, _amount);
    } 

    function _collectSwapFees(address _token, uint256 _amount, uint256 _feeBasisPoints) private returns (uint256) {
        uint256 afterFeeAmount = _amount.mul(BASIS_POINTS_DIVISOR.sub(_feeBasisPoints)).div(BASIS_POINTS_DIVISOR);
        uint256 feeAmount = _amount.sub(afterFeeAmount);
        addrObjs[_token].feeReserves = addrObjs[_token].feeReserves.add(uint128(feeAmount));
        emit CollectSwapFees(_token, tokenToUsdMin(_token, feeAmount), feeAmount);
        return afterFeeAmount;
    }
    
    function getTargetUsdgAmount(address _token) public view returns (uint256) {
        uint256 supply = IERC20(usdg).totalSupply();
        if (supply == 0) { return 0; }
        uint256 weight = addrObjs[_token].tokenWeights;
        return weight.mul(supply).div(slot0.totalTokenWeights);
    } 

    function getRedemptionAmount(address _token, uint256 _usdgAmount) public  view returns (uint256) {
        uint256 price = IVaultPriceFeed(priceFeed).getPrice(_token, true, slot0.includeAmmPrice, slot1.useSwapPricing);
        uint256 redemptionAmount = _usdgAmount.mul(PRICE_PRECISION).div(price);
        return adjustForDecimals(redemptionAmount, usdg, _token);
    }

    function adjustForDecimals(uint256 _amount, address _tokenDiv, address _tokenMul) private view returns (uint256) {
        uint256 decimalsDiv = _tokenDiv == usdg ? USDG_DECIMALS : addrObjs[_tokenDiv].tokenDecimals;
        uint256 decimalsMul = _tokenMul == usdg ? USDG_DECIMALS : addrObjs[_tokenMul].tokenDecimals;
        return _amount.mul(10 ** decimalsMul).div(10 ** decimalsDiv);
    }
    
    function _updateTokenBalance(address _token) private {
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;
    } 

    function _validateBufferAmount(address _token) private view {
        if (poolAmounts[_token] < bufferAmounts[_token]) {
            revert("Vault: poolAmount < buffer");
        }
    }

    function setUsdgAmount(address _token, uint256 _amount) external {

        uint256 usdgAmount = usdgAmounts[_token];
        if (_amount > usdgAmount) {
            _increaseUsdgAmount(_token, _amount.sub(usdgAmount));
            return;
        }

        _decreaseUsdgAmount(_token, usdgAmount.sub(_amount));
    }    

     function setFees(
        uint256 _taxBasisPoints,
        uint256 _stableTaxBasisPoints,
        uint256 _mintBurnFeeBasisPoints,
        uint256 _swapFeeBasisPoints,
        uint256 _stableSwapFeeBasisPoints,
        uint256 _marginFeeBasisPoints,
        uint256 _liquidationFeeUsd,
        uint256 _minProfitTime,
        bool _hasDynamicFees
    ) public   {

        DataTypes.Slot0 memory _slot0 = slot0;
        DataTypes.Slot1 memory _slot1 = slot1;

        _slot0.taxBasisPoints = uint8(_taxBasisPoints);
        _slot0.stableTaxBasisPoints = uint8(_stableTaxBasisPoints);
        _slot0.mintBurnFeeBasisPoints = uint8(_mintBurnFeeBasisPoints);
        _slot0.liquidationFeeUsd = uint112(_liquidationFeeUsd);
        slot0 = _slot0;

        _slot1.swapFeeBasisPoints = uint32 (_swapFeeBasisPoints);
        _slot1.stableSwapFeeBasisPoints = uint32   (_stableSwapFeeBasisPoints);
        _slot1.marginFeeBasisPoints = uint32 (_marginFeeBasisPoints);
        _slot1.minProfitTime = uint32 (_minProfitTime);
        _slot1.hasDynamicFees = _hasDynamicFees;
        slot1 = _slot1;
    }

/**
bnb.address, // _token
    18, // _tokenDecimals
    10000, // _tokenWeight
    75, // _minProfitBps,
    0, // _maxUsdgAmount
    false, // _isStable
    true // _isShortable
     */
     function setTokenConfig(
        address _token,
        uint256 _tokenDecimals,
        uint256 _tokenWeight,
        uint256 _minProfitBps,
        uint256 _maxUsdgAmount,
        bool _isStable,
        bool _isShortable
    ) public   {
        // increment token count for the first time
        DataTypes.AddrObj memory _addrObj = addrObjs[_token];
        DataTypes.Slot0 memory _slot0 = slot0;
        if (!_addrObj.whitelistedTokens) {
            uint256 _local_count = uint256(_slot0.whitelistedTokenCount);
            _slot0.whitelistedTokenCount = _local_count.add(1).toUInt16();
            allWhitelistedTokens.push(_token);
        }

        uint256 _totalTokenWeights = uint256(slot0.totalTokenWeights);
        _totalTokenWeights = _totalTokenWeights.sub(_addrObj.tokenWeights);

        _addrObj.whitelistedTokens = true;
        _addrObj.tokenDecimals = _tokenDecimals.toUInt16();
        _addrObj.tokenWeights = _tokenWeight.toUInt16();
        _addrObj.minProfitBasisPoints = _minProfitBps.toUInt16();
        _addrObj.stableTokens = _isStable;
        _addrObj.shortableTokens = _isShortable;
        addrObjs[_token] = _addrObj;

        _slot0.totalTokenWeights = _totalTokenWeights.add(_tokenWeight).toUInt32();

        slot0 = _slot0;
        maxUsdgAmounts[_token] = _maxUsdgAmount;
    }

    function clearTokenConfig(address _token) public {
        DataTypes.AddrObj memory _addrObj = addrObjs[_token];
        require( _addrObj.whitelistedTokens , "13");
        DataTypes.Slot0 memory _slot0 = slot0;
        _slot0.totalTokenWeights = uint256(_slot0.totalTokenWeights).sub(uint256( _addrObj.tokenWeights )).toUInt32();
        delete _addrObj.whitelistedTokens;
        delete _addrObj.tokenDecimals;
        delete _addrObj.tokenWeights;
        delete _addrObj.minProfitBasisPoints;
        delete _addrObj.stableTokens;
        delete _addrObj.shortableTokens;
        delete maxUsdgAmounts[_token];
        _slot0.whitelistedTokenCount = uint256(_slot0.whitelistedTokenCount).sub(1).toUInt16();
        slot0 = _slot0;
        addrObjs[_token] = _addrObj;
    }

    function initialize(
            address _router,
            address _usdg,
            address _priceFeed,
            uint256 _liquidationFeeUsd,
            uint256 _fundingRateFactor,
            uint256 _stableFundingRateFactor
        ) external   {
             slot0 = DataTypes.Slot0({
            isInitialized : true,
            isSwapEnabled  : true,
            isLeverageEnabled  : true,
            includeAmmPrice : true,
            //-----------------
            taxBasisPoints : 50,
            stableTaxBasisPoints : 20,        // _slot1.stableTaxBasisPoints = 20; // 0.2%
            mintBurnFeeBasisPoints : 30,        // _slot1. mintBurnFeeBasisPoints = 30; // 0.3%
            //------------------
            whitelistedTokenCount : 0,            
            totalTokenWeights : 0,
            maxLeverage : 50 * 10000,        // _slot1. mintBurnFeeBasisPoints = 30; // 0.3% 
            liquidationFeeUsd:uint112(_liquidationFeeUsd)
        });

        slot1 = DataTypes.Slot1({
             fundingRateFactor : uint16(_fundingRateFactor),
            stableFundingRateFactor : uint16(_stableFundingRateFactor),
            fundingInterval : 8 hours,
            inPrivateLiquidationMode  : false,
            hasDynamicFees  : false,
            swapFeeBasisPoints : 30,
            //-----------------
            stableSwapFeeBasisPoints : 4,
            marginFeeBasisPoints : 10,        // _slot1.stableTaxBasisPoints = 20; // 0.2%
            //------------------
            useSwapPricing : false,
            inManagerMode : false,
            minProfitTime : 0,
            maxGasPrice : 0
        });

        router = _router;
        usdg = _usdg;
        priceFeed = _priceFeed;
    }

}