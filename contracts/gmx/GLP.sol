// SPDX-License-Identifier: MIT

pragma solidity ^0.8.12;

import "../tokens/MintableBaseToken.sol";

contract GLP is MintableBaseToken {
    constructor()   MintableBaseToken("GMX LP", "GLP", 0) {
    }

    function id() external pure returns (string memory _name) {
        return "GLP";
    }
}
