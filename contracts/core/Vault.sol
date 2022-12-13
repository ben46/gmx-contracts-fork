// SPDX-License-Identifier: MIT

pragma solidity ^0.8.12;

// import "../libraries/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
// import "../libraries/token/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// import "../libraries/token/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// import "../libraries/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../tokens/interfaces/IUSDG.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IVaultManager.sol";
import "./interfaces/IVaultPriceFeed.sol";
import "../libraries/math/SafeCast.sol";
import "./VaultStorage.sol";
import "./TokenLogic.sol";
import "./GenericLogic.sol";

contract Vault is ReentrancyGuard,  VaultStorage, IVault {
    using SafeMath for uint256;  
    using SafeCast for uint256;  
    using SafeMath128 for uint128;
    using SafeERC20 for IERC20;
    using TokenLogic for DataTypes.FundingData; 

    // once the parameters are verified to be working correctly,
    // gov should be set to a timelock contract or a governance contract
    constructor(address _vaultManager)  {
        gov = msg.sender;  
        vaultManager = _vaultManager ;      
    }
 
    function getUsdg() override external view returns (address){
        return usdg;
    }

    function initialize(
            address ,
            address ,
            address ,
            uint256 ,
            uint256 ,
            uint256 
        ) external override {
        _onlyGov();
        _validate(!slot0.isInitialized, 1);
        (bool suc,) = vaultManager.delegatecall(msg.data);
        require(suc);
    } 
    
    function setInManagerMode(bool _inManagerMode) external override {
        _onlyGov();
        slot1.inManagerMode = _inManagerMode;
    }
    function isManager(address _account) external view returns (bool){
        return addrObjs[_account].isManager;
    }

    function setManager(address _manager, bool _isManager) external override {
        _onlyGov();
        addrObjs[_manager].isManager = _isManager;
    }

    function setInPrivateLiquidationMode(bool _inPrivateLiquidationMode) external override {
        _onlyGov();
        slot1.inPrivateLiquidationMode = _inPrivateLiquidationMode;
    }
 
    function setLiquidator(address _liquidator, bool _isActive) external override {
        _onlyGov();
        addrObjs[_liquidator].isLiquidator = _isActive;
    }

    function setIsSwapEnabled(bool _isSwapEnabled) external override {
        _onlyGov();
        slot0.isSwapEnabled = _isSwapEnabled;
    } 

    function setIsLeverageEnabled(bool _isLeverageEnabled) external override {
        _onlyGov();
        slot0.isLeverageEnabled = _isLeverageEnabled;
    }

    function setMaxGasPrice(uint256 _maxGasPrice) external override {
        _onlyGov();
        slot1.maxGasPrice = uint32(_maxGasPrice);
    }

    function buyUSDG(address _token, address _receiver) external override nonReentrant returns (uint256) {
        _validateManager();
        _validate(addrObjs[_token].whitelistedTokens, 16);
        (bool suc,) = vaultManager.delegatecall(abi.encodeWithSignature(
            "buyUSDG(address,address,uint256)", 
            _token, 
            _receiver,
            _transferIn(_token)));
        require(suc);
    } 

    function sellUSDG(address _token, address ) external override nonReentrant returns (uint256) {
        _validateManager();
        _validate(addrObjs[_token].whitelistedTokens, 19);
        (bool success, bytes memory result) = vaultManager.delegatecall(msg.data);
        require(success);
        return abi.decode(result, (uint256));
    } 
    function swap(address  , address  , address  ) override external returns (uint256){ 
        (bool success, bytes memory result) = vaultManager.delegatecall(msg.data);
        require(success);
        return abi.decode(result, (uint256));
    }

    function setGov(address _gov) external {
        _onlyGov();
        gov = _gov;
    }

    function setPriceFeed(address _priceFeed) external override {
        _onlyGov();
        priceFeed = _priceFeed;
    }

    function setMaxLeverage(uint256 _maxLeverage) external override {
        _onlyGov();
        _validate(_maxLeverage > MIN_LEVERAGE, 2);
        slot0.maxLeverage = uint32(_maxLeverage);
    }
    function getBufferAmounts(address _token) override external view returns (uint256){
        return bufferAmounts[_token];
    }

    function setBufferAmount(address _token, uint256 _amount) external override {
        _onlyGov();
        bufferAmounts[_token] = _amount;
    } 

    // function minProfitBasisPoints(address _token) override external view returns (uint256){
    //     return addrObjs[_token].minProfitBasisPoints;
    // } 
     
    function getUsdgAmounts(address _token) override external view returns (uint256){
        return usdgAmounts[_token];
    }

    function getTokenBalances(address _token) override external view returns(uint256){
        return tokenBalances[_token];
    } 

    function getReservedAmounts(address _token) override external view returns (uint256){
        return reservedAmounts[_token];
    }
    function getPriceFeed() external override view returns (address){
        return priceFeed;
    }
    function getPoolAmounts(address _token) external override view returns (uint256){
        return poolAmounts[_token];
    }
    function getMaxUsdgAmounts(address _token) external override view returns (uint256){
        return maxUsdgAmounts[_token];
    }  
//----------------------------
    function addRouter(address _router) external {
        approvedRouters[msg.sender][_router] = true;
    }

    function removeRouter(address _router) external {
        approvedRouters[msg.sender][_router] = false;
    }
    function setFees(
        uint256 _taxBasisPoints,
        uint256 _stableTaxBasisPoints,
        uint256 _mintBurnFeeBasisPoints,
        uint256 _swapFeeBasisPoints,
        uint256 _stableSwapFeeBasisPoints,
        uint256 _marginFeeBasisPoints,
        uint256 _liquidationFeeUsd,
        uint256 ,
        bool 
    ) external override {
        _onlyGov();
        _validate(_taxBasisPoints <= MAX_FEE_BASIS_POINTS, 3);
        _validate(_stableTaxBasisPoints <= MAX_FEE_BASIS_POINTS, 4);
        _validate(_mintBurnFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 5);
        _validate(_swapFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 6);
        _validate(_stableSwapFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 7);
        _validate(_marginFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 8);
        _validate(_liquidationFeeUsd <= MAX_LIQUIDATION_FEE_USD, 9);
        (bool suc, ) = vaultManager.delegatecall(msg.data);
        require(suc, "swap error"); 
    }

    function setFundingRate(uint256 _fundingInterval, uint256 _fundingRateFactor, uint256 _stableFundingRateFactor) external override {
        _onlyGov();
        _validate(_fundingInterval >= MIN_FUNDING_RATE_INTERVAL, 10);
        _validate(_fundingRateFactor <= MAX_FUNDING_RATE_FACTOR, 11);
        _validate(_stableFundingRateFactor <= MAX_FUNDING_RATE_FACTOR, 12);

        DataTypes.Slot1 memory _slot1 = slot1;
        _slot1.fundingRateFactor = uint16(_fundingRateFactor);
        _slot1.stableFundingRateFactor = uint16(_stableFundingRateFactor);
        _slot1.fundingInterval = uint32(_fundingInterval);
        slot1 = _slot1;
    }

    function setTokenConfig(
        address _token,
        uint256 _tokenDecimals,
        uint256 _tokenWeight,
        uint256 _minProfitBps,
        uint256 _maxUsdgAmount,
        bool _isStable,
        bool _isShortable
    ) external override { 
        _onlyGov(); 
        (bool suc, ) = vaultManager.delegatecall(msg.data);
        require(suc, "swap error"); 
        
    } 

    function clearTokenConfig(address ) external {
        _onlyGov(); 
        (bool suc, ) = vaultManager.delegatecall(msg.data);
        require(suc, "swap error"); 
    } 
   
    function withdrawFees(address _token, address _receiver) external override returns (uint256) {
        _onlyGov();
        uint256 amount = addrObjs[_token].feeReserves;
        if(amount == 0) { return 0; }
        addrObjs[_token].feeReserves = 0;
        _transferOut(_token, amount, _receiver);
        return amount;
    }  

    function setUsdgAmount(address , uint256 ) external {
        _onlyGov();
        (bool suc,) = vaultManager.delegatecall(msg.data);
        require(suc);
    }    

    // the governance controlling this function should have a timelock
    function scheduleUpgradeVault(address _newVault, address _token, uint256 _amount) external {
        _onlyGov();
        DataTypes.UpgradeVaultParams memory _params = upgradeVaultParams;
        _params.newVault = _newVault;
        _params.token = _token;
        _params.amount = _amount;
        _params.endTime = block.timestamp + 7 days;
        upgradeVaultParams = _params;
    }

    function excuteUpgradeVault() public{
        DataTypes.UpgradeVaultParams memory _params = upgradeVaultParams;
        require(_params.newVault!=address(0) && address(this) != _params.newVault, "invalid address");
        require(block.timestamp >= _params.endTime, "not time yet");
        IERC20(_params.token).safeTransfer(_params.newVault, _params.amount);
    }

    // deposit into the pool without minting USDG tokens
    // useful in allowing the pool to become over-collaterised
    function directPoolDeposit(address _token) external override nonReentrant {
        _validate(addrObjs[_token].whitelistedTokens, 14);
        uint256 tokenAmount = _transferIn(_token); 
        _validate(tokenAmount > 0, 15);
        _increasePoolAmount(_token, tokenAmount);
        emit DirectPoolDeposit(_token, tokenAmount); 
    } 

    function _validateGasPrice() internal view {
        if (slot1.maxGasPrice == 0) { return; }
        _validate(tx.gasprice <= slot1.maxGasPrice, 55);
    }

    function getMaxPrice(address _token) override  public  view returns (uint256) {
        return IVaultPriceFeed(priceFeed).getPrice(_token, true, slot0.includeAmmPrice, slot1.useSwapPricing);
    } 

    function getMinPrice(address _token) override public  view returns (uint256) {
        return IVaultPriceFeed(priceFeed).getPrice(_token, false, slot0.includeAmmPrice, slot1.useSwapPricing);
    }
    function swapCallback(address _tokenIn, uint256  amountIn, address _tokenOut, uint256  amountOut) public{
        require(msg.sender == address(this));
        _increasePoolAmount(_tokenIn, amountIn);
        _decreasePoolAmount(_tokenOut, amountOut);
    }

    function errors(uint256 _i) internal pure returns (string memory str){
        if (_i == 0)
        {
            return "0";
        }
        uint256 j = _i;
        uint256 length;
        while (j != 0)
        {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        j = _i;
        while (j != 0)
        {
            bstr[--k] = bytes1(uint8(48 + j % 10));
            j /= 10;
        }
        str = string(bstr);
    }

    function _validate(bool _condition, uint256 _errorCode) internal pure {
        require(_condition, errors(_errorCode));
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _onlyGov() internal view {
        _validate(msg.sender == gov, 53);
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateManager() internal view {
        if (slot1.inManagerMode) { 
            _validate(addrObjs[msg.sender].isManager , 54);
        }
    }
    
    function _validatePosition(uint256 _size, uint256 _collateral) internal pure {
        if (_size == 0) {
            _validate(_collateral == 0, 39);
            return;
        }
        _validate(_size >= _collateral, 40);
    }

    function _validateRouter(address _account) internal view {
        if (msg.sender == _account) { return; }
        if (msg.sender == router) { return; }
        _validate(approvedRouters[_account][msg.sender], 41);
    }

    function _validateTokens(address _collateralToken, address _indexToken, bool _isLong) internal view {
        if (_isLong) {
            _validate(_collateralToken == _indexToken, 42);
            DataTypes.AddrObj memory _addrObj = addrObjs[_collateralToken];
            _validate(_addrObj.whitelistedTokens, 43);
            _validate(!_addrObj.stableTokens, 44);
        } else {
            DataTypes.AddrObj memory _collateralTokenObj = addrObjs[_collateralToken];
            _validate(_collateralTokenObj.whitelistedTokens, 45);
            _validate(_collateralTokenObj.stableTokens, 46);
            DataTypes.AddrObj memory _indexTokenObj = addrObjs[_indexToken];
            _validate(!_indexTokenObj.stableTokens, 47);
            _validate(_indexTokenObj.shortableTokens, 48);
        }
        
    }

    function increasePosition(address _account, address _collateralToken, address _indexToken, uint256 _sizeDelta, bool _isLong) external override nonReentrant {
        _validate(slot0.isLeverageEnabled, 28);
        _validateGasPrice();
        _validateRouter(_account);
        _validateTokens(_collateralToken, _indexToken, _isLong);
        updateCumulativeFundingRate(_collateralToken); 

        bytes32 key = GenericLogic.getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        DataTypes.Position storage position = positions[key];

        uint256 price = _isLong ? getMaxPrice(_indexToken) : getMinPrice(_indexToken);

        if (position.size == 0) {
            position.averagePrice = price;
        }

        if (position.size > 0 && _sizeDelta > 0) {
            position.averagePrice = getNextAveragePrice(_indexToken, position.size, position.averagePrice, _isLong, price, _sizeDelta, position.lastIncreasedTime);
        }

        uint256 fee = _collectMarginFees(_collateralToken, _sizeDelta, position.size, position.entryFundingRate);
        uint256 collateralDelta = _transferIn(_collateralToken);
        uint256 collateralDeltaUsd = tokenToUsdMin(_collateralToken, collateralDelta);

        position.collateral = position.collateral.add(collateralDeltaUsd);
        _validate(position.collateral >= fee, 29);

        position.collateral = position.collateral.sub(fee);
        position.entryFundingRate = fundingDatas[_collateralToken].cumulativeFundingRates;
        position.size = position.size.add(_sizeDelta);
        position.lastIncreasedTime = block.timestamp;

        _validate(position.size > 0, 30);
        _validatePosition(position.size, position.collateral);
        validateLiquidation(_account, _collateralToken, _indexToken, _isLong, true);

        // reserve tokens to pay profits on the position
        uint256 reserveDelta = usdToTokenMax(_collateralToken, _sizeDelta);
        position.reserveAmount = position.reserveAmount.add(reserveDelta);
        _increaseReservedAmount(_collateralToken, reserveDelta);

        if (_isLong) {
            // guaranteedUsd stores the sum of (position.size - position.collateral) for all positions
            // if a fee is charged on the collateral then guaranteedUsd should be increased by that fee amount
            // since (position.size - position.collateral) would have increased by `fee`
            _increaseGuaranteedUsd(_collateralToken, _sizeDelta.add(fee));
            _decreaseGuaranteedUsd(_collateralToken, collateralDeltaUsd);
            // treat the deposited collateral as part of the pool
            _increasePoolAmount(_collateralToken, collateralDelta);
            // fees need to be deducted from the pool since fees are deducted from position.collateral
            // and collateral is treated as part of the pool
            _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, fee));
        } else {
            if (globalShortSizes[_indexToken] == 0) {
                globalShortAveragePrices[_indexToken] = price;
            } else {
                globalShortAveragePrices[_indexToken] = getNextGlobalShortAveragePrice(_indexToken, price, _sizeDelta);
            }
            globalShortSizes[_indexToken] = globalShortSizes[_indexToken].add(_sizeDelta);
        }
    }

    // for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    function getNextAveragePrice(address _indexToken, uint256 _size, uint256 _averagePrice, 
                bool _isLong, uint256 _nextPrice, uint256 _sizeDelta, uint256 _lastIncreasedTime) public view returns (uint256) {
        (bool hasProfit, uint256 delta) = getDelta(_indexToken, _size, _averagePrice, _isLong, _lastIncreasedTime);
        uint256 nextSize = _size.add(_sizeDelta);
        uint256 divisor;
        if (_isLong) {
            divisor = hasProfit ? nextSize.add(delta) : nextSize.sub(delta);
        } else {
            divisor = hasProfit ? nextSize.sub(delta) : nextSize.add(delta);
        }
        return _nextPrice.mul(nextSize).div(divisor);
    }

    function decreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong, address _receiver) external override nonReentrant returns (uint256) {
        _validateGasPrice();
        _validateRouter(_account);
        return _decreasePosition(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver);
    }

    function _decreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong, address _receiver) private returns (uint256) {
       updateCumulativeFundingRate(_collateralToken);

        bytes32 key = GenericLogic.getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        DataTypes.Position storage position = positions[key];
        _validate(position.size > 0, 31);
        _validate(position.size >= _sizeDelta, 32);
        _validate(position.collateral >= _collateralDelta, 33);

        uint256 collateral = position.collateral;
        // scrop variables to avoid stack too deep errors
        {
        uint256 reserveDelta = position.reserveAmount.mul(_sizeDelta).div(position.size);
        position.reserveAmount = position.reserveAmount.sub(reserveDelta);
        _decreaseReservedAmount(_collateralToken, reserveDelta);
        }

        (uint256 usdOut, uint256 usdOutAfterFee) = _reduceCollateral(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong);

        if (position.size != _sizeDelta) {
            position.entryFundingRate = fundingDatas[_collateralToken].cumulativeFundingRates;
            position.size = position.size.sub(_sizeDelta);

            _validatePosition(position.size, position.collateral);
            validateLiquidation(_account, _collateralToken, _indexToken, _isLong, true);

            if (_isLong) {
                _increaseGuaranteedUsd(_collateralToken, collateral.sub(position.collateral));
                _decreaseGuaranteedUsd(_collateralToken, _sizeDelta);
            }

            uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
            emit DecreasePosition(key, _account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, price, usdOut.sub(usdOutAfterFee));
            emit UpdatePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl);
        } else {
            if (_isLong) {
                _increaseGuaranteedUsd(_collateralToken, collateral);
                _decreaseGuaranteedUsd(_collateralToken, _sizeDelta);
            }

            uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
            emit DecreasePosition(key, _account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, price, usdOut.sub(usdOutAfterFee));
            emit ClosePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl);

            delete positions[key];
        }

        if (!_isLong) {
            _decreaseGlobalShortSize(_indexToken, _sizeDelta);
        }

        if (usdOut > 0) {
            if (_isLong) {
                _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, usdOut));
            }
            uint256 amountOutAfterFees = usdToTokenMin(_collateralToken, usdOutAfterFee);
            _transferOut(_collateralToken, amountOutAfterFees, _receiver);
            return amountOutAfterFees;
        }

        return 0;
    }
    
    function _reduceCollateral(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong) private returns (uint256, uint256) {
        bytes32 key =GenericLogic. getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        DataTypes.Position storage position = positions[key];

        uint256 fee = _collectMarginFees(_collateralToken, _sizeDelta, position.size, position.entryFundingRate);
        bool hasProfit;
        uint256 adjustedDelta;

        // scope variables to avoid stack too deep errors
        {
        (bool _hasProfit, uint256 delta) = getDelta(_indexToken, position.size, position.averagePrice, _isLong, position.lastIncreasedTime);
        hasProfit = _hasProfit;
        // get the proportional change in pnl
        adjustedDelta = _sizeDelta.mul(delta).div(position.size);
        }

        uint256 usdOut;
        // transfer profits out
        if (hasProfit && adjustedDelta > 0) {
            usdOut = adjustedDelta;
            position.realisedPnl = position.realisedPnl + int256(adjustedDelta);

            // pay out realised profits from the pool amount for short positions
            if (!_isLong) {
                uint256 tokenAmount = usdToTokenMin(_collateralToken, adjustedDelta);
                _decreasePoolAmount(_collateralToken, tokenAmount);
            }
        }

        if (!hasProfit && adjustedDelta > 0) {
            position.collateral = position.collateral.sub(adjustedDelta);

            // transfer realised losses to the pool for short positions
            // realised losses for long positions are not transferred here as
            // _increasePoolAmount was already called in increasePosition for longs
            if (!_isLong) {
                uint256 tokenAmount = usdToTokenMin(_collateralToken, adjustedDelta);
                _increasePoolAmount(_collateralToken, tokenAmount);
            }

            position.realisedPnl = position.realisedPnl - int256(adjustedDelta);
        }

        // reduce the position's collateral by _collateralDelta
        // transfer _collateralDelta out
        if (_collateralDelta > 0) {
            usdOut = usdOut.add(_collateralDelta);
            position.collateral = position.collateral.sub(_collateralDelta);
        }

        // if the position will be closed, then transfer the remaining collateral out
        if (position.size == _sizeDelta) {
            usdOut = usdOut.add(position.collateral);
            position.collateral = 0;
        }

        // if the usdOut is more than the fee then deduct the fee from the usdOut directly
        // else deduct the fee from the position's collateral
        uint256 usdOutAfterFee = usdOut;
        if (usdOut > fee) {
            usdOutAfterFee = usdOut.sub(fee);
        } else {
            position.collateral = position.collateral.sub(fee);
            if (_isLong) {
                uint256 feeTokens = usdToTokenMin(_collateralToken, fee);
                _decreasePoolAmount(_collateralToken, feeTokens);
            }
        }

        emit UpdatePnl(key, hasProfit, adjustedDelta);

        return (usdOut, usdOutAfterFee);
    }

    function getPositionDelta(address _account, address _collateralToken, address _indexToken, bool _isLong) internal view returns (bool, uint256) {
        bytes32 key = GenericLogic.getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        DataTypes.Position memory position = positions[key];
        return getDelta(_indexToken, position.size, position.averagePrice, _isLong, position.lastIncreasedTime);
    }

    function liquidatePosition(address _account, address _collateralToken, 
                                address _indexToken, bool _isLong, address _feeReceiver) external nonReentrant {
        if (slot1.inPrivateLiquidationMode) {
            _validate(addrObjs[msg.sender].isLiquidator, 34);
        }

        // set includeAmmPrice to false prevent manipulated liquidations
        slot0.includeAmmPrice = false;

        updateCumulativeFundingRate(_collateralToken);

        bytes32 key = GenericLogic.getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        DataTypes.Position memory position = positions[key];
        _validate(position.size > 0, 35);

        (uint256 liquidationState, uint256 marginFees) = validateLiquidation(_account, _collateralToken, _indexToken, _isLong, false);
        _validate(liquidationState != 0, 36);
        if (liquidationState == 2) {
            // max leverage exceeded but there is collateral remaining after deducting losses so decreasePosition instead
            _decreasePosition(_account, _collateralToken, _indexToken, 0, position.size, _isLong, _account);
            return;
        }

        uint256 feeTokens = usdToTokenMin(_collateralToken, marginFees);
        addrObjs[_collateralToken].feeReserves = uint256(addrObjs[_collateralToken].feeReserves).add(feeTokens).toUInt128();
        emit CollectMarginFees(_collateralToken, marginFees, feeTokens);

        _decreaseReservedAmount(_collateralToken, position.reserveAmount);
        if (_isLong) {
            _decreaseGuaranteedUsd(_collateralToken, position.size.sub(position.collateral));
            _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, marginFees));
        }

        uint256 markPrice = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
        emit LiquidatePosition(key, _account, _collateralToken, _indexToken, _isLong, position.size, position.collateral, position.reserveAmount, position.realisedPnl, markPrice);

        if (!_isLong && marginFees < position.collateral) {
            uint256 remainingCollateral = position.collateral.sub(marginFees);
            _increasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, remainingCollateral));
        }

        if (!_isLong) {
            _decreaseGlobalShortSize(_indexToken, position.size);
        }

        delete positions[key];

        // pay the fee receiver using the pool, we assume that in general the liquidated amount should be sufficient to cover
        // the liquidation fees
        _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, slot0.liquidationFeeUsd));
        _transferOut(_collateralToken, usdToTokenMin(_collateralToken, slot0.liquidationFeeUsd), _feeReceiver);

        slot0.includeAmmPrice = true;
    }

    // validateLiquidation returns (state, fees)
    function validateLiquidation(address _account, address _collateralToken, address _indexToken, bool _isLong, bool _raise) public view returns (uint256, uint256) {
        bytes32 key = GenericLogic.getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        DataTypes.Position memory position = positions[key];

        (bool hasProfit, uint256 delta) = getDelta(_indexToken, position.size, position.averagePrice, _isLong, position.lastIncreasedTime);
        uint256 marginFees = getFundingFee(_collateralToken, position.size, position.entryFundingRate);
        marginFees = marginFees.add(GenericLogic. getPositionFee(position.size,
                                                            BASIS_POINTS_DIVISOR,
                                                            slot1.marginFeeBasisPoints  ));

        if (!hasProfit && position.collateral < delta) {
            if (_raise) { revert("Vault: losses exceed collateral"); }
            return (1, marginFees);
        }

        uint256 remainingCollateral = position.collateral;
        if (!hasProfit) {
            remainingCollateral = position.collateral.sub(delta);
        }

        if (remainingCollateral < marginFees) {
            if (_raise) { revert("Vault: fees exceed collateral"); }
            // cap the fees to the remainingCollateral
            return (1, remainingCollateral);
        }

        if (remainingCollateral < marginFees.add(slot0.liquidationFeeUsd)) {
            if (_raise) { revert("Vault: liquidation fees exceed collateral"); }
            return (1, marginFees);
        }

        if (remainingCollateral.mul(slot0.maxLeverage) < position.size.mul(BASIS_POINTS_DIVISOR)) {
            if (_raise) { revert("Vault: maxLeverage exceeded"); }
            return (2, marginFees);
        }

        return (0, marginFees);
    }

    function getRedemptionCollateral(address _token) public view returns (uint256) {
        if (addrObjs[_token].stableTokens) {
            return poolAmounts[_token];
        }
        uint256 collateral = usdToTokenMin(_token, guaranteedUsd[_token]);
        return collateral.add(poolAmounts[_token]).sub(reservedAmounts[_token]);
    }

    function getRedemptionCollateralUsd(address _token) public view returns (uint256) {
        return tokenToUsdMin(_token, getRedemptionCollateral(_token));
    } 

    function usdToTokenMax(address _token, uint256 _usdAmount) public view returns (uint256) {
        if (_usdAmount == 0) { return 0; }
        return usdToToken(_token, _usdAmount, getMinPrice(_token));
    }

    function usdToTokenMin(address _token, uint256 _usdAmount) public view returns (uint256) {
        if (_usdAmount == 0) { return 0; }
        return usdToToken(_token, _usdAmount, getMaxPrice(_token));
    }

    function usdToToken(address _token, uint256 _usdAmount, uint256 _price) public view returns (uint256) {
        if (_usdAmount == 0) { return 0; }
        uint256 decimals = addrObjs[_token]. tokenDecimals;
        return _usdAmount.mul(10 ** decimals).div(_price);
    }

    function getPosition(address _account, address _collateralToken, address _indexToken, bool _isLong) public override view returns (uint256, uint256, uint256, uint256, uint256, uint256, bool, uint256) {
        bytes32 key = GenericLogic.getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        DataTypes.Position memory position = positions[key];
        uint256 realisedPnl = position.realisedPnl > 0 ? uint256(position.realisedPnl) : uint256(-position.realisedPnl);
        return (
            position.size, // 0
            position.collateral, // 1
            position.averagePrice, // 2
            position.entryFundingRate, // 3
            position.reserveAmount, // 4
            realisedPnl, // 5
            position.realisedPnl >= 0, // 6
            position.lastIncreasedTime // 7
        );
    } 

    function updateCumulativeFundingRate(address _token) private { 
        fundingDatas[_token].updateCumulativeFundingRate(slot1.fundingInterval,
                                                        poolAmounts[_token],
                                                        slot1.stableFundingRateFactor,
                                                        slot1.fundingRateFactor,
                                                        reservedAmounts[_token],
                                                        addrObjs[_token].stableTokens); 
        emit UpdateFundingRate(_token, fundingDatas[_token].cumulativeFundingRates);
    }

    function getNextFundingRate(address _token) public override view returns (uint256) {
        uint _localFundingInterval = slot1.fundingInterval;
        uint _lastFundingTimes = fundingDatas[_token].lastFundingTimes; 

        if (_lastFundingTimes.add( _localFundingInterval) > block.timestamp) { return 0; }

        uint256 intervals = block.timestamp.sub(_lastFundingTimes).div(_localFundingInterval);
        uint256 poolAmount = poolAmounts[_token];
        if (poolAmount == 0) { return 0; }
        DataTypes.Slot1 memory _slot1 = slot1;
        uint256 _fundingRateFactor = addrObjs[_token].stableTokens ? _slot1.stableFundingRateFactor : _slot1.fundingRateFactor;
        return _fundingRateFactor.mul(reservedAmounts[_token]).mul(intervals).div(poolAmount);
    }

    function getUtilisation(address _token) public view returns (uint256) {
        uint256 poolAmount = poolAmounts[_token];
        if (poolAmount == 0) { return 0; }

        return reservedAmounts[_token].mul(FUNDING_RATE_PRECISION).div(poolAmount);
    }

    function getPositionLeverage(address _account, address _collateralToken, address _indexToken, bool _isLong) public view returns (uint256) {
        bytes32 key = GenericLogic.getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        DataTypes.Position memory position = positions[key];
        _validate(position.collateral > 0, 37);
        return position.size.mul(BASIS_POINTS_DIVISOR).div(position.collateral);
    }
 
    function getDelta(address _indexToken, 
                    uint256 _size, 
                    uint256 _averagePrice, 
                    bool _isLong, 
                    uint256 _lastIncreasedTime) override public view returns (bool, uint256) {
        _validate(_averagePrice > 0, 38);
    
        uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
        uint256 priceDelta = _averagePrice > price ? _averagePrice.sub(price) : price.sub(_averagePrice);
        uint256 delta = _size.mul(priceDelta).div(_averagePrice);

        bool hasProfit;

        if (_isLong) {
            hasProfit = price > _averagePrice;
        } else {
            hasProfit = _averagePrice > price;
        }

        // if the minProfitTime has passed then there will be no min profit threshold
        // the min profit threshold helps to prevent front-running issues
        uint256 minBps = block.timestamp > _lastIncreasedTime.add(uint256(slot1.minProfitTime)) ? 0 : uint256(addrObjs[_indexToken].minProfitBasisPoints);
        if (hasProfit && delta.mul(BASIS_POINTS_DIVISOR) <= _size.mul(minBps)) {
            delta = 0;
        }

        return (hasProfit, delta);
    }

    // for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    function getNextGlobalShortAveragePrice(address _indexToken, uint256 _nextPrice, uint256 _sizeDelta) public view returns (uint256) {
        uint256 size = globalShortSizes[_indexToken];
        uint256 averagePrice = globalShortAveragePrices[_indexToken];
        uint256 priceDelta = averagePrice > _nextPrice ? averagePrice.sub(_nextPrice) : _nextPrice.sub(averagePrice);
        uint256 delta = size.mul(priceDelta).div(averagePrice);
        bool hasProfit = averagePrice > _nextPrice;

        uint256 nextSize = size.add(_sizeDelta);
        uint256 divisor = hasProfit ? nextSize.sub(delta) : nextSize.add(delta);

        return _nextPrice.mul(nextSize).div(divisor);
    }

    function getGlobalShortDelta(address _token) public view returns (bool, uint256) {
        uint256 size = globalShortSizes[_token];
        if (size == 0) { return (false, 0); }

        uint256 nextPrice = getMaxPrice(_token);
        uint256 averagePrice = globalShortAveragePrices[_token];
        uint256 priceDelta = averagePrice > nextPrice ? averagePrice.sub(nextPrice) : nextPrice.sub(averagePrice);
        uint256 delta = size.mul(priceDelta).div(averagePrice);
        bool hasProfit = averagePrice > nextPrice;

        return (hasProfit, delta);
    }
    
    //---------------------------------------------
    //---------------------------------------------
    // 私有方法
    //--------------------------------------------- 
    
    function getFundingFee(address _token, uint256 _size, uint256 _entryFundingRate) internal view returns (uint256) {
        if (_size == 0) { return 0; }

        uint256 fundingRate = fundingDatas[_token].cumulativeFundingRates.sub(_entryFundingRate);
        if (fundingRate == 0) { return 0; }

        return _size.mul(fundingRate).div(FUNDING_RATE_PRECISION);
    }

    function _collectMarginFees(address _token, uint256 _sizeDelta, uint256 _size, uint256 _entryFundingRate) private returns (uint256) {
        uint256 feeUsd = GenericLogic. getPositionFee(_sizeDelta,
                                                    BASIS_POINTS_DIVISOR,
                                                    slot1.marginFeeBasisPoints  );

        uint256 fundingFee = getFundingFee(_token, _size, _entryFundingRate);
        feeUsd = feeUsd.add(fundingFee);

        uint256 feeTokens = usdToTokenMin(_token, feeUsd);
        addrObjs[_token].feeReserves = addrObjs[_token].feeReserves.add(uint128(feeTokens));
        emit CollectMarginFees(_token, feeUsd, feeTokens);
        return feeUsd;
    } 

    // function _decreasePoolAmount(address _token, uint256 _amount) private {
    //     poolAmounts[_token] = poolAmounts[_token].sub(_amount, "Vault: poolAmount exceeded");
    //     _validate(reservedAmounts[_token] <= poolAmounts[_token], 50);
    //     emit DecreasePoolAmount(_token, _amount);
    // }  
   

    function _increaseReservedAmount(address _token, uint256 _amount) private {
        reservedAmounts[_token] = reservedAmounts[_token].add(_amount);
        _validate(reservedAmounts[_token] <= poolAmounts[_token], 52);
        emit IncreaseReservedAmount(_token, _amount);
    }

    function _decreaseReservedAmount(address _token, uint256 _amount) private {
        reservedAmounts[_token] = reservedAmounts[_token].sub(_amount, "Vault: insufficient reserve");
        emit DecreaseReservedAmount(_token, _amount);
    }

    function _increaseGuaranteedUsd(address _token, uint256 _usdAmount) private {
        guaranteedUsd[_token] = guaranteedUsd[_token].add(_usdAmount);
        emit IncreaseGuaranteedUsd(_token, _usdAmount);
    }

    function getLastFundingTimes(address _token)override external view returns (uint256){
        return fundingDatas[_token].lastFundingTimes;
    }

    function getAllWhitelistedTokens(uint256 _idx) override external view returns (address){
       return allWhitelistedTokens[_idx];
}


    function getGlobalShortSizes(address _token) override external view returns (uint256){
       return globalShortSizes[_token];
    }

    function getGlobalShortAveragePrices(address _token) override external view returns (uint256){
       return globalShortAveragePrices[_token];
    }

    function getGuaranteedUsd(address _token) view override public returns (uint256){
        return guaranteedUsd[_token];
    }

    function getAddrObj(address _token)  override external view returns(DataTypes.AddrObj memory) {
        return addrObjs[_token];
    } 

    function _decreaseGuaranteedUsd(address _token, uint256 _usdAmount) private {
        guaranteedUsd[_token] = guaranteedUsd[_token].sub(_usdAmount);
        emit DecreaseGuaranteedUsd(_token, _usdAmount);
    }

    function _decreaseGlobalShortSize(address _token, uint256 _amount) private {
        uint256 size = globalShortSizes[_token];
        if (_amount > size) {
          globalShortSizes[_token] = 0;
          return;
        }

        globalShortSizes[_token] = size.sub(_amount);
    }

    function getRedemptionAmount(address , uint256 ) public override   returns (uint256) {
        (bool success, bytes memory result) = vaultManager.delegatecall(msg.data);
        require(success);
        return abi.decode(result, (uint256));
    } 

    function getCumulativeFundingRates(address _token) override external view returns (uint256){
       return fundingDatas[_token].cumulativeFundingRates;
    }
    function getApprovedRouters(address _account, address _router) override external view returns (bool){
        return approvedRouters[_account][_router];
    } 
   


}
