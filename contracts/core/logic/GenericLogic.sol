pragma solidity ^0.8.12;
// import "./DataTypes.sol";
// import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../DataTypes.sol";
import "../interfaces/IVaultPriceFeed.sol";

library GenericLogic { 
    using SafeMath for uint256;  

    // 一个账户, 一个品种, 一个方向, 对应一个position key(稳定币只能做空, 山寨币只能做多, 因此无法同时开多/开空)
    function getPositionKey(address _account, address _collateralToken, address _indexToken, bool _isLong) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        ));
    }
  
    function getPositionFee(uint256 _sizeDelta, uint256 _BASIS_POINTS_DIVISOR, uint256 marginFeeBasisPoints) internal pure returns (uint256) {
        if (_sizeDelta == 0) { return 0; }
        // size delta * (base_points_divisor - margin basis points )
        uint256 afterFeeUsd = _sizeDelta.mul(_BASIS_POINTS_DIVISOR.sub(marginFeeBasisPoints)).div(_BASIS_POINTS_DIVISOR);
        return _sizeDelta.sub(afterFeeUsd);
    }
     
   
    
}