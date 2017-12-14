pragma solidity ^0.4.18;

import './SafeMath.sol';
import './interfaces/IERC20.sol';
import './interfaces/ICustomers.sol';
import './interfaces/ISTRegistrar.sol';
import './interfaces/ICompliance.sol';
import './interfaces/ITemplate.sol';
import './interfaces/ISTO.sol';

contract SecurityToken is IERC20 {

    using SafeMath for uint256;

    uint256 public version = 1;

    // Instance of the POLY token contract
    IERC20 public POLY;

    // Instance of the Compliance contract
    ICompliance public PolyCompliance;

    // Instance of the Template contract
    ITemplate public Template;

    // Instance of the Customers contract
    ICustomers public PolyCustomers;

    // ERC20 Fields
    string public name;
    uint8 public decimals;
    bytes8 public symbol;
    address public owner;
    uint256 public totalSupply;
    mapping (address => mapping (address => uint256)) allowed;
    mapping (address => uint256) balances;

    // Template
    address public delegate;
    bytes32 public complianceProof;
    address[] public KYC;

    // Security token shareholders
    struct Shareholder {
        address verifier;
        bool allowed;
        uint8 role;
    }
    mapping(address => Shareholder) public shareholders;

    // STO address
    address public STO;
    uint256 public maxPoly;

    // The start and end time of the STO
    uint256 public startSTO;
    uint256 public endSTO;

    // POLY allocations
    struct Allocation {
        uint256 amount;
        uint256 vestingPeriod;
        uint8 quorum;
        uint256 yayVotes;
        uint256 yayPercent;
        bool frozen;
        mapping (address => bool) votes;
    }
    mapping(address => Allocation) allocations;

		// Security Token Offering statistics
    mapping (address => uint256) contributedToSTO;
		uint tokensIssuedBySTO = 0;

    // Notifications
    event LogTemplateSet(address indexed _delegateAddress, address _template, address indexed _KYC);
    event LogUpdatedComplianceProof(bytes32 merkleRoot, bytes32 _complianceProofHash);
    event LogSetSTOContract(address _STO, address indexed _STOtemplate, address indexed _auditor, uint256 _startTime, uint256 _endTime);
    event LogNewWhitelistedAddress(address _KYC, address _shareholder, uint8 _role);
    event LogVoteToFreeze(address _recipient, uint256 _yayPercent, uint8 _quorum, bool _frozen);

    modifier onlyOwner() {
        require (msg.sender == owner);
        _;
    }

    modifier onlyDelegate() {
        require (msg.sender == delegate);
        _;
    }

    modifier onlyOwnerOrDelegate() {
        require (msg.sender == delegate || msg.sender == owner);
        _;
    }

		modifier onlySTO() {
			require (msg.sender == address(STO));
			_;
		}

    modifier onlyShareholder() {
        require (shareholders[msg.sender].allowed == true);
        _;
    }

    /* @dev Set default security token parameters
    @param _name Name of the security token
    @param _ticker Ticker name of the security
    @param _totalSupply Total amount of tokens being created
    @param _owner Ethereum address of the security token owner
    @param _maxPoly Amount of POLY being raised
    @param _lockupPeriod Length of time raised POLY will be locked up for dispute
    @param _quorum Percent of initial investors required to freeze POLY raise
    @param _polyTokenAddress Ethereum address of the POLY token contract
    @param _polyCustomersAddress Ethereum address of the PolyCustomers contract
    @param _polyComplianceAddress Ethereum address of the PolyCompliance contract */
    function SecurityToken(
        string _name,
        bytes8 _ticker,
        uint256 _totalSupply,
        address _owner,
        uint256 _maxPoly,
        uint256 _lockupPeriod,
        uint8 _quorum,
        address _polyTokenAddress,
        address _polyCustomersAddress,
        address _polyComplianceAddress
    ) public
    {
        decimals = 0;
        name = _name;
        symbol = _ticker;
        owner = _owner;
        maxPoly = _maxPoly;
        totalSupply = _totalSupply;
        balances[_owner] = _totalSupply;
        POLY = IERC20(_polyTokenAddress);
        PolyCustomers = ICustomers(_polyCustomersAddress);
        PolyCompliance = ICompliance(_polyComplianceAddress);
        allocations[owner] = Allocation(0, _lockupPeriod, _quorum, 0, 0, false);
    }

    /* @dev `selectTemplate` Select a proposed template for the issuance
    @param _templateIndex Array index of the delegates proposed template
    @return bool success */
    function selectTemplate(uint8 _templateIndex) public onlyOwner returns (bool success) {
        address _template = PolyCompliance.getTemplateByProposal(this, _templateIndex);
        require(_template != address(0));
        Template = ITemplate(_template);
        var (_fee, _quorum, _vestingPeriod, _delegate, _KYC) = Template.getUsageDetails();
        require(POLY.balanceOf(this) >= _fee);
        allocations[_delegate] = Allocation(_fee, _vestingPeriod, _quorum, 0, 0, false);
        delegate = _delegate;
        KYC[0] = _KYC;
        PolyCompliance.updateTemplateReputation(_template, _templateIndex);
        LogTemplateSet(_delegate, _template, _KYC);
        return true;
    }

    /* @dev Update compliance proof hash for the issuance
    @param _newMerkleRoot New merkle root hash of the compliance Proofs
    @param _complianceProof Compliance Proof hash
    @return bool success */
    function updateComplianceProof(
        bytes32 _newMerkleRoot,
        bytes32 _complianceProof
    ) public onlyOwnerOrDelegate returns (bool success)
    {
        complianceProof = _newMerkleRoot;
        LogUpdatedComplianceProof(_newMerkleRoot, _complianceProof);
        return true;
    }

    /* @dev Select an security token offering proposal for the issuance
    @param _offeringProposalIndex Array index of the STO proposal
    @param _startTime Start of issuance period
    @param _endTime End of issuance period
    @return bool success */
    function selectOfferingProposal (
        uint8 _offeringProposalIndex,
        uint256 _startTime,
        uint256 _endTime
    ) public onlyDelegate returns (bool success)
    {
        var (_stoContract, _auditor, _vestingPeriod, _quorum, _fee) = PolyCompliance.getOfferingByProposal(this, _offeringProposalIndex);
        require(_stoContract != address(0));
        require(complianceProof != 0);
        require(delegate != address(0));
        require(_startTime > now && _endTime > _startTime);
        require(POLY.balanceOf(this) >= allocations[delegate].amount + _fee);
        allocations[_auditor] = Allocation(_fee, _vestingPeriod, _quorum, 0, 0, false);
        STO = ISTO(_stoContract);
        shareholders[address(STO)] = Shareholder(this, true, 5);
        startSTO = _startTime;
        endSTO = _endTime;
        PolyCompliance.updateOfferingReputation(_stoContract, _offeringProposalIndex);
        LogSetSTOContract(STO, _stoContract, _auditor, _startTime, _endTime);
        return true;
    }

    /* @dev Add a verified address to the Security Token whitelist
    @param _whitelistAddress Address attempting to join ST whitelist
    @return bool success */
    function addToWhitelist(uint8 KYCProviderIndex, address _whitelistAddress) public returns (bool success) {
        if (now > endSTO) {
          require(KYC[KYCProviderIndex] == msg.sender);
        } else {
          require(KYC[0] == msg.sender);
        }
        var (jurisdiction, accredited, role, verified, expires) = PolyCustomers.getCustomer(msg.sender, _whitelistAddress);
        require(verified && expires > now);
        require(Template.checkTemplateRequirements(jurisdiction, accredited, role));
        shareholders[_whitelistAddress] = Shareholder(msg.sender, true, role);
        LogNewWhitelistedAddress(msg.sender, _whitelistAddress, role);
        return true;
    }

    /* @dev Allow POLY allocations to be withdrawn by owner, delegate, and the STO auditor at appropriate times
    @return bool success */
    function withdrawPoly() public returns (bool success) {
  			if (delegate == address(0)) {
          return POLY.transfer(owner, POLY.balanceOf(this));
        } else {
  				require(now > endSTO + allocations[msg.sender].vestingPeriod);
          require(allocations[msg.sender].frozen == false);
          require(allocations[msg.sender].amount > 0);
  				require(POLY.transfer(msg.sender, allocations[msg.sender].amount));
          allocations[msg.sender].amount = 0;
          return true;
        }
    }

    /* @dev Vote to freeze the fee of a certain network participant
    @param _recipient The fee recipient being protested
    @return bool success */
    function voteToFreeze(address _recipient) public onlyShareholder returns (bool success) {
        require(delegate != address(0));
        require(now > endSTO);
        require(now < endSTO + allocations[_recipient].vestingPeriod);
        require(allocations[_recipient].votes[msg.sender] == false);
        allocations[_recipient].yayVotes = allocations[_recipient].yayVotes + contributedToSTO[msg.sender];
        allocations[_recipient].yayPercent = allocations[_recipient].yayVotes.mul(100).div(tokensIssuedBySTO);
        if (allocations[_recipient].yayPercent > allocations[_recipient].quorum) {
          allocations[_recipient].frozen = true;
        }
        LogVoteToFreeze(_recipient, allocations[_recipient].yayPercent, allocations[_recipient].quorum, allocations[_recipient].frozen);
        return true;
    }

	  /* @dev `issueSecurityTokens` is used by the STO to keep track of STO investors
    @param _contributor The address of the person whose contributing
    @param _amountOfSecurityTokens The amount of ST to pay out.
    @param _polyContributed The amount of POLY paid for the security tokens. */
    function issueSecurityTokens(address _contributor, uint256 _amountOfSecurityTokens, uint256 _polyContributed) public onlySTO returns (bool success) {
        require(startSTO > now && endSTO < now);
        require(POLY.transferFrom(_contributor, this, _polyContributed));
        require(tokensIssuedBySTO.add(_amountOfSecurityTokens) <= balanceOf(this));
        require(maxPoly > allocations[owner].amount + _polyContributed);
        tokensIssuedBySTO = tokensIssuedBySTO.add(_amountOfSecurityTokens);
        contributedToSTO[_contributor] = contributedToSTO[_contributor].add(_amountOfSecurityTokens);
        allocations[owner].amount = allocations[owner].amount + _polyContributed;
        return true;
    }

    /// Get token details
    function getTokenDetails() view public returns (address, address, bytes32, address, address) {
        return (Template, delegate, complianceProof, STO, KYC[0]);
    }

    /* @dev Trasfer tokens from one address to another
    @param _to Ethereum public address to transfer tokens to
    @param _value Amount of tokens to send
    @return bool success */
    function transfer(address _to, uint256 _value) public returns (bool success) {
        if (shareholders[_to].allowed && balances[msg.sender] >= _value && _value > 0) {
            balances[msg.sender] = balances[msg.sender].sub(_value);
            balances[_to] = balances[_to].add(_value);
            Transfer(msg.sender, _to, _value);
            return true;
        } else {
            return false;
        }
    }

    /* @dev Allows contracts to transfer tokens on behalf of token holders
    @param _from Address to transfer tokens from
    @param _to Address to send tokens to
    @param _value Number of tokens to transfer
    @return bool success */
    function transferFrom(address _from, address _to, uint256 _value) public returns (bool success) {
        if (shareholders[_to].allowed && shareholders[msg.sender].allowed && balances[_from] >= _value && allowed[_from][msg.sender] >= _value && _value > 0) {
            uint256 _allowance = allowed[_from][msg.sender];
            balances[_from] = balances[_from].sub(_value);
            allowed[_from][msg.sender] = _allowance.sub(_value);
            balances[_to] = balances[_to].add(_value);
            Transfer(_from, _to, _value);
            return true;
        } else {
            return false;
        }
    }

    /* @param _owner The address from which the balance will be retrieved
    @return The balance */
    function balanceOf(address _owner) public constant returns (uint256 balance) {
        return balances[_owner];
    }

    /* @dev Approve transfer of tokens manually
    @param _spender Address to approve transfer to
    @param _value Amount of tokens to approve for transfer
    @return bool success */
    function approve(address _spender, uint256 _value) public returns (bool success) {
        if (shareholders[_spender].allowed) {
            require(_value != 0);
            allowed[msg.sender][_spender] = _value;
            Approval(msg.sender, _spender, _value);
            return true;
        } else {
            return false;
        }
    }

    /* @param _owner The address of the account owning tokens
    @param _spender The address of the account able to transfer the tokens
    @return Amount of remaining tokens allowed to spent */
    function allowance(address _owner, address _spender) public constant returns (uint256 remaining) {
        return allowed[_owner][_spender];
    }
}
