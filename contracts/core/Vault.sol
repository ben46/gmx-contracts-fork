// SPDX-License-Identifier: MIT

pragma solidity ^0.8.12;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../tokens/interfaces/IUSDG.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IVaultManager.sol";
import "./interfaces/IVaultPriceFeed.sol";
import "../libraries/math/SafeCast.sol";
import "./VaultStorage.sol";
import "./logic/TokenLogic.sol";
import "./logic/GenericLogic.sol";
import "./ERC1967.sol";

contract Vault is ReentrancyGuard,  VaultStorage, IVault, ERC1967 {
    using SafeMath for uint256;  
    using SafeCast for uint256;  
    using SafeMath128 for uint128;
    using SafeERC20 for IERC20;
    using TokenLogic for DataTypes.FundingData; 

    // once the parameters are verified to be working correctly,
    // gov should be set to a timelock contract or a governance contract
    constructor(address _vaultManager)  {
        gov = msg.sender;  
                _setImplementation(_vaultManager);

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
        (bool suc,) = _getImplementation().delegatecall(msg.data);
        require(suc);
    } 
    /*****************************************
    * usdg相关
    ****************************************************** */
    function buyUSDG(address _token, address _receiver) external override nonReentrant returns (uint256) {
        _validateManager();
        _validate(addrObjs[_token].whitelistedTokens, 16);
        (bool suc,) = _getImplementation().delegatecall(abi.encodeWithSignature(
            "buyUSDG(address,address,uint256)", 
            _token, 
            _receiver,
            _transferIn(_token)));
        require(suc);
    } 

    function sellUSDG(address _token, address ) external override nonReentrant returns (uint256) {
        _validateManager();
        _validate(addrObjs[_token].whitelistedTokens, 19);
        (bool success, bytes memory result) = _getImplementation().delegatecall(msg.data);
        require(success);
        return abi.decode(result, (uint256));
    } 
    function swap(address  , address  , address  ) override external returns (uint256){ 
        (bool success, bytes memory result) = _getImplementation().delegatecall(msg.data);
        require(success);
        return abi.decode(result, (uint256));
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
        (bool suc,) = _getImplementation().delegatecall(msg.data);
        require(suc);
    }    
  
    function upgradeVault(address _newVault, address _token, uint256 _amount) public{
        // 让timelock去部署
        _onlyGov(); 
        require(_newVault!=address(0) && address(this) != _newVault, "invalid address");
        IERC20(_token).safeTransfer(_newVault, _amount);
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
  
    function swapCallback(address _tokenIn, uint256  amountIn, address _tokenOut, uint256  amountOut) public{
        require(msg.sender == address(this));
        _increasePoolAmount(_tokenIn, amountIn);
        _decreasePoolAmount(_tokenOut, amountOut);
    }

    function increasePosition(address _account, address _collateralToken, address _indexToken, uint256 _sizeDelta, bool _isLong) external override nonReentrant {
        _validate(slot0.isLeverageEnabled, 28); // 临时暂停杠杆交易?
        _validateGasPrice(); // 防止三明治攻击
        _validateRouter(_account); // 用户只能通过路由调用, 不可自己调用
        _validateTokens(_collateralToken, _indexToken, _isLong); // 稳定币只能做空, 山寨币只能做多
        // 更新全局资金费率
        updateCumulativeFundingRate(_collateralToken); 

        bytes32 key = GenericLogic.getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        DataTypes.Position storage position = positions[key];

        uint256 price = _isLong ? getMaxPrice(_indexToken) : getMinPrice(_indexToken);
        if(_isLong){
            _maxPrice[_indexToken] = price;
        } else {
            _minPrice[_indexToken] = price;
        }
        if (position.size == 0) {
            position.averagePrice = price;
        } else if (position.size > 0 && _sizeDelta > 0) {
            position.averagePrice = getNextAveragePrice(_indexToken, position.size, position.averagePrice, _isLong, price, _sizeDelta, position.lastIncreasedTime);
        }
        _minPrice[_collateralToken] = getMinPrice(_collateralToken);

        // 收取 手续费+资金费
        (uint256 fee, uint256 feeTokens) = _collectMarginFees(_collateralToken, _sizeDelta, position.size, position.entryFundingRate);

        uint256 collateralDelta = _transferIn(_collateralToken);
        // 计算转入的抵押物价值多少usd
        uint256 collateralDeltaUsd = _tokenToUsdMin(_collateralToken, collateralDelta);
        {
            // 给该仓位加上转入的抵押物
            uint256 _collateral = position.collateral.add(collateralDeltaUsd);
            _validate(_collateral >= fee, 29); 
            _collateral =_collateral.sub(fee);        // 抵押物要扣除fee
            position.collateral = _collateral; // 用户的担保
        }

        position.entryFundingRate = fundingDatas[_collateralToken].cumulativeFundingRates; // 资金费已收, 更新
        position.size = position.size.add(_sizeDelta); // 用户的头寸
        position.lastIncreasedTime = block.timestamp; // 刚加的头寸不能马上被清算?

        _validate(position.size > 0, 30);
        _validatePosition(position.size, position.collateral);
        validateLiquidation(_account, _collateralToken, _indexToken, _isLong, true);

        // reserve tokens to pay profits on the position
        uint256 reserveDelta = usdToTokenMax(_collateralToken, _sizeDelta);
        position.reserveAmount = position.reserveAmount.add(reserveDelta); // 用户总头寸?
        _increaseReservedAmount(_collateralToken, reserveDelta); // 全局头寸?

        if (_isLong) {
            // guaranteedUsd stores the sum of (position.size - position.collateral) for all positions
            // if a fee is charged on the collateral then guaranteedUsd should be increased by that fee amount
            // since (position.size - position.collateral) would have increased by `fee`
            /**  guaranteedUsd存储所有头寸的（position.size-position.抵押品）总和，
            如果抵押品收取费用，那么guaranteedUsd应增加该费用金额，
            因为（position.size-position.抵押物）将增加“费用”`*/
            // _increaseGuaranteedUsd(_collateralToken, _sizeDelta.add(fee)); // 增加全局的担保usd
            // _decreaseGuaranteedUsd(_collateralToken, collateralDeltaUsd); // 借给用户了10倍杠杆
            {
                uint256 _tmp = guaranteedUsd[_collateralToken];
                _tmp = _tmp.add(_sizeDelta);
                _tmp = _tmp.add(fee);
                _tmp = _tmp.sub(collateralDeltaUsd);
                guaranteedUsd[_collateralToken] =_tmp;
            }
            emit IncreaseGuaranteedUsd(_collateralToken, _sizeDelta.add(fee));
            emit IncreaseGuaranteedUsd(_collateralToken, collateralDeltaUsd);
            // treat the deposited collateral as part of the pool
            // 5. 散户拿着1eth, 开10倍多单, 可以理解为: 卖给vault, 因此poolamount[weth] += 1
            _increasePoolAmount(_collateralToken, collateralDelta); // 用户上交的保证金
            // fees need to be deducted from the pool since fees are deducted from position.collateral
            // and collateral is treated as part of the pool
            //费用需要从池中扣除，因为费用是从头寸中扣除的。抵押品和抵押品被视为池的一部分 
            // 6. vault中的LP借钱给散户27000
            _decreasePoolAmount(_collateralToken, feeTokens);
        } else {
            // if (globalShortSizes[_indexToken] == 0) {
            //     globalShortAveragePrices[_indexToken] = price;
            // } else {
            //     globalShortAveragePrices[_indexToken] = getNextGlobalShortAveragePrice(_indexToken, price, _sizeDelta);
            // }
            // // 全局做空的仓位
            // globalShortSizes[_indexToken] = globalShortSizes[_indexToken].add(_sizeDelta);
        }
        
        if (_maxPrice[_indexToken] > 0) {
            _maxPrice[_indexToken] =0;
        }  
        if (_minPrice[_indexToken] > 0) {
            _minPrice[_indexToken] =0;
        }
        if (_maxPrice[_collateralToken] > 0) {
            _maxPrice[_collateralToken] =0;
        }
        if (_minPrice[_collateralToken] > 0) {
            _minPrice[_collateralToken] =0;
        }
    } 

    function decreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong, address _receiver) external override nonReentrant returns (uint256) {
        _validateGasPrice(); // 防止三明治攻击
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
        // 2.
        _decreaseReservedAmount(_collateralToken, reserveDelta);
        }

        // 5.
        (uint256 usdOut, uint256 usdOutAfterFee) = _reduceCollateral(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong);

        if (position.size != _sizeDelta) {
            position.entryFundingRate = fundingDatas[_collateralToken].cumulativeFundingRates;
            position.size = position.size.sub(_sizeDelta);

            _validatePosition(position.size, position.collateral);
            validateLiquidation(_account, _collateralToken, _indexToken, _isLong, true);

            if (_isLong) {
                // 3.
                _increaseGuaranteedUsd(_collateralToken, collateral.sub(position.collateral));
                _decreaseGuaranteedUsd(_collateralToken, _sizeDelta);
            }

            uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
            emit DecreasePosition(key, _account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, price, usdOut.sub(usdOutAfterFee));
            emit UpdatePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl);
        } else {
            if (_isLong) {
                //3.
                _increaseGuaranteedUsd(_collateralToken, collateral);
                _decreaseGuaranteedUsd(_collateralToken, _sizeDelta);
            }

            uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
            emit DecreasePosition(key, _account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, price, usdOut.sub(usdOutAfterFee));
            emit ClosePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl);

            delete positions[key];
        }

        if (!_isLong) {
            //4.
            _decreaseGlobalShortSize(_indexToken, _sizeDelta);
        }

        if (usdOut > 0) {
            if (_isLong) {
                //1.
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

        (uint256 fee,) = _collectMarginFees(_collateralToken, _sizeDelta, position.size, position.entryFundingRate);
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
                _decreasePoolAmount(_collateralToken, tokenAmount);//
            }
        }

        if (!hasProfit && adjustedDelta > 0) {
            // 亏钱了
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
            // 保证金
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
        //1. 手续费
        addrObjs[_collateralToken].feeReserves = uint256(addrObjs[_collateralToken].feeReserves).add(feeTokens).toUInt128();
        emit CollectMarginFees(_collateralToken, marginFees, feeTokens);

        //2. 用户用借来的钱购买的仓位, 要减少
        _decreaseReservedAmount(_collateralToken, position.reserveAmount);
        if (_isLong) {
            //3. 借给散户的债务, 要清算
            _decreaseGuaranteedUsd(_collateralToken, position.size.sub(position.collateral));
            //4. 用户池子里的担保物 
            _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, marginFees));
        }

        uint256 markPrice = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
        emit LiquidatePosition(key, _account, _collateralToken, _indexToken, _isLong, position.size, position.collateral, position.reserveAmount, position.realisedPnl, markPrice);

        if (!_isLong && marginFees < position.collateral) {
            uint256 remainingCollateral = position.collateral.sub(marginFees);
            //5.用户清算完之后,多余的还给池子(可能后续被用户提走?)
            _increasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, remainingCollateral));
        }

        if (!_isLong) {
            // 6. 减少全局空单仓位
            _decreaseGlobalShortSize(_indexToken, position.size);
        }

        delete positions[key];

        // pay the fee receiver using the pool, we assume that in general the liquidated amount should be sufficient to cover
        // the liquidation fees
        //7. 池子里扣掉清算费
        _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, slot0.liquidationFeeUsd));
        //8. 清算费转给清算人
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

    function updateCumulativeFundingRate(address _token) private { 
        fundingDatas[_token].updateCumulativeFundingRate(slot1.fundingInterval,
                                                        poolAmounts[_token],
                                                        slot1.stableFundingRateFactor,
                                                        slot1.fundingRateFactor,
                                                        reservedAmounts[_token], // 计算资金利用率, 从而得出资金费
                                                        addrObjs[_token].stableTokens,
                                                        _token); 
    }
  /*********************************************************
  工具方法
   *******************************************************/
    function getPositionDelta(address _account, address _collateralToken, address _indexToken, bool _isLong) internal view returns (bool, uint256) {
        bytes32 key = GenericLogic.getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        DataTypes.Position memory position = positions[key];
        return getDelta(_indexToken, position.size, position.averagePrice, _isLong, position.lastIncreasedTime);
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
     function getMaxPrice(address _token) override  public  view returns (uint256) {
         if(_maxPrice[_token] > 0) {
            return _maxPrice[_token];
        }
        return IVaultPriceFeed(priceFeed).getPrice(_token, true, slot0.includeAmmPrice, slot1.useSwapPricing);
    } 

    function getMinPrice(address _token) override public  view returns (uint256) {
         if(_minPrice[_token] > 0) {
            return _minPrice[_token];
        } 
        return IVaultPriceFeed(priceFeed).getPrice(_token, false, slot0.includeAmmPrice, slot1.useSwapPricing);
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
     /*********************************************************
  只读方法
   *******************************************************/
   // 可赎回的抵押?
    function getRedemptionCollateral(address _token) public view returns (uint256) {
        if (addrObjs[_token].stableTokens) {
            return poolAmounts[_token];
        }
        uint256 collateral = usdToTokenMin(_token, guaranteedUsd[_token]);
        // ? + 池子内的总token - 被用户借走的
        return collateral.add(poolAmounts[_token]).sub(reservedAmounts[_token]);
    }

    function getRedemptionCollateralUsd(address _token) public view returns (uint256) {
        return _tokenToUsdMin(_token, getRedemptionCollateral(_token));
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
        // 用户借走的 * 精度 / 池子所有token
        return reservedAmounts[_token].mul(FUNDING_RATE_PRECISION).div(poolAmount);
    }

    function allWhitelistedTokensLength() external override view returns (uint256) {
        return allWhitelistedTokens.length;
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

    /**
    手续费  + 资金费
    */
    function _collectMarginFees(address _token, uint256 _sizeDelta, uint256 _size, uint256 _entryFundingRate) private returns (uint256,uint256) {
        // usd计价的fee是多少
        // 手续费
        uint256 feeUsd = GenericLogic. getPositionFee(_sizeDelta,
                                                    BASIS_POINTS_DIVISOR,
                                                    slot1.marginFeeBasisPoints  );

        // 资金费
        uint256 fundingFee = getFundingFee(_token, _size, _entryFundingRate);
        feeUsd = feeUsd.add(fundingFee); // 手续费 + 资金费

        // 换算
        uint256 feeTokens = usdToTokenMin(_token, feeUsd);
        addrObjs[_token].feeReserves = addrObjs[_token].feeReserves.add(uint128(feeTokens));
        emit CollectMarginFees(_token, feeUsd, feeTokens);
        return (feeUsd,feeTokens);
    } 
   
    function _increaseReservedAmount(address _token, uint256 _amount) private {
        reservedAmounts[_token] = reservedAmounts[_token].add(_amount);
        _validate(reservedAmounts[_token] <= poolAmounts[_token], 52);//新开仓位的最大开仓限制
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

    //---------------------------------------------
    //---------------------------------------------
    // getter方法
    //--------------------------------------------- 
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

    function getRedemptionAmount(address , uint256 ) public override   returns (uint256) {
        (bool success, bytes memory result) = _getImplementation().delegatecall(msg.data);
        require(success);
        return abi.decode(result, (uint256));
    } 

    function getCumulativeFundingRates(address _token) override external view returns (uint256){
       return fundingDatas[_token].cumulativeFundingRates;
    }
    function getApprovedRouters(address _account, address _router) override external view returns (bool){
        return approvedRouters[_account][_router];
    } 

    function getUsdg() override external view returns (address){
        return usdg;
    }    function isManager(address _account) external view returns (bool){
        return addrObjs[_account].isManager;
    }  
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
     /*****************************************
    * setters
    ****************************************************** */
    function setInManagerMode(bool _inManagerMode) external override {
        _onlyGov();
        slot1.inManagerMode = _inManagerMode;
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
        // 2*10**10
        _onlyGov();
        slot1.maxGasPrice = uint32(_maxGasPrice);
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
        (bool suc, ) = _getImplementation().delegatecall(msg.data);
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
        address ,
        uint256 ,
        uint256 ,
        uint256 ,
        uint256 ,
        bool ,
        bool 
    ) external override { 
        _onlyGov(); 
        (bool suc, ) = _getImplementation().delegatecall(msg.data);
        require(suc, "swap error"); 
        
    } 

    function clearTokenConfig(address ) external {
        _onlyGov(); 
        (bool suc, ) = _getImplementation().delegatecall(msg.data);
        require(suc, "swap error"); 
    } 
   
/*********************************************
* 验证方法
****************************************************************************** */

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
            _validate(addrObjs[_collateralToken].whitelistedTokens, 43);
            _validate(!addrObjs[_collateralToken].stableTokens, 44); // 不能做多稳定币, 只能做多山寨币
        } else {
            _validate(addrObjs[_collateralToken].whitelistedTokens, 45);
            _validate(addrObjs[_collateralToken].stableTokens, 46);// 只能做空稳定币, 不能做空山寨币
            //-------------------------
            _validate(!addrObjs[_indexToken].stableTokens, 47);
            _validate(addrObjs[_indexToken].shortableTokens, 48);
        }
    }
    
    function _validateGasPrice() internal view {
        // 为什么要限制最大gas? 防止三明治攻击?
        if (slot1.maxGasPrice == 0) { return; }
        _validate(tx.gasprice <= slot1.maxGasPrice, 55);
    }
}
