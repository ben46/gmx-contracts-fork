pragma solidity ^0.8.12;

interface IVaultManager{
    event BuyUSDG(address account, address token, uint256 tokenAmount, uint256 usdgAmount, uint256 feeBasisPoints);    
    event SellUSDG(address account, address token, uint256 usdgAmount, uint256 tokenAmount, uint256 feeBasisPoints);
    event Swap(address account, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, uint256 amountOutAfterFees, uint256 feeBasisPoints);

      event IncreaseUsdgAmount(address token, uint256 amount);
    event DecreaseUsdgAmount(address token, uint256 amount);
  
        event CollectSwapFees(address token, uint256 feeUsd, uint256 feeTokens);

    // function buyUSDG(address _token, address _receiver) external    returns (uint256) ;
    // function sellUSDG(address _token, address _receiver) external     returns (uint256) ;
    // function swap(address _tokenIn, address _tokenOut, address _receiver) external     returns (uint256) ;

}