// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interfaces/IPriceFeed.sol";

contract PriceFeed is IPriceFeed {
    struct AnswerStruct{
        int176  answer;
        uint80  roundId;
    }

    AnswerStruct public answerStruct;
    
    string public override description = "PriceFeed";
    address public override aggregator;

    uint256 public decimals;

    address public gov;

    mapping (uint80 => int256) public answers;
    mapping (address => bool) public isAdmin;

    constructor()  {
        gov = msg.sender;
        isAdmin[msg.sender] = true;
    }

    function setAdmin(address _account, bool _isAdmin) public {
        require(msg.sender == gov, "PriceFeed: forbidden");
        isAdmin[_account] = _isAdmin;
    }

    function latestAnswer() public override view returns (int256) {
        return int256(answerStruct.answer);
    }

    function latestRound() public override view returns (uint80) {
        return answerStruct.roundId;
    }

    function setLatestAnswer(int256 _answer) public {
        require(isAdmin[gov], "PriceFeed: forbidden");
        AnswerStruct memory _local_anwer_struct = answerStruct;
        _local_anwer_struct.roundId = _local_anwer_struct.roundId + 1;
        require((_local_anwer_struct.answer = int176(_answer)) == _answer, "PriceFeed:cast error");
        answers[_local_anwer_struct.roundId] = _answer;
        answerStruct = _local_anwer_struct;
    }

    // returns roundId, answer, startedAt, updatedAt, answeredInRound
    function getRoundData(uint80 _roundId) public override view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (_roundId, answers[_roundId], 0, 0, 0);
    }
}
