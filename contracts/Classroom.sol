pragma solidity 0.6.6;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@chainlink/contracts/src/v0.6/ChainlinkClient.sol";
import "@chainlink/contracts/src/v0.6/interfaces/LinkTokenInterface.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router01.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";
import "./interface/IUniversity.sol";
import "./interface/IStudent.sol";
import "./interface/IClassroom.sol";
import "./interface/IStudentApplication.sol";
import "./interface/IClassroomChallenge.sol";
import "./interface/IStudentApplicationFactory.sol";
import "./StudentApplicationFactory.sol";
import "./MyUtils.sol";


contract Classroom is Ownable, ChainlinkClient, IClassroom {
    IUniversity public university;
    bool public openForApplication;
    bool public courseFinished;
    bool public classroomActive;
    bool _timestampAlarm;
    address[] _studentApplications;
    address[] _validStudentApplications;
    mapping(address => address) _studentApplicationsLink;
    address[] _studentsLookUp;
    address[] _applicationsLookUp;
    uint256 _endDate;
    uint256 _totalBalance;
    bytes32 _seed;

    //Classroom parameters
    bytes32 public name;
    uint24 public principalCut;
    uint24 public poolCut;
    int32 public minScore;
    uint256 public override entryPrice;
    uint256 public duration;

    IERC20 public daiToken;
    CERC20 public cToken;
    StudentApplicationFactory _studentApplicationFactory;
    address public _challengeAddress;

    //Chainlink config
    address _oracleRandom;
    bytes32 _requestIdRandom;
    uint256 _oraclePaymentRandom;
    address _oracleTimestamp;
    bytes32 _requestIdTimestamp;
    uint256 _oraclePaymentTimestamp;
    address _linkToken;

    //Uniswap Config
    address _uniswapLINK;
    address _uniswapDAI;
    IUniswapV2Router01 public _uniswapRouter;

    constructor(
        bytes32 _name,
        uint24 _principalCut,
        uint24 _poolCut,
        int32 _minScore,
        uint256 _entryPrice,
        uint256 _duration,
        address payable universityAddress,
        address challengeAddress,
        address daiAddress,
        address compoundAddress,
        address studentApplicationFactoryAddress
    ) public {
        name = _name;
        principalCut = _principalCut;
        poolCut = _poolCut;
        minScore = _minScore;
        entryPrice = _entryPrice;
        duration = _duration;
        university = IUniversity(universityAddress);
        _challengeAddress = challengeAddress;
        openForApplication = false;
        classroomActive = false;
        daiToken = IERC20(daiAddress);
        cToken = CERC20(compoundAddress);
        _studentApplicationFactory = StudentApplicationFactory(studentApplicationFactoryAddress);
    }

    event LogOpenApplications();
    event LogCloseApplications();
    event LogCourseFinished();
    event LogChangeChallenge(address);
    event LogChangeName(bytes32);
    event LogChangePrincipalCut(uint24);
    event LogChangePoolCut(uint24);
    event LogChangeMinScore(int32);
    event LogChangeEntryPrice(uint256);
    event LogChangeDuration(uint256);

    // @dev "Stack too deep" error if done in the constructor
    function configureOracles(
        address oracleRandom,
        bytes32 requestIdRandom,
        uint256 oraclePaymentRandom,
        address oracleTimestamp,
        bytes32 requestIdTimestamp,
        uint256 oraclePaymentTimestamp,
        address linkToken
    ) public onlyOwner {
        _oracleRandom = oracleRandom;
        _requestIdRandom = requestIdRandom;
        _oraclePaymentRandom = oraclePaymentRandom;
        _oracleTimestamp = oracleTimestamp;
        _requestIdTimestamp = requestIdTimestamp;
        _oraclePaymentTimestamp = oraclePaymentTimestamp;
        _linkToken = linkToken;
        require(
            LinkTokenInterface(_linkToken).balanceOf(address(this)) >= _oraclePaymentRandom,
            "Classroom: not enough Link tokens"
        );
        _generateSeed();
    }

    function configureUniswap(
        address uniswapLINK,
        address uniswapDAI,
        address uniswapRouter
    ) public onlyOwner {
        _uniswapLINK = uniswapLINK;
        _uniswapDAI = uniswapDAI;
        _uniswapRouter = IUniswapV2Router01(uniswapRouter);
    }

    function transferOwnershipClassroom(address newOwner) public override {
        transferOwnership(newOwner);
    }

    function changeName(bytes32 val) public onlyOwner {
        name = val;
        emit LogChangeName(name);
    }

    function changePrincipalCut(uint24 val) public onlyOwner {
        principalCut = val;
        emit LogChangePrincipalCut(principalCut);
    }

    function changePoolCut(uint24 val) public onlyOwner {
        poolCut = val;
        emit LogChangePoolCut(poolCut);
    }

    function changeMinScore(int32 val) public onlyOwner {
        minScore = val;
        emit LogChangeMinScore(minScore);
    }

    function changeEntryPrice(uint256 val) public onlyOwner {
        entryPrice = val;
        emit LogChangeEntryPrice(entryPrice);
    }

    function changeDuration(uint256 val) public onlyOwner {
        duration = val;
        emit LogChangeDuration(duration);
    }

    function changeChallenge(address addr) public onlyOwner {
        require(isClassroomEmpty(), "Classroom: can't change challenge now");
        _challengeAddress = addr;
        emit LogChangeChallenge(_challengeAddress);
    }

    function viewAllApplications()
        public
        view
        onlyOwner
        returns (address[] memory)
    {
        return _applicationsLookUp;
    }

    function viewMyApplication() public view override returns (address) {
        return viewApplication(_msgSender());
    }

    function viewApplication(address addr) public view returns (address) {
        require(
            addr == _msgSender() || _msgSender() == owner(),
            "Classroom: read permission denied"
        );
        return _studentApplicationsLink[addr];
    }

    function viewAllStudents()
        public
        view
        onlyOwner
        returns (address[] memory)
    {
        return _studentsLookUp;
    }

    function isClassroomEmpty() public view returns (bool) {
        return
            _studentApplications.length.add(_validStudentApplications.length) ==
            0;
    }

    function isCourseOngoing() public view returns (bool) {
        return _validStudentApplications.length > 0;
    }

    function openApplications() public onlyOwner {
        require(
            _oracleRandom != address(0),
            "Classroom: setup oracles first"
        );
        require(
            !openForApplication,
            "Classroom: applications are already opened"
        );
        require(
            _studentApplications.length == 0,
            "Classroom: students list not empty"
        );
        require(
            LinkTokenInterface(_linkToken).balanceOf(address(this)) >= _oraclePaymentTimestamp,
            "Classroom: not enough Link tokens"
        );
        openForApplication = true;
        emit LogOpenApplications();
    }

    function closeApplications() public onlyOwner {
        require(
            openForApplication,
            "Classroom: applications are already closed"
        );
        openForApplication = false;
        emit LogCloseApplications();
    }

    //public onlyOwner allow the professor to apply money before and after closing applications
    function applyDAI() public onlyOwner {
        uint256 balance = daiToken.balanceOf(address(this));
        if (balance <= 0) return;
        TransferHelper.safeApprove(address(daiToken), address(cToken), balance);
        cToken.mint(balance);
    }

    function studentApply() public override {
        require(
            _msgSender() != owner(),
            "Classroom: professor can't be its own student"
        );
        require(
            university.studentIsRegistered(_msgSender()),
            "Classroom: student is not registered"
        );
        require(openForApplication, "Classroom: applications closed");
        IStudent applicant = IStudent(_msgSender());
        require(
            applicant.score() >= minScore,
            "Classroom: student doesn't have enough score"
        );
        address application = _createStudentApplication(address(applicant));
        _studentApplications.push(application);
    }

    function _createStudentApplication(address student)
        internal
        returns (address)
    {
        address newApplication = _studentApplicationFactory.newStudentApplication(
            student,
            address(this),
            address(daiToken),
            _challengeAddress,
            generateNewSeed()
        );
        _studentApplicationsLink[student] = newApplication;
        university.registerStudentApplication(
            student,
            newApplication
        );
        _studentsLookUp.push(student);
        _applicationsLookUp.push(newApplication);
        return newApplication;
    }

    function generateNewSeed() internal view returns (bytes32) {
        return blockhash(0) ^ _seed;
    }

    function beginCourse() public onlyOwner {
        require(!openForApplication, "Classroom: applications are still open");
        require(
            daiToken.balanceOf(address(this)) == 0,
            "Classroom: invest all balance before begin"
        );
        checkApplications();
        _studentApplications = new address[](0);
        require(
            _validStudentApplications.length > 0,
            "Classroom: no ready application"
        );
        classroomActive = true;
        _setAlarm();
    }

    function checkApplications() internal {
        for (uint256 i = 0; i < _studentApplications.length; i++) {
            if (IStudentApplication(_studentApplications[i]).applicationState() == 1) {
                IStudentApplication(_studentApplications[i]).activate();
                _validStudentApplications.push(_studentApplications[i]);
            } else {
                IStudentApplication(_studentApplications[i]).expire();
            }
        }
    }

    function finishCourse() public onlyOwner {
        require(_timestampAlarm, "Classroom: too soon to finish course");
        require(
            _validStudentApplications.length > 0,
            "Classroom: no applications"
        );
        _totalBalance = _recoverInvestment();
        courseFinished = true;
        emit LogCourseFinished();
    }

    function _recoverInvestment() internal returns (uint256) {
        uint256 balance = cToken.balanceOfUnderlying(address(this));
        cToken.redeemUnderlying(balance);
        return balance;
    }

    function processResults() public onlyOwner {
        require(courseFinished, "Classroom: course not finished");
        require(
            _totalBalance <= daiToken.balanceOf(address(this)),
            "Classroom: not enough DAI to proceed"
        );
        (uint256 successCount, uint256 emptyCount) = _startAnswerVerification();
        (
            uint256 universityCut,
            uint256[] memory studentAllowances
        ) = _accountValues(successCount, emptyCount);
        _resolveStudentAllowances(studentAllowances);
        _resolveUniversityCut(universityCut);
        _updateStudentScores();
        _clearClassroom();
    }

    function _startAnswerVerification() internal returns (uint256, uint256) {
        uint256 successCount = 0;
        uint256 emptyCount = 0;
        for (uint256 i = 0; i < _validStudentApplications.length; i++) {
            IStudentApplication(_validStudentApplications[i]).registerFinalAnswer();
            uint256 appState = IStudentApplication(_validStudentApplications[i]).applicationState();
            if (appState == 3)
                successCount++;
            if (appState == 5)
                emptyCount++;
        }
        return (successCount, emptyCount);
    }

    function _accountValues(uint256 successCount, uint256 emptyCount)
        internal
        returns (uint256, uint256[] memory)
    {
        uint256 nStudents = _validStudentApplications.length;
        uint256 returnsPool = _totalBalance.sub(entryPrice.mul(nStudents));
        uint256 professorPaymentPerStudent = entryPrice.mul(principalCut).div(
            10**6
        );
        uint256 studentPrincipalReturn = entryPrice.sub(
            professorPaymentPerStudent
        );
        uint256 successPool = returnsPool.mul(successCount).div(nStudents);
        uint256 professorTotalPoolSuccessShare = successPool.mul(poolCut).div(
            10**6
        );
        uint256 successStudentPoolShare = returnsPool
            .sub(professorTotalPoolSuccessShare)
            .div(successCount);
        uint256[] memory studentAllowances = new uint256[](nStudents);
        for (uint256 i = 0; i < nStudents; i++) {
            uint256 appState = IStudentApplication(_validStudentApplications[i]).applicationState();
            if (appState == 3) {
                IStudentApplication(_validStudentApplications[i]).accountAllowance(
                    studentPrincipalReturn,
                    successStudentPoolShare
                );
                studentAllowances[i] = studentPrincipalReturn.add(
                    successStudentPoolShare
                );
            }
            if (appState == 4) {
                IStudentApplication(_validStudentApplications[i]).accountAllowance(
                    studentPrincipalReturn,
                    0
                );
                studentAllowances[i] = studentPrincipalReturn;
            }
            if (appState== 5)
                IStudentApplication(_validStudentApplications[i]).accountAllowance(0, 0);
        }
        uint24 uCut = university.cut();
        return (
            _calculateUniversityShare(emptyCount, 
                entryPrice,
                professorTotalPoolSuccessShare,
                uCut,
                nStudents,
                professorPaymentPerStudent
            ),
            studentAllowances
        );
    }

    function _calculateUniversityShare(uint256 emptyCount, uint256 _entryPrice, uint256 professorTotalPoolSuccessShare, uint24 uCut, uint256 nStudents, uint professorPaymentPerStudent) internal pure returns (uint){
        uint256 universityEmptyShare = emptyCount.mul(_entryPrice);
        uint256 universityPaymentShare = professorTotalPoolSuccessShare
            .mul(uCut)
            .div(10**6);
        uint256 notEmptyCount = nStudents.sub(emptyCount);
        uint256 universitySucessPoolShare = professorPaymentPerStudent
            .mul(notEmptyCount)
            .mul(uCut)
            .div(10**6);
        return universityEmptyShare
            .add(universityPaymentShare)
            .add(universitySucessPoolShare);
    }

    function _resolveStudentAllowances(uint256[] memory studentAllowances)
        internal
    {
        for (uint256 i = 0; i < _validStudentApplications.length; i++) {
            if (studentAllowances[i] > 0)
                TransferHelper.safeApprove
                    (address(daiToken),
                    address(_validStudentApplications[i]),
                    studentAllowances[i]
                );
        }
    }

    function _resolveUniversityCut(uint256 universityCut) internal {
        TransferHelper.safeTransfer(address(daiToken), address(university), universityCut);
    }

    function _updateStudentScores() internal {
        for (uint256 i = 0; i < _validStudentApplications.length; i++) {
            uint256 appState = IStudentApplication(_validStudentApplications[i]).applicationState();
            if (appState == 3)
                university.addStudentScore(
                    IStudentApplication(_validStudentApplications[i]).studentAddress(),
                    1
                );
            if (appState == 4)
                university.subStudentScore(
                    IStudentApplication(_validStudentApplications[i]).studentAddress(),
                    1
                );
            if (appState == 5)
                university.subStudentScore(
                    IStudentApplication(_validStudentApplications[i]).studentAddress(),
                    2
                );
        }
    }

    function _clearClassroom() internal {
        _validStudentApplications = new address[](0);
        withdrawAllResults();
        _totalBalance = 0;
        courseFinished = false;
        _timestampAlarm = false;
        _mutateSeed();
    }

    function _mutateSeed() internal {
        _seed = (_seed & blockhash(0)) | (_seed & blockhash(1));
    }

    function withdrawAllResults() public onlyOwner {
        daiToken.transferFrom(
            address(this),
            owner(),
            daiToken.balanceOf(address(this))
        );
    }

    function swapDAI_LINK(uint256 amount, uint256 deadline) public onlyOwner {
        require(
            _uniswapLINK != address(0),
            "University: setup uniswap first"
        );
        swapBlind(_uniswapDAI, _uniswapLINK, amount, deadline);
    }

    function swapLINK_DAI(uint256 amount, uint256 deadline) public onlyOwner {
        require(
            _uniswapLINK != address(0),
            "University: setup uniswap first"
        );
        swapBlind(_uniswapLINK, _uniswapDAI, amount, deadline);
    }

    function swapBlind(address tokenA, address tokenB, uint256 amount, uint256 deadline) internal {
        TransferHelper.safeApprove(tokenA, address(_uniswapRouter), amount);
        address[] memory path = new address[](2);
        path[0] = tokenA;
        path[1] = tokenB;
        _uniswapRouter.swapExactTokensForTokens(
            amount,
            0,
            path,
            address(this),
            deadline
        );
    }

    function _generateSeed() internal {
        Chainlink.Request memory req = buildChainlinkRequest(
            _requestIdRandom,
            address(this),
            this.fulfillGenerateSeed.selector
        );
        sendChainlinkRequestTo(_oracleRandom, req, _oraclePaymentRandom);
    }

    function fulfillGenerateSeed(bytes32 _requestId, uint256 data)
        public
        recordChainlinkFulfillment(_requestId)
    {
        _seed = keccak256(MyUtils._toBytes(data));
    }

    function _setAlarm() internal {
        Chainlink.Request memory req = buildChainlinkRequest(
            _requestIdTimestamp,
            address(this),
            this.fulfillGetTimestamp.selector
        );
        req.addUint("until", now + duration);
        sendChainlinkRequestTo(_oracleTimestamp, req, _oraclePaymentTimestamp);
    }

    function fulfillGetTimestamp(bytes32 _requestId)
        public
        recordChainlinkFulfillment(_requestId)
    {
        _timestampAlarm = true;
    }
}
