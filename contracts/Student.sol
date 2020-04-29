pragma solidity 0.6.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./Classroom.sol";
import "./UniversityFund.sol";

contract Student is Ownable {
    using SafeMath for uint256;

    bytes32 _name;
    address _universityAddress;
    address[] _classroomAddress;

    constructor(bytes32 name, address universityAddress) public {
        _name = name;
        _universityAddress = universityAddress;
    }

}