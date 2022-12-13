// SPDX-License-Identifier: MIT

pragma solidity ^0.8.12;
import "./DataTypes.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IVaultPriceFeed.sol";

contract VaultStorage   {
    using SafeMath for uint256;  
    using SafeERC20 for IERC20;


    uint256 internal constant BASIS_POINTS_DIVISOR = 10000;
    uint256 internal constant FUNDING_RATE_PRECISION = 1000000;
    uint256 internal constant PRICE_PRECISION = 10 ** 30;
    uint256 internal constant MIN_LEVERAGE = 10000; // 1x
    uint256 internal constant USDG_DECIMALS = 18;
    uint256 internal constant MAX_FEE_BASIS_POINTS = 500; // 5%
    uint256 internal constant MAX_LIQUIDATION_FEE_USD = 100 * PRICE_PRECISION; // 100 USD
    uint256 internal constant MIN_FUNDING_RATE_INTERVAL = 1 hours;
    uint256 internal constant MAX_FUNDING_RATE_FACTOR = 10000; // 1% 
         
    DataTypes.Slot0 internal slot0; 
    DataTypes.Slot1 internal slot1; 
    DataTypes.UpgradeVaultParams internal upgradeVaultParams;

    address internal  router;
    address internal  priceFeed;

    address internal  usdg;
    address internal  gov;
    address internal  vaultManager;

    mapping (address => mapping (address => bool)) internal  approvedRouters;
    address[] internal  allWhitelistedTokens;
    //---------------------
    
    mapping (address => DataTypes.AddrObj) internal addrObjs;
    mapping (address => DataTypes.FundingData) internal fundingDatas;

    //---------------------

    // tokenBalances 仅用于确定_transferIn值
    mapping (address => uint256) internal  tokenBalances;

      // usdgAmounts tracks the amount of USDG debt for each whitelisted token
      // 跟踪每个白名单代币的USDG债务金额
    mapping (address => uint256) internal  usdgAmounts;

    // maxUsdgAmounts allows setting a max amount of USDG debt for a token
    //允许为代币设置USDG债务的最大金额
    mapping (address => uint256) internal  maxUsdgAmounts;    
    // mapping (address => uint256) internal  poolAmounts;

    // reservedAmounts tracks the number of tokens reserved for open leverage positions
    //跟踪为未平仓杠杆仓位保留的代币数量
    mapping (address => uint256) internal  reservedAmounts;

    // bufferAmounts allows specification of an amount to exclude from swaps
    //允许指定从swaps中排除的金额
    // this can be used to ensure a certain amount of liquidity is available for leverage positions
    //这可用于确保杠杆头寸有一定数量的流动性
    mapping (address => uint256) internal  bufferAmounts;

    // guaranteedUsd tracks the amount of USD that is "guaranteed" by opened leverage positions
    //跟踪未平仓杠杆头寸“担保”的美元金额
    // this value is used to calculate the redemption values for selling of USDG
    //该值用于计算卖出USDG的赎回值
    // this is an estimated amount, it is possible for the actual guaranteed value to be lower 
    // in the case of sudden price decreases, the guaranteed value should be corrected
    // after liquidations are carried out
    //这是一个估计金额，如果价格突然下降，实际担保价值可能会降低，在清算结束后，应在清算结束之后更正担保价值
    mapping (address => uint256) internal  guaranteedUsd;

    // cumulativeFundingRates tracks the funding rates based on utilization
    //根据利用率跟踪资金率
    mapping (address => uint256) internal  cumulativeFundingRates;

    // positions tracks all open positions
    mapping (bytes32 => DataTypes.Position) internal positions;
    mapping (address => uint256) internal  globalShortSizes;
    mapping (address => uint256) internal  globalShortAveragePrices;

// poolAmounts tracks the number of received tokens that can be used for leverage
    //跟踪可用于杠杆作用的接收令牌的数量
    // this is tracked separately from tokenBalances to exclude funds that are deposited as margin collateral
    //这与tokenBalance分开跟踪，以排除作为保证金抵押品存入的资金
     mapping (address => uint256)     internal poolAmounts;

    function _transferIn(address _token) internal returns (uint256) {
        uint256 prevBalance = tokenBalances[_token]; 
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;
        return nextBalance.sub(prevBalance);
    }

    function _transferOut(address _token, uint256 _amount, address _receiver) internal {
        IERC20(_token).safeTransfer(_receiver, _amount);
        tokenBalances[_token] = IERC20(_token).balanceOf(address(this));
    }

    event IncreasePoolAmount(address token, uint256 amount);
    event DecreasePoolAmount(address token, uint256 amount);

    function _decreasePoolAmount(address _token, uint256 _amount) internal {
        poolAmounts[_token] = poolAmounts[_token].sub(_amount, "Vault: poolAmount exceeded");
        require(reservedAmounts[_token] <= poolAmounts[_token], "50");
        emit DecreasePoolAmount(_token, _amount);
    }

    function _increasePoolAmount(address _token, uint256 _amount) internal {
        uint256 _local = poolAmounts[_token];
        _local = _local.add(_amount);
        uint256 balance = IERC20(_token).balanceOf(address(this));
        require(_local <= balance, "49");
        poolAmounts[_token] = _local;
        emit IncreasePoolAmount(_token, _amount);
    } 
    
    function tokenToUsdMin(address _token, uint256 _tokenAmount) public  view returns (uint256) {
        if (_tokenAmount == 0) { return 0; }
        uint256 price = IVaultPriceFeed(priceFeed).getPrice(_token, false, slot0.includeAmmPrice, slot1.useSwapPricing);
        uint256 decimals = addrObjs[_token].tokenDecimals;
        return _tokenAmount.mul(price).div(10 ** decimals);
    }
}









 

    // function setInManagerMode(bool _inManagerMode) external  {
    //     _onlyGov();
    //     slot1.inManagerMode = _inManagerMode;
    // }
    // function isManager(address _account) external view returns (bool){
    //     return addrObjs[_account].isManager;
    // }

    // function setManager(address _manager, bool _isManager) external  {
    //     _onlyGov();
    //     addrObjs[_manager].isManager = _isManager;
    // }

    // function setIninternalLiquidationMode(bool _ininternalLiquidationMode) external  {
    //     _onlyGov();
    //     slot1.ininternalLiquidationMode = _ininternalLiquidationMode;
    // }
    // function isLiquidator(address _account) external  view returns (bool){
    //     return addrObjs[_account].isLiquidator;
    // }

    // function setLiquidator(address _liquidator, bool _isActive) external  {
    //     _onlyGov();
    //     addrObjs[_liquidator].isLiquidator = _isActive;
    // }

    // function setIsSwapEnabled(bool _isSwapEnabled) external  {
    //     _onlyGov();
    //     slot0.isSwapEnabled = _isSwapEnabled;
    // }

    // function setIsLeverageEnabled(bool _isLeverageEnabled) external  {
    //     _onlyGov();
    //     slot0.isLeverageEnabled = _isLeverageEnabled;
    // }

    // function setMaxGasPrice(uint256 _maxGasPrice) external  {
    //     _onlyGov();
    //     slot1.maxGasPrice = uint32(_maxGasPrice);
    // }

    
    // function setMaxLeverage(uint256 _maxLeverage) external  {
    //     _onlyGov();
    //     _validate(_maxLeverage > MIN_LEVERAGE, 2);
    //     slot1.maxLeverage = uint32(_maxLeverage);
    // }

    // function setBufferAmount(address _token, uint256 _amount) external  {
    //     _onlyGov();
    //     bufferAmounts[_token] = _amount;
    // } 

    // function minProfitBasisPoints(address _token)  external view returns (uint256){
    //     return addrObjs[_token].minProfitBasisPoints;
    // }

    // function stableTokens(address _token)  external view returns (bool){
    //     return addrObjs[_token].stableTokens;
    // }

    // function shortableTokens(address _token)  external view returns (bool){
    //     return addrObjs[_token].shortableTokens;
    // }
//  function feeReserves(address _token)  external view returns (uint256){
//         return addrObjs[_token].feeReserves;
//     }
// function tokenDecimals(address _token)  external view returns (uint256){
//         return addrObjs[_token].tokenDecimals;
//     }
//     function tokenWeights(address _token) external view returns (uint256){
//         return addrObjs[_token].tokenWeights;
//     }