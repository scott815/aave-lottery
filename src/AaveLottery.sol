// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPool} from "aave-v3-core/contracts/interfaces/IPool.sol";
import {IAToken} from "aave-v3-core/contracts/interfaces/IAToken.sol";
import {DataTypes} from "aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol";
import {WadRayMath} from "aave-v3-core/contracts/protocol/libraries/math/WadRayMath.sol";


// 1000 dai -> 1000 adai (scaled balance 990)
// 1005 adai -> 990 sclaedbalande + index = 1005 aDai


contract AaveLottery {
    using SafeERC20 for IERC20;
    using WadRayMath for uint256;

    struct Round {
        uint256 endTime;
        uint256 totalStake;
        uint256 award;
        uint256 winnerTicket;
        address winner;
        uint256 scaledBalanceStake;
    }

    struct Ticket {
        uint256 stake;
        uint256 segmentStart;
        bool exited;
    }

    uint256 public roundDuration; // seconds
    uint256 public currentId; // current round
    IERC20 public underlying; // asset

    IPool private aave;
    IAToken private aToken;

    //roundId => Round
    mapping(uint256 => Round) public rounds;

    //roundId => userAddress => Ticket
    mapping(uint256 => mapping(address => Ticket)) public tickets;

    constructor(uint256 _roundDuration, address _underlying, address _aavePool) {
        roundDuration = _roundDuration;
        underlying = IERC20(_underlying);
        aave = IPool(_aavePool);
        DataTypes.ReserveData memory data = aave.getReserveData(_underlying);
        require(data.aTokenAddress != address(0), 'ATOKEN_NOT_EXISITS');
        aToken = IAToken(data.aTokenAddress);

        underlying.approve(address(_aavePool), type(uint256).max);

        // Init first round
        rounds[currentId] = Round(
            block.timestamp + _roundDuration,
            0,
            0,
            0,
            address(0),
            0
        );
    }

    function getRound(uint256 roundId) external view returns (Round memory) {
        return rounds[roundId];
    }

    function getTicket(
        uint256 roundId,
        address user
    ) external view returns (Ticket memory) {
        return tickets[roundId][user];
    }

    function enter(uint256 amount) external {
        //checks
        require(
            tickets[currentId][msg.sender].stake == 0,
            "USER_ALREADY_PARTICIPENT"
        );
        //updates
        _updateState();
        // user enters
        tickets[currentId][msg.sender].segmentStart = rounds[currentId]
            .totalStake;
        tickets[currentId][msg.sender].stake = amount;
        rounds[currentId].totalStake += amount;

        // transfer fund in
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        // deposit funds int Aave Pool
        uint256 scaledBlanaceStakeBefore = aToken.scaledBalanceOf(address(this));
        aave.deposit(address(underlying), amount, address(this), 0);
        uint256 scaledBalanceStakeAfter = aToken.scaledBalanceOf(address(this));
        rounds[currentId].scaledBalanceStake += scaledBalanceStakeAfter - scaledBlanaceStakeBefore;

    }

    function exit(uint256 roundId) external {
        //checks
        require(tickets[roundId][msg.sender].exited == false, "ALREADY_EXITED");
        //updates
        _updateState();

        require(roundId < currentId, "CURRENT_LOTTERY");
        //user exits
        uint256 amount = tickets[roundId][msg.sender].stake;
        tickets[roundId][msg.sender].exited = true;
        rounds[roundId].totalStake -= amount;
        //tranfer funds out
        underlying.safeTransfer(msg.sender, amount);
    }

    function claim(uint256 roundId) external {
        //checks
        require(roundId < currentId, "CURRENT_LOTTERY");

        Ticket memory ticket = tickets[roundId][msg.sender];
        Round memory round = rounds[roundId];
        //check winner
        require(
            round.winnerTicket - ticket.segmentStart < ticket.stake,
            "NOT_WINNER"
        );
        require(round.winner == address(0), 'ALREADY_CLAIMED');
        round.winner = msg.sender;
        //transfer jackpot
        underlying.safeTransfer(msg.sender, round.award); 
    }

    function _drawWinner(uint total) internal view returns (uint256) {
        uint256 random = uint256(
            keccak256(
                abi.encodePacked(
                    block.timestamp,
                    rounds[currentId].totalStake,
                    currentId
                )
            )
        ); // [0, 2^256 -1]
        //
        return random % total; // 0 to total
    }

    function _updateState() internal {
        if (block.timestamp > rounds[currentId].endTime) {
            // award -- aave witdhraw
            // sclaedBalance + index = total amount of atokens
            uint256 index = aave.getReserveNormalizedIncome(address(underlying));
            uint256 aTokenBalance = rounds[currentId].scaledBalanceStake.rayMul(index);
            uint256 aaveAmount = aave.withdraw(address(underlying), aTokenBalance, address(this));
            //aave amoutn = principal + interest
            rounds[currentId].award = aaveAmount - rounds[currentId].totalStake;




            // lottery draw

            rounds[currentId].winnerTicket = _drawWinner(
                rounds[currentId].totalStake
            );

            //create a new round
            currentId += 1;
            rounds[currentId].endTime = block.timestamp + roundDuration;
        }
    }
}
