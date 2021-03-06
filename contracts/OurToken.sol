pragma solidity ^0.4.18;

import 'zeppelin-solidity/contracts/token/StandardToken.sol';


contract OurToken is StandardToken {

    // data structures
    enum States {
        Initial, // deployment time
        ValuationSet,
        Ico, // whitelist addresses, accept funds, update balances
        Underfunded, // ICO time finished and minimal amount not raised
        Operational, // manage contests
        Paused         // for contract upgrades
    }

    //should be constant, but is not, to avoid compiler warning
    address public constant RAKE_EVENT_PLACEHOLDER_ADDR = 0x0000000000000000000000000000000000000000;

    string public constant name = "OurToken";  //

    string public constant symbol = "FRM";

    uint8 public constant decimals = 18;

    mapping (address => bool) public whitelist;

    address public initialHolder;

    address public stateControl;

    address public whitelistControl;

    address public withdrawControl;

    States public state;

    uint256 public weiICOMinimum;

    uint256 public weiICOMaximum;

    uint256 public silencePeriod;

    uint256 public startAcceptingFundsBlock;

    uint256 public endBlock;

    uint256 public numberFRMPerETH; //number of FRM per ETH

    mapping (address => uint256) lastRakePoints;

    uint256 constant POINT_MULTIPLIER = 1e18; //100% = 1*10^18 points
    uint256 totalRakePoints; //total amount of rakes ever paid out as a points value. increases monotonically, but the number range is 2^256, that's enough.
    uint256 unclaimedRakes; //amount of coins unclaimed. acts like a special entry to balances
    uint256 constant PERCENT_FOR_SALE = 30;

    mapping (address => bool) public contests; // true if this address holds a contest

    //this creates the contract and stores the owner. it also passes in 3 addresses to be used later during the lifetime of the contract.
    function OurToken(address _stateControl, address _whitelistControl, address _withdraw, address _initialHolder) public {
        initialHolder = _initialHolder;
        stateControl = _stateControl;
        whitelistControl = _whitelistControl;
        withdrawControl = _withdraw;
        moveToState(States.Initial);
        weiICOMinimum = 0;
        //to be overridden
        weiICOMaximum = 0;
        endBlock = 0;
        numberFRMPerETH = 0;
        totalSupply = 2000000000 * POINT_MULTIPLIER;
        //sets the value in the superclass.
        balances[initialHolder] = totalSupply;
        //initially, initialHolder has 100%
    }

    event ContestAnnouncement(address addr);

    event Whitelisted(address addr);

    event Credited(address addr, uint balance, uint txAmount);

    event StateTransition(States oldState, States newState);

    modifier onlyWhitelist() {
        require(msg.sender == whitelistControl);
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == initialHolder);
        _;
    }

    modifier onlyStateControl() {
        require(msg.sender == stateControl);
        _;
    }

    modifier onlyWithdraw() {
        require(msg.sender == withdrawControl);
        _;
    }

    modifier requireState(States _requiredState) {
        require(state == _requiredState);
        _;
    }

    /**
    BEGIN ICO functions
    */
    // ICO contract configuration function
    // newEthICOMinimum is the minimum amount of funds to raise
    // newEthICOMaximum is the maximum amount of funds to raise
    // silencePeriod is a number of blocks to wait after starting the ICO. No funds are accepted during the silence period. It can be set to zero.
    // newEndBlock is the absolute block number at which the ICO must stop. It must be set after now + silence period.
    function updateEthICOThresholds(uint256 _newWeiICOMinimum, uint256 _newWeiICOMaximum, uint256 _silencePeriod, uint256 _newEndBlock)
    public
    onlyStateControl
    {
        require(state == States.Initial || state == States.ValuationSet);
        require(_newWeiICOMaximum > _newWeiICOMinimum);
        require(block.number + silencePeriod < _newEndBlock);
        require(block.number < _newEndBlock);
        weiICOMinimum = _newWeiICOMinimum;
        weiICOMaximum = _newWeiICOMaximum;
        silencePeriod = _silencePeriod;
        endBlock = _newEndBlock;
        // initial conversion rate of numberFRMPerETH set now, this is used during the Ico phase.
        numberFRMPerETH = ((totalSupply * PERCENT_FOR_SALE) / 100) / weiICOMaximum;
        // check POINT_MULTIPLIER
        moveToState(States.ValuationSet);
    }

    function startICO()
    public
    onlyStateControl
    requireState(States.ValuationSet) 
    {
        require(block.number < endBlock);
        require(block.number + silencePeriod < endBlock);
        startAcceptingFundsBlock = block.number + silencePeriod;
        moveToState(States.Ico);
    }

    //this is the main funding function, it updates the balances of FRM during the ICO.
    //no particular incentive schemes have been implemented here
    //it is only accessible during the "ICO" phase.
    function() public payable
    requireState(States.Ico) 
    {
        require(whitelist[msg.sender] == true);
        require(this.balance <= weiICOMaximum); //note that msg.value is already included in this.balance
        require(block.number < endBlock);
        require(block.number >= startAcceptingFundsBlock);
        uint256 numberFRMTokenIncrease = msg.value * numberFRMPerETH;
        balances[initialHolder] -= numberFRMTokenIncrease;
        balances[msg.sender] += numberFRMTokenIncrease;
        Credited(msg.sender, balances[msg.sender], msg.value);
    }

    function endICO() 
    public 
    onlyStateControl 
    requireState(States.Ico) 
    {
        if (this.balance < weiICOMinimum) {
            moveToState(States.Underfunded);
        } else {
            burnUnsoldCoins();
            moveToState(States.Operational);
        }
    }

    function anyoneEndICO()
    public
    requireState(States.Ico)
    {
        require(block.number > endBlock);
        if (this.balance < weiICOMinimum) {
            moveToState(States.Underfunded);
        } else {
            burnUnsoldCoins();
            moveToState(States.Operational);
        }
    }

    function addToWhitelist(address _whitelisted)
    public
    onlyWhitelist
        //    requireState(States.Ico)
    {
        whitelist[_whitelisted] = true;
        Whitelisted(_whitelisted);
    }

    //emergency pause for the ICO
    function pause()
    public
    onlyStateControl
    requireState(States.Ico)
    {
        moveToState(States.Paused);
    }

    //in case we want to completely abort
    function abort()
    public
    onlyStateControl
    requireState(States.Paused)
    {
        moveToState(States.Underfunded);
    }

    //un-pause
    function resumeICO()
    public
    onlyStateControl
    requireState(States.Paused)
    {
        moveToState(States.Ico);
    }

    //in case of a failed/aborted ICO every investor can get back their money
    function requestRefund()
    public
    requireState(States.Underfunded)
    {
        require(balances[msg.sender] > 0);
        //there is no need for updateAccount(msg.sender) since the token never became active.
        uint256 payout = balances[msg.sender] / numberFRMPerETH;
        //reverse calculate the amount to pay out
        balances[msg.sender] = 0;
        msg.sender.transfer(payout);
    }

    //after the ico has run its course, the withdraw account can drain funds bit-by-bit as needed.
    function requestPayout(uint _amount)
    public
    onlyWithdraw //very important!
    requireState(States.Operational)
    {
        msg.sender.transfer(_amount);
    }
    /**
    END ICO functions
    */

    /**
    BEGIN ERC20 functions
    */
    function balanceOf(address _account)
    public
    constant
    returns (uint256 balance) 
    {
        return balances[_account] + rakesOwing(_account);
    }

    function transfer(address _to, uint256 _value)
    public
    requireState(States.Operational)
    updateAccount(msg.sender) //update senders rake before transfer, so they can access their full balance
    updateAccount(_to) //update receivers rake before transfer as well, to avoid over-attributing rake
    enforceRake(msg.sender, _value)
    returns (bool success) 
    {
        require(balances[msg.sender] >= _value);           // Check if the sender has enough
        require(balances[_to] + _value >= balances[_to]); // Check for overflows
        return super.transfer(_to, _value);
    }

    function transferFrom(address _from, address _to, uint256 _value)
    public
    requireState(States.Operational)
    updateAccount(_from) //update senders rake before transfer, so they can access their full balance
    updateAccount(_to) //update receivers rake before transfer as well, to avoid over-attributing rake
    enforceRake(_from, _value)
    returns (bool success) 
    {
        return super.transferFrom(_from, _to, _value);
    }

    function payRake(uint256 _value)
    public
    requireState(States.Operational)
    updateAccount(msg.sender)
    returns (bool success) 
    {
        return payRakeInternal(msg.sender, _value);
    }

    // registerContest declares a contest to FRMToken.
    // It must be called from an address that has FRMToken.
    // This address is recorded as the contract admin.
    function registerContest() public {
        contests[msg.sender] = true;
        ContestAnnouncement(msg.sender);
    }

    function moveToState(States _newState) internal {
        StateTransition(state, _newState);
        state = _newState;
    }

    function burnUnsoldCoins() internal {
        uint256 soldcoins = this.balance * numberFRMPerETH;
        totalSupply = soldcoins * 100 / PERCENT_FOR_SALE;
        balances[initialHolder] = totalSupply - soldcoins;
        //slashing the initial supply, so that the ico is selling 30% total
    }

    function payRakeInternal(address _sender, uint256 _value)
    internal
    returns (bool success) 
    {
        if (balances[_sender] <= _value) {
            return false;
        }
        if (_value != 0) {
            Transfer(_sender, RAKE_EVENT_PLACEHOLDER_ADDR, _value);
            balances[_sender] -= _value;
            unclaimedRakes += _value;
            //   calc amount of points from total:
            uint256 pointsPaid = _value * POINT_MULTIPLIER / totalSupply;
            totalRakePoints += pointsPaid;
        }
        return true;
    }

    /**
    END ERC20 functions
    */
    /**
    BEGIN Rake modifier updateAccount
    */
    modifier updateAccount(address _account) {
        uint256 owing = rakesOwing(_account);
        if (owing != 0) {
            unclaimedRakes -= owing;
            balances[_account] += owing;
            Transfer(RAKE_EVENT_PLACEHOLDER_ADDR, _account, owing);
        }
        //also if 0 this needs to be called, since lastRakePoints need the right value
        lastRakePoints[_account] = totalRakePoints;
        _;
    }

    //todo use safemath.sol
    function rakesOwing(address _account)
    internal
    constant
    returns (uint256) {
        //returns always > 0 value
        //how much is _account owed, denominated in points from total supply
        uint256 newRakePoints = totalRakePoints - lastRakePoints[_account];
        //always positive
        //weigh by my balance (dimension HC*10^18)
        uint256 basicPoints = balances[_account] * newRakePoints;
        //still positive
        //normalize to dimension HC by moving comma left by 18 places
        return (basicPoints) / POINT_MULTIPLIER;
    }
    /**
    END Rake modifier updateAccount
    */

    // contest management functions
    modifier enforceRake(address _contest, uint256 _value) {
        //we calculate 1% of the total value, rounded up. division would round down otherwise.
        //explicit brackets illustrate that the calculation only round down when dividing by 100, to avoid an expression
        // like value * (99/100)
        if (contests[_contest]) {
            uint256 toPay = _value - ((_value * 99) / 100);
            bool paid = payRakeInternal(_contest, toPay);
            require(paid);
        }
        _;
    }
    // all functions require FRMToken operational state
}