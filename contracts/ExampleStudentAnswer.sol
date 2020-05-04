pragma solidity 0.6.6;

import "./IStudentAnswer.sol";
import "./StudentApplication.sol";


contract ExampleStudentAnswer is IStudentAnswer, Ownable {
    bytes32 _seedAnswer;
    StudentApplication _application;

    constructor(address application) public {
        _application = StudentApplication(application);
    }

    function getOwner() external view override returns (address) {
        // note: the student address may be hardcoded and still the answer would pass the check. Perhaps it is good enough if the student somehow don't need protection in his answer contract
        return owner();
    }

    function getSeed() external view override returns (bytes32) {
        return _seedAnswer;
    }

    function solve() public onlyOwner {
        _application.registerAnswer();
        bytes32 hint1 = _application.getHint(0);
        bytes32 hint2 = _application.getHint(1);
        _seedAnswer = ~(hint1 ^ hint2);
    }
}